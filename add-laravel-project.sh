#!/usr/bin/env bash
#
# add-laravel-project.sh
#
# Laravel / Vemto local development project provisioner
#
# Supported:
#   - Debian
#   - Ubuntu
#   - systemd
#   - Apache 2.4+
#   - MySQL / MariaDB
#
# Features:
#   - Dynamic PHP-FPM detection
#   - Installs PHP if no usable PHP-FPM exists
#   - Multiple PHP versions supported
#   - PHP version selection
#   - Conservative Laravel/PHP compatibility recommendations
#   - Composer compatibility check
#   - Normal Laravel project
#   - Vemto project
#   - GitHub project import
#   - Dynamic project directory
#   - Creates missing base directories after confirmation
#   - MySQL/MariaDB database creation
#   - Optional dedicated database user
#   - Apache VirtualHost
#   - Per-project PHP-FPM socket
#   - ACL support for /home/... projects
#   - Group-permission fallback if ACL is unavailable
#   - NVM-aware Node.js detection
#   - Node.js LTS fallback
#   - Git detection
#   - Optional local HTTPS
#   - Dry-run mode
#   - Non-interactive mode
#   - Safe logging
#   - Consolidated cleanup
#   - Apache configuration validation
#   - Laravel configuration/database verification
#   - HTTP verification
#
# Usage:
#   sudo ./add-laravel-project.sh
#   sudo ./add-laravel-project.sh --help
#   sudo ./add-laravel-project.sh --version
#   sudo ./add-laravel-project.sh --dry-run
#
# Version:
#   1.0.0
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

DEFAULT_BASE_DIR="/var/www"

APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
APACHE_SITES_ENABLED="/etc/apache2/sites-enabled"
HOSTS_FILE="/etc/hosts"

WEB_USER="www-data"
WEB_GROUP="www-data"

MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"

LOG_FILE="/var/log/add-laravel-project.log"

DRY_RUN=0
NON_INTERACTIVE=0
QUIET=0

OWNER=""
OWNER_HOME=""

PROJECT_TYPE=""
PROJ=""
SERVER_NAME=""
BASE_DIR=""
PROJECT_DIR=""

PHP_VER=""
PHP_BIN=""
PHP_FPM_SERVICE=""
PHP_FPM_SOCKET=""

LARAVEL_MAJOR=""
LARAVEL_CONSTRAINT=""

DB_SERVICE=""
DB_NAME=""
DB_USERNAME=""
DB_PASSWORD=""

MYSQL_OPTS_FILE=""

VHOST_FILE=""

HTTPS_ENABLED=0

NVM_DIR=""

###############################################################################
# COLORS
###############################################################################

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
RESET="\033[0m"

###############################################################################
# OUTPUT
###############################################################################

info() {
    [[ "$QUIET" -eq 1 ]] && return 0
    echo -e "[${GREEN}INFO${RESET}] $*"
}

warn() {
    echo -e "[${YELLOW}WARN${RESET}] $*" >&2
}

error() {
    echo -e "[${RED}ERROR${RESET}] $*" >&2
}

debug() {
    [[ "$QUIET" -eq 1 ]] && return 0
    echo -e "[${BLUE}DEBUG${RESET}] $*"
}

section() {
    [[ "$QUIET" -eq 1 ]] && return 0

    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}

die() {
    error "$*"
    exit 2
}

###############################################################################
# LOGGING
###############################################################################

setup_logging() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi

    if [[ ! -e "$LOG_FILE" ]]; then
        if ! install -m 600 /dev/null "$LOG_FILE" 2>/dev/null; then
            LOG_FILE="${OWNER_HOME:-/tmp}/.add-laravel-project.log"
            (umask 077 && touch "$LOG_FILE") || true
        fi
    fi

    if [[ -w "$LOG_FILE" ]]; then
        {
            echo
            echo "============================================================"
            echo "$(date '+%Y-%m-%d %H:%M:%S') $SCRIPT_NAME $SCRIPT_VERSION"
            echo "============================================================"
        } >> "$LOG_FILE"
    fi
}

log() {
    local message="$*"

    if [[ -n "${LOG_FILE:-}" && -w "$LOG_FILE" ]]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$LOG_FILE"
    fi
}

###############################################################################
# COMMAND EXECUTION
###############################################################################

run_cmd() {
    log "COMMAND: $*"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] $*"
        return 0
    fi

    "$@"
}

run_shell() {
    log "SHELL: $*"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] $*"
        return 0
    fi

    bash -c "$*"
}

###############################################################################
# CLEANUP
###############################################################################

cleanup() {
    local exit_code=$?

    if [[ -n "${MYSQL_OPTS_FILE:-}" && -f "$MYSQL_OPTS_FILE" ]]; then
        rm -f "$MYSQL_OPTS_FILE" 2>/dev/null || true
    fi

    if [[ "$exit_code" -eq 0 ]]; then
        log "Script finished successfully."
    else
        log "Script exited with code $exit_code."
    fi
}

on_error() {
    local line="$1"
    local command="$2"

    error "Script failed at line ${line}."
    error "Command: ${command}"

    log "ERROR line=${line} command=${command}"
}

trap cleanup EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

###############################################################################
# HELP
###############################################################################

show_help() {
    cat <<EOF

$SCRIPT_NAME $SCRIPT_VERSION

Creates and configures a Laravel/Vemto/GitHub project on Debian/Ubuntu.

USAGE

  sudo $SCRIPT_NAME
  sudo $SCRIPT_NAME --help
  sudo $SCRIPT_NAME --version
  sudo $SCRIPT_NAME --dry-run
  sudo $SCRIPT_NAME --non-interactive

OPTIONS

  --help
      Show this help.

  --version
      Show script version.

  --dry-run
      Show intended changes without modifying the system.

  --non-interactive
      Use defaults wherever possible.

  --quiet
      Reduce console output.

EXAMPLES

  sudo $SCRIPT_NAME

  sudo $SCRIPT_NAME --dry-run

  sudo $SCRIPT_NAME --non-interactive

SUPPORTED

  Debian
  Ubuntu

The script assumes:

  - systemd
  - Apache 2.4+
  - MySQL or MariaDB
  - sudo privileges
  - Bash 4+

EOF
}

