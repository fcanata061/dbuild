#!/bin/sh
# dbuild — gerenciador de receitas estilo BLFS em POSIX sh
# Recursos:
#  - build: baixar → sha256 → extrair (tar.{gz,bz2,xz,zst}, zip, tar) → aplicar patches (https/git) → preconfig → configure → build → check
#  - install: DESTDIR, hooks (preinstall/install/postinstall), strip opcional, empacotar com fakeroot (tar.xz), --pack-only, --no-package
#  - remove: desfaz instalação via manifest + hook postremove
#  - info/list/search: informações e descoberta
#  - sync: git pull do repositório de receitas
#  - upgrade: compara versão instalada x da receita e atualiza
#  - UX: colorido, spinner, logs por etapa
#
# Formato de receita (.recipe):
#   name="pkg" ; version="1.0" ; release="1"
#   sources<<EOF
#   https://site/pkg-1.0.tar.xz
#   EOF
#   sha256sums<<EOF
#   deadbeef... (uma linha por source; use "skip" para não checar)
#   EOF
#   patches<<EOF
#   https://site/fix.patch [SHA256]
#   git+https://github.com/user/repo.git@<ref>:path/to/patch.diff [SHA256]
#   EOF
#   preconfig<<'SH' ... SH
#   configure<<'SH'  ... SH
#   build<<'SH'      ... SH
#   check<<'SH'      ... SH
#   preinstall<<'SH' ... SH
#   install<<'SH'    ... SH    # deve respeitar DESTDIR
#   postinstall<<'SH'... SH
#   postremove<<'SH' ... SH

set -eu

###############################################################################
# Config / Paths
###############################################################################
DBUILD_ROOT=${DBUILD_ROOT:-"$PWD"}
DBUILD_CACHE_SOURCES=${DBUILD_CACHE_SOURCES:-"$DBUILD_ROOT/src"}
DBUILD_CACHE_PATCHES=${DBUILD_CACHE_PATCHES:-"$DBUILD_ROOT/patches"}
DBUILD_BUILD_DIR=${DBUILD_BUILD_DIR:-"$DBUILD_ROOT/build"}
DBUILD_LOG_DIR=${DBUILD_LOG_DIR:-"$DBUILD_ROOT/logs"}
DBUILD_DB_DIR=${DBUILD_DB_DIR:-"$DBUILD_ROOT/db"}
DBUILD_REPO_DIR=${DBUILD_REPO_DIR:-"$DBUILD_ROOT/repo"}
DBUILD_PKG_DIR=${DBUILD_PKG_DIR:-"$DBUILD_ROOT/pkg"}
DBUILD_COLOR=${DBUILD_COLOR:-auto}   # auto|always|never
DBUILD_SPINNER=${DBUILD_SPINNER:-dots} # dots|none
DBUILD_NO_CHECK=${DBUILD_NO_CHECK:-no}

# ensure dirs
mkdir -p "$DBUILD_CACHE_SOURCES" "$DBUILD_CACHE_PATCHES" \
         "$DBUILD_BUILD_DIR" "$DBUILD_LOG_DIR" \
         "$DBUILD_DB_DIR" "$DBUILD_REPO_DIR" "$DBUILD_PKG_DIR"

###############################################################################
# UX: colors / spinner / logs
###############################################################################
_is_tty(){ [ -t 1 ]; }
_use_color(){ case "$DBUILD_COLOR" in always) return 0;; never) return 1;; *) _is_tty;; esac }
if _use_color; then C_B='\033[34m'; C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_M='\033[35m'; C_0='\033[0m'; else C_B='';C_G='';C_Y='';C_R='';C_M='';C_0=''; fi
info(){ printf "%s▶%s %s\n" "$C_B" "$C_0" "$*"; }
ok(){   printf "%s✓%s %s\n" "$C_G" "$C_0" "$*"; }
warn(){ printf "%s!%s %s\n" "$C_Y" "$C_0" "$*"; }
err(){  printf "%s✗%s %s\n" "$C_R" "$C_0" "$*" >&2; }
die(){ err "$*"; exit 1; }

