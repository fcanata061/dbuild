#!/bin/sh
# dbuild - esqueleto inicial
# POSIX shell script simples

DBUILD_ROOT="${DBUILD_ROOT:-$PWD}"
DBUILD_SRC="$DBUILD_ROOT/src"
DBUILD_BUILD="$DBUILD_ROOT/build"
DBUILD_PKG="$DBUILD_ROOT/pkg"
DBUILD_DB="$DBUILD_ROOT/db"
DBUILD_LOGS="$DBUILD_ROOT/logs"
DBUILD_REPO="$DBUILD_ROOT/repo"

# --- Cores ---
RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
RESET="$(printf '\033[0m')"

# --- Spinner fake ---
spinner() {
    printf "%s⠋%s " "$BLUE" "$RESET"
}

# --- Mensagens ---
msg_info()  { printf "%s[i]%s %s\n" "$BLUE" "$RESET" "$*"; }
msg_ok()    { printf "%s[+]%s %s\n" "$GREEN" "$RESET" "$*"; }
msg_warn()  { printf "%s[!]%s %s\n" "$YELLOW" "$RESET" "$*"; }
msg_err()   { printf "%s[x]%s %s\n" "$RED" "$RESET" "$*"; }

# --- Inicialização ---
init_dirs() {
    for d in "$DBUILD_SRC" "$DBUILD_BUILD" "$DBUILD_PKG" "$DBUILD_DB" "$DBUILD_LOGS" "$DBUILD_REPO"; do
        [ -d "$d" ] || mkdir -p "$d"
    done
}

# --- Subcomandos ---
cmd_build() {
    msg_info "Executando build para $1"
    spinner; echo " (placeholder)"
}

cmd_install() {
    msg_info "Instalando $1"
    spinner; echo " (placeholder)"
}

cmd_remove() {
    msg_info "Removendo $1"
    spinner; echo " (placeholder)"
}

cmd_info() {
    msg_info "Mostrando informações de $1"
    spinner; echo " (placeholder)"
}

cmd_list() {
    msg_info "Listando pacotes instalados"
    spinner; echo " (placeholder)"
}

cmd_search() {
    msg_info "Procurando por $1 em receitas"
    spinner; echo " (placeholder)"
}

cmd_sync() {
    msg_info "Sincronizando repositório de receitas"
    spinner; echo " (placeholder)"
}

cmd_upgrade() {
    msg_info "Atualizando $1"
    spinner; echo " (placeholder)"
}

# --- Help ---
usage() {
    cat <<EOF
dbuild - gerenciador simples de receitas

Uso: dbuild <subcomando> [pacote]

Subcomandos:
  build <recipe>     Compila um pacote (sem instalar)
  install <recipe>   Compila e instala um pacote
  remove <pkg>       Remove pacote instalado
  info <pkg>         Mostra informações sobre pacote
  list               Lista pacotes instalados
  search <name>      Busca receita no repositório
  sync               Atualiza repositório de receitas
  upgrade <pkg>      Atualiza pacote para nova versão
EOF
}

# --- Main ---
main() {
    init_dirs
    cmd="$1"; shift || true
    case "$cmd" in
        build)    cmd_build "$@";;
        install)  cmd_install "$@";;
        remove)   cmd_remove "$@";;
        info)     cmd_info "$@";;
        list)     cmd_list "$@";;
        search)   cmd_search "$@";;
        sync)     cmd_sync "$@";;
        upgrade)  cmd_upgrade "$@";;
        ""|help|-h|--help) usage;;
        *) msg_err "Comando inválido: $cmd"; usage; exit 1;;
    esac
}

main "$@"