###############################################################################
# ARGUMENTS
###############################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;

            --version|-v)
                echo "$SCRIPT_VERSION"
                exit 0
                ;;

            --dry-run)
                DRY_RUN=1
                ;;

            --non-interactive)
                NON_INTERACTIVE=1
                ;;

            --quiet)
                QUIET=1
                ;;

            *)
                die "Unknown option: $1"
                ;;
        esac

        shift
    done
}

###############################################################################
# ROOT / OWNER
###############################################################################

detect_owner() {
    if [[ "$EUID" -ne 0 ]]; then
        exec sudo -E "$0" "$@"
    fi

    if [[ -z "${SUDO_USER:-}" ]]; then
        die "Run the script with sudo from a normal user account."
    fi

    OWNER="$SUDO_USER"

    OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"

    [[ -n "$OWNER_HOME" ]] ||
        die "Unable to determine home directory for $OWNER."

    info "Project owner: $OWNER"
    info "Owner home: $OWNER_HOME"
}

###############################################################################
# OS
###############################################################################

check_os() {
    section "OPERATING SYSTEM"

    [[ -f /etc/os-release ]] ||
        die "/etc/os-release not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            info "Detected: ${PRETTY_NAME}"
            ;;
        *)
            die "This script supports Debian and Ubuntu only."
            ;;
    esac
}

###############################################################################
# APT
###############################################################################

APT_UPDATED=0

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

###############################################################################
# BASIC COMMANDS
###############################################################################

ensure_basic_dependencies() {
    section "BASIC DEPENDENCIES"

    if ! command -v apache2 >/dev/null 2>&1; then
        info "Apache is not installed."
        install_packages apache2
    fi

    if ! command -v ss >/dev/null 2>&1; then
        install_packages iproute2
    fi

    if ! command -v curl >/dev/null 2>&1; then
        install_packages curl
    fi

    if ! command -v git >/dev/null 2>&1; then
        info "Git is not installed."
        install_packages git
    fi

    if ! command -v setfacl >/dev/null 2>&1; then
        info "ACL utilities are not installed."
        install_packages acl
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        warn "MySQL client is not installed."

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            install_packages default-mysql-client
        else
            read -rp "Install MySQL client now? [Y/n]: " answer
            answer="${answer:-Y}"

            if [[ "$answer" =~ ^[Yy]$ ]]; then
                install_packages default-mysql-client
            else
                die "MySQL client is required."
            fi
        fi
    fi
}

###############################################################################
# APACHE
###############################################################################

check_apache() {
    section "APACHE"

    local version
    version="$(apache2 -v 2>/dev/null | head -1 || true)"

    [[ "$version" =~ Apache/2\.4 ]] ||
        die "Apache 2.4+ is required. Detected: $version"

    info "$version"

    run_cmd systemctl enable --now apache2

    if ! systemctl is-active --quiet apache2; then
        systemctl status apache2 --no-pager || true
        die "Apache is not running."
    fi
}

###############################################################################
# PHP-FPM DETECTION
###############################################################################

detect_php_fpm_versions() {
    INSTALLED_PHP_VERSIONS=()

    local versions=()

    while IFS= read -r version; do
        [[ -n "$version" ]] && versions+=("$version")
    done < <(
        find /usr/sbin /usr/bin -maxdepth 1 \
            -type f \
            \( -name 'php-fpm[0-9]*' -o -name 'php-fpm[0-9]*.[0-9]*' \) \
            -printf '%f\n' 2>/dev/null |
        sed -nE 's/^php-fpm([0-9]+\.[0-9]+)$/\1/p' |
        sort -Vu
    )

    if [[ ${#versions[@]} -eq 0 ]]; then
        while IFS= read -r service; do
            [[ -n "$service" ]] || continue

            local version
            version="$(sed -nE 's/^php([0-9]+\.[0-9]+)-fpm\.service$/\1/p' <<< "$service")"

            [[ -n "$version" ]] && versions+=("$version")
        done < <(
            systemctl list-unit-files \
                'php*-fpm.service' \
                --no-legend \
                --no-pager 2>/dev/null |
            awk '{print $1}'
        )
    fi

    mapfile -t INSTALLED_PHP_VERSIONS < <(
        printf '%s\n' "${versions[@]}" |
        sort -Vu
    )
}

###############################################################################
# INSTALL PHP
###############################################################################

install_default_php() {
    section "PHP NOT FOUND"

    warn "No PHP-FPM installation was detected."

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        answer="Y"
    else
        read -rp "Install the default PHP version from APT? [Y/n]: " answer
        answer="${answer:-Y}"
    fi

    [[ "$answer" =~ ^[Yy]$ ]] ||
        die "PHP-FPM is required."

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
        php-gd

    detect_php_fpm_versions

    [[ ${#INSTALLED_PHP_VERSIONS[@]} -gt 0 ]] ||
        die "PHP installation completed but PHP-FPM was not detected."
}

###############################################################################
# PHP VERSION SELECTION
###############################################################################

select_php_version() {
    section "INSTALLED PHP-FPM VERSIONS"

    for i in "${!INSTALLED_PHP_VERSIONS[@]}"; do
        echo "  $((i + 1))) PHP ${INSTALLED_PHP_VERSIONS[$i]}"
    done

    local highest="${INSTALLED_PHP_VERSIONS[-1]}"

    echo
    info "Highest installed PHP-FPM version: PHP $highest"

    local selection

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        selection="${#INSTALLED_PHP_VERSIONS[@]}"
    else
        while true; do
            read -rp \
                "Select PHP version [default: ${#INSTALLED_PHP_VERSIONS[@]} - PHP $highest]: " \
                selection

            selection="${selection:-${#INSTALLED_PHP_VERSIONS[@]}}"

            if [[ "$selection" =~ ^[0-9]+$ ]] &&
               (( selection >= 1 && selection <= ${#INSTALLED_PHP_VERSIONS[@]} )); then
                break
            fi

            if printf '%s\n' "${INSTALLED_PHP_VERSIONS[@]}" |
                grep -qx "$selection"; then
                break
            fi

            warn "Invalid PHP selection."
        done
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] &&
       (( selection >= 1 && selection <= ${#INSTALLED_PHP_VERSIONS[@]} )); then
        PHP_VER="${INSTALLED_PHP_VERSIONS[$((selection - 1))]}"
    else
        PHP_VER="$selection"
    fi

    PHP_BIN="/usr/bin/php${PHP_VER}"
    PHP_FPM_SERVICE="php${PHP_VER}-fpm"
    PHP_FPM_SOCKET="/run/php/php${PHP_VER}-fpm.sock"

    [[ -x "$PHP_BIN" ]] ||
        die "$PHP_BIN does not exist."

    info "Selected PHP: $PHP_VER"
}

###############################################################################
# PHP EXTENSIONS
###############################################################################

check_php_extensions() {
    section "PHP EXTENSIONS"

    local extensions=(
        pdo_mysql
        mbstring
        xml
        curl
        zip
        bcmath
        intl
        gd
    )

    local missing=()
    local loaded

    loaded="$("$PHP_BIN" -m 2>/dev/null || true)"

    for extension in "${extensions[@]}"; do
        if ! grep -qi "^${extension}$" <<< "$loaded"; then
            missing+=("$extension")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        info "Required PHP extensions are available."
        return
    fi

    warn "Missing extensions for PHP $PHP_VER:"
    printf '  %s\n' "${missing[@]}"

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        answer="Y"
    else
        read -rp "Install missing extensions now? [Y/n]: " answer
        answer="${answer:-Y}"
    fi

    [[ "$answer" =~ ^[Yy]$ ]] ||
        die "Required PHP extensions are missing."

    local packages=()

    for extension in "${missing[@]}"; do
        case "$extension" in
            pdo_mysql)
                packages+=("php${PHP_VER}-mysql")
                ;;
            *)
                packages+=("php${PHP_VER}-${extension}")
                ;;
        esac
    done

    install_packages "${packages[@]}"

    loaded="$("$PHP_BIN" -m 2>/dev/null || true)"

    for extension in "${extensions[@]}"; do
        grep -qi "^${extension}$" <<< "$loaded" ||
            die "PHP extension still missing: $extension"
    done

    info "PHP extensions verified."
}

###############################################################################
# PHP-FPM
###############################################################################

start_php_fpm() {
    section "PHP-FPM"

    if ! systemctl list-unit-files |
        grep -q "^${PHP_FPM_SERVICE}.service"; then
        die "PHP-FPM service not found: $PHP_FPM_SERVICE"
    fi

    run_cmd systemctl enable --now "$PHP_FPM_SERVICE"

    if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        systemctl status "$PHP_FPM_SERVICE" --no-pager || true
        die "$PHP_FPM_SERVICE is not running."
    fi

    info "$PHP_FPM_SERVICE: active"

    if [[ ! -S "$PHP_FPM_SOCKET" ]]; then
        sleep 2

        if [[ ! -S "$PHP_FPM_SOCKET" ]]; then
            systemctl status "$PHP_FPM_SERVICE" --no-pager || true
            die "PHP-FPM socket not found: $PHP_FPM_SOCKET"
        fi
    fi

    info "PHP-FPM socket: $PHP_FPM_SOCKET"
}

###############################################################################
# LARAVEL COMPATIBILITY
###############################################################################

laravel_php_min() {
    case "$1" in
        13) echo "8.3" ;;
        12) echo "8.2" ;;
        11) echo "8.2" ;;
        10) echo "8.1" ;;
        9)  echo "8.0" ;;
        8)  echo "7.3" ;;
        *)  echo "99.0" ;;
    esac
}

laravel_php_max() {
    case "$1" in
        13) echo "8.5" ;;
        12) echo "8.5" ;;
        11) echo "8.4" ;;
        10) echo "8.3" ;;
        9)  echo "8.1" ;;
        8)  echo "8.1" ;;
        *)  echo "0.0" ;;
    esac
}