sp_start(){ _is_tty || return 0; [ "$DBUILD_SPINNER" = none ] && return 0; (
  i=0; s='|/-\\'; while :; do i=$(( (i+1)%4 )); printf "\r%s…%s %c " "$C_M" "$C_0" "$(printf %s "$s"|cut -c $((i+1)))"; sleep 0.1; done ) & SP=$!; }
sp_stop(){ [ "${SP-}" ] || return 0; kill "$SP" 2>/dev/null || true; wait "$SP" 2>/dev/null || true; unset SP; _is_tty && printf "\r\033[K"; }

###############################################################################
# Helpers: download, sha256, extract, patch, recipe parsing, version cmp
###############################################################################
_fetch(){ if command -v curl >/dev/null 2>&1; then printf 'curl -L --fail --retry 3 -o'; elif command -v wget >/dev/null 2>&1; then printf 'wget -O'; else die "Requer curl ou wget"; fi }
sha256_file(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"|awk '{print $1}'; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"|awk '{print $1}'; else die "Requer sha256sum/shasum"; fi }
low(){ printf %s "$1"|tr 'A-Z' 'a-z'; }

# Parse simples: name=, version=
kv(){ awk -v k="$2" '$0~"^"k"="{sub("^"k"=",""); gsub("^\"|\"$","",$0); print; exit}' "$1"; }
# blocos: label<<TAG ... TAG
block(){ awk -v n="$2" -v t="$3" '$0==n"<<"t{on=1;next} on&&$0==t{exit} on{print}' "$1"; }
get_sources(){ block "$1" sources EOF || true; }
get_sha256s(){ block "$1" sha256sums EOF || true; }
get_patches(){ block "$1" patches EOF || true; }
get_step(){ block "$1" "$2" SH || true; }

# Download lista alinhada (url por linha) com checagens de sha (linha-a-linha)
# $1=list URLs, $2=list SHAs, $3=cache_dir, $4=kind
fetch_many(){ urls="$1"; sums="$2"; cache="$3"; kind="$4"; i=0; \
  printf %s "$urls" | while IFS= read -r u; do [ -n "$u" ] || continue; case "$u" in \#*) continue;; esac; i=$((i+1)); base=${u##*/}; out="$cache/$base"; info "$kind[$i] $u"; if [ ! -f "$out" ]; then sp_start; $(_fetch) "$out" "$u" >/dev/null 2>&1 || { sp_stop; die "Falha no download: $u"; }; sp_stop; fi; s=$(printf %s "$sums" | sed -n "${i}p" || true); s=$(printf %s "$s"|sed 's/^SHA256://I'); if [ -n "$s" ] && [ "$(low "$s")" != "skip" ]; then c=$(sha256_file "$out"); [ "$(low "$c")" = "$(low "$s")" ] || die "SHA256 inválido para $base"; fi; ok "$kind[$i] OK: $base"; done; }

# Extração (suporta múltiplos archives)
extract(){ dest="$1"; shift; mkdir -p "$dest"; for f in "$@"; do info "Extraindo $(basename "$f")"; case "$f" in
  *.tar.gz|*.tgz)   tar -xzf "$f" -C "$dest" ;;
  *.tar.bz2|*.tbz2) tar -xjf "$f" -C "$dest" ;;
  *.tar.xz|*.txz)   tar -xJf "$f" -C "$dest" ;;
  *.tar.zst|*.tzst) if tar --help 2>&1|grep -q -- --zstd; then tar --zstd -xf "$f" -C "$dest"; else unzstd -c "$f" | tar -xf - -C "$dest"; fi ;;
  *.tar)            tar -xf "$f" -C "$dest" ;;
  *.zip)            command -v unzip >/dev/null 2>&1 || die "unzip ausente"; unzip -q "$f" -d "$dest" ;;
  *.gz)             gunzip -c "$f" > "$dest/$(basename "$f" .gz)" ;;
  *) die "Formato não suportado: $f" ;;
  esac; done }

