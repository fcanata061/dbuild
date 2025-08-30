#!/bin/sh
# dbuild — implementação inicial do subcomando `build` com logs
# Objetivos desta versão:
#  - Ler receita POSIX com blocos heredoc (sources/patches e etapas SH)
#  - Baixar fontes/patches (curl ou wget)
#  - Verificar SHA256
#  - Extrair fontes (tar.{gz,bz2,xz,zst}, .zip, .tar)
#  - Aplicar patches em ordem
#  - Executar etapas: preconfig, configure, build, check (sem instalar)
#  - Registrar logs por etapa em $DBUILD_LOGS
#  - UX básica com cores e spinners simples
#
# NOTA: mantido simples e POSIX. Sem resolução automática de dependências.

set -eu

# ===================== Configuração =====================
DBUILD_ROOT=${DBUILD_ROOT:-"$PWD"}
DBUILD_CACHE_SOURCES=${DBUILD_CACHE_SOURCES:-"$DBUILD_ROOT/src"}
DBUILD_CACHE_PATCHES=${DBUILD_CACHE_PATCHES:-"$DBUILD_ROOT/patches"}
DBUILD_BUILD_DIR=${DBUILD_BUILD_DIR:-"$DBUILD_ROOT/build"}
DBUILD_LOG_DIR=${DBUILD_LOG_DIR:-"$DBUILD_ROOT/logs"}
DBUILD_REPO_DIR=${DBUILD_REPO_DIR:-"$DBUILD_ROOT/repo"}
DBUILD_COLOR=${DBUILD_COLOR:-auto}
DBUILD_SPINNER=${DBUILD_SPINNER:-dots}
DBUILD_JOBS=${DBUILD_JOBS:-}

# ===================== Cores / UX =====================
_is_tty() { [ -t 1 ]; }
_use_color() {
    case "$DBUILD_COLOR" in
        always) return 0 ;;
        never)  return 1 ;;
        *) _is_tty ;;
    esac
}
if _use_color; then
    C_BLUE='\033[34m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_RESET='\033[0m'
else
    C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

log_info() { printf "%s▶%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
log_ok()   { printf "%s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf "%s!%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
log_err()  { printf "%s✗%s %s\n" "$C_RED" "$C_RESET" "$*"; }

sp_start() {
    _is_tty || return 0
    case "$DBUILD_SPINNER" in
        none) return 0 ;;
        *) : ;;
    esac
    (
        i=0
        seq='|/-\\'
        while :; do
            i=$(( (i+1) % 4 ))
            printf "\r%s…%s %c " "$C_BLUE" "$C_RESET" "$(printf %s "$seq" | cut -c $((i+1)))"
            sleep 0.1
        done
    ) &
    SP_PID=$!
}
sp_stop() {
    [ "${SP_PID-}" ] || return 0
    kill "$SP_PID" 2>/dev/null || true
    wait "$SP_PID" 2>/dev/null || true
    unset SP_PID
    _is_tty && printf "\r\033[K"
}

# ===================== Utilidades =====================
ensure_dirs() {
    mkdir -p "$DBUILD_CACHE_SOURCES" "$DBUILD_CACHE_PATCHES" \
             "$DBUILD_BUILD_DIR" "$DBUILD_LOG_DIR" "$DBUILD_REPO_DIR"
}

# seleciona ferramenta de download (curl preferido)
_fetch_cmd() {
    if command -v curl >/dev/null 2>&1; then
        printf 'curl -L --fail --retry 3 -o'
    elif command -v wget >/dev/null 2>&1; then
        printf 'wget -O'
    else
        log_err "Nem curl nem wget encontrados"
        exit 9
    fi
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        log_err "Ferramenta sha256sum/shasum não encontrada"
        exit 9
    fi
}

# converte SHA informado tipo "SHA256:abcd" ou apenas "abcd" em hex puro
norm_sha() {
    printf %s "$1" | sed 's/^SHA256://I'
}

# extrai bloco de um recipe: BEGIN=^name<<TAG$  END=^TAG$
# uso: read_block FILE NAME TAG
read_block() {
    awk -v name="$2" -v tag="$3" '
        $0==name"<<"tag {inb=1; next}
        inb && $0==tag {inb=0; exit}
        inb {print}
    ' "$1"
}

# detecta primeiro diretório raiz criado após extração
first_dir() {
    # lista o primeiro item de diretório
    find "$1" -mindepth 1 -maxdepth 1 -type d | head -n 1
}

# ===================== Leitura de receita =====================
# Campos simples extraídos via awk (name, version, release, prefix opcional)
read_kv() {
    # $1=recipe $2=key
    awk -v k="$2" '
        $0 ~ "^"k"=" {sub("^"k"=",""); gsub("^\"|\"$","",$0); print; exit}
    ' "$1"
}

# Lista de sources e patches via blocos heredoc (EOF padrão)
get_sources() { read_block "$1" sources EOF; }
get_patches() { read_block "$1" patches EOF; }

# Blocos de etapas via TAG SH (<<'SH')
get_step() { read_block "$1" "$2" SH; }

# ===================== Baixar & Verificar =====================
# Espera linhas: "URL  SHA256:abcdef" ou "URL  abcdef"
download_list() {
    list="$1"; cache_dir="$2"; kind="$3"; pkgname="$4"; pkgver="$5"
    [ -n "$list" ] || return 0
    fetch=$(_fetch_cmd)
    i=0
    echo "$list" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        url=$(printf %s "$line" | awk '{print $1}')
        sha=$(printf %s "$line" | awk '{print $2}')
        sha=$(norm_sha "${sha:-}")
        base=${url##*/}
        out="$cache_dir/$base"
        i=$((i+1))
        log_info "$kind[$i] baixando: $url"
        if [ -f "$out" ]; then
            log_ok "$base já em cache"
        else
            sp_start
            # shellcheck disable=SC2086
            $fetch "$out" "$url" >/dev/null 2>&1 || {
                sp_stop; log_err "Falha ao baixar $url"; exit 3; }
            sp_stop
            log_ok "baixado: $base"
        fi
        if [ -n "$sha" ] && [ "$sha" != "skip" ]; then
            calc=$(sha256_file "$out")
            if [ "$(printf %s "$calc" | tr 'A-F' 'a-f')" != "$(printf %s "$sha" | tr 'A-F' 'a-f')" ]; then
                log_err "$kind[$i] checksum inválido: $base"
                exit 4
            fi
            log_ok "$kind[$i] sha256 OK"
        else
            log_warn "$kind[$i] sem verificação SHA256 (skip)"
        fi
    done
}

# ===================== Extração =====================
extract_archive() {
    file="$1"; dest="$2"
    mkdir -p "$dest"
    case "$file" in
        *.tar.gz|*.tgz)   tar -xzf "$file" -C "$dest" ;;
        *.tar.bz2|*.tbz2) tar -xjf "$file" -C "$dest" ;;
        *.tar.xz|*.txz)   tar -xJf "$file" -C "$dest" ;;
        *.tar.zst|*.tzst)
            if tar --help 2>&1 | grep -q -- '--zstd'; then
                tar --zstd -xf "$file" -C "$dest"
            elif command -v unzstd >/dev/null 2>&1; then
                unzstd -c "$file" | tar -xf - -C "$dest"
            else
                log_err "Sem suporte a .zst (instale zstd)"; exit 9
            fi ;;
        *.tar)            tar -xf "$file" -C "$dest" ;;
        *.zip)            command -v unzip >/dev/null 2>&1 || { log_err "unzip ausente"; exit 9; }
                          unzip -q "$file" -d "$dest" ;;
        *.gz)             gunzip -c "$file" > "$dest/$(basename "$file" .gz)" ;;
        *)                log_err "Formato não suportado: $file"; exit 2 ;;
    esac
}