version_ge() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

version_le() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$2" ]]
}

php_supports_laravel() {
    local laravel="$1"
    local php="$2"

    local min
    local max

    min="$(laravel_php_min "$laravel")"
    max="$(laravel_php_max "$laravel")"

    version_ge "$php" "$min" &&
        version_le "$php" "$max"
}

###############################################################################
# LARAVEL VERSION SELECTION
###############################################################################

select_laravel_version() {
    section "LARAVEL VERSION"

    echo
    echo "PHP selected: PHP $PHP_VER"
    echo

    local candidates=()
    local version

    # Current Laravel generations first.
    for version in 13 12 11 10 9 8; do
        if php_supports_laravel "$version" "$PHP_VER"; then
            candidates+=("$version")
        fi
    done

    [[ ${#candidates[@]} -gt 0 ]] ||
        die "No supported Laravel version was found for PHP $PHP_VER."

    echo "Compatible Laravel versions:"
    echo

    for i in "${!candidates[@]}"; do
        if (( i == 0 )); then
            echo "  $((i + 1))) Laravel ${candidates[$i]} [RECOMMENDED]"
        else
            echo "  $((i + 1))) Laravel ${candidates[$i]}"
        fi
    done

    echo
    warn "The recommendation is based on Laravel's documented PHP compatibility."
    warn "Composer will perform the final dependency compatibility check."

    local selection

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        selection=1
    else
        while true; do
            read -rp "Select Laravel version [default: 1]: " selection
            selection="${selection:-1}"

            if [[ "$selection" =~ ^[0-9]+$ ]] &&
               (( selection >= 1 && selection <= ${#candidates[@]} )); then
                break
            fi

            warn "Invalid Laravel selection."
        done
    fi

    LARAVEL_MAJOR="${candidates[$((selection - 1))]}"
    LARAVEL_CONSTRAINT="^${LARAVEL_MAJOR}.0"

    info "Selected Laravel: $LARAVEL_MAJOR"
}

###############################################################################
# COMPOSER
###############################################################################

ensure_composer() {
    section "COMPOSER"

    local composer_bin

    composer_bin="$(command -v composer || true)"

    if [[ -z "$composer_bin" ]]; then
        info "Composer is not installed."
        install_packages composer
        composer_bin="$(command -v composer || true)"
    fi

    [[ -n "$composer_bin" ]] ||
        die "Composer could not be installed."

    local composer_version
    composer_version="$(
        "$PHP_BIN" "$composer_bin" --version 2>/dev/null |
        sed -nE 's/.*Composer version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'
    )"

    [[ -n "$composer_version" ]] ||
        die "Unable to determine Composer version."

    info "Composer: $composer_bin"
    info "Composer version: $composer_version"

    if ! version_ge "$composer_version" "2.0.0"; then
        warn "Composer 2.0+ is recommended."
        warn "The installed Composer version is old."
    fi

    COMPOSER_BIN="$composer_bin"
}

###############################################################################
# NODE / NPM / NVM
###############################################################################

detect_nvm() {
    NVM_DIR="$OWNER_HOME/.nvm"

    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        return 0
    fi

    return 1
}

detect_node_for_owner() {
    NODE_BIN=""
    NPM_BIN=""

    local result

    result="$(
        su - "$OWNER" -c '
            if [ -s "$HOME/.nvm/nvm.sh" ]; then
                . "$HOME/.nvm/nvm.sh"
                NODE="$(command -v node || true)"
                NPM="$(command -v npm || true)"
                if [ -n "$NODE" ] && [ -n "$NPM" ]; then
                    printf "%s|%s|%s\n" "$NODE" "$NPM" "$(node -v)"
                    exit 0
                fi
            fi

            NODE="$(command -v node || true)"
            NPM="$(command -v npm || true)"

            if [ -n "$NODE" ] && [ -n "$NPM" ]; then
                printf "%s|%s|%s\n" "$NODE" "$NPM" "$(node -v)"
            fi
        ' 2>/dev/null || true
    )"

    if [[ -n "$result" ]]; then
        NODE_BIN="${result%%|*}"
        result="${result#*|}"
        NPM_BIN="${result%%|*}"
        NODE_VERSION="${result#*|}"
        return 0
    fi

    return 1
}

install_nvm_for_owner() {
    info "NVM is not available for $OWNER."

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        answer="Y"
    else
        read -rp "Install NVM and Node.js LTS for $OWNER? [Y/n]: " answer
        answer="${answer:-Y}"
    fi

    [[ "$answer" =~ ^[Yy]$ ]] || return 1

    local nvm_script
    nvm_script="$(mktemp)"

    curl -fsSL \
        "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh" \
        -o "$nvm_script"

    chown "$OWNER:$OWNER" "$nvm_script"

    su - "$OWNER" -c "bash '$nvm_script'"

    rm -f "$nvm_script"

    if ! detect_nvm; then
        return 1
    fi

    su - "$OWNER" -c '
        export NVM_DIR="$HOME/.nvm"
        . "$NVM_DIR/nvm.sh"
        nvm install --lts
        nvm alias default "lts/*"
    '

    return 0
}

ensure_node() {
    section "NODE.JS / NPM"

    if detect_node_for_owner; then
        info "Node.js: $NODE_VERSION"
        info "Node binary: $NODE_BIN"
        info "npm: $NPM_BIN"
        return 0
    fi

    if detect_nvm; then
        info "NVM detected."

        su - "$OWNER" -c '
            export NVM_DIR="$HOME/.nvm"
            . "$NVM_DIR/nvm.sh"

            if ! nvm ls --no-colors "lts/*" >/dev/null 2>&1; then
                nvm install --lts
            fi

            nvm use --lts >/dev/null
            nvm alias default "lts/*" >/dev/null
        ' || true

        if detect_node_for_owner; then
            info "Node.js via NVM: $NODE_VERSION"
            return 0
        fi
    else
        if install_nvm_for_owner && detect_node_for_owner; then
            info "Node.js via NVM: $NODE_VERSION"
            return 0
        fi
    fi

    warn "NVM Node.js setup was unavailable."

    if ! command -v node >/dev/null 2>&1 ||
       ! command -v npm >/dev/null 2>&1; then

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            answer="Y"
        else
            read -rp "Install distro Node.js/npm as fallback? [Y/n]: " answer
            answer="${answer:-Y}"
        fi

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            install_packages nodejs npm
        fi
    fi

    if detect_node_for_owner; then
        info "Node.js: $NODE_VERSION"
        return 0
    fi

    warn "Node.js/npm could not be configured for $OWNER."
    warn "Laravel backend setup can continue, but frontend tooling may require manual installation."
}

###############################################################################
# PROJECT TYPE
###############################################################################

select_project_type() {
    section "PROJECT TYPE"

    echo
    echo "  1) Normal Laravel"
    echo "     Composer creates a new Laravel application."
    echo
    echo "  2) Vemto"
    echo "     Creates an empty directory for Vemto."
    echo
    echo "  3) GitHub"
    echo "     Clones an existing GitHub repository."
    echo

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        PROJECT_TYPE="1"
    else
        while true; do
            read -rp "Select project type [1]: " PROJECT_TYPE
            PROJECT_TYPE="${PROJECT_TYPE:-1}"

            case "$PROJECT_TYPE" in
                1|2|3)
                    break
                    ;;
                *)
                    warn "Choose 1, 2 or 3."
                    ;;
            esac
        done
    fi
}

###############################################################################
# PROJECT NAME
###############################################################################

select_project_name() {
    section "PROJECT NAME"

    while true; do
        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            read -rp "Enter project name: " PROJ
        else
            read -rp "Enter project name (example: myapp): " PROJ
        fi

        # No leading/trailing dot and no double dots.
        if [[ "$PROJ" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$ ]] ||
           [[ "$PROJ" =~ ^[A-Za-z0-9]$ ]]; then

            if [[ "$PROJ" != *..* ]]; then
                break
            fi
        fi

        warn "Invalid project name."
        warn "Use letters, numbers, dots, underscores and hyphens."
        warn "The name must start/end with an alphanumeric character."
        warn "Double dots are not allowed."
    done

    SERVER_NAME="${PROJ}.test"
}

###############################################################################
# BASE DIRECTORY
###############################################################################

expand_path() {
    local path="$1"

    if [[ "$path" == "~" ]]; then
        echo "$OWNER_HOME"
        return
    fi

    if [[ "$path" == "~/"* ]]; then
        echo "$OWNER_HOME/${path#~/}"
        return
    fi

    echo "$path"
}

select_base_directory() {
    section "PROJECT DIRECTORY"

    echo
    echo "Choose where the project should be stored."
    echo
    echo "Examples:"
    echo "  /var/www"
    echo "  /home/$OWNER/www"
    echo "  /srv/www"
    echo

    local selected

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        selected="$DEFAULT_BASE_DIR"
    else
        read -rp \
            "Enter base directory for projects [default: $DEFAULT_BASE_DIR]: " \
            selected

        selected="${selected:-$DEFAULT_BASE_DIR}"
    fi

    BASE_DIR="$(expand_path "$selected")"
    BASE_DIR="${BASE_DIR%/}"

    [[ -n "$BASE_DIR" ]] ||
        die "Base directory cannot be empty."

    info "Base directory: $BASE_DIR"

    if [[ ! -d "$BASE_DIR" ]]; then
        warn "Directory does not exist: $BASE_DIR"

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            answer="Y"
        else
            read -rp "Create this directory? [Y/n]: " answer
            answer="${answer:-Y}"
        fi

        [[ "$answer" =~ ^[Yy]$ ]] ||
            die "Base directory does not exist."

        run_cmd mkdir -p "$BASE_DIR"
    fi

    PROJECT_DIR="$BASE_DIR/$PROJ"

    info "Project directory: $PROJECT_DIR"
}

###############################################################################
# PROJECT DIRECTORY CHECK
###############################################################################

check_project_directory() {
    if [[ -e "$PROJECT_DIR" ]]; then

        if [[ "$PROJECT_TYPE" == "1" ]]; then
            die "Normal Laravel project directory already exists: $PROJECT_DIR"
        fi

        if [[ "$PROJECT_TYPE" == "3" ]]; then
            die "GitHub project directory already exists: $PROJECT_DIR"
        fi

        warn "Vemto directory already exists."

        if find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -print -quit |
            grep -q .; then

            warn "Directory is not empty."
        fi

        if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
            read -rp "Continue using this directory? [y/N]: " answer

            [[ "$answer" =~ ^[Yy]$ ]] ||
                die "Operation cancelled."
        fi

    else
        run_cmd mkdir -p "$PROJECT_DIR"
    fi
}

###############################################################################
# GITHUB
###############################################################################

GITHUB_URL=""

validate_github_url() {
    local url="$1"

    [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/?(\.git)?$ ]] ||
    [[ "$url" =~ ^git@github\.com:[^/]+/[^/]+/?(\.git)?$ ]]
}

prepare_github() {
    section "GITHUB"

    while true; do
        read -rp "GitHub repository URL: " GITHUB_URL

        if validate_github_url "$GITHUB_URL"; then
            break
        fi

        warn "Invalid GitHub URL."
        warn "Examples:"
        warn "  https://github.com/user/repository"
        warn "  https://github.com/user/repository.git"
        warn "  git@github.com:user/repository.git"
    done

    info "Checking repository accessibility..."

    if ! git ls-remote "$GITHUB_URL" >/dev/null 2>&1; then
        warn "GitHub repository could not be accessed."
        warn "For a private repository, verify SSH keys or credentials."

        if [[ "$GITHUB_URL" != *.git ]]; then
            warn "You may also try adding .git to the URL."
        fi

        die "GitHub repository verification failed."
    fi

    info "GitHub repository is reachable."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] git clone $GITHUB_URL $PROJECT_DIR"
        return
    fi

    if ! git clone "$GITHUB_URL" "$PROJECT_DIR"; then
        die "GitHub clone failed."
    fi

    if [[ ! -e "$PROJECT_DIR/.git" ]]; then
        die "Clone completed but .git was not found."
    fi

    info "GitHub repository cloned successfully."
}

