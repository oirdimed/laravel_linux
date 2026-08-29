#!/usr/bin/env bash
#
# add-laravel-project.sh
#
# Creates and configures Laravel projects on Debian/Ubuntu.
#
# Project modes:
#   1) Normal Laravel
#      Composer creates the Laravel application.
#
#   2) Vemto
#      Creates an empty project directory and prepares the environment
#      for Vemto to generate the Laravel application.
#
#   3) GitHub
#      Clones an existing Laravel project from GitHub.
#
# Features:
#   - Debian / Ubuntu detection
#   - Dynamic PHP-FPM detection
#   - Offers PHP installation if none is installed
#   - User-selectable PHP-FPM version
#   - Composer verification
#   - Dynamic Laravel compatibility detection through Composer
#   - User-selectable Laravel version
#   - NVM-aware Node.js detection
#   - Node.js LTS installation fallback
#   - npm verification
#   - Git verification
#   - Dynamic project directory
#   - Automatically uses the actual invoking user's home directory
#   - Creates missing base directories after confirmation
#   - MySQL / MariaDB support
#   - Optional dedicated database user
#   - Safe SQL escaping
#   - Apache VirtualHost
#   - Per-project PHP-FPM socket
#   - ACL support for /home/... projects
#   - Group-permission fallback when ACL is unavailable
#   - Laravel storage/bootstrap/cache permissions
#   - .env generation
#   - Laravel application key generation
#   - Apache configuration validation
#   - Port conflict warning
#   - Optional local self-signed HTTPS
#   - Laravel database connection test
#   - HTTP verification
#   - Final system/project verification
#   - Safe logging
#   - Dry-run mode
#   - Non-interactive mode
#
# Assumptions:
#   - Debian or Ubuntu
#   - systemd
#   - Apache 2.4+
#   - MySQL/MariaDB
#   - Bash 4+
#   - User has sudo privileges
#
# Usage:
#   sudo ./add-laravel-project.sh
#   sudo ./add-laravel-project.sh --dry-run
#   sudo ./add-laravel-project.sh --help
#   sudo ./add-laravel-project.sh --version
#

set -Eeuo pipefail

SCRIPT_NAME="add-laravel-project"
SCRIPT_VERSION="1.0.0"

DEFAULT_BASE_DIR="/var/www"

APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
APACHE_SITES_ENABLED="/etc/apache2/sites-enabled"
HOSTS_FILE="/etc/hosts"

WEB_USER="www-data"
WEB_GROUP="www-data"

MYSQL_CLIENT="mysql"
MYSQL_HOST="127.0.0.1"

LOG_FILE="/var/log/add-laravel-project.log"

DRY_RUN=0
NON_INTERACTIVE=0

OWNER=""
OWNER_HOME=""

PHP_VER=""
PHP_BIN=""
PHP_FPM_SERVICE=""
PHP_FPM_SOCKET=""

PROJECT_TYPE=""
PROJ=""
SERVER_NAME=""
BASE_DIR=""
PROJECT_DIR=""

LARAVEL_MAJOR=""
LARAVEL_CONSTRAINT=""

DB_NAME=""
DB_USERNAME=""
DB_PASSWORD=""

DB_SERVICE=""
MYSQL_OPTS_FILE=""

NODE_BIN=""
NPM_BIN=""
COMPOSER_BIN=""

HTTPS_ENABLED=0
SSL_CERT=""
SSL_KEY=""

APT_UPDATED=0
CLEANUP_DONE=0

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
RESET="\033[0m"

info() {
    echo -e "[${GREEN}INFO${RESET}] $*"
}

warn() {
    echo -e "[${YELLOW}WARN${RESET}] $*" >&2
}

error() {
    echo -e "[${RED}ERROR${RESET}] $*" >&2
}

debug() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "[${CYAN}DRY-RUN${RESET}] $*"
    fi
}

section() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}

die() {
    error "$*"
    exit 2
}

cancel() {
    warn "$*"
    exit 1
}

show_version() {
    echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
}

show_help() {
    cat <<EOF

${SCRIPT_NAME} ${SCRIPT_VERSION}

Creates and configures Laravel projects on Debian/Ubuntu.

Usage:
  sudo $0 [options]

Options:
  --help            Show this help.
  --version         Show script version.
  --dry-run         Show intended changes without modifying the system.
  --non-interactive Use defaults where possible.

Project types:
  1) Normal Laravel
     Composer creates the Laravel application.

  2) Vemto
     Creates an empty Laravel-ready directory for Vemto.

  3) GitHub
     Imports an existing Laravel project from GitHub.

Examples:
  sudo $0
  sudo $0 --dry-run
  sudo $0 --non-interactive

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                show_version
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --non-interactive)
                NON_INTERACTIVE=1
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

cleanup() {
    if [[ "$CLEANUP_DONE" -eq 1 ]]; then
        return
    fi

    CLEANUP_DONE=1

    if [[ -n "${MYSQL_OPTS_FILE:-}" && -f "$MYSQL_OPTS_FILE" ]]; then
        rm -f "$MYSQL_OPTS_FILE" || true
    fi
}

on_error() {
    local exit_code=$?
    error "Script failed at line ${BASH_LINENO[0]:-unknown}."
    error "Command: ${BASH_COMMAND:-unknown}"
    error "Exit code: $exit_code"
    exit 2
}

trap cleanup EXIT
trap on_error ERR

log_setup() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        LOG_FILE="${OWNER_HOME:-/tmp}/.add-laravel-project-dry-run.log"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi

    if [[ ! -d "$(dirname "$LOG_FILE")" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    fi

    if [[ ! -e "$LOG_FILE" ]]; then
        (umask 077 && touch "$LOG_FILE") ||
            die "Unable to create log file: $LOG_FILE"
    fi

    chmod 600 "$LOG_FILE" 2>/dev/null || true

    exec > >(tee -a "$LOG_FILE") 2>&1
}

run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[DRY-RUN] '
        printf '%q ' "$@"
        echo
        return 0
    fi

    "$@"
}

apt_update_once() {
    if [[ "$APT_UPDATED" -eq 0 ]]; then
        info "Updating APT package information..."
        run_cmd apt-get update
        APT_UPDATED=1
    fi
}

install_packages() {
    apt_update_once
    run_cmd apt-get install -y "$@"
}

confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local answer=""

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        [[ "$default" == "Y" ]]
        return
    fi

    if [[ "$default" == "Y" ]]; then
        read -rp "$prompt [Y/n]: " answer
        answer="${answer:-Y}"
    else
        read -rp "$prompt [y/N]: " answer
        answer="${answer:-N}"
    fi

    [[ "$answer" =~ ^[Yy]$ ]]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_owner() {
    section "USER"

    if [[ "$EUID" -ne 0 ]]; then
        if command_exists sudo; then
            exec sudo -E "$0" "$@"
        fi

        die "Root privileges are required. Run this script with sudo."
    fi

    if [[ -z "${SUDO_USER:-}" ]]; then
        die "Run this script with sudo from a normal user account."
    fi

    OWNER="$SUDO_USER"

    OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"

    [[ -n "$OWNER_HOME" ]] ||
        die "Unable to determine home directory for $OWNER."

    info "Project owner: $OWNER"
    info "Owner home: $OWNER_HOME"
}

detect_os() {
    section "OPERATING SYSTEM"

    [[ -f /etc/os-release ]] ||
        die "/etc/os-release not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            info "Detected: ${PRETTY_NAME:-$ID}"
            ;;
        *)
            die "This script supports Debian and Ubuntu only."
            ;;
    esac
}

check_basic_system() {
    section "SYSTEM REQUIREMENTS"

    command_exists systemctl ||
        die "systemd is required."

    command_exists apt-get ||
        die "APT is required."

    if ! command_exists apache2; then
        info "Apache is not installed."
        install_packages apache2
    fi

    if ! command_exists ss; then
        info "Installing iproute2 for port checks..."
        install_packages iproute2
    fi

    if ! command_exists curl; then
        info "Installing curl..."
        install_packages curl
    fi

    if ! command_exists git; then
        info "Installing Git..."
        install_packages git
    fi

    if ! command_exists setfacl || ! command_exists getfacl; then
        info "Installing ACL support..."
        install_packages acl
    fi

    if ! command_exists mysql; then
        info "Installing MySQL client..."
        install_packages mysql-client
    fi
}

check_apache() {
    section "APACHE"

    local version
    version="$(apache2 -v 2>/dev/null | head -1 || true)"

    [[ "$version" =~ Apache/2\.4 ]] ||
        die "Apache 2.4+ is required. Detected: ${version:-unknown}"

    info "$version"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        systemctl enable --now apache2
    else
        debug "systemctl enable --now apache2"
    fi
}

detect_php_fpm_versions() {
    mapfile -t INSTALLED_PHP_VERSIONS < <(
        {
            find /usr/sbin -maxdepth 1 -type f \
                -name 'php-fpm[0-9]*.[0-9]*' \
                -printf '%f\n' 2>/dev/null || true

            find /etc/init.d -maxdepth 1 -type f \
                -name 'php*-fpm' \
                -printf '%f\n' 2>/dev/null || true

            systemctl list-unit-files --type=service 2>/dev/null |
                sed -nE 's/^(php[0-9]+\.[0-9]+-fpm)\.service.*/\1/p' || true
        } |
        sed -nE 's/^php-fpm([0-9]+\.[0-9]+)$/\1/p;
                  s/^php([0-9]+\.[0-9]+)-fpm$/\1/p' |
        sort -Vu
    )
}