first_dir(){ find "$1" -mindepth 1 -maxdepth 1 -type d | head -n1; }

# Patches: linha pode ser
#   HTTPS_URL [SHA256]
#   git+REPO_URL@REF:PATH [SHA256]
resolve_patch(){ line="$1"; url=$(printf %s "$line"|awk '{print $1}'); sha=$(printf %s "$line"|awk '{print $2}'); sha=$(printf %s "$sha"|sed 's/^SHA256://I'); case "$url" in
  git+*) repo=${url#git+}; ref=${repo#*@}; repo=${repo%%@*}; path=${ref#*:}; ref=${ref%%:*}; tmpd="$DBUILD_CACHE_PATCHES/git-$(basename "$repo" .git)-$ref"; mkdir -p "$tmpd"; if [ ! -d "$tmpd/.git" ]; then info "Clonando repo patch $repo@${ref:-HEAD}"; git clone --depth 1 ${ref:+--branch "$ref"} "$repo" "$tmpd" >/dev/null 2>&1 || die "git clone falhou"; fi; out="$DBUILD_CACHE_PATCHES/$(basename "$path")"; git -C "$tmpd" show "${ref:-HEAD}:$path" >"$out" 2>/dev/null || die "git show falhou para $path"; printf '%s\n' "$out" ;;
  http*|https*) base=${url##*/}; out="$DBUILD_CACHE_PATCHES/$base"; [ -f "$out" ] || { info "Baixando patch $url"; $(_fetch) "$out" "$url" >/dev/null 2>&1 || die "download patch"; }; printf '%s\n' "$out" ;;
  *) # caminho local
     [ -f "$url" ] || die "patch não encontrado: $url"; printf '%s\n' "$url" ;;
 esac }