###############################################################################
# MYSQL
###############################################################################

detect_database_service() {
    section "DATABASE"

    if systemctl is-active --quiet mysql 2>/dev/null; then
        DB_SERVICE="mysql"
    elif systemctl is-active --quiet mariadb 2>/dev/null; then
        DB_SERVICE="mariadb"
    elif systemctl list-unit-files |
        grep -q '^mysql.service'; then

        DB_SERVICE="mysql"
        run_cmd systemctl enable --now mysql

    elif systemctl list-unit-files |
        grep -q '^mariadb.service'; then

        DB_SERVICE="mariadb"
        run_cmd systemctl enable --now mariadb

    else
        die "MySQL/MariaDB is not installed."
    fi

    systemctl is-active --quiet "$DB_SERVICE" ||
        die "$DB_SERVICE is not running."

    info "Database service: $DB_SERVICE"
}

###############################################################################
# MYSQL ROOT AUTHENTICATION
###############################################################################

prepare_mysql_auth() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        MYSQL_ROOT_PASSWORD=""
    else
        echo
        read -rsp \
            "MySQL root password (leave blank for socket authentication): " \
            MYSQL_ROOT_PASSWORD
        echo
    fi

    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        MYSQL_CMD=(mysql -u root)
    else
        MYSQL_OPTS_FILE="$(mktemp)"
        chmod 600 "$MYSQL_OPTS_FILE"

        cat > "$MYSQL_OPTS_FILE" <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