install_default_php() {
    section "PHP INSTALLATION"

    warn "No usable PHP-FPM installation was detected."

    if ! confirm "Install the default PHP version from the current repositories?" "Y"; then
        cancel "PHP-FPM installation cancelled."
    fi

    install_packages \
        php \
        php-fpm \
        php-cli \
        php-common \
        php-mysql \
        php-mbstring \
        php-xml \
        php-curl \
        php-zip \
        php-bcmath \
        php-intl \
        php-gd \
        php-curl

    detect_php_fpm_versions

    [[ ${#INSTALLED_PHP_VERSIONS[@]} -gt 0 ]] ||
        die "PHP-FPM installation completed but no PHP-FPM version was detected."
}

select_php_version() {
    section "INSTALLED PHP-FPM VERSIONS"

    if [[ ${#INSTALLED_PHP_VERSIONS[@]} -eq 0 ]]; then
        install_default_php
    fi

    for i in "${!INSTALLED_PHP_VERSIONS[@]}"; do
        echo "  $((i + 1))) PHP ${INSTALLED_PHP_VERSIONS[$i]}"
    done

    local highest="${INSTALLED_PHP_VERSIONS[-1]}"
    local selection=""

    echo
    info "Highest installed PHP-FPM version: PHP $highest"

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        selection="${#INSTALLED_PHP_VERSIONS[@]}"
    else
        read -rp \
            "Select PHP version [default: ${#INSTALLED_PHP_VERSIONS[@]} - PHP $highest]: " \
            selection

        selection="${selection:-${#INSTALLED_PHP_VERSIONS[@]}}"
    fi

    while true; do
        if [[ "$selection" =~ ^[0-9]+$ ]] &&
            (( selection >= 1 && selection <= ${#INSTALLED_PHP_VERSIONS[@]} )); then

            PHP_VER="${INSTALLED_PHP_VERSIONS[$((selection - 1))]}"
            break
        fi

        if printf '%s\n' "${INSTALLED_PHP_VERSIONS[@]}" |
            grep -qx "$selection"; then
            PHP_VER="$selection"
            break
        fi

        warn "Invalid PHP selection."

        read -rp "Select PHP version: " selection
    done

    PHP_BIN="/usr/bin/php${PHP_VER}"
    PHP_FPM_SERVICE="php${PHP_VER}-fpm"
    PHP_FPM_SOCKET="/run/php/php${PHP_VER}-fpm.sock"

    [[ -x "$PHP_BIN" ]] ||
        die "$PHP_BIN does not exist."

    info "Selected PHP: $PHP_VER"
}

verify_php_service() {
    section "PHP-FPM SERVICE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "systemctl enable --now $PHP_FPM_SERVICE"
        return
    fi

    dpkg-query -W -f='${Status}' "php${PHP_VER}-fpm" 2>/dev/null |
        grep -q "install ok installed" ||
        die "php${PHP_VER}-fpm package is not installed."

    if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        info "Starting $PHP_FPM_SERVICE..."
        systemctl enable --now "$PHP_FPM_SERVICE"
    fi

    if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        systemctl status "$PHP_FPM_SERVICE" --no-pager || true
        die "$PHP_FPM_SERVICE is not running."
    fi

    info "$PHP_FPM_SERVICE: ACTIVE"

    if [[ ! -S "$PHP_FPM_SOCKET" ]]; then
        sleep 2
    fi

    [[ -S "$PHP_FPM_SOCKET" ]] ||
        die "PHP-FPM socket not found: $PHP_FPM_SOCKET"

    info "Socket: $PHP_FPM_SOCKET"
}

ensure_composer() {
    section "COMPOSER"

    COMPOSER_BIN="$(command -v composer || true)"

    if [[ -z "$COMPOSER_BIN" ]]; then
        info "Composer is not installed."
        install_packages composer
        COMPOSER_BIN="$(command -v composer || true)"
    fi

    if [[ -z "$COMPOSER_BIN" ]]; then
        die "Composer could not be installed."
    fi

    local composer_version
    composer_version="$(
        "$COMPOSER_BIN" --version 2>/dev/null |
            sed -nE 's/.*Composer version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' |
            head -1
    )"

    if [[ -z "$composer_version" ]]; then
        die "Unable to determine Composer version."
    fi

    info "Composer: $composer_version"

    local major
    major="${composer_version%%.*}"

    if (( major < 2 )); then
        warn "Composer 2 or newer is recommended."

        if confirm "Install the latest Composer from getcomposer.org?" "Y"; then
            install_official_composer
        else
            die "Composer 2+ is required for this setup."
        fi
    fi
}

install_official_composer() {
    section "INSTALLING COMPOSER"

    local installer="/tmp/composer-setup.php"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Download Composer installer"
        debug "Install Composer into /usr/local/bin/composer"
        COMPOSER_BIN="/usr/local/bin/composer"
        return
    fi

    curl -fsSL https://getcomposer.org/installer -o "$installer"

    local expected actual
    expected="$(curl -fsSL https://composer.github.io/installer.sig)"
    actual="$(
        php -r \
            "echo hash_file('sha384', '$installer');"
    )"

    [[ "$expected" == "$actual" ]] ||
        die "Composer installer signature verification failed."

    php "$installer" \
        --install-dir=/usr/local/bin \
        --filename=composer

    rm -f "$installer"

    COMPOSER_BIN="/usr/local/bin/composer"

    "$COMPOSER_BIN" --version
}

get_user_node_version() {
    su - "$OWNER" -c '
        if [ -s "$HOME/.nvm/nvm.sh" ]; then
            . "$HOME/.nvm/nvm.sh"
            node --version 2>/dev/null || true
        fi
    ' 2>/dev/null || true
}

ensure_node_nvm() {
    local version
    version="$(get_user_node_version)"

    if [[ "$version" =~ ^v([0-9]+) ]]; then
        if (( BASH_REMATCH[1] >= 20 )); then
            NODE_BIN="$version"
            return 0
        fi

        warn "Existing NVM Node.js is too old: $version"
    fi

    return 1
}

install_nvm_and_node() {
    section "NVM / NODE.JS"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Install NVM for user $OWNER"
        debug "Install latest Node.js LTS with NVM"
        return 0
    fi

    local nvm_dir="$OWNER_HOME/.nvm"

    if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
        info "NVM is not installed for $OWNER."
        info "Installing NVM..."

        su - "$OWNER" -c \
            'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'
    fi

    [[ -s "$nvm_dir/nvm.sh" ]] ||
        return 1

    su - "$OWNER" -c \
        "source '$nvm_dir/nvm.sh' && nvm install --lts && nvm alias default 'lts/*'"

    su - "$OWNER" -c \
        "source '$nvm_dir/nvm.sh' && node --version && npm --version"
}

ensure_node() {
    section "NODE.JS / NPM"

    if ensure_node_nvm; then
        info "Using existing NVM Node.js."
        return
    fi

    if install_nvm_and_node; then
        if ensure_node_nvm; then
            info "Using NVM Node.js."
            return
        fi
    fi

    warn "NVM Node.js setup failed."

    if confirm "Install Node.js and npm from Debian/Ubuntu repositories instead?" "Y"; then
        install_packages nodejs npm

        local system_node
        system_node="$(node --version 2>/dev/null || true)"

        if [[ "$system_node" =~ ^v([0-9]+) ]]; then
            if (( BASH_REMATCH[1] < 20 )); then
                warn "Distribution Node.js is $system_node."
                warn "Laravel frontend tooling may require Node.js 20+."
            fi
        fi
    else
        die "Node.js/npm are required for the frontend tooling."
    fi

    NODE_BIN="$(command -v node || true)"
    NPM_BIN="$(command -v npm || true)"

    [[ -n "$NODE_BIN" ]] || die "Node.js is unavailable."
    [[ -n "$NPM_BIN" ]] || die "npm is unavailable."

    info "Node: $("$NODE_BIN" --version)"
    info "npm:  $("$NPM_BIN" --version)"
}

ensure_git() {
    section "GIT"

    if ! command_exists git; then
        install_packages git
    fi

    info "Git: $(git --version)"
}

composer_can_resolve_laravel() {
    local major="$1"
    local test_dir="$2"

    "$COMPOSER_BIN" create-project \
        --dry-run \
        --no-interaction \
        --prefer-dist \
        "laravel/laravel:^${major}.0" \
        "$test_dir" >/dev/null 2>&1
}

detect_laravel_versions() {
    section "LARAVEL COMPATIBILITY"

    echo
    info "Selected PHP: PHP $PHP_VER"
    echo "Testing Laravel compatibility dynamically through Composer..."
    echo

    local temp_root
    temp_root="$(mktemp -d /tmp/laravel-compat-XXXXXX)"

    COMPATIBLE_LARAVEL_VERSIONS=()

    local major

    # Test currently relevant Laravel major versions without assuming
    # that every PHP version maps permanently to a fixed Laravel version.
    for major in 13 12 11 10 9 8; do
        if composer_can_resolve_laravel "$major" "$temp_root/project-$major"; then
            COMPATIBLE_LARAVEL_VERSIONS+=("$major")
        fi
    done

    rm -rf "$temp_root"

    if [[ ${#COMPATIBLE_LARAVEL_VERSIONS[@]} -eq 0 ]]; then
        die "No tested Laravel version is compatible with PHP $PHP_VER according to Composer."
    fi

    RECOMMENDED_LARAVEL="${COMPATIBLE_LARAVEL_VERSIONS[0]}"

    info "Composer-compatible Laravel versions:"
    for i in "${!COMPATIBLE_LARAVEL_VERSIONS[@]}"; do
        local version="${COMPATIBLE_LARAVEL_VERSIONS[$i]}"

        if [[ "$version" == "$RECOMMENDED_LARAVEL" ]]; then
            echo "  $((i + 1))) Laravel $version [RECOMMENDED]"
        else
            echo "  $((i + 1))) Laravel $version"
        fi
    done
}

select_laravel_version() {
    local selection

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        selection=1
    else
        read -rp \
            "Select Laravel version [default: 1 - Laravel $RECOMMENDED_LARAVEL]: " \
            selection

        selection="${selection:-1}"
    fi

    while true; do
        if [[ "$selection" =~ ^[0-9]+$ ]] &&
            (( selection >= 1 && selection <= ${#COMPATIBLE_LARAVEL_VERSIONS[@]} )); then

            LARAVEL_MAJOR="${COMPATIBLE_LARAVEL_VERSIONS[$((selection - 1))]}"
            break
        fi

        warn "Invalid Laravel selection."
        read -rp "Select Laravel version: " selection
    done

    LARAVEL_CONSTRAINT="^${LARAVEL_MAJOR}.0"

    info "Selected Laravel: $LARAVEL_CONSTRAINT"
}

check_php_extensions() {
    section "PHP EXTENSIONS"

    local required=(
        bcmath
        ctype
        curl
        dom
        fileinfo
        filter
        hash
        mbstring
        openssl
        pcre
        PDO
        session
        tokenizer
        xml
        zip
        pdo_mysql
    )

    local missing=()
    local modules

    modules="$("$PHP_BIN" -m 2>/dev/null || true)"

    local ext
    for ext in "${required[@]}"; do
        if ! grep -qiE "^${ext}$" <<< "$modules"; then
            missing+=("$ext")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        info "Required PHP extensions are available."
        return
    fi

    warn "Missing PHP extensions:"
    printf '  %s\n' "${missing[@]}"

    if ! confirm "Install missing PHP extensions?" "Y"; then
        die "Required PHP extensions are missing."
    fi

    local packages=()

    for ext in "${missing[@]}"; do
        case "$ext" in
            pdo_mysql)
                packages+=("php${PHP_VER}-mysql")
                ;;
            PDO|session|ctype|fileinfo|filter|hash|openssl|pcre|tokenizer|dom)
                # Usually provided by php-common / core package.
                ;;
            *)
                packages+=("php${PHP_VER}-${ext}")
                ;;
        esac
    done

    if [[ ${#packages[@]} -gt 0 ]]; then
        install_packages "${packages[@]}"
    fi

    modules="$("$PHP_BIN" -m 2>/dev/null || true)"

    for ext in "${missing[@]}"; do
        case "$ext" in
            PDO|session|ctype|fileinfo|filter|hash|openssl|pcre|tokenizer|dom)
                continue
                ;;
        esac

        grep -qiE "^${ext}$" <<< "$modules" ||
            die "PHP extension still missing: $ext"
    done

    info "PHP extensions verified."
}

select_project_type() {
    section "PROJECT TYPE"

    echo
    echo "  1) Normal Laravel"
    echo "     Composer creates the Laravel application."
    echo
    echo "  2) Vemto"
    echo "     Creates an empty directory for Vemto."
    echo
    echo "  3) GitHub"
    echo "     Imports an existing Laravel project."
    echo

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        PROJECT_TYPE="1"
    else
        read -rp "Select project type [1]: " PROJECT_TYPE
        PROJECT_TYPE="${PROJECT_TYPE:-1}"
    fi

    case "$PROJECT_TYPE" in
        1)
            info "Project type: Normal Laravel"
            ;;
        2)
            info "Project type: Vemto"
            ;;
        3)
            info "Project type: GitHub"
            ;;
        *)
            cancel "Invalid project type."
            ;;
    esac
}

validate_project_name() {
    while true; do
        read -rp "Enter project name: " PROJ

        if [[ "$PROJ" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]$ ]] ||
            [[ "$PROJ" =~ ^[a-zA-Z0-9]$ ]]; then

            if [[ "$PROJ" != *".."* ]]; then
                break
            fi
        fi

        warn "Invalid project name."
        warn "Use letters, numbers, dots, underscores and hyphens."
        warn "The first and last characters must be alphanumeric."
        warn "Double dots are not allowed."
    done

    SERVER_NAME="${PROJ}.test"
}

expand_base_dir() {
    if [[ "$BASE_DIR" == "~" ]]; then
        BASE_DIR="$OWNER_HOME"
    elif [[ "$BASE_DIR" == "~/"* ]]; then
        BASE_DIR="${OWNER_HOME}/${BASE_DIR#~/}"
    fi

    BASE_DIR="${BASE_DIR%/}"
}

select_base_directory() {
    section "PROJECT DIRECTORY"

    echo
    echo "Choose where the project should be stored."
    echo
    echo "Examples:"
    echo "  /var/www"
    echo "  ~/www"
    echo "  /srv/www"
    echo "  /home/username/www"
    echo
    echo "The default uses /var/www."
    echo "If you choose ~/..., your actual Linux username is used automatically."
    echo

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        BASE_DIR="$DEFAULT_BASE_DIR"
    else
        read -rp \
            "Enter base directory for projects [$DEFAULT_BASE_DIR]: " \
            BASE_DIR

        BASE_DIR="${BASE_DIR:-$DEFAULT_BASE_DIR}"
    fi

    expand_base_dir

    [[ -n "$BASE_DIR" ]] || die "Base directory cannot be empty."

    PROJECT_DIR="${BASE_DIR}/${PROJ}"

    info "Base directory: $BASE_DIR"
    info "Project directory: $PROJECT_DIR"
}

prepare_base_directory() {
    if [[ -d "$BASE_DIR" ]]; then
        return
    fi

    warn "Directory does not exist:"
    echo "  $BASE_DIR"

    if ! confirm "Create this directory?" "Y"; then
        cancel "Base directory creation cancelled."
    fi

    run_cmd mkdir -p "$BASE_DIR"
}

check_existing_project() {
    if [[ ! -e "$PROJECT_DIR" ]]; then
        return
    fi

    case "$PROJECT_TYPE" in
        1)
            die "Normal Laravel project directory already exists: $PROJECT_DIR"
            ;;
        2)
            warn "Vemto directory already exists: $PROJECT_DIR"

            if [[ -n "$(find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
                warn "The directory is not empty."
            fi

            confirm "Continue using this directory?" "N" ||
                cancel "Operation cancelled."
            ;;
        3)
            die "GitHub target directory already exists: $PROJECT_DIR"
            ;;
    esac
}

mysql_detect_service() {
    if systemctl is-active --quiet mysql 2>/dev/null; then
        DB_SERVICE="mysql"
    elif systemctl is-active --quiet mariadb 2>/dev/null; then
        DB_SERVICE="mariadb"
    else
        DB_SERVICE=""
    fi
}

ensure_database_service() {
    section "DATABASE"

    mysql_detect_service

    if [[ -n "$DB_SERVICE" ]]; then
        info "Database service: $DB_SERVICE"
        return
    fi

    warn "MySQL/MariaDB is not running."

    if systemctl list-unit-files 2>/dev/null |
        grep -q '^mysql.service'; then

        DB_SERVICE="mysql"

    elif systemctl list-unit-files 2>/dev/null |
        grep -q '^mariadb.service'; then

        DB_SERVICE="mariadb"

    else
        die "MySQL/MariaDB is not installed."
    fi

    run_cmd systemctl enable --now "$DB_SERVICE"

    [[ "$DRY_RUN" -eq 1 ]] && return

    systemctl is-active --quiet "$DB_SERVICE" ||
        die "$DB_SERVICE could not be started."
}

setup_mysql_connection() {
    section "MYSQL CONNECTION"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Ask for MySQL root password."
        return
    fi

    local root_password

    read -rsp \
        "Enter MySQL root password (leave blank for socket authentication): " \
        root_password

    echo

    if [[ -z "$root_password" ]]; then
        MYSQL_CMD=(mysql -u root)
    else
        MYSQL_OPTS_FILE="$(mktemp)"
        chmod 600 "$MYSQL_OPTS_FILE"

        cat > "$MYSQL_OPTS_FILE" <<EOF
[client]
user=root
password=${root_password}
host=${MYSQL_HOST}
EOF

        MYSQL_CMD=(
            mysql
            "--defaults-extra-file=$MYSQL_OPTS_FILE"
        )
    fi

    "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1 ||
        die "Unable to connect to MySQL as root."

    info "MySQL connection successful."
}

validate_database_name() {
    DB_NAME="$PROJ"

    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        read -rp \
            "Database name [default: $DB_NAME]: " \
            INPUT_DB_NAME

        DB_NAME="${INPUT_DB_NAME:-$DB_NAME}"
    fi

    [[ "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]] ||
        die "Invalid database name."
}

escape_mysql_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"

    printf '%s' "$value"
}

create_database() {
    section "CREATE DATABASE"

    validate_database_name

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`"
        return
    fi

    local db_name_sql
    db_name_sql="$(escape_mysql_string "$DB_NAME")"

    "${MYSQL_CMD[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name_sql}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;
SQL

    info "Database ready: $DB_NAME"
}

create_database_user() {
    section "DATABASE USER"

    DB_USERNAME="root"
    DB_PASSWORD=""

    if ! confirm "Create a dedicated MySQL user for this project?" "Y"; then
        warn "Using root credentials in .env."
        return
    fi

    DB_USERNAME="${PROJ}_user"

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        DB_PASSWORD="$(tr -dc 'A-Za-z0-9!@#%+=_' </dev/urandom | head -c 32 || true)"
    else
        read -rsp \
            "Enter password for '$DB_USERNAME' (leave blank to generate): " \
            DB_PASSWORD
        echo
    fi

    if [[ -z "$DB_PASSWORD" ]]; then
        DB_PASSWORD="$(tr -dc 'A-Za-z0-9!@#%+=_' </dev/urandom | head -c 32 || true)"
    fi

    [[ ${#DB_PASSWORD} -ge 20 ]] ||
        die "Database password generation failed."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Create MySQL user $DB_USERNAME@$MYSQL_HOST"
        debug "Grant privileges on database $DB_NAME"
        return
    fi

    local password_sql
    local db_name_sql
    local user_sql

    password_sql="$(escape_mysql_string "$DB_PASSWORD")"
    db_name_sql="$(escape_mysql_string "$DB_NAME")"
    user_sql="$(escape_mysql_string "$DB_USERNAME")"

    "${MYSQL_CMD[@]}" <<SQL
CREATE USER IF NOT EXISTS '${user_sql}'@'${MYSQL_HOST}'
IDENTIFIED BY '${password_sql}';

ALTER USER '${user_sql}'@'${MYSQL_HOST}'
IDENTIFIED BY '${password_sql}';

GRANT ALL PRIVILEGES ON \`${db_name_sql}\`.*
TO '${user_sql}'@'${MYSQL_HOST}';

FLUSH PRIVILEGES;
SQL

    info "Dedicated database user created: $DB_USERNAME@$MYSQL_HOST"
}

clone_github_project() {
    section "GITHUB IMPORT"

    local github_url
    local branch
    local clone_url

    read -rp "Enter GitHub repository URL: " github_url

    [[ "$github_url" =~ ^https://github\.com/[^/]+/[^/]+/?(\.git)?$ ||
       "$github_url" =~ ^git@github\.com:[^/]+/[^/]+/?(\.git)?$ ]] ||
        die "Invalid GitHub URL."

    github_url="${github_url%/}"

    if ! [[ "$github_url" == *.git ]]; then
        clone_url="${github_url}.git"
    else
        clone_url="$github_url"
    fi

    info "Testing repository access..."

    if ! git ls-remote "$github_url" HEAD >/dev/null 2>&1; then
        if ! git ls-remote "$clone_url" HEAD >/dev/null 2>&1; then
            die "Unable to access the GitHub repository.

Check:
  - Repository URL
  - Internet connection
  - SSH keys for private repositories
  - GitHub authentication
  - Repository permissions"
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "git clone $clone_url $PROJECT_DIR"
        return
    fi

    read -rp "Git branch/tag to clone [default: default branch]: " branch

    if [[ -n "$branch" ]]; then
        su - "$OWNER" -c \
            "git clone --branch '$branch' '$clone_url' '$PROJECT_DIR'"
    else
        su - "$OWNER" -c \
            "git clone '$clone_url' '$PROJECT_DIR'"
    fi

    [[ -d "$PROJECT_DIR/.git" ]] ||
        die "Git clone did not create a valid repository."

    info "GitHub repository cloned successfully."
}

create_normal_laravel() {
    section "CREATE LARAVEL APPLICATION"

    mkdir -p "$PROJECT_DIR"

    if [[ -d "$PROJECT_DIR" ]] &&
        [[ -n "$(find "$PROJECT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        die "Target directory is not empty."
    fi

    chown "$OWNER:$WEB_GROUP" "$PROJECT_DIR"

    info "Creating Laravel $LARAVEL_MAJOR with PHP $PHP_VER..."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "$PHP_BIN $COMPOSER_BIN create-project laravel/laravel $PROJECT_DIR $LARAVEL_CONSTRAINT"
        return
    fi

    su - "$OWNER" -c \
        "'$PHP_BIN' -d memory_limit=-1 '$COMPOSER_BIN' create-project \
        --prefer-dist \
        laravel/laravel \
        '$PROJECT_DIR' \
        '$LARAVEL_CONSTRAINT'"

    [[ -f "$PROJECT_DIR/artisan" ]] ||
        die "Laravel installation failed: artisan not found."

    info "Laravel application created."
}

prepare_vemto_project() {
    section "PREPARE VEMTO PROJECT"

    mkdir -p "$PROJECT_DIR"

    info "Vemto project directory:"
    info "$PROJECT_DIR"

    warn "Vemto will generate the Laravel application."

    if [[ "$DRY_RUN" -eq 0 ]]; then
        if [[ -n "$(find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            warn "Existing files were preserved."
        fi
    fi
}

import_github_project() {
    clone_github_project

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi

    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        warn "No artisan file was found after cloning."
        warn "The repository may not yet contain a complete Laravel application."
    fi
}

ensure_laravel_directories() {
    section "LARAVEL DIRECTORIES"

    mkdir -p "$PROJECT_DIR/storage"
    mkdir -p "$PROJECT_DIR/bootstrap/cache"
    mkdir -p "$PROJECT_DIR/public"

    info "storage: OK"
    info "bootstrap/cache: OK"
    info "public: OK"
}

create_env() {
    section "ENVIRONMENT"

    local env_file="$PROJECT_DIR/.env"

    if [[ -f "$env_file" ]]; then
        warn ".env already exists. Preserving existing file."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Create $env_file"
        return
    fi

    cat > "$env_file" <<EOF
APP_NAME=${PROJ}
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://${SERVER_NAME}

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=${MYSQL_HOST}
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}

BROADCAST_CONNECTION=log
CACHE_STORE=file
FILESYSTEM_DISK=local
QUEUE_CONNECTION=database
SESSION_DRIVER=file
SESSION_LIFETIME=120

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=log
MAIL_HOST=127.0.0.1
MAIL_PORT=2525
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS="hello@example.com"
MAIL_FROM_NAME="\${APP_NAME}"

VITE_APP_NAME="\${APP_NAME}"
EOF

    chmod 640 "$env_file"

    info ".env created."
}

set_project_permissions() {
    section "PROJECT PERMISSIONS"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "chown -R $OWNER:$WEB_GROUP $PROJECT_DIR"
        debug "Set directories to 755 and files to 644"
        debug "Set storage and bootstrap/cache to writable"
        return
    fi

    chown -R "$OWNER:$WEB_GROUP" "$PROJECT_DIR"

    find "$PROJECT_DIR" -type d -exec chmod 755 {} +
    find "$PROJECT_DIR" -type f -exec chmod 644 {} +

    chmod -R 775 "$PROJECT_DIR/storage"
    chmod -R 775 "$PROJECT_DIR/bootstrap/cache"

    [[ -f "$PROJECT_DIR/.env" ]] &&
        chmod 640 "$PROJECT_DIR/.env"

    info "Basic permissions configured."
}

configure_acl() {
    section "WEB SERVER ACCESS / ACL"

    if ! command_exists setfacl || ! command_exists getfacl; then
        warn "ACL tools are unavailable."
        warn "Using group-permission fallback."

        if [[ "$DRY_RUN" -eq 0 ]]; then
            chgrp -R "$WEB_GROUP" "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
            chmod -R g+rwX "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
        else
            debug "chgrp -R $WEB_GROUP storage bootstrap/cache"
            debug "chmod -R g+rwX storage bootstrap/cache"
        fi

        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Grant Apache traversal permissions for $PROJECT_DIR"
        debug "Grant Apache rwX permissions to storage"
        debug "Grant Apache rwX permissions to bootstrap/cache"
        return
    fi

    local current="/"
    local part

    IFS='/' read -ra parts <<< "${PROJECT_DIR#/}"

    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue

        current="${current%/}/${part}"

        if [[ -d "$current" ]]; then
            setfacl -m "u:${WEB_USER}:--x" "$current" 2>/dev/null || true
        fi
    done

    setfacl -R -m "u:${WEB_USER}:rwX" "$PROJECT_DIR/storage"
    setfacl -R -m "u:${WEB_USER}:rwX" "$PROJECT_DIR/bootstrap/cache"

    setfacl -R -d -m "u:${WEB_USER}:rwX" "$PROJECT_DIR/storage"
    setfacl -R -d -m "u:${WEB_USER}:rwX" "$PROJECT_DIR/bootstrap/cache"

    info "ACL permissions configured."
}

generate_laravel_key() {
    section "LARAVEL APPLICATION KEY"

    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        warn "artisan not found. Skipping key generation."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "cd $PROJECT_DIR && $PHP_BIN artisan key:generate --force"
        return
    fi

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan key:generate --force"

    info "Application key generated."
}

clear_laravel_cache() {
    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        return
    fi

    section "LARAVEL CACHE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "php artisan config:clear"
        debug "php artisan cache:clear"
        return
    fi

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan config:clear" ||
        warn "config:clear failed."

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan cache:clear" ||
        warn "cache:clear failed."
}

check_ports() {
    section "PORT CHECK"

    if ! command_exists ss; then
        warn "ss command unavailable. Skipping port check."
        return
    fi

    local ports_in_use

    ports_in_use="$(
        ss -tlnp 2>/dev/null |
            grep -E ':(80|443)[[:space:]]' || true
    )"

    if [[ -n "$ports_in_use" ]]; then
        warn "Port 80 or 443 is already in use."
        echo "$ports_in_use"

        if ! confirm "Continue anyway?" "N"; then
            cancel "Port conflict check cancelled."
        fi
    else
        info "Ports 80/443 are available."
    fi
}

enable_apache_modules() {
    section "APACHE MODULES"

    local modules=(
        rewrite
        proxy
        proxy_fcgi
        setenvif
    )

    local mod

    for mod in "${modules[@]}"; do
        if ! a2query -m "$mod" >/dev/null 2>&1; then
            info "Enabling Apache module: $mod"

            if [[ "$DRY_RUN" -eq 0 ]]; then
                a2enmod "$mod" >/dev/null
            else
                debug "a2enmod $mod"
            fi
        fi
    done
}

setup_https() {
    section "LOCAL HTTPS"

    HTTPS_ENABLED=0

    if ! confirm "Enable HTTPS with a self-signed certificate for local development?" "N"; then
        return
    fi

    HTTPS_ENABLED=1

    SSL_CERT="/etc/ssl/certs/${PROJ}.test.crt"
    SSL_KEY="/etc/ssl/private/${PROJ}.test.key"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Generate self-signed certificate: $SSL_CERT"
        debug "Generate private key: $SSL_KEY"
        return
    fi

    mkdir -p /etc/ssl/private

    openssl req \
        -x509 \
        -nodes \
        -days 825 \
        -newkey rsa:2048 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -subj "/CN=${SERVER_NAME}" \
        -addext "subjectAltName=DNS:${SERVER_NAME}"

    chmod 600 "$SSL_KEY"
    chmod 644 "$SSL_CERT"

    if ! a2query -m ssl >/dev/null 2>&1; then
        a2enmod ssl >/dev/null
    fi
}

create_apache_vhost() {
    section "APACHE VIRTUALHOST"

    local vhost_file="${APACHE_SITES_AVAILABLE}/${PROJ}.test.conf"

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        APP_URL="https://${SERVER_NAME}"
    else
        APP_URL="http://${SERVER_NAME}"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Create Apache VirtualHost: $vhost_file"
        return
    fi

    cat > "$vhost_file" <<EOF
<VirtualHost *:80>
    ServerName ${SERVER_NAME}

    DocumentRoot ${PROJECT_DIR}/public

    <Directory ${PROJECT_DIR}/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html
    </Directory>

    <FilesMatch "\.php$">
        SetHandler "proxy:unix:${PHP_FPM_SOCKET}|fcgi://localhost/"
    </FilesMatch>

    <FilesMatch "^\.">
        Require all denied
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${PROJ}_error.log
    CustomLog \${APACHE_LOG_DIR}/${PROJ}_access.log combined
</VirtualHost>
EOF

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        cat >> "$vhost_file" <<EOF

<VirtualHost *:443>
    ServerName ${SERVER_NAME}

    DocumentRoot ${PROJECT_DIR}/public

    SSLEngine on
    SSLCertificateFile ${SSL_CERT}
    SSLCertificateKeyFile ${SSL_KEY}

    <Directory ${PROJECT_DIR}/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html
    </Directory>

    <FilesMatch "\.php$">
        SetHandler "proxy:unix:${PHP_FPM_SOCKET}|fcgi://localhost/"
    </FilesMatch>

    <FilesMatch "^\.">
        Require all denied
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${PROJ}_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/${PROJ}_ssl_access.log combined
</VirtualHost>
EOF
    fi

    info "Apache configuration created: $vhost_file"
}

update_env_app_url() {
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Set APP_URL=$APP_URL in .env"
        return
    fi

    sed -i \
        "s|^APP_URL=.*|APP_URL=${APP_URL}|" \
        "$PROJECT_DIR/.env"
}

configure_hosts() {
    section "LOCAL DOMAIN"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "Add 127.0.0.1 $SERVER_NAME to $HOSTS_FILE if missing"
        return
    fi

    if grep -qE \
        "^[[:space:]]*127\.0\.0\.1[[:space:]]+.*(^|[[:space:]])${SERVER_NAME}([[:space:]]|$)" \
        "$HOSTS_FILE"; then

        info "$SERVER_NAME already exists in /etc/hosts."
        return
    fi

    echo "127.0.0.1    ${SERVER_NAME}" >> "$HOSTS_FILE"

    info "Added $SERVER_NAME to /etc/hosts."
}

enable_apache_site() {
    section "ENABLE APACHE SITE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "a2ensite ${PROJ}.test.conf"
        return
    fi

    a2ensite "${PROJ}.test.conf" >/dev/null
    info "Apache site enabled."
}

apache_config_test() {
    section "APACHE CONFIGURATION TEST"

    local output
    local status

    set +e
    output="$(apache2ctl configtest 2>&1)"
    status=$?
    set -e

    echo "$output"

    if [[ "$status" -eq 0 ]]; then
        info "Apache configuration: OK"
        return
    fi

    if grep -qiE 'syntax error|AH0[0-9]+:' <<< "$output"; then
        error "Apache configuration test FAILED."
        error "Apache will NOT be reloaded."
        exit 2
    fi

    warn "Apache returned a non-zero result without a clear syntax error."
    warn "Apache will NOT be reloaded until this is checked."

    exit 2
}

reload_apache() {
    section "RELOAD APACHE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "systemctl reload apache2"
        return
    fi

    systemctl reload apache2

    systemctl is-active --quiet apache2 ||
        die "Apache is not active after reload."

    info "Apache reloaded successfully."
}

test_laravel_database() {
    section "LARAVEL DATABASE TEST"

    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        warn "artisan not found. Database test deferred."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "php artisan config:clear"
        debug "php artisan cache:clear"
        debug "php artisan tinker database connection test"
        return
    fi

    clear_laravel_cache

    local output

    if output="$(
        su - "$OWNER" -c \
            "cd '$PROJECT_DIR' && '$PHP_BIN' artisan tinker --execute='DB::connection()->getPdo(); echo \"DATABASE_OK\\n\";'" \
            2>&1
    )"; then

        if grep -q "DATABASE_OK" <<< "$output"; then
            info "Laravel database connection: OK"
            return
        fi
    fi

    warn "Laravel database connection test failed."
    echo "$output"
}

detect_laravel_version() {
    LARAVEL_VERSION="N/A"

    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        LARAVEL_VERSION="Dry-run"
        return
    fi

    LARAVEL_VERSION="$(
        su - "$OWNER" -c \
            "cd '$PROJECT_DIR' && '$PHP_BIN' artisan --version" \
            2>/dev/null || echo "Unable to determine"
    )"
}

http_test() {
    section "HTTP TEST"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        debug "curl -H 'Host: $SERVER_NAME' http://127.0.0.1/"
        return
    fi

    local url
    local status

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        url="https://${SERVER_NAME}"
        status="$(
            curl -k -s \
                -o /dev/null \
                -w "%{http_code}" \
                --resolve "${SERVER_NAME}:443:127.0.0.1" \
                "$url" || echo "000"
        )"
    else
        url="http://${SERVER_NAME}"
        status="$(
            curl -s \
                -o /dev/null \
                -w "%{http_code}" \
                -H "Host: ${SERVER_NAME}" \
                http://127.0.0.1/ || echo "000"
        )"
    fi

    if [[ "$status" =~ ^[23] ]]; then
        info "HTTP status: $status"
    else
        warn "HTTP test returned status: $status"
        warn "Check Apache logs."
    fi
}

final_verification() {
    section "FINAL VERIFICATION"

    detect_laravel_version

    echo
    echo "Project"
    echo "-------"
    echo "Name:             $PROJ"
    echo "Type:             $(
        case "$PROJECT_TYPE" in
            1) echo "Normal Laravel" ;;
            2) echo "Vemto" ;;
            3) echo "GitHub" ;;
        esac
    )"
    echo "Directory:        $PROJECT_DIR"
    echo "URL:              $APP_URL"

    echo
    echo "PHP"
    echo "---"
    echo "Version:          PHP $PHP_VER"
    echo "Binary:           $PHP_BIN"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$PHP_BIN" -v | head -1
    fi

    echo
    echo "PHP-FPM"
    echo "-------"
    echo "Service:          $PHP_FPM_SERVICE"
    echo "Socket:           $PHP_FPM_SOCKET"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
            echo "Service status:   ACTIVE"
        else
            echo "Service status:   FAILED"
        fi

        if [[ -S "$PHP_FPM_SOCKET" ]]; then
            echo "Socket status:    OK"
        else
            echo "Socket status:    MISSING"
        fi
    else
        echo "Status:           DRY-RUN"
    fi

    echo
    echo "Composer"
    echo "--------"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$COMPOSER_BIN" --version | head -1
    else
        echo "Status:           DRY-RUN"
    fi

    echo
    echo "Node.js / npm"
    echo "-------------"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        su - "$OWNER" -c '
            if [ -s "$HOME/.nvm/nvm.sh" ]; then
                . "$HOME/.nvm/nvm.sh"
            fi
            printf "Node: "
            node --version 2>/dev/null || echo "not available"
            printf "npm:  "
            npm --version 2>/dev/null || echo "not available"
        ' || true
    else
        echo "Status:           DRY-RUN"
    fi

    echo
    echo "Git"
    echo "---"
    echo "$(git --version 2>/dev/null || echo "not available")"

    echo
    echo "Apache"
    echo "------"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        apache2 -v | head -1
        if systemctl is-active --quiet apache2; then
            echo "Service status:   ACTIVE"
        else
            echo "Service status:   FAILED"
        fi
    else
        echo "Status:           DRY-RUN"
    fi

    echo
    echo "Database"
    echo "--------"
    echo "Database:         $DB_NAME"
    echo "Username:         $DB_USERNAME"

    echo
    echo "Laravel"
    echo "-------"
    echo "Version:          $LARAVEL_VERSION"

    echo
    echo "Permissions"
    echo "-----------"

    if [[ "$DRY_RUN" -eq 0 && -d "$PROJECT_DIR" ]]; then
        echo "Owner:            $(stat -c '%U' "$PROJECT_DIR")"
        echo "Group:            $(stat -c '%G' "$PROJECT_DIR")"
        echo "storage:          $(stat -c '%A' "$PROJECT_DIR/storage")"
        echo "bootstrap/cache:  $(stat -c '%A' "$PROJECT_DIR/bootstrap/cache")"
    else
        echo "Status:           DRY-RUN"
    fi
}

final_instructions() {
    section "PROJECT READY"

    echo
    echo "Project:"
    echo "  $PROJ"
    echo
    echo "Directory:"
    echo "  $PROJECT_DIR"
    echo
    echo "URL:"
    echo "  $APP_URL"
    echo
    echo "PHP:"
    echo "  PHP $PHP_VER"
    echo
    echo "Database:"
    echo "  $DB_NAME"
    echo

    case "$PROJECT_TYPE" in
        1)
            echo "Next steps:"
            echo
            echo "  cd $PROJECT_DIR"
            echo "  $PHP_BIN artisan migrate"
            echo
            echo "Frontend:"
            echo "  npm install"
            echo "  npm run dev"
            ;;

        2)
            echo "Vemto next steps:"
            echo
            echo "  1. Open Vemto."
            echo "  2. Select:"
            echo
            echo "       $PROJECT_DIR"
            echo
            echo "  3. Generate the Laravel application."
            echo "  4. Then run:"
            echo
            echo "       cd $PROJECT_DIR"
            echo "       $PHP_BIN artisan key:generate"
            echo "       $PHP_BIN artisan migrate"
            ;;

        3)
            echo "GitHub project imported."
            echo
            echo "Next steps:"
            echo
            echo "  cd $PROJECT_DIR"
            echo "  $PHP_BIN artisan migrate"
            echo
            echo "Frontend:"
            echo "  npm install"
            echo "  npm run dev"
            ;;
    esac

    echo
    echo "Apache:"
    echo "  ${APACHE_SITES_AVAILABLE}/${PROJ}.test.conf"
    echo
    echo "PHP-FPM:"
    echo "  $PHP_FPM_SOCKET"
    echo

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "DRY-RUN completed. No system changes were made."
    else
        info "Installation and configuration completed successfully."
        info "Log file: $LOG_FILE"
    fi
}

main() {
    parse_arguments "$@"

    detect_owner "$@"
    log_setup

    section "$SCRIPT_NAME $SCRIPT_VERSION"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "DRY-RUN MODE: no mutating operation will be executed."
    fi

    detect_os
    check_basic_system
    check_apache

    detect_php_fpm_versions
    select_php_version
    verify_php_service

    ensure_composer
    ensure_git
    ensure_node

    # Laravel version detection is useful for Normal Laravel mode.
    # For Vemto and GitHub projects, the actual application version may differ.
    if [[ "$PROJECT_TYPE" == "" ]]; then
        select_project_type
    fi

    if [[ "$PROJECT_TYPE" == "1" ]]; then
        detect_laravel_versions
        select_laravel_version
    else
        # Still establish a Laravel-compatible environment when possible.
        detect_laravel_versions || true
        if [[ ${#COMPATIBLE_LARAVEL_VERSIONS[@]:-0} -gt 0 ]]; then
            RECOMMENDED_LARAVEL="${COMPATIBLE_LARAVEL_VERSIONS[0]}"
            LARAVEL_MAJOR="$RECOMMENDED_LARAVEL"
            LARAVEL_CONSTRAINT="^${LARAVEL_MAJOR}.0"
        fi
    fi

    check_php_extensions

    validate_project_name
    select_base_directory
    prepare_base_directory
    check_existing_project

    ensure_database_service
    setup_mysql_connection
    create_database
    create_database_user

    case "$PROJECT_TYPE" in
        1)
            create_normal_laravel
            ;;
        2)
            prepare_vemto_project
            ;;
        3)
            import_github_project
            ;;
    esac

    ensure_laravel_directories
    create_env

    set_project_permissions
    configure_acl

    if [[ "$PROJECT_TYPE" == "1" ]]; then
        generate_laravel_key
    elif [[ "$PROJECT_TYPE" == "3" && -f "$PROJECT_DIR/artisan" ]]; then
        generate_laravel_key
    fi

    clear_laravel_cache

    check_ports
    enable_apache_modules
    setup_https
    create_apache_vhost
    update_env_app_url
    configure_hosts
    enable_apache_site

    apache_config_test
    reload_apache

    if [[ "$PROJECT_TYPE" == "1" ||
          ("$PROJECT_TYPE" == "3" && -f "$PROJECT_DIR/artisan") ]]; then
        test_laravel_database
    else
        info "Laravel database test deferred until Vemto generates the application."
    fi

    http_test
    final_verification
    final_instructions
}

main "$@"