# ===================== Patch =====================
apply_patches() {
    list="$1"; srcdir="$2"
    [ -n "$list" ] || return 0
    i=0
    echo "$list" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        url=$(printf %s "$line" | awk '{print $1}')
        sha=$(norm_sha "$(printf %s "$line" | awk '{print $2}')")
        base=${url##*/}
        patchfile="$DBUILD_CACHE_PATCHES/$base"
        i=$((i+1))
        if [ ! -f "$patchfile" ]; then
            fetch=$(_fetch_cmd)
            log_info "patch[$i] baixando: $url"
            # shellcheck disable=SC2086
            $fetch "$patchfile" "$url" >/dev/null 2>&1 || { log_err "Falha ao baixar patch $url"; exit 3; }
        else
            log_ok "patch[$i] em cache: $base"
        fi
        if [ -n "$sha" ] && [ "$sha" != "skip" ]; then
            calc=$(sha256_file "$patchfile")
            [ "$(printf %s "$calc" | tr 'A-F' 'a-f')" = "$(printf %s "$sha" | tr 'A-F' 'a-f')" ] || { log_err "patch[$i] checksum inválido"; exit 4; }
        else
            log_warn "patch[$i] sem verificação SHA256 (skip)"
        fi
        log_info "Aplicando patch[$i]: $base"
        ( cd "$srcdir" && patch -p1 --forward --batch < "$patchfile" ) || { log_err "Falha ao aplicar patch[$i]"; exit 5; }
        log_ok "patch[$i] aplicado"
    done
}

# ===================== Execução de etapas =====================
run_step() {
    step_name="$1"; recipe="$2"; cwd="$3"; logfile="$4"
    content=$(get_step "$recipe" "$step_name" || true)
    [ -n "$content" ] || return 0
    log_info "Rodando etapa: $step_name"
    tmpsh="$cwd/.dbuild-$step_name.sh"
    printf '%s\n' "$content" > "$tmpsh"
    chmod +x "$tmpsh"
    sp_start
    (
        cd "$cwd"
        # shellcheck disable=SC2086
        sh "$tmpsh" ${DBUILD_JOBS:+DBUILD_JOBS="$DBUILD_JOBS"} >>"$logfile" 2>&1
    ) || { sp_stop; log_err "Etapa $step_name falhou (veja $(basename "$logfile"))"; exit 6; }
    sp_stop
    log_ok "etapa $step_name concluída"
}

# ===================== BUILD =====================
cmd_build() {
    recipe_path="$1"
    [ -n "${recipe_path:-}" ] || { log_err "Informe o caminho da recipe"; exit 2; }
    [ -f "$recipe_path" ] || { log_err "Recipe não encontrada: $recipe_path"; exit 2; }

    ensure_dirs

    name=$(read_kv "$recipe_path" name)
    version=$(read_kv "$recipe_path" version)
    [ -n "$name" ] && [ -n "$version" ] || { log_err "Recipe precisa de 'name' e 'version'"; exit 2; }

    log_info "Build de $name-$version"

    sources=$(get_sources "$recipe_path" || true)
    patches=$(get_patches "$recipe_path" || true)

    buildroot="$DBUILD_BUILD_DIR/$name-$version"
    srcroot="$buildroot/src"
    log_build="$DBUILD_LOG_DIR/$name-$version.build.log"
    : >"$log_build"

    # 1) Baixar fontes e verificar
    download_list "$sources" "$DBUILD_CACHE_SOURCES" source "$name" "$version"

    # 2) Extrair (suporta múltiplas fontes; extrai todas dentro de srcroot)
    rm -rf "$buildroot" && mkdir -p "$srcroot"
    echo "$sources" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        url=$(printf %s "$line" | awk '{print $1}')
        base=${url##*/}
        archive="$DBUILD_CACHE_SOURCES/$base"
        log_info "Extraindo $base"
        extract_archive "$archive" "$srcroot" >>"$log_build" 2>&1
    done

    # detectar diretório raiz (se uma única raiz foi criada)
    rootdir=$(first_dir "$srcroot")
    [ -n "${rootdir:-}" ] || rootdir="$srcroot"

    # 3) Aplicar patches
    [ -n "${patches:-}" ] && apply_patches "$patches" "$rootdir"

    # 4) Rodar etapas: preconfig, configure, build, check
    run_step preconfig "$recipe_path" "$rootdir" "$log_build"
    run_step configure "$recipe_path" "$rootdir" "$log_build"
    run_step build     "$recipe_path" "$rootdir" "$log_build"
    # check é opcional; pode ser pulado via variável DBUILD_NO_CHECK=yes
    if [ "${DBUILD_NO_CHECK:-no}" = "yes" ]; then
        log_warn "check pulado por DBUILD_NO_CHECK=yes"
    else
        run_step check "$recipe_path" "$rootdir" "$log_build"
    fi

    log_ok "Build concluído: $name-$version (log: $(basename "$log_build"))"
}

# ===================== Placeholders p/ demais subcomandos =====================
cmd_install() { log_warn "'install' ainda não implementado nesta versão"; }
cmd_remove()  { log_warn "'remove' ainda não implementado nesta versão"; }
cmd_info()    { log_warn "'info' ainda não implementado nesta versão"; }
cmd_list()    { log_warn "'list' ainda não implementado nesta versão"; }
cmd_search()  { log_warn "'search' ainda não implementado nesta versão"; }
cmd_sync()    { log_warn "'sync' ainda não implementado nesta versão"; }
cmd_upgrade() { log_warn "'upgrade' ainda não implementado nesta versão"; }

# ===================== CLI =====================
usage() {
    cat <<EOF
Uso: dbuild <subcomando> [args]

Subcomandos:
  build <recipe>     Compila um pacote (até etapa check) e gera logs
  install <recipe>   Compila + instala (N/I nesta versão)
  remove <name>      Remove pacote instalado (N/I)
  info <name>        Mostra metadados (N/I)
  list               Lista pacotes instalados (N/I)
  search <term>      Busca no repositório (N/I)
  sync               Sincroniza repo git (N/I)
  upgrade <name>     Atualiza pacote (N/I)

Variáveis úteis:
  DBUILD_ROOT        Raiz do workspace (default: pwd)
  DBUILD_NO_CHECK    yes para pular etapa check
  DBUILD_JOBS        usado em etapas (ex.: make -j)
  DBUILD_COLOR       auto|always|never
  DBUILD_SPINNER     dots|none
EOF
}

main() {
    ensure_dirs
    cmd=${1:-}; shift || true
    case "$cmd" in
        build)   cmd_build "$@" ;;
        install) cmd_install "$@" ;;
        remove)  cmd_remove  "$@" ;;
        info)    cmd_info    "$@" ;;
        list)    cmd_list    "$@" ;;
        search)  cmd_search  "$@" ;;
        sync)    cmd_sync    "$@" ;;
        upgrade) cmd_upgrade "$@" ;;
        ''|-h|--help|help) usage ;;
        *) log_err "Subcomando inválido: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