EOF

        MYSQL_CMD=(mysql "--defaults-extra-file=$MYSQL_OPTS_FILE")
    fi

    if ! "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
        die "Unable to connect to MySQL as root."
    fi

    info "MySQL authentication successful."
}

###############################################################################
# DATABASE CREATION
###############################################################################

create_database() {
    section "DATABASE CONFIGURATION"

    DB_NAME="$PROJ"

    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        local input
        read -rp "Database name [default: $DB_NAME]: " input
        DB_NAME="${input:-$DB_NAME}"
    fi

    [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] ||
        die "Invalid database name."

    DB_USERNAME="root"
    DB_PASSWORD=""

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] CREATE DATABASE $DB_NAME"
        return
    fi

    prepare_mysql_auth

    "${MYSQL_CMD[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;
SQL

    info "Database created/verified: $DB_NAME"

    local create_user="Y"

    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        read -rp \
            "Create a dedicated MySQL user for this project? [Y/n]: " \
            create_user

        create_user="${create_user:-Y}"
    fi

    if [[ "$create_user" =~ ^[Yy]$ ]]; then

        DB_USERNAME="${PROJ}_user"

        if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
            read -rsp \
                "Password for $DB_USERNAME (leave blank to generate): " \
                DB_PASSWORD
            echo
        fi

        if [[ -z "$DB_PASSWORD" ]]; then
            DB_PASSWORD="$(openssl rand -base64 32 2>/dev/null |
                tr -dc 'A-Za-z0-9_+=@#%-' |
                head -c 24 || true)"

            [[ ${#DB_PASSWORD} -ge 20 ]] ||
                die "Could not generate a secure database password."
        fi

        local db_password_sql
        db_password_sql="${DB_PASSWORD//\'/\'\'}"

        "${MYSQL_CMD[@]}" <<SQL
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'${MYSQL_HOST}'
IDENTIFIED BY '${db_password_sql}';

ALTER USER '${DB_USERNAME}'@'${MYSQL_HOST}'
IDENTIFIED BY '${db_password_sql}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USERNAME}'@'${MYSQL_HOST}';

FLUSH PRIVILEGES;
SQL

        info "Dedicated MySQL user created: $DB_USERNAME"
    else
        warn "Using root credentials for Laravel."
    fi
}

###############################################################################
# CREATE LARAVEL
###############################################################################

create_normal_laravel() {
    section "CREATING LARAVEL APPLICATION"

    [[ ! -e "$PROJECT_DIR" ]] ||
        die "Target directory already exists."

    info "Creating Laravel $LARAVEL_MAJOR using PHP $PHP_VER..."

    su - "$OWNER" -c \
        "$PHP_BIN -d memory_limit=-1 '$COMPOSER_BIN' create-project laravel/laravel '$PROJECT_DIR' '$LARAVEL_CONSTRAINT' --prefer-dist"

    [[ -f "$PROJECT_DIR/artisan" ]] ||
        die "Composer finished but Laravel artisan was not found."

    info "Laravel application created."
}

###############################################################################
# VEMTO
###############################################################################

prepare_vemto() {
    section "PREPARING VEMTO PROJECT"

    run_cmd mkdir -p "$PROJECT_DIR"

    info "Vemto project directory:"
    info "$PROJECT_DIR"

    info "Vemto will generate the Laravel application in this directory."
}

###############################################################################
# GITHUB PROJECT
###############################################################################

prepare_github_project() {
    prepare_github

    if [[ -f "$PROJECT_DIR/artisan" ]]; then
        info "GitHub repository appears to contain a Laravel application."
    else
        warn "No artisan file detected."
        warn "The repository may not be a Laravel application."
    fi
}

###############################################################################
# LARAVEL DIRECTORIES
###############################################################################

ensure_laravel_directories() {
    section "LARAVEL DIRECTORIES"

    run_cmd mkdir -p "$PROJECT_DIR/storage"
    run_cmd mkdir -p "$PROJECT_DIR/bootstrap/cache"
    run_cmd mkdir -p "$PROJECT_DIR/public"

    info "storage: OK"
    info "bootstrap/cache: OK"
    info "public: OK"
}

###############################################################################
# ENVIRONMENT
###############################################################################

write_env() {
    section "ENVIRONMENT"

    local env_file="$PROJECT_DIR/.env"

    if [[ -f "$env_file" ]]; then
        warn ".env already exists. It will not be overwritten."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] create $env_file"
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
DB_PORT=${MYSQL_PORT}
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

###############################################################################
# PERMISSIONS
###############################################################################

configure_permissions() {
    section "PROJECT PERMISSIONS"

    run_cmd chown -R "$OWNER:$WEB_GROUP" "$PROJECT_DIR"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        find "$PROJECT_DIR" -type d -exec chmod 755 {} +
        find "$PROJECT_DIR" -type f -exec chmod 644 {} +

        chmod -R 775 "$PROJECT_DIR/storage"
        chmod -R 775 "$PROJECT_DIR/bootstrap/cache"

        [[ ! -f "$PROJECT_DIR/.env" ]] ||
            chmod 640 "$PROJECT_DIR/.env"
    else
        echo "[DRY-RUN] chmod directories 755"
        echo "[DRY-RUN] chmod files 644"
        echo "[DRY-RUN] chmod storage 775"
        echo "[DRY-RUN] chmod bootstrap/cache 775"
    fi
}

###############################################################################
# ACL
###############################################################################

grant_traversal() {
    local target="$1"
    local current="/"
    local part

    IFS='/' read -ra parts <<< "${target#/}"

    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue

        current="${current%/}/$part"

        if [[ -d "$current" ]]; then
            setfacl -m "u:${WEB_USER}:--x" "$current" 2>/dev/null || true
        fi
    done
}

configure_acl() {
    section "WEB SERVER ACCESS"

    if command -v setfacl >/dev/null 2>&1; then

        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "[DRY-RUN] setfacl traversal permissions"
            echo "[DRY-RUN] setfacl storage"
            echo "[DRY-RUN] setfacl bootstrap/cache"
            return
        fi

        grant_traversal "$PROJECT_DIR"

        setfacl -R -m "u:${WEB_USER}:rwX" "$PROJECT_DIR/storage"
        setfacl -R -m "u:${WEB_USER}:rwX" "$PROJECT_DIR/bootstrap/cache"

        setfacl -R -d -m "u:${WEB_USER}:rwX" "$PROJECT_DIR/storage"
        setfacl -R -d -m "u:${WEB_USER}:rwX" "$PROJECT_DIR/bootstrap/cache"

        info "ACL permissions configured."
    else
        warn "ACL support is unavailable."
        warn "Using www-data group permissions instead."

        if [[ "$DRY_RUN" -eq 0 ]]; then
            chgrp -R "$WEB_GROUP" "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
            chmod -R g+rwX "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
        fi
    fi
}

###############################################################################
# LARAVEL ARTISAN
###############################################################################

run_laravel_setup() {
    [[ -f "$PROJECT_DIR/artisan" ]] || return 0

    section "LARAVEL INITIALIZATION"

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan key:generate --force"

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan config:clear"

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan cache:clear" ||
        warn "Laravel cache:clear returned an error."

    info "Laravel initialization completed."
}

###############################################################################
# APACHE PORT CHECK
###############################################################################

check_ports() {
    section "PORT CHECK"

    if ! command -v ss >/dev/null 2>&1; then
        warn "ss command unavailable; skipping port check."
        return
    fi

    local ports
    ports="$(ss -tlnp 2>/dev/null || true)"

    if grep -qE ':(80|443)[[:space:]]' <<< "$ports"; then
        warn "Port 80 and/or 443 is already in use."

        if grep -qE ':80[[:space:]]' <<< "$ports"; then
            warn "Port 80 is in use."
        fi

        if grep -qE ':443[[:space:]]' <<< "$ports"; then
            warn "Port 443 is in use."
        fi

        if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
            read -rp "Continue anyway? [y/N]: " answer
            [[ "$answer" =~ ^[Yy]$ ]] ||
                die "Operation cancelled."
        fi
    else
        info "Ports 80/443 are available."
    fi
}

###############################################################################
# HTTPS
###############################################################################

configure_https() {
    section "HTTPS"

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        HTTPS_ENABLED=0
        return
    fi

    read -rp \
        "Enable local HTTPS with a self-signed certificate? [y/N]: " \
        answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        HTTPS_ENABLED=0
        return
    fi

    HTTPS_ENABLED=1

    install_packages openssl

    local cert_dir="/etc/ssl/localcerts"
    local cert_file="${cert_dir}/${SERVER_NAME}.crt"
    local key_file="${cert_dir}/${SERVER_NAME}.key"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] create self-signed certificate $cert_file"
        return
    fi

    install -d -m 755 "$cert_dir"

    if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
        openssl req \
            -x509 \
            -nodes \
            -days 825 \
            -newkey rsa:2048 \
            -keyout "$key_file" \
            -out "$cert_file" \
            -subj "/CN=${SERVER_NAME}"
    fi

    chmod 600 "$key_file"
    chmod 644 "$cert_file"

    a2enmod ssl >/dev/null

    info "Self-signed certificate created."
}

###############################################################################
# APACHE VHOST
###############################################################################

create_apache_vhost() {
    section "APACHE VIRTUALHOST"

    VHOST_FILE="${APACHE_SITES_AVAILABLE}/${PROJ}.test.conf"

    local app_url="http://${SERVER_NAME}"

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        app_url="https://${SERVER_NAME}"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] create $VHOST_FILE"
        return
    fi

    cat > "$VHOST_FILE" <<EOF
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
        cat >> "$VHOST_FILE" <<EOF

<VirtualHost *:443>

    ServerName ${SERVER_NAME}

    DocumentRoot ${PROJECT_DIR}/public

    SSLEngine on
    SSLCertificateFile /etc/ssl/localcerts/${SERVER_NAME}.crt
    SSLCertificateKeyFile /etc/ssl/localcerts/${SERVER_NAME}.key

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

    info "VirtualHost created: $VHOST_FILE"
}