apply_patches(){ list="$1"; srcdir="$2"; [ -n "$list" ] || return 0; i=0; printf %s "$list" | while IFS= read -r line; do [ -n "$line" ] || continue; case "$line" in \#*) continue;; esac; i=$((i+1)); pfile=$(resolve_patch "$line"); s=$(printf %s "$line"|awk '{print $2}'); s=$(printf %s "$s"|sed 's/^SHA256://I'); if [ -n "$s" ] && [ "$(low "$s")" != "skip" ]; then c=$(sha256_file "$pfile"); [ "$(low "$c")" = "$(low "$s")" ] || die "patch[$i] sha256 inválido"; fi; info "Aplicando patch[$i] $(basename "$pfile")"; (cd "$srcdir" && patch -p1 --forward --batch <"$pfile") || die "Falha em patch[$i]"; ok "patch[$i] aplicado"; done }

# version compare: returns 0 if a>b, 1 if a==b, 2 if a<b (numeric dot compare)
vercmp(){ a="$1"; b="$2"; awk -v A="$a" -v B="$b" '
  function splitv(s,arr){ n=split(s,arr,/[^0-9]+/); for(i=1;i<=n;i++){ if(arr[i]=="") arr[i]=0; } return n}
  BEGIN{na=splitv(A,aa); nb=splitv(B,bb); n=(na>nb?na:nb); for(i=1;i<=n;i++){va=(aa[i]?aa[i]:0); vb=(bb[i]?bb[i]:0); if(va+0>vb+0){print 0; exit} if(va+0<vb+0){print 2; exit}} print 1; }'
}

###############################################################################
# Steps runner
###############################################################################
run_step(){ step="$1"; recipe="$2"; cwd="$3"; logfile="$4"; content=$(get_step "$recipe" "$step" || true); [ -n "$content" ] || return 0; info "Etapa: $step"; tmpsh="$cwd/.dbuild-$step.sh"; printf '%s\n' "$content" >"$tmpsh"; chmod +x "$tmpsh"; sp_start; (
  cd "$cwd" && sh "$tmpsh" >>"$logfile" 2>&1
) || { sp_stop; err "Falha na etapa $step (log: $(basename "$logfile"))"; exit 5; }; sp_stop; ok "$step ok"; }

###############################################################################
# BUILD pipeline (até check)
###############################################################################
_do_build(){ recipe="$1"; name=$(kv "$recipe" name); version=$(kv "$recipe" version); release=$(kv "$recipe" release); [ -n "$name" ] || die "recipe sem name"; [ -n "$version" ] || die "recipe sem version"; : ${release:=1}; pkg="$name-$version"; log_build="$DBUILD_LOG_DIR/$name-$version.build.log"; : >"$log_build"; info "Build de $pkg";
  srcs=$(get_sources "$recipe" || true); sums=$(get_sha256s "$recipe" || true); pats=$(get_patches "$recipe" || true);
  # baixar + checar
  fetch_many "$srcs" "$sums" "$DBUILD_CACHE_SOURCES" source
  # extrair
  rm -rf "$DBUILD_BUILD_DIR/$pkg" "$DBUILD_BUILD_DIR/$pkg.src"; mkdir -p "$DBUILD_BUILD_DIR/$pkg.src"
  archives="$(printf %s "$srcs" | awk '{print $1}' | while read -r u; do [ -n "$u" ] || continue; printf '%s\n' "$DBUILD_CACHE_SOURCES/${u##*/}"; done)"
  # shellcheck disable=SC2086
  extract "$DBUILD_BUILD_DIR/$pkg.src" $archives >>"$log_build" 2>&1
  root=$(first_dir "$DBUILD_BUILD_DIR/$pkg.src") || true; [ -n "${root:-}" ] || root="$DBUILD_BUILD_DIR/$pkg.src"; mv "$root" "$DBUILD_BUILD_DIR/$pkg"
  # patches
  [ -n "${pats:-}" ] && apply_patches "$pats" "$DBUILD_BUILD_DIR/$pkg"
  # steps
  run_step preconfig "$recipe" "$DBUILD_BUILD_DIR/$pkg" "$log_build"
  run_step configure "$recipe" "$DBUILD_BUILD_DIR/$pkg" "$log_build"
  run_step build     "$recipe" "$DBUILD_BUILD_DIR/$pkg" "$log_build"
  if [ "$DBUILD_NO_CHECK" = yes ]; then warn "check pulado (DBUILD_NO_CHECK=yes)"; else run_step check "$recipe" "$DBUILD_BUILD_DIR/$pkg" "$log_build"; fi
  ok "Build concluído: $pkg (log: $(basename "$log_build"))"
}

cmd_build(){ [ $# -ge 1 ] || die "uso: dbuild build <recipe>"; recipe="$1"; [ -f "$recipe" ] || recipe="$DBUILD_REPO_DIR/$recipe"; [ -f "$recipe" ] || die "recipe não encontrada: $1"; _do_build "$recipe"; }

###############################################################################
# INSTALL (com --pack-only, --no-package, --strip, fakeroot)
###############################################################################
_strip_tree(){ root="$1"; command -v file >/dev/null 2>&1 || { warn "'file' não encontrado; pulando strip"; return 0; }; command -v strip >/dev/null 2>&1 || { warn "'strip' não encontrado; pulando strip"; return 0; }; info "Executando strip em binários"; find "$root" -type f | while IFS= read -r f; do case "$(file -bi "$f" 2>/dev/null)" in *application/x-executable*|*application/x-pie-executable*|*application/x-sharedlib*) strip --strip-unneeded "$f" 2>/dev/null || true;; esac; done }

_manifest(){ dest="$1"; ( cd "$dest" && find . -mindepth 1 | sort ) }

_install_to_root(){ dest="$1"; info "Copiando para /"; ( cd "$dest" && tar -cf - . ) | ( cd / && tar -xpf - ) }

cmd_install(){ pack_only=no; no_package=no; do_strip=no; while [ $# -gt 0 ]; do case "$1" in --pack-only) pack_only=yes;; --no-package) no_package=yes;; --strip) do_strip=yes;; *) break;; esac; shift; done; [ $# -ge 1 ] || die "uso: dbuild install [--pack-only] [--no-package] [--strip] <recipe>"; recipe="$1"; [ -f "$recipe" ] || recipe="$DBUILD_REPO_DIR/$recipe"; [ -f "$recipe" ] || die "recipe não encontrada: $1";
  name=$(kv "$recipe" name); version=$(kv "$recipe" version); release=$(kv "$recipe" release); : ${release:=1}; pkg="$name-$version"; dest="$DBUILD_BUILD_DIR/$pkg-destdir"; log_build="$DBUILD_LOG_DIR/$name-$version.build.log"; : >"$log_build";
  _do_build "$recipe" # garante build pronto
  rm -rf "$dest"; mkdir -p "$dest"
  # hooks + install
  run_step preinstall "$recipe" "$DBUILD_BUILD_DIR/$pkg" "$log_build"
  # etapa install (da receita) deve respeitar DESTDIR; se ausente, tenta make install
  content_install=$(get_step "$recipe" install SH || true)
  if [ -n "$content_install" ]; then info "Etapa: install"; sh -c "$content_install" DESTDIR="$dest" >>"$log_build" 2>&1 || die "Falha na etapa install"; else info "Executando make install DESTDIR=$dest"; ( cd "$DBUILD_BUILD_DIR/$pkg" && make install DESTDIR="$dest" >>"$log_build" 2>&1 ) || die "make install falhou"; fi

  [ "$do_strip" = yes ] && _strip_tree "$dest"

  # pacote e manifest
  mkdir -p "$DBUILD_PKG_DIR" "$DBUILD_DB_DIR"
  pkgfile="$DBUILD_PKG_DIR/${name}-${version}-${release}.tar.xz"
  if [ "$no_package" = no ]; then info "Empacotando (fakeroot): $(basename "$pkgfile")"; fakeroot -- tar -C "$dest" -cJf "$pkgfile" . || die "empacotar falhou"; else warn "--no-package: pulando geração do pacote"; pkgfile=""; fi
  _manifest "$dest" >"$DBUILD_DB_DIR/$name.manifest"
  # salvar meta + uma cópia da recipe p/ hooks de remoção futuros
  cat >"$DBUILD_DB_DIR/$name.meta" <<EOF
name=$name
version=$version
release=$release
pkgfile=$pkgfile
recipe=$DBUILD_DB_DIR/$name.recipe
EOF
  cp -f "$recipe" "$DBUILD_DB_DIR/$name.recipe"

  if [ "$pack_only" = yes ]; then ok "Pacote/manifest gerados (não instalado no /)"; exit 0; fi

  # copiar para root e pós-install
  _install_to_root "$dest"
  run_step postinstall "$recipe" / "$log_build"
  ok "Instalado: $name $version-$release"
}

###############################################################################
# REMOVE (desfaz instalação via manifest + postremove)
###############################################################################
cmd_remove(){ [ $# -ge 1 ] || die "uso: dbuild remove <name>"; name="$1"; man="$DBUILD_DB_DIR/$name.manifest"; meta="$DBUILD_DB_DIR/$name.meta"; rec="$DBUILD_DB_DIR/$name.recipe"; [ -f "$man" ] || die "manifest não encontrado: $man"; info "Removendo $name"; # remover na ordem reversa (arquivos antes de dirs)
  tac "$man" 2>/dev/null || sed '1!G;h;$!d' "$man" | while IFS= read -r p; do [ -z "$p" ] && continue; tgt="/$p"; if [ -L "$tgt" ] || [ -f "$tgt" ]; then rm -f "$tgt" 2>/dev/null || true; elif [ -d "$tgt" ]; then rmdir "$tgt" 2>/dev/null || true; fi; done
  if [ -f "$rec" ]; then run_step postremove "$rec" / "$DBUILD_LOG_DIR/$name-remove.log" || true; fi
  rm -f "$man" "$meta" "$rec" 2>/dev/null || true
  ok "Removido: $name"
}

###############################################################################
# INFO / LIST / SEARCH
###############################################################################
cmd_info(){ [ $# -ge 1 ] || die "uso: dbuild info <name>"; n="$1"; meta="$DBUILD_DB_DIR/$n.meta"; man="$DBUILD_DB_DIR/$n.manifest"; [ -f "$meta" ] || die "não instalado: $n"; echo "-- $n --"; cat "$meta"; echo "files=$(wc -l <"$man" 2>/dev/null || echo 0)"; }
cmd_list(){ for m in "$DBUILD_DB_DIR"/*.meta; do [ -e "$m" ] || { echo "(vazio)"; break; }; . "$m" 2>/dev/null || true; printf "%s %s-%s\n" "$name" "$version" "$release"; done }
cmd_search(){ [ $# -ge 1 ] || die "uso: dbuild search <termo>"; term="$1"; find "$DBUILD_REPO_DIR" -type f -name "*.recipe" -print | while read -r f; do case "$(basename "$f")" in *$term*) printf "%s\n" "$f";; *) grep -qi "$term" "$f" && printf "%s\n" "$f" || true;; esac; done }

###############################################################################
# SYNC (git pull)
###############################################################################
cmd_sync(){ [ -d "$DBUILD_REPO_DIR/.git" ] || die "repo não é git: $DBUILD_REPO_DIR"; info "git pull --rebase"; git -C "$DBUILD_REPO_DIR" pull --rebase || die "git pull falhou"; ok "sync ok"; }

###############################################################################
# UPGRADE (se versão da receita > instalada)
###############################################################################
cmd_upgrade(){ [ $# -ge 1 ] || die "uso: dbuild upgrade <name|recipe>"; ref="$1"; # localizar recipe
  recipe=""; if [ -f "$ref" ]; then recipe="$ref"; else # procurar por nome
    cand=$(find "$DBUILD_REPO_DIR" -type f -name "*.recipe" -printf '%p\n' | while read -r f; do [ "$(kv "$f" name)" = "$ref" ] && echo "$f" && break; done); [ -n "$cand" ] || die "recipe para $ref não encontrada"; recipe="$cand"; fi
  name=$(kv "$recipe" name); ver_new=$(kv "$recipe" version); rel_new=$(kv "$recipe" release); : ${rel_new:=1}; meta="$DBUILD_DB_DIR/$name.meta"; if [ ! -f "$meta" ]; then warn "$name não instalado; instalando"; cmd_install "$recipe"; exit 0; fi; . "$meta" 2>/dev/null || true; ver_old=${version:-0}; cmp=$(vercmp "$ver_new" "$ver_old"); if [ "$cmp" -eq 2 ] || [ "$cmp" -eq 1 ]; then warn "versão não é maior (instalada=$ver_old, recipe=$ver_new)"; exit 0; fi; info "Atualizando $name: $ver_old → $ver_new"; cmd_install "$recipe"; }

###############################################################################
# CLI
###############################################################################
usage(){ cat <<EOF
uso: dbuild <subcomando> [opções]

subcomandos:
  build <recipe>                         compila até check
  install [--pack-only] [--no-package] [--strip] <recipe>
                                         compila + instala (ou só empacota)
  remove <name>                          desfaz instalação via manifest
  info <name>                            mostra metadados do pacote instalado
  list                                   lista pacotes instalados
  search <termo>                         busca receitas no repo
  sync                                   git pull no repositório de receitas
  upgrade <name|recipe>                  atualiza se há versão maior

variáveis úteis:
  DBUILD_ROOT, DBUILD_COLOR=auto|always|never, DBUILD_SPINNER=dots|none
  DBUILD_NO_CHECK=yes (pular testes), DBUILD_REPO_DIR=repo
EOF }

cmd=${1:-}; shift || true
case "$cmd" in
  build)   cmd_build "$@" ;;
  install) cmd_install "$@" ;;
  remove)  cmd_remove "$@" ;;
  info)    cmd_info   "$@" ;;
  list)    cmd_list   "$@" ;;
  search)  cmd_search "$@" ;;
  sync)    cmd_sync   "$@" ;;
  upgrade) cmd_upgrade "$@" ;;
  -h|--help|help|'') usage ;;
  *) die "subcomando inválido: $cmd" ;;
esac