###############################################################################
# APACHE MODULES / SITE
###############################################################################

enable_apache() {
    section "APACHE CONFIGURATION"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] a2enmod rewrite proxy proxy_fcgi setenvif"
        echo "[DRY-RUN] a2ensite ${PROJ}.test.conf"
        return
    fi

    a2enmod rewrite >/dev/null
    a2enmod proxy >/dev/null
    a2enmod proxy_fcgi >/dev/null
    a2enmod setenvif >/dev/null

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        a2enmod ssl >/dev/null
    fi

    a2ensite "${PROJ}.test.conf" >/dev/null

    info "Apache modules and site enabled."
}

###############################################################################
# HOSTS
###############################################################################

configure_hosts() {
    section "LOCAL DOMAIN"

    if grep -qE \
        "^[[:space:]]*127\.0\.0\.1[[:space:]]+${SERVER_NAME}([[:space:]]|$)" \
        "$HOSTS_FILE"; then

        info "$SERVER_NAME already exists in /etc/hosts."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] add 127.0.0.1 $SERVER_NAME to /etc/hosts"
        return
    fi

    echo "127.0.0.1    ${SERVER_NAME}" >> "$HOSTS_FILE"

    info "Added $SERVER_NAME to /etc/hosts."
}

###############################################################################
# APACHE TEST
###############################################################################

test_apache() {
    section "APACHE CONFIGURATION TEST"

    local output
    local rc

    set +e
    output="$(apache2ctl configtest 2>&1)"
    rc=$?
    set -e

    echo "$output"

    if [[ "$rc" -ne 0 ]]; then
        echo
        error "Apache configuration test FAILED."
        error "Apache will NOT be reloaded."
        error "Full Apache output:"
        echo "$output"
        exit 2
    fi

    info "Apache configuration: OK"
}

###############################################################################
# RELOAD APACHE
###############################################################################

reload_apache() {
    section "RELOADING APACHE"

    run_cmd systemctl reload apache2

    if [[ "$DRY_RUN" -eq 0 ]] &&
       ! systemctl is-active --quiet apache2; then

        systemctl status apache2 --no-pager || true
        die "Apache is not active after reload."
    fi

    info "Apache reload completed."
}

###############################################################################
# DATABASE TEST
###############################################################################

test_laravel_database() {
    [[ -f "$PROJECT_DIR/artisan" ]] || return 0

    section "LARAVEL DATABASE TEST"

    if su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan tinker --execute='DB::connection()->getPdo(); echo \"Database connection OK\\n\";'" \
        2>&1; then

        info "Laravel database connection: OK"
    else
        warn "Laravel database connection test failed."
        warn "Check .env credentials and database configuration."
    fi
}

###############################################################################
# LARAVEL VERSION TEST
###############################################################################

get_laravel_version() {
    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        echo "Not generated"
        return
    fi

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan --version" \
        2>/dev/null || echo "Unable to determine"
}

###############################################################################
# HTTP TEST
###############################################################################

test_http() {
    section "HTTP TEST"

    local protocol="http"
    local port="80"
    local status

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        protocol="https"
        port="443"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] curl $protocol://$SERVER_NAME"
        return
    fi

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        status="$(
            curl \
                -k \
                -s \
                -o /dev/null \
                -w "%{http_code}" \
                "https://${SERVER_NAME}:${port}/" \
                || echo "000"
        )"
    else
        status="$(
            curl \
                -s \
                -o /dev/null \
                -w "%{http_code}" \
                -H "Host: ${SERVER_NAME}" \
                "http://127.0.0.1:${port}/" \
                || echo "000"
        )"
    fi

    if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
        info "HTTP status: $status"
    else
        warn "HTTP status: $status"
        warn "Check Apache logs if the site is not responding."
    fi
}

###############################################################################
# FINAL VERIFICATION
###############################################################################

final_verification() {
    section "FINAL VERIFICATION"

    local laravel_version
    laravel_version="$(get_laravel_version)"

    echo
    echo "Project"
    echo "-------"
    echo "Name:             $PROJ"
    echo "Directory:        $PROJECT_DIR"

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        echo "URL:              https://${SERVER_NAME}"
    else
        echo "URL:              http://${SERVER_NAME}"
    fi

    case "$PROJECT_TYPE" in
        1) echo "Type:             Normal Laravel" ;;
        2) echo "Type:             Vemto" ;;
        3) echo "Type:             GitHub" ;;
    esac

    echo
    echo "PHP"
    echo "---"
    echo "Selected PHP:     PHP $PHP_VER"
    echo "PHP binary:       $PHP_BIN"

    if [[ -x "$PHP_BIN" ]]; then
        "$PHP_BIN" -v | head -1
    fi

    echo
    echo "PHP-FPM"
    echo "-------"
    echo "Service:          $PHP_FPM_SERVICE"

    if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        echo "Status:           ACTIVE"
    else
        echo "Status:           FAILED"
    fi

    echo "Socket:           $PHP_FPM_SOCKET"

    if [[ -S "$PHP_FPM_SOCKET" ]]; then
        echo "Socket:           OK"
    else
        echo "Socket:           MISSING"
    fi

    echo
    echo "Composer"
    echo "--------"

    if command -v "$COMPOSER_BIN" >/dev/null 2>&1; then
        "$PHP_BIN" "$COMPOSER_BIN" --version | head -1
    else
        echo "Not available"
    fi

    echo
    echo "Node.js"
    echo "-------"

    if detect_node_for_owner; then
        echo "Version:          $NODE_VERSION"
        echo "Node:             $NODE_BIN"
        echo "npm:              $NPM_BIN"
    else
        echo "Not configured"
    fi

    echo
    echo "Apache"
    echo "------"

    if apache2ctl configtest >/dev/null 2>&1; then
        echo "Configuration:    OK"
    else
        echo "Configuration:    FAILED"
    fi

    if systemctl is-active --quiet apache2; then
        echo "Service:          ACTIVE"
    else
        echo "Service:          FAILED"
    fi

    echo
    echo "Database"
    echo "--------"
    echo "Service:          $DB_SERVICE"
    echo "Database:         $DB_NAME"
    echo "Username:         $DB_USERNAME"

    if [[ -f "$PROJECT_DIR/artisan" ]]; then
        echo "Laravel DB:       tested above"
    else
        echo "Laravel DB:       deferred"
    fi

    echo
    echo "Laravel"
    echo "-------"
    echo "Version:          $laravel_version"

    echo
    echo "Permissions"
    echo "-----------"

    if [[ -d "$PROJECT_DIR" ]]; then
        echo "Owner:            $(stat -c '%U' "$PROJECT_DIR")"
        echo "Group:            $(stat -c '%G' "$PROJECT_DIR")"
    fi

    if [[ -d "$PROJECT_DIR/storage" ]]; then
        echo "storage:          $(stat -c '%A' "$PROJECT_DIR/storage")"
    fi

    if [[ -d "$PROJECT_DIR/bootstrap/cache" ]]; then
        echo "bootstrap/cache:  $(stat -c '%A' "$PROJECT_DIR/bootstrap/cache")"
    fi
}

###############################################################################
# FINAL INSTRUCTIONS
###############################################################################

final_instructions() {
    section "PROJECT READY"

    echo
    echo "Project:"
    echo "  $PROJECT_DIR"
    echo

    if [[ "$HTTPS_ENABLED" -eq 1 ]]; then
        echo "URL:"
        echo "  https://${SERVER_NAME}"
    else
        echo "URL:"
        echo "  http://${SERVER_NAME}"
    fi

    echo
    echo "PHP:"
    echo "  PHP ${PHP_VER}"
    echo

    echo "Database:"
    echo "  ${DB_NAME}"
    echo

    case "$PROJECT_TYPE" in

        1)
            echo "Normal Laravel next steps:"
            echo
            echo "  cd ${PROJECT_DIR}"
            echo
            echo "  ${PHP_BIN} artisan migrate"
            echo
            echo "  npm install"
            echo "  npm run dev"
            ;;

        2)
            echo "Vemto next steps:"
            echo
            echo "  1. Open Vemto."
            echo "  2. Select:"
            echo
            echo "       ${PROJECT_DIR}"
            echo
            echo "  3. Generate the Laravel application."
            echo "  4. Then run:"
            echo
            echo "       cd ${PROJECT_DIR}"
            echo "       ${PHP_BIN} artisan key:generate"
            echo "       ${PHP_BIN} artisan migrate"
            ;;

        3)
            echo "GitHub project next steps:"
            echo
            echo "  cd ${PROJECT_DIR}"
            echo
            echo "  ${PHP_BIN} artisan migrate"
            echo
            echo "  npm install"
            echo "  npm run dev"
            ;;
    esac

    echo
    echo "Apache:"
    echo "  ${VHOST_FILE}"
    echo

    echo "PHP-FPM:"
    echo "  ${PHP_FPM_SOCKET}"
    echo

    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "Log:"
        echo "  ${LOG_FILE}"
        echo
    fi

    info "Project setup completed successfully."
}

###############################################################################
# MAIN
###############################################################################

main() {
    parse_arguments "$@"

    detect_owner "$@"

    setup_logging

    section "ADD LARAVEL PROJECT $SCRIPT_VERSION"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "DRY-RUN MODE ENABLED."
        warn "No intended system modifications will be performed."
    fi

    check_os
    ensure_basic_dependencies
    check_apache

    detect_php_fpm_versions

    if [[ ${#INSTALLED_PHP_VERSIONS[@]} -eq 0 ]]; then
        install_default_php
    fi

    detect_php_fpm_versions

    [[ ${#INSTALLED_PHP_VERSIONS[@]} -gt 0 ]] ||
        die "No PHP-FPM version is available."

    select_php_version
    check_php_extensions
    start_php_fpm

    select_laravel_version

    ensure_composer
    ensure_node

    select_project_type
    select_project_name
    select_base_directory
    check_project_directory

    check_ports

    detect_database_service

    if [[ "$PROJECT_TYPE" != "2" ]]; then
        create_database
    else
        # Vemto may need a database later, but creating it now is useful
        # for the generated application.
        create_database
    fi

    case "$PROJECT_TYPE" in
        1)
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "[DRY-RUN] Composer create-project laravel/laravel"
                run_cmd mkdir -p "$PROJECT_DIR"
            else
                create_normal_laravel
            fi
            ;;

        2)
            prepare_vemto
            ;;

        3)
            prepare_github_project
            ;;
    esac

    ensure_laravel_directories
    write_env
    configure_permissions
    configure_acl

    if [[ "$PROJECT_TYPE" != "2" ]]; then
        if [[ "$DRY_RUN" -eq 0 ]]; then
            run_laravel_setup
        else
            echo "[DRY-RUN] php artisan key:generate"
            echo "[DRY-RUN] php artisan config:clear"
            echo "[DRY-RUN] php artisan cache:clear"
        fi
    fi

    configure_https
    create_apache_vhost
    configure_hosts
    enable_apache
    test_apache

    reload_apache

    if [[ "$PROJECT_TYPE" != "2" && "$DRY_RUN" -eq 0 ]]; then
        test_laravel_database
    fi

    test_http
    final_verification
    final_instructions
}

main "$@"
