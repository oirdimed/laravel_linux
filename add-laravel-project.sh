#!/usr/bin/env bash
#
# add-laravel-project.sh
#
# Laravel local development environment provisioner for Debian and Ubuntu.
#
# Version: 1.1.0
#
# Features:
#   - Debian / Ubuntu detection
#   - Root / sudo-user detection
#   - Dry-run mode
#   - Non-interactive mode
#   - Secure logging
#   - Dynamic PHP-FPM detection
#   - PHP installation if no PHP-FPM is available
#   - Multiple PHP-FPM versions
#   - PHP version selection
#   - Dynamic Laravel compatibility testing through Composer
#   - Composer detection and installation
#   - Composer 2.x verification
#   - NVM-aware Node.js detection
#   - Node.js LTS fallback
#   - npm verification
#   - Git verification
#   - Normal Laravel project creation
#   - Vemto project preparation
#   - GitHub project import
#   - GitHub repository validation with git ls-remote
#   - Dynamic project directory
#   - MySQL / MariaDB support
#   - Optional dedicated database user
#   - Apache VirtualHost
#   - Per-project PHP-FPM socket
#   - ACL support for /home/... projects
#   - Group permission fallback when ACL is unavailable
#   - .env generation
#   - APP_KEY generation
#   - Optional local HTTPS
#   - Apache configuration validation
#   - Laravel database connection test
#   - HTTP verification
#   - Final system verification
#
# Assumptions:
#   - Debian or Ubuntu
#   - systemd
#   - Apache 2.4+
#   - MySQL or MariaDB
#   - Bash 4+
#   - User has sudo privileges
#
# Usage:
#   sudo ./add-laravel-project.sh
#   sudo ./add-laravel-project.sh --dry-run
#   sudo ./add-laravel-project.sh --non-interactive
#   sudo ./add-laravel-project.sh --version
#
# Exit codes:
#   0 = success
#   1 = user abort
#   2 = unrecoverable error
#

set -Eeuo pipefail

SCRIPT_NAME="add-laravel-project"
SCRIPT_VERSION="1.1.0"

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

OWNER=""
OWNER_HOME=""

PROJECT_TYPE=""
PROJ=""
BASE_DIR=""
PROJECT_DIR=""
SERVER_NAME=""

PHP_VER=""
PHP_BIN=""
PHP_FPM_SERVICE=""
PHP_FPM_SOCKET=""

COMPOSER_BIN=""
NODE_BIN=""
NPM_BIN=""
GIT_BIN=""

LARAVEL_MAJOR=""
LARAVEL_CONSTRAINT=""

DB_SERVICE=""
DB_NAME=""
DB_USERNAME=""
DB_PASSWORD=""
MYSQL_ROOT_PASSWORD=""
MYSQL_OPTS_FILE=""

VHOST_FILE=""

SSL_ENABLED=0
SSL_CERT=""
SSL_KEY=""

CLEANUP_DONE=0

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
RESET="\033[0m"


# ------------------------------------------------------------------------------
# OUTPUT
# ------------------------------------------------------------------------------

info() {
    echo -e "[${GREEN}INFO${RESET}] $*"
}

warn() {
    echo -e "[${YELLOW}WARN${RESET}] $*"
}

error() {
    echo -e "[${RED}ERROR${RESET}] $*" >&2
}

debug() {
    echo -e "[${CYAN}DEBUG${RESET}] $*"
}

dry_run() {
    echo -e "[${BLUE}DRY-RUN${RESET}] $*"
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


# ------------------------------------------------------------------------------
# CLEANUP
# ------------------------------------------------------------------------------

cleanup() {
    if [[ "$CLEANUP_DONE" -eq 1 ]]; then
        return
    fi

    CLEANUP_DONE=1

    if [[ -n "${MYSQL_OPTS_FILE:-}" && -f "$MYSQL_OPTS_FILE" ]]; then
        rm -f "$MYSQL_OPTS_FILE" || true
    fi
}

trap cleanup EXIT
trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR


# ------------------------------------------------------------------------------
# HELP
# ------------------------------------------------------------------------------

show_version() {
    echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
}

show_help() {
    cat <<EOF

${SCRIPT_NAME} ${SCRIPT_VERSION}

Creates and configures a Laravel development project on Debian or Ubuntu.

Usage:
  sudo $0
  sudo $0 --dry-run
  sudo $0 --non-interactive
  sudo $0 --version
  sudo $0 --help

Options:
  --dry-run          Show planned changes without modifying the system.
  --non-interactive  Use defaults where possible.
  --version          Show script version.
  --help             Show this help.

Project types:
  1) Normal Laravel
     Composer creates a new Laravel application.

  2) Vemto
     Creates/prepares an empty directory for Vemto.

  3) GitHub
     Imports an existing Laravel project from GitHub.

Supported:
  Debian
  Ubuntu

EOF
}


# ------------------------------------------------------------------------------
# ARGUMENTS
# ------------------------------------------------------------------------------

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            --non-interactive)
                NON_INTERACTIVE=1
                ;;
            --version|-v)
                show_version
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac

        shift
    done
}


# ------------------------------------------------------------------------------
# ROOT / OWNER
# ------------------------------------------------------------------------------

determine_owner() {
    if [[ "$EUID" -ne 0 ]]; then
        info "Root privileges are required. Re-running with sudo..."
        exec sudo -E "$0" "$@"
    fi

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        OWNER="$SUDO_USER"
    else
        OWNER="${USER:-root}"
    fi

    if [[ "$OWNER" == "root" ]]; then
        die "Run this script with sudo from a normal user account."
    fi

    OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"

    [[ -n "$OWNER_HOME" ]] ||
        die "Unable to determine home directory for $OWNER."

    info "Project owner: $OWNER"
    info "Owner home: $OWNER_HOME"
}


# ------------------------------------------------------------------------------
# OS
# ------------------------------------------------------------------------------

check_os() {
    section "OPERATING SYSTEM"

    [[ -f /etc/os-release ]] ||
        die "/etc/os-release not found."

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


# ------------------------------------------------------------------------------
# APT
# ------------------------------------------------------------------------------

APT_UPDATED=0

apt_update_once() {
    if [[ "$APT_UPDATED" -eq 1 ]]; then
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would run: apt-get update"
        APT_UPDATED=1
        return
    fi

    info "Updating APT package information..."
    apt-get update

    APT_UPDATED=1
}

install_packages() {
    if [[ $# -eq 0 ]]; then
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would install packages: $*"
        return
    fi

    apt_update_once
    apt-get install -y "$@"
}


# ------------------------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------------------------

setup_logging() {
    section "LOGGING"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        LOG_FILE="/tmp/add-laravel-project-dry-run.log"
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! (umask 077 && touch "$LOG_FILE"); then
            die "Cannot create log file: $LOG_FILE"
        fi
    else
        if ! (umask 077 && touch "$LOG_FILE"); then
            die "Cannot create dry-run log file: $LOG_FILE"
        fi
    fi

    exec > >(tee -a "$LOG_FILE") 2>&1

    info "Log file: $LOG_FILE"
}


# ------------------------------------------------------------------------------
# BASIC SYSTEM DEPENDENCIES
# ------------------------------------------------------------------------------

check_basic_dependencies() {
    section "SYSTEM DEPENDENCIES"

    local commands=(
        bash
        awk
        sed
        grep
        find
        cut
        sort
        head
        tail
        curl
        tar
        ss
        systemctl
        openssl
        
    )

    local missing=()

    for cmd in "${commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            info "$cmd: OK"
        else
            warn "$cmd: MISSING"
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        local packages=()

        for cmd in "${missing[@]}"; do
            case "$cmd" in
                curl)
                    packages+=("curl")
                    ;;
                ss)
                    packages+=("iproute2")
                    ;;

                 openssl)
                    packages+=("openssl")
                    ;;
            esac
        done

        if [[ ${#packages[@]} -gt 0 ]]; then
            install_packages "${packages[@]}"
        fi
    fi

    if ! command -v apache2 >/dev/null 2>&1; then
        info "Apache is not installed."
        install_packages apache2
    else
        info "Apache: OK"
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        warn "MySQL client: MISSING"
        install_packages default-mysql-client
    else
        info "MySQL client: OK"
    fi

    if ! command -v setfacl >/dev/null 2>&1; then
        warn "ACL tools: MISSING"
        install_packages acl
    else
        info "ACL tools: OK"
    fi
}


# ------------------------------------------------------------------------------
# APACHE
# ------------------------------------------------------------------------------

check_apache() {
    section "APACHE"

    local version
    local apache_version

    version="$(apache2 -v 2>/dev/null | head -1 || true)"

    apache_version="$(printf '%s\n' "$version" |
        sed -nE 's/.*Apache\/([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"

    [[ -n "$apache_version" ]] ||
        die "Unable to determine Apache version. Detected: ${version:-unknown}"

    if ! printf '%s\n' "$apache_version" |
        awk -F. '{ exit !($1 > 2 || ($1 == 2 && $2 >= 4)) }'; then

        die "Apache 2.4 or newer is required. Detected: ${version:-unknown}"
    fi

    info "Server version: $version"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would enable and start apache2."
    else
        systemctl enable --now apache2
    fi
}

# ------------------------------------------------------------------------------
# PORT CHECK
# ------------------------------------------------------------------------------

check_ports() {
    section "PORT CHECK"

    local conflict=0

    if command -v ss >/dev/null 2>&1; then

        if ss -tlnp 2>/dev/null | grep -qE '(^|[[:space:]])[^[:space:]]*:80[[:space:]]'; then
            warn "Port 80 is currently in use."
            conflict=1
        else
            info "Port 80: available"
        fi

        if ss -tlnp 2>/dev/null | grep -qE '(^|[[:space:]])[^[:space:]]*:443[[:space:]]'; then
            warn "Port 443 is currently in use."
            conflict=1
        else
            info "Port 443: available"
        fi
    fi

    if [[ "$conflict" -eq 1 ]]; then
        if [[ "$DRY_RUN" -eq 1 || "$NON_INTERACTIVE" -eq 1 ]]; then
            warn "Continuing because this is dry-run/non-interactive mode."
            return
        fi

        read -rp "Continue despite the port conflict? [y/N]: " answer

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# ------------------------------------------------------------------------------
# PHP-FPM DETECTION
# ------------------------------------------------------------------------------

detect_php_fpm_versions() {
    INSTALLED_PHP_VERSIONS=()

    # --------------------------------------------------------------------------
    # Detect installed PHP-FPM services
    #
    # Examples:
    #   php7.3-fpm.service
    #   php8.1-fpm.service
    #   php8.2-fpm.service
    #   php8.3-fpm.service
    #
    # Store ONLY:
    #   7.3
    #   8.1
    #   8.2
    #   8.3
    # --------------------------------------------------------------------------

    mapfile -t INSTALLED_PHP_VERSIONS < <(
        systemctl list-unit-files \
            --type=service \
            --no-legend 2>/dev/null |
        awk '{print $1}' |
        sed -nE 's/^php([0-9]+\.[0-9]+)-fpm\.service$/\1/p' |
        sort -Vu
    )

    # --------------------------------------------------------------------------
    # If systemctl did not find them, check /etc/systemd/system and
    # /lib/systemd/system directly.
    # --------------------------------------------------------------------------

    if [[ ${#INSTALLED_PHP_VERSIONS[@]} -eq 0 ]]; then

        mapfile -t INSTALLED_PHP_VERSIONS < <(
            find \
                /etc/systemd/system \
                /lib/systemd/system \
                -maxdepth 1 \
                -type f \
                -name 'php*-fpm.service' \
                -printf '%f\n' 2>/dev/null |
            sed -nE 's/^php([0-9]+\.[0-9]+)-fpm\.service$/\1/p' |
            sort -Vu
        )

    fi

    # --------------------------------------------------------------------------
    # Also check installed PHP-FPM binaries.
    #
    # This is a fallback only.
    # --------------------------------------------------------------------------

    if [[ ${#INSTALLED_PHP_VERSIONS[@]} -eq 0 ]]; then

        mapfile -t INSTALLED_PHP_VERSIONS < <(
            find /usr/sbin \
                -maxdepth 1 \
                -type f \
                -name 'php-fpm[0-9]*' \
                -printf '%f\n' 2>/dev/null |
            sed -nE 's/^php-fpm([0-9]+\.[0-9]+)$/\1/p' |
            sort -Vu
        )

    fi

    # --------------------------------------------------------------------------
    # Final validation
    # --------------------------------------------------------------------------

    local valid_versions=()
    local version

    for version in "${INSTALLED_PHP_VERSIONS[@]}"; do

        # Only accept X.Y
        if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
            valid_versions+=("$version")
        fi

    done

    INSTALLED_PHP_VERSIONS=()

    if [[ ${#valid_versions[@]} -gt 0 ]]; then
        mapfile -t INSTALLED_PHP_VERSIONS < <(
            printf '%s\n' "${valid_versions[@]}" |
            sort -Vu
        )
    fi
}



# ------------------------------------------------------------------------------
# PHP INSTALLATION
# ------------------------------------------------------------------------------

install_default_php() {
    section "PHP NOT INSTALLED"

    warn "No usable PHP-FPM version was detected."

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        INSTALL_PHP="Y"
    else
        read -rp "Install the default PHP-FPM now? [Y/n]: " INSTALL_PHP
        INSTALL_PHP="${INSTALL_PHP:-Y}"
    fi

    if [[ ! "$INSTALL_PHP" =~ ^[Yy]$ ]]; then
        error "PHP-FPM is required."
        return 1
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
        php-gd

    detect_php_fpm_versions

    if [[ ${#INSTALLED_PHP_VERSIONS[@]} -eq 0 ]]; then
        error "PHP installation completed but PHP-FPM could not be detected."
        return 1
    fi

    return 0
}


# ------------------------------------------------------------------------------
# PHP EXTENSIONS
# ------------------------------------------------------------------------------

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
        json
        mbstring
        openssl
        pcre
        PDO
        pdo_mysql
        session
        tokenizer
        xml
        zip
        intl
        gd
    )

    local missing=()
    local ext

    for ext in "${required[@]}"; do
        if "$PHP_BIN" -m 2>/dev/null |
            grep -qiE "^${ext}$"; then

            info "$ext: OK"

        else
            warn "$ext: MISSING"
            missing+=("$ext")
        fi
    done

    # --------------------------------------------------------------------------
    # All extensions are available
    # --------------------------------------------------------------------------

    if [[ ${#missing[@]} -eq 0 ]]; then
        info "PHP extensions verified."
        return 0
    fi

    echo
    warn "Required PHP extensions are missing for PHP $PHP_VER."

    # --------------------------------------------------------------------------
    # NON-INTERACTIVE MODE
    # --------------------------------------------------------------------------

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        INSTALL_EXT="Y"
    else
        read -rp "Install missing PHP extensions now? [Y/n]: " INSTALL_EXT
        INSTALL_EXT="${INSTALL_EXT:-Y}"
    fi

    # --------------------------------------------------------------------------
    # User chose NOT to install
    #
    # IMPORTANT:
    # Do NOT call die here.
    # Returning 1 allows select_php_version() to ask for another PHP version.
    # --------------------------------------------------------------------------

    if [[ ! "$INSTALL_EXT" =~ ^[Yy]$ ]]; then
        echo
        warn "Required PHP extensions were not installed."
        warn "Please select another PHP version."
        return 1
    fi

    # --------------------------------------------------------------------------
    # Build Debian package list
    # --------------------------------------------------------------------------

    local packages=()

    for ext in "${missing[@]}"; do

        case "$ext" in

            # Built into PHP / not installed separately
            PDO|pcre|filter|hash|session|tokenizer|ctype|fileinfo|json|openssl)
                ;;

            dom)
                packages+=("php${PHP_VER}-xml")
                ;;

            pdo_mysql)
                packages+=("php${PHP_VER}-mysql")
                ;;

            *)
                packages+=("php${PHP_VER}-${ext}")
                ;;
        esac

    done

    # Remove duplicate packages
    if [[ ${#packages[@]} -gt 0 ]]; then
        mapfile -t packages < <(
            printf '%s\n' "${packages[@]}" |
            sort -u
        )

        info "Installing missing PHP packages:"
        printf '  %s\n' "${packages[@]}"

        install_packages "${packages[@]}"
    fi

    # --------------------------------------------------------------------------
    # DRY-RUN
    # --------------------------------------------------------------------------

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would verify PHP $PHP_VER extensions after installation."
        return 0
    fi

    # --------------------------------------------------------------------------
    # Verify again after installation
    # --------------------------------------------------------------------------

    echo
    info "Verifying PHP $PHP_VER extensions..."

    local still_missing=()

    for ext in "${missing[@]}"; do

        case "$ext" in
            PDO|pcre|filter|hash|session|tokenizer|ctype|fileinfo|json|openssl)
                continue
                ;;
        esac

        if "$PHP_BIN" -m 2>/dev/null |
            grep -qiE "^${ext}$"; then

            info "$ext: OK"

        else
            warn "$ext: STILL MISSING"
            still_missing+=("$ext")
        fi

    done

    # --------------------------------------------------------------------------
    # Installation failed
    #
    # Return 1 instead of terminating the whole script.
    # The caller will return to PHP version selection.
    # --------------------------------------------------------------------------

    if [[ ${#still_missing[@]} -gt 0 ]]; then
        echo
        error "Some PHP extensions are still missing for PHP $PHP_VER."

        for ext in "${still_missing[@]}"; do
            echo "  - $ext"
        done

        echo
        warn "Please select another PHP version."

        return 1
    fi

    echo
    info "PHP extensions verified."

    return 0
}


# ------------------------------------------------------------------------------
# PHP SELECTION + EXTENSION VALIDATION
# ------------------------------------------------------------------------------

select_php_version() {
    section "INSTALLED PHP-FPM VERSIONS"

    if [[ ${#INSTALLED_PHP_VERSIONS[@]} -eq 0 ]]; then
        error "No PHP-FPM versions are available."
        return 1
    fi

    local highest
    highest="${INSTALLED_PHP_VERSIONS[-1]}"

    # --------------------------------------------------------------------------
    # Keep asking until:
    #   1. A valid PHP version is selected
    #   2. All required extensions are available
    # --------------------------------------------------------------------------

    while true; do

        echo

        for i in "${!INSTALLED_PHP_VERSIONS[@]}"; do
            echo "  $((i + 1))) PHP ${INSTALLED_PHP_VERSIONS[$i]}"
        done

        echo
        info "Highest installed PHP-FPM version: PHP $highest"

        local selection=""

        # ----------------------------------------------------------------------
        # PHP selection
        # ----------------------------------------------------------------------

        while true; do

            if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
                selection="${PHP_SELECTION:-${#INSTALLED_PHP_VERSIONS[@]}}"
            else
                read -rp \
                    "Select PHP version [default: ${#INSTALLED_PHP_VERSIONS[@]} - PHP $highest]: " \
                    selection

                selection="${selection:-${#INSTALLED_PHP_VERSIONS[@]}}"
            fi

            # Selection by number
            if [[ "$selection" =~ ^[0-9]+$ ]] &&
                (( selection >= 1 &&
                   selection <= ${#INSTALLED_PHP_VERSIONS[@]} )); then

                PHP_VER="${INSTALLED_PHP_VERSIONS[$((selection - 1))]}"
                break
            fi

            # Selection by version number, e.g. 8.3
            if printf '%s\n' "${INSTALLED_PHP_VERSIONS[@]}" |
                grep -qx "$selection"; then

                PHP_VER="$selection"
                break
            fi

            warn "Invalid PHP selection."
            echo

            if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
                error "Invalid PHP selection."
                return 1
            fi
        done

        # ----------------------------------------------------------------------
        # Configure selected PHP
        # ----------------------------------------------------------------------

        PHP_BIN="/usr/bin/php${PHP_VER}"
        PHP_FPM_SERVICE="php${PHP_VER}-fpm"
        PHP_FPM_SOCKET="/run/php/php${PHP_VER}-fpm.sock"

        if [[ ! -x "$PHP_BIN" ]]; then
            error "$PHP_BIN not found."
            echo
            warn "Please select another PHP version."

            if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
                return 1
            fi

            continue
        fi

        info "Selected PHP: PHP $PHP_VER"

        # ----------------------------------------------------------------------
        # Check extensions
        #
        # If the user refuses installation, check_php_extensions returns 1.
        # We then continue the outer loop and ask for PHP version again.
        # ----------------------------------------------------------------------

        if check_php_extensions; then
            return 0
        fi

        # ----------------------------------------------------------------------
        # Non-interactive mode cannot ask for another version.
        # ----------------------------------------------------------------------

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            error "PHP $PHP_VER does not have all required extensions."
            return 1
        fi

        echo
        echo "Please choose another PHP version."
        echo
    done
}


# ------------------------------------------------------------------------------
# PHP-FPM SERVICE
# ------------------------------------------------------------------------------

start_php_fpm() {
    section "PHP-FPM SERVICE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would enable and start $PHP_FPM_SERVICE."
        dry_run "Expected socket: $PHP_FPM_SOCKET"
        return 0
    fi

    if ! systemctl enable --now "$PHP_FPM_SERVICE"; then
        error "Failed to enable/start $PHP_FPM_SERVICE."
        return 1
    fi

    if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        systemctl status "$PHP_FPM_SERVICE" --no-pager || true
        error "$PHP_FPM_SERVICE is not running."
        return 1
    fi

    info "$PHP_FPM_SERVICE: active"

    if [[ ! -S "$PHP_FPM_SOCKET" ]]; then
        sleep 2
    fi

    if [[ ! -S "$PHP_FPM_SOCKET" ]]; then
        error "PHP-FPM socket not found: $PHP_FPM_SOCKET"
        return 1
    fi

    info "PHP-FPM socket: $PHP_FPM_SOCKET"

    return 0
}

# ------------------------------------------------------------------------------
# COMPOSER
# ------------------------------------------------------------------------------

install_composer_if_needed() {
    section "COMPOSER"

    COMPOSER_BIN="$(command -v composer || true)"

    if [[ -n "$COMPOSER_BIN" ]]; then
        info "Composer: $("$COMPOSER_BIN" --version 2>/dev/null | head -1)"
    else
        warn "Composer is not installed."

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            INSTALL_COMPOSER="Y"
        else
            read -rp "Install Composer now? [Y/n]: " INSTALL_COMPOSER
            INSTALL_COMPOSER="${INSTALL_COMPOSER:-Y}"
        fi

        [[ "$INSTALL_COMPOSER" =~ ^[Yy]$ ]] ||
            die "Composer is required."

        install_packages composer

        COMPOSER_BIN="$(command -v composer || true)"
    fi

    if [[ -z "$COMPOSER_BIN" ]]; then
        die "Composer could not be installed."
    fi

    local composer_version
    composer_version="$(
        "$COMPOSER_BIN" --version 2>/dev/null |
        sed -nE 's/.*Composer version ([0-9]+)\..*/\1/p'
    )"

    if [[ -n "$composer_version" ]] &&
        (( composer_version < 2 )); then

        warn "Composer 2.x is recommended."

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            UPGRADE_COMPOSER="Y"
        else
            read -rp "Install the official Composer 2.x? [Y/n]: " UPGRADE_COMPOSER
            UPGRADE_COMPOSER="${UPGRADE_COMPOSER:-Y}"
        fi

        if [[ "$UPGRADE_COMPOSER" =~ ^[Yy]$ ]]; then
            install_official_composer
        fi
    fi

    info "Composer: $("$COMPOSER_BIN" --version 2>/dev/null | head -1)"
}


install_official_composer() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would install official Composer 2.x to /usr/local/bin/composer."
        COMPOSER_BIN="/usr/local/bin/composer"
        return
    fi

    local installer
    installer="$(mktemp)"

    curl -fsSL https://getcomposer.org/installer -o "$installer"

    "$PHP_BIN" "$installer" \
        --install-dir=/usr/local/bin \
        --filename=composer

    rm -f "$installer"

    COMPOSER_BIN="/usr/local/bin/composer"

    [[ -x "$COMPOSER_BIN" ]] ||
        die "Official Composer installation failed."
}


# ------------------------------------------------------------------------------
# GIT
# ------------------------------------------------------------------------------

check_git() {
    section "GIT"

    GIT_BIN="$(command -v git || true)"

    if [[ -z "$GIT_BIN" ]]; then
        warn "Git is not installed."
        install_packages git
        GIT_BIN="$(command -v git || true)"
    fi

    [[ -n "$GIT_BIN" ]] ||
        die "Git is required."

    info "Git: $("$GIT_BIN" --version)"
}


# ------------------------------------------------------------------------------
# NVM / NODE.JS / NPM
# ------------------------------------------------------------------------------

detect_nvm_node() {
    local nvm_dir="${NVM_DIR:-$OWNER_HOME/.nvm}"

    if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
        return 1
    fi

    local result

    result="$(
        su - "$OWNER" -c "
            export NVM_DIR='$nvm_dir'
            source '\$NVM_DIR/nvm.sh'
            node --version
        " 2>/dev/null || true
    )"

    if [[ "$result" =~ ^v([0-9]+)\. ]]; then
        local major="${BASH_REMATCH[1]}"

        if (( major >= 20 )); then
            NODE_BIN="nvm"
            NPM_BIN="nvm"
            info "Using existing NVM Node.js: $result"
            return 0
        fi
    fi

    return 1
}


install_nvm_node() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would install/use Node.js LTS through NVM for $OWNER."
        NODE_BIN="nvm"
        NPM_BIN="nvm"
        return 0
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        INSTALL_NVM="Y"
    else
        read -rp "Install/use Node.js LTS through NVM? [Y/n]: " INSTALL_NVM
        INSTALL_NVM="${INSTALL_NVM:-Y}"
    fi

    if [[ ! "$INSTALL_NVM" =~ ^[Yy]$ ]]; then
        return 1
    fi

    local nvm_dir="$OWNER_HOME/.nvm"

    if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
        info "Installing NVM for $OWNER..."

        su - "$OWNER" -c \
            "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash"
    fi

    if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
        warn "NVM installation failed."
        return 1
    fi

    su - "$OWNER" -c "
        export NVM_DIR='$nvm_dir'
        source '\$NVM_DIR/nvm.sh'
        nvm install --lts
        nvm alias default 'lts/*'
    " || {
        warn "NVM Node.js installation failed."
        return 1
    }

    NODE_BIN="nvm"
    NPM_BIN="nvm"

    return 0
}


install_distro_node() {
    info "Falling back to distribution Node.js packages."

    install_packages nodejs npm

    NODE_BIN="$(command -v node || true)"
    NPM_BIN="$(command -v npm || true)"

    [[ -n "$NODE_BIN" ]] || die "Node.js installation failed."
    [[ -n "$NPM_BIN" ]] || die "npm installation failed."

    local major
    major="$("$NODE_BIN" --version | sed -nE 's/^v([0-9]+).*/\1/p')"

    if [[ -n "$major" ]] && (( major < 20 )); then
        warn "Distribution Node.js is $("$NODE_BIN" --version)."
        warn "Laravel frontend tooling may require a newer Node.js release."
    fi
}


check_node() {
    section "NODE.JS / NPM"

    if detect_nvm_node; then
        return
    fi

    if install_nvm_node; then
        info "Using NVM Node.js."
        return
    fi

    install_distro_node

    info "Node.js: $("$NODE_BIN" --version)"
    info "npm: $("$NPM_BIN" --version)"
}


# ------------------------------------------------------------------------------
# LARAVEL COMPATIBILITY
# ------------------------------------------------------------------------------

composer_can_resolve_laravel() {
    local major="$1"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would test Laravel ^${major}.0 compatibility with PHP ${PHP_VER} using Composer."
        return 0
    fi

    local output
    local status

    set +e

    output="$(
        timeout 90 \
            "$COMPOSER_BIN" create-project \
            "laravel/laravel:^${major}.0" \
            /tmp/laravel-compatibility-test \
            --no-install \
            --no-interaction \
            --prefer-dist \
            --ignore-platform-req=ext-* \
            2>&1
    )"

    status=$?

    rm -rf /tmp/laravel-compatibility-test

    set -e

    if [[ "$status" -eq 0 ]]; then
        return 0
    fi

    if grep -qiE \
        'requires php|your php version|could not resolve|conflict|does not satisfy' \
        <<< "$output"; then
        return 1
    fi

    return 1
}


select_laravel_version() {
    section "LARAVEL COMPATIBILITY"

    info "Selected PHP: PHP $PHP_VER"

    echo
    echo "Composer will be used to test Laravel compatibility."
    echo "This avoids relying on a hard-coded PHP/Laravel compatibility matrix."
    echo
    echo "Enter the Laravel major version you want."
    echo "Examples: 10, 11, 12, 13"
    echo

    local requested

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        requested="${LARAVEL_VERSION:-13}"
    else
        read -rp "Laravel major version [default: 13]: " requested
        requested="${requested:-13}"
    fi

    [[ "$requested" =~ ^[0-9]+$ ]] ||
        die "Invalid Laravel major version."

    LARAVEL_MAJOR="$requested"
    LARAVEL_CONSTRAINT="^${LARAVEL_MAJOR}.0"

    info "Testing Laravel ${LARAVEL_CONSTRAINT} with PHP ${PHP_VER}..."

    if composer_can_resolve_laravel "$LARAVEL_MAJOR"; then
        info "Laravel ${LARAVEL_MAJOR} is compatible with the selected PHP according to Composer."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi

    error "Laravel ${LARAVEL_MAJOR} could not be resolved with PHP ${PHP_VER}."

    echo
    echo "Try another Laravel major version."
    echo

    while true; do
        read -rp "Enter another Laravel major version, or q to abort: " requested

        if [[ "$requested" == "q" || "$requested" == "Q" ]]; then
            exit 1
        fi

        if [[ ! "$requested" =~ ^[0-9]+$ ]]; then
            warn "Invalid Laravel version."
            continue
        fi

        if composer_can_resolve_laravel "$requested"; then
            LARAVEL_MAJOR="$requested"
            LARAVEL_CONSTRAINT="^${LARAVEL_MAJOR}.0"
            info "Laravel ${LARAVEL_MAJOR} is compatible."
            break
        fi

        warn "Laravel ${requested} is not compatible with PHP ${PHP_VER}."
    done
}


# ------------------------------------------------------------------------------
# PROJECT TYPE
# ------------------------------------------------------------------------------

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

    while true; do

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            PROJECT_TYPE="${PROJECT_TYPE:-1}"
        else
            read -rp "Select project type [1]: " PROJECT_TYPE
            PROJECT_TYPE="${PROJECT_TYPE:-1}"
        fi

        case "$PROJECT_TYPE" in

            1)
                info "Project type: Normal Laravel"
                return 0
                ;;

            2)
                info "Project type: Vemto"
                return 0
                ;;

            3)
                info "Project type: GitHub"
                return 0
                ;;

            *)
                echo
                error "Invalid project type: $PROJECT_TYPE"
                warn "Please select 1, 2, or 3."
                echo

                if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
                    die "Invalid PROJECT_TYPE."
                fi
                ;;
        esac

    done
}


# ------------------------------------------------------------------------------
# PROJECT NAME
# ------------------------------------------------------------------------------

select_project_name() {
    section "PROJECT NAME"

    while true; do

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            PROJ="${PROJECT_NAME:-}"
        else
            read -rp "Enter project name (example: myapp): " PROJ
        fi

        # ----------------------------------------------------------------------
        # Validate project name
        #
        # Allowed:
        #   myapp
        #   my-app
        #   my_app
        #   my.app
        #   app123
        #
        # Not allowed:
        #   -myapp
        #   myapp-
        #   .myapp
        #   myapp.
        #   my..app
        #   empty
        # ----------------------------------------------------------------------

        if [[ "$PROJ" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]$ ]] ||
           [[ "$PROJ" =~ ^[a-zA-Z0-9]$ ]]; then

            if [[ "$PROJ" != *".."* ]]; then
                break
            fi
        fi

        echo
        warn "Invalid project name."
        warn "Use letters, numbers, dots, underscores and hyphens."
        warn "The first and last character must be alphanumeric."
        warn "Double dots are not allowed."
        echo

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            die "Invalid PROJECT_NAME."
        fi

    done

    # --------------------------------------------------------------------------
    # Local domain
    # --------------------------------------------------------------------------

    SERVER_NAME="${PROJ}.test"

    info "Project name: $PROJ"
    info "Local domain: $SERVER_NAME"
}


# ------------------------------------------------------------------------------
# BASE DIRECTORY
# ------------------------------------------------------------------------------

select_base_directory() {
    section "PROJECT DIRECTORY"

    echo
    echo "The project will be stored under the selected base directory."
    echo
    echo "Examples:"
    echo "  /var/www"
    echo "  /home/${OWNER}/www"
    echo "  /srv/www"
    echo

    local selected

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        selected="${BASE_DIRECTORY:-$DEFAULT_BASE_DIR}"
    else
        read -rp \
            "Enter base directory [default: $DEFAULT_BASE_DIR]: " \
            selected

        selected="${selected:-$DEFAULT_BASE_DIR}"
    fi

    if [[ "$selected" == "~" ]]; then
        selected="$OWNER_HOME"
    elif [[ "$selected" == "~/"* ]]; then
        selected="${OWNER_HOME}/${selected#~/}"
    fi

    selected="${selected%/}"

    [[ -n "$selected" ]] ||
        die "Base directory cannot be empty."

    BASE_DIR="$selected"
    PROJECT_DIR="${BASE_DIR}/${PROJ}"

    info "Base directory: $BASE_DIR"
    info "Project directory: $PROJECT_DIR"

    if [[ ! -d "$BASE_DIR" ]]; then

        warn "Directory does not exist: $BASE_DIR"

        if [[ "$DRY_RUN" -eq 1 ]]; then
            dry_run "Would create directory: $BASE_DIR"
        else
            local create

            if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
                create="Y"
            else
                read -rp "Create this directory? [Y/n]: " create
                create="${create:-Y}"
            fi

            if [[ "$create" =~ ^[Yy]$ ]]; then
                mkdir -p "$BASE_DIR"
                info "Created: $BASE_DIR"
            else
                exit 1
            fi
        fi
    fi
}


# ------------------------------------------------------------------------------
# PROJECT DIRECTORY SAFETY
# ------------------------------------------------------------------------------

check_project_directory() {
    section "PROJECT DIRECTORY SAFETY"

    # Directory does not exist — safe to continue
    if [[ ! -e "$PROJECT_DIR" ]]; then
        info "Project directory does not exist yet."
        return 0
    fi

    # --------------------------------------------------------------------------
    # NORMAL LARAVEL / GITHUB
    # These project types require a new directory.
    # Do NOT exit. Ask the user for another project name/base directory.
    # --------------------------------------------------------------------------

    if [[ "$PROJECT_TYPE" == "1" || "$PROJECT_TYPE" == "3" ]]; then

        echo
        error "Project directory already exists:"
        echo "  $PROJECT_DIR"
        echo

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            die "Cannot choose another project directory in non-interactive mode."
        fi

        warn "A new directory is required for this project type."
        echo

        # Ask for another project name
        while true; do
            read -rp "Enter another project name (example: myapp): " PROJECT_NAME

            if [[ -z "$PROJECT_NAME" ]]; then
                warn "Project name cannot be empty."
                continue
            fi

            if [[ ! "$PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$ ]]; then
                warn "Invalid project name."
                warn "Use letters, numbers, dots, underscores and hyphens."
                warn "The first and last character must be alphanumeric."
                continue
            fi

            if [[ "$PROJECT_NAME" == *".."* ]]; then
                warn "Double dots are not allowed."
                continue
            fi

            PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"

            if [[ -e "$PROJECT_DIR" ]]; then
                error "Project directory already exists:"
                echo "  $PROJECT_DIR"
                echo
                continue
            fi

            LOCAL_DOMAIN="${PROJECT_NAME}.test"

            info "Project name: $PROJECT_NAME"
            info "Local domain: $LOCAL_DOMAIN"
            info "Project directory: $PROJECT_DIR"

            break
        done

        return 0
    fi

    # --------------------------------------------------------------------------
    # VEMTO
    # Existing directory is allowed, but warn the user.
    # --------------------------------------------------------------------------

    if [[ "$PROJECT_TYPE" == "2" ]]; then

        warn "Vemto project directory already exists:"
        echo "  $PROJECT_DIR"

        if find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null |
            grep -q .; then

            warn "Directory is not empty."

            if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
                read -rp "Continue using this directory? [y/N]: " answer

                if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                    die "Vemto project setup cancelled by user."
                fi
            else
                die "Vemto project directory exists and is not empty."
            fi
        fi

        return 0
    fi

    # --------------------------------------------------------------------------
    # Unknown project type
    # --------------------------------------------------------------------------

    die "Unknown project type: $PROJECT_TYPE"
}


# ------------------------------------------------------------------------------
# GITHUB REPOSITORY
# ------------------------------------------------------------------------------

select_github_url() {
    section "GITHUB REPOSITORY"

    while true; do

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            GITHUB_URL="${GITHUB_URL:-}"
        else
            read -rp "GitHub repository URL: " GITHUB_URL
        fi

        # ----------------------------------------------------------------------
        # Required
        # ----------------------------------------------------------------------

        if [[ -z "$GITHUB_URL" ]]; then
            warn "GitHub URL is required."

            if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
                die "GitHub URL is required."
            fi

            continue
        fi

        # ----------------------------------------------------------------------
        # Basic GitHub URL validation
        # ----------------------------------------------------------------------

        if [[ "$GITHUB_URL" =~ ^https://github\.com/[^/]+/[^/]+/?$ ]]; then
            break
        fi

        if [[ "$GITHUB_URL" =~ ^https://github\.com/[^/]+/[^/]+\.git$ ]]; then
            break
        fi

        if [[ "$GITHUB_URL" =~ ^git@github\.com:[^/]+/[^/]+\.git$ ]]; then
            break
        fi

        warn "Invalid GitHub repository URL."
        warn "Use one of these formats:"
        echo
        echo "  https://github.com/user/repository"
        echo "  https://github.com/user/repository.git"
        echo "  git@github.com:user/repository.git"
        echo

        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            die "Invalid GitHub repository URL."
        fi

    done

    info "GitHub repository: $GITHUB_URL"
}

# ------------------------------------------------------------------------------
# MYSQL
# ------------------------------------------------------------------------------

detect_database_service() {
    section "MYSQL / MARIADB"

    if systemctl is-active --quiet mysql 2>/dev/null; then
        DB_SERVICE="mysql"
    elif systemctl is-active --quiet mariadb 2>/dev/null; then
        DB_SERVICE="mariadb"
    elif systemctl list-unit-files 2>/dev/null |
        grep -q '^mysql.service'; then

        if [[ "$DRY_RUN" -eq 1 ]]; then
            dry_run "Would enable/start mysql."
            DB_SERVICE="mysql"
        else
            systemctl enable --now mysql
            DB_SERVICE="mysql"
        fi

    elif systemctl list-unit-files 2>/dev/null |
        grep -q '^mariadb.service'; then

        if [[ "$DRY_RUN" -eq 1 ]]; then
            dry_run "Would enable/start mariadb."
            DB_SERVICE="mariadb"
        else
            systemctl enable --now mariadb
            DB_SERVICE="mariadb"
        fi
    else
        die "MySQL/MariaDB is not installed."
    fi

    info "Database service: $DB_SERVICE"
}


prepare_mysql_connection() {
    section "MYSQL ROOT CONNECTION"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would test MySQL root connection."
        return
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
    else
        read -rsp \
            "Enter MySQL root password (leave blank for socket authentication): " \
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
host=${MYSQL_HOST}
port=${MYSQL_PORT}
EOF

        MYSQL_CMD=(mysql "--defaults-extra-file=$MYSQL_OPTS_FILE")
    fi

    if ! "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
        die "Unable to connect to MySQL/MariaDB as root."
    fi

    info "Database connection successful."
}


select_database() {
    section "DATABASE"

    DB_NAME="${PROJ//[^a-zA-Z0-9_]/_}"

    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        local input
        read -rp "Database name [default: $DB_NAME]: " input
        DB_NAME="${input:-$DB_NAME}"
    else
        DB_NAME="${DATABASE_NAME:-$DB_NAME}"
    fi

    [[ "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]] ||
        die "Invalid database name."

    info "Database: $DB_NAME"
}


create_database() {
    section "CREATE DATABASE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would create database: $DB_NAME"
        return
    fi

    local db_name_sql

    db_name_sql="${DB_NAME//\`/\`\`}"

    "${MYSQL_CMD[@]}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${db_name_sql}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;
EOF

    info "Database ready."
}


select_database_user() {
    section "DATABASE USER"

    DB_USERNAME="root"
    DB_PASSWORD=""

    local create_user

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        create_user="${CREATE_DB_USER:-Y}"
    else
        read -rp \
            "Create a dedicated MySQL user for this project? [Y/n]: " \
            create_user

        create_user="${create_user:-Y}"
    fi

    if [[ ! "$create_user" =~ ^[Yy]$ ]]; then
        warn "Using root credentials in .env."
        return
    fi

    DB_USERNAME="${PROJ}_user"

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        DB_PASSWORD="${DB_PASSWORD:-}"
    else
        read -rsp \
            "Password for MySQL user '$DB_USERNAME' (leave blank to generate): " \
            DB_PASSWORD
        echo
    fi

    if [[ -z "$DB_PASSWORD" ]]; then
    if ! command -v openssl >/dev/null 2>&1; then
        echo "[ERROR] openssl is required to generate a secure database password."
        exit 1
    fi

        DB_PASSWORD="$(openssl rand -hex 24)"
        echo "[INFO] Generated MySQL password: $DB_PASSWORD"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would create MySQL user: ${DB_USERNAME}@${MYSQL_HOST}"
        return
    fi

    local db_password_sql
    local db_name_sql

    # Escape backslashes first.
    db_password_sql="${DB_PASSWORD//\\/\\\\}"

    # Then escape single quotes.
    db_password_sql="${db_password_sql//\'/\'\'}"

    db_name_sql="${DB_NAME//\`/\`\`}"

    "${MYSQL_CMD[@]}" <<EOF
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'${MYSQL_HOST}'
IDENTIFIED BY '${db_password_sql}';

ALTER USER '${DB_USERNAME}'@'${MYSQL_HOST}'
IDENTIFIED BY '${db_password_sql}';

GRANT ALL PRIVILEGES ON \`${db_name_sql}\`.* TO '${DB_USERNAME}'@'${MYSQL_HOST}';

FLUSH PRIVILEGES;
EOF

    info "Dedicated MySQL user created."
}


# ------------------------------------------------------------------------------
# NORMAL LARAVEL PROJECT
# ------------------------------------------------------------------------------

create_normal_laravel() {
    section "CREATING LARAVEL APPLICATION"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would create Laravel ${LARAVEL_CONSTRAINT} in $PROJECT_DIR."
        mkdir -p "$PROJECT_DIR"
        return
    fi

    mkdir -p "$(dirname "$PROJECT_DIR")"

    info "Creating Laravel ${LARAVEL_CONSTRAINT} using PHP ${PHP_VER}..."

    su - "$OWNER" -c "
        '$PHP_BIN' -d memory_limit=-1 '$COMPOSER_BIN' create-project \
        'laravel/laravel:${LARAVEL_CONSTRAINT}' \
        '$PROJECT_DIR' \
        --prefer-dist \
        --no-interaction \
        --no-progress
    " || die "Composer failed to create the Laravel application."

    [[ -f "$PROJECT_DIR/artisan" ]] ||
        die "Laravel creation finished but artisan was not found."

    info "Laravel application created."
}


# ------------------------------------------------------------------------------
# VEMTO
# ------------------------------------------------------------------------------

prepare_vemto() {
    section "PREPARING VEMTO PROJECT"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would create Vemto directory: $PROJECT_DIR"
    else
        mkdir -p "$PROJECT_DIR"
    fi

    info "Vemto project directory:"
    info "$PROJECT_DIR"

    info "Vemto should generate the Laravel application in this directory."
}


# ------------------------------------------------------------------------------
# COMPOSER FOR EXISTING PROJECT
# ------------------------------------------------------------------------------

install_project_dependencies() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would run Composer install in $PROJECT_DIR."
        return
    fi

    if [[ ! -f "$PROJECT_DIR/composer.json" ]]; then
        warn "composer.json not found. Skipping composer install."
        return
    fi

    info "Installing Composer dependencies..."

    su - "$OWNER" -c "
        cd '$PROJECT_DIR' &&
        '$PHP_BIN' '$COMPOSER_BIN' install \
        --no-interaction \
        --prefer-dist \
        --no-progress
    " || die "Composer dependency installation failed."

    info "Composer dependencies installed."
}


# ------------------------------------------------------------------------------
# NODE DEPENDENCIES
# ------------------------------------------------------------------------------

install_node_dependencies() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would install npm dependencies if package.json exists."
        return
    fi

    if [[ ! -f "$PROJECT_DIR/package.json" ]]; then
        info "No package.json found. Skipping npm install."
        return
    fi

    info "Installing npm dependencies..."

    if [[ "$NODE_BIN" == "nvm" ]]; then
        su - "$OWNER" -c "
            export NVM_DIR='$OWNER_HOME/.nvm'
            source '\$NVM_DIR/nvm.sh'
            cd '$PROJECT_DIR'
            npm install
        "
    else
        su - "$OWNER" -c "
            cd '$PROJECT_DIR'
            '$NPM_BIN' install
        "
    fi

    info "npm dependencies installed."
}


# ------------------------------------------------------------------------------
# REQUIRED LARAVEL DIRECTORIES
# ------------------------------------------------------------------------------

prepare_laravel_directories() {
    section "LARAVEL DIRECTORIES"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would create storage, bootstrap/cache and public directories."
        return
    fi

    mkdir -p "$PROJECT_DIR/storage"
    mkdir -p "$PROJECT_DIR/bootstrap/cache"
    mkdir -p "$PROJECT_DIR/public"

    info "storage: OK"
    info "bootstrap/cache: OK"
    info "public: OK"
}


# ------------------------------------------------------------------------------
# ENVIRONMENT
# ------------------------------------------------------------------------------

prepare_env() {
    section "ENVIRONMENT CONFIGURATION"

    local env_file="$PROJECT_DIR/.env"

    if [[ -f "$env_file" ]]; then
        warn ".env already exists. Preserving it."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would create $env_file."
        return
    fi

    cat > "$env_file" <<EOF
APP_NAME=${PROJ}
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=${APP_URL_VALUE}

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


# ------------------------------------------------------------------------------
# PERMISSIONS
# ------------------------------------------------------------------------------

set_project_permissions() {
    section "PROJECT PERMISSIONS"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would set ownership to ${OWNER}:${WEB_GROUP}."
        dry_run "Would set directories to 755 and files to 644."
        dry_run "Would set storage/bootstrap/cache to 775."
        return
    fi

    chown -R "$OWNER:$WEB_GROUP" "$PROJECT_DIR"

    find "$PROJECT_DIR" -type d -exec chmod 755 {} \;
    find "$PROJECT_DIR" -type f -exec chmod 644 {} \;

    chmod -R 775 "$PROJECT_DIR/storage"
    chmod -R 775 "$PROJECT_DIR/bootstrap/cache"

    chmod 640 "$PROJECT_DIR/.env" 2>/dev/null || true

    info "Ownership and basic permissions configured."
}


# ------------------------------------------------------------------------------
# ACL
# ------------------------------------------------------------------------------

grant_parent_traversal() {
    local target="$1"
    local current="/"

    IFS='/' read -ra parts <<< "${target#/}"

    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue

        current="${current%/}/${part}"

        if [[ -d "$current" ]]; then
            setfacl -m "u:${WEB_USER}:--x" "$current" 2>/dev/null || true
        fi
    done
}


configure_acl() {
    section "WEB SERVER ACCESS / ACL"

    if ! command -v setfacl >/dev/null 2>&1; then
        warn "setfacl is unavailable."
        warn "Falling back to www-data group permissions."

        if [[ "$DRY_RUN" -eq 1 ]]; then
            dry_run "Would grant group read/write permissions to storage and bootstrap/cache."
        else
            chgrp -R "$WEB_GROUP" "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
            chmod -R g+rwX "$PROJECT_DIR/storage" "$PROJECT_DIR/bootstrap/cache"
        fi

        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would grant ${WEB_USER} directory traversal through ${PROJECT_DIR}."
        dry_run "Would grant ${WEB_USER} read/write access to storage and bootstrap/cache."
        return
    fi

    grant_parent_traversal "$PROJECT_DIR"

    setfacl -R -m "u:${WEB_USER}:rwX" \
        "$PROJECT_DIR/storage" \
        "$PROJECT_DIR/bootstrap/cache"

    setfacl -R -d -m "u:${WEB_USER}:rwX" \
        "$PROJECT_DIR/storage" \
        "$PROJECT_DIR/bootstrap/cache"

    info "ACL permissions configured."
}


# ------------------------------------------------------------------------------
# APP KEY / CACHE
# ------------------------------------------------------------------------------

prepare_laravel_application() {
    if [[ "$PROJECT_TYPE" == "2" ]]; then
        info "Skipping Laravel application commands until Vemto generation is complete."
        return
    fi

    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        warn "artisan not found. Laravel commands deferred."
        return
    fi

    section "LARAVEL APPLICATION"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would run artisan key:generate."
        dry_run "Would run artisan config:clear."
        dry_run "Would run artisan cache:clear."
        return
    fi

    su - "$OWNER" -c "
        cd '$PROJECT_DIR' &&
        '$PHP_BIN' artisan key:generate --force &&
        '$PHP_BIN' artisan config:clear &&
        '$PHP_BIN' artisan cache:clear
    " || die "Laravel application preparation failed."

    info "Laravel application prepared."
}


# ------------------------------------------------------------------------------
# HTTPS
# ------------------------------------------------------------------------------

select_ssl() {
    section "LOCAL HTTPS"

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        SSL_ENABLED="${ENABLE_SSL:-0}"
        return
    fi

    read -rp \
        "Enable local self-signed SSL/TLS for ${SERVER_NAME}? [y/N]: " \
        answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        SSL_ENABLED=1
    else
        SSL_ENABLED=0
    fi
}


create_ssl_certificate() {
    if [[ "$SSL_ENABLED" -ne 1 ]]; then
        APP_URL_VALUE="http://${SERVER_NAME}"
        return
    fi

    SSL_CERT="/etc/ssl/certs/${SERVER_NAME}.crt"
    SSL_KEY="/etc/ssl/private/${SERVER_NAME}.key"

    APP_URL_VALUE="https://${SERVER_NAME}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would create self-signed certificate: $SSL_CERT"
        dry_run "Would create private key: $SSL_KEY"
        return
    fi

    install -m 644 /dev/null "$SSL_CERT"
    install -m 600 /dev/null "$SSL_KEY"

    openssl req \
        -x509 \
        -nodes \
        -days 825 \
        -newkey rsa:2048 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -subj "/CN=${SERVER_NAME}" \
        -addext "subjectAltName=DNS:${SERVER_NAME}" \
        >/dev/null 2>&1

    info "Self-signed certificate created."
}


# ------------------------------------------------------------------------------
# APACHE VIRTUALHOST
# ------------------------------------------------------------------------------

create_apache_vhost() {
    section "APACHE VIRTUALHOST"

    VHOST_FILE="${APACHE_SITES_AVAILABLE}/${PROJ}.test.conf"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would create Apache configuration: $VHOST_FILE"
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

    if [[ "$SSL_ENABLED" -eq 1 ]]; then

        cat >> "$VHOST_FILE" <<EOF

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

    info "Apache VirtualHost created."
}


# ------------------------------------------------------------------------------
# HOSTS
# ------------------------------------------------------------------------------

configure_hosts() {
    section "LOCAL DOMAIN"

    if grep -qE \
        "^[[:space:]]*127\.0\.0\.1[[:space:]]+${SERVER_NAME}([[:space:]]|$)" \
        "$HOSTS_FILE" 2>/dev/null; then

        info "${SERVER_NAME} already exists in /etc/hosts."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would add 127.0.0.1 ${SERVER_NAME} to /etc/hosts."
        return
    fi

    echo "127.0.0.1    ${SERVER_NAME}" >> "$HOSTS_FILE"

    info "Added ${SERVER_NAME} to /etc/hosts."
}


# ------------------------------------------------------------------------------
# APACHE MODULES
# ------------------------------------------------------------------------------

enable_apache_modules() {
    section "APACHE MODULES"

    local modules=(
        rewrite
        proxy
        proxy_fcgi
        setenvif
    )

    if [[ "$SSL_ENABLED" -eq 1 ]]; then
        modules+=(ssl)
    fi

    local mod

    for mod in "${modules[@]}"; do
        if a2query -m "$mod" >/dev/null 2>&1; then
            info "$mod: enabled"
        else
            if [[ "$DRY_RUN" -eq 1 ]]; then
                dry_run "Would enable Apache module: $mod"
            else
                a2enmod "$mod" >/dev/null
                info "$mod: enabled"
            fi
        fi
    done
}


# ------------------------------------------------------------------------------
# ENABLE SITE
# ------------------------------------------------------------------------------

enable_apache_site() {
    section "APACHE SITE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would enable ${PROJ}.test.conf."
        return
    fi

    if [[ ! -L "${APACHE_SITES_ENABLED}/${PROJ}.test.conf" ]]; then
        a2ensite "${PROJ}.test.conf" >/dev/null
        info "Enabled site: ${PROJ}.test"
    else
        info "Site already enabled."
    fi
}


# ------------------------------------------------------------------------------
# APACHE VALIDATION
# ------------------------------------------------------------------------------

validate_apache() {
    section "APACHE CONFIGURATION TEST"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would run: apache2ctl configtest"
        return
    fi

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

    if grep -qE 'Syntax error|AH00[0-9]{4}:' <<< "$output"; then
        error "Apache configuration test FAILED."
        error "Apache will NOT be reloaded."
        exit 2
    fi

    warn "Apache reported non-fatal output."
    warn "Configuration test returned status $status."

    if grep -qi "Syntax OK" <<< "$output"; then
        info "Apache appears syntactically valid."
    else
        error "Apache configuration could not be safely validated."
        exit 2
    fi
}


# ------------------------------------------------------------------------------
# APACHE RELOAD
# ------------------------------------------------------------------------------

reload_apache() {
    section "RELOADING APACHE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would reload apache2."
        return
    fi

    if ! systemctl reload apache2; then
        error "Apache reload failed."
        systemctl status apache2 --no-pager || true
        exit 2
    fi

    info "Apache reloaded successfully."
}


# ------------------------------------------------------------------------------
# LARAVEL DATABASE TEST
# ------------------------------------------------------------------------------

test_laravel_database() {
    if [[ "$PROJECT_TYPE" == "2" ]]; then
        info "Laravel database test deferred until Vemto generation."
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would test Laravel database connection after project creation."
        return
    fi

    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        warn "artisan not found. Laravel database test skipped."
        return
    fi

    section "LARAVEL DATABASE TEST"

    if su - "$OWNER" -c "
        cd '$PROJECT_DIR' &&
        '$PHP_BIN' artisan tinker --execute='DB::connection()->getPdo(); echo \"Database connection OK\\n\";'
    "; then
        info "Laravel database connection: OK"
    else
        warn "Laravel database connection test failed."
        warn "Check .env database credentials."
    fi
}


# ------------------------------------------------------------------------------
# LARAVEL VERSION
# ------------------------------------------------------------------------------

get_laravel_version() {
    LARAVEL_VERSION="N/A"

    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        LARAVEL_VERSION="Deferred in dry-run"
        return
    fi

    LARAVEL_VERSION="$(
        su - "$OWNER" -c "
            cd '$PROJECT_DIR' &&
            '$PHP_BIN' artisan --version
        " 2>/dev/null || echo "Unable to determine"
    )"
}


# ------------------------------------------------------------------------------
# HTTP TEST
# ------------------------------------------------------------------------------

test_http() {
    section "HTTP TEST"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_run "Would test http://${SERVER_NAME}/."
        return
    fi

    local scheme="http"
    local port="80"

    if [[ "$SSL_ENABLED" -eq 1 ]]; then
        scheme="https"
        port="443"
    fi

    local status

    if [[ "$scheme" == "https" ]]; then
        status="$(
            curl -k -s \
                -o /dev/null \
                -w "%{http_code}" \
                -H "Host: ${SERVER_NAME}" \
                "https://127.0.0.1:${port}/" ||
                echo "000"
        )"
    else
        status="$(
            curl -s \
                -o /dev/null \
                -w "%{http_code}" \
                -H "Host: ${SERVER_NAME}" \
                "http://127.0.0.1:${port}/" ||
                echo "000"
        )"
    fi

    if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
        info "HTTP status: $status (OK)"
    else
        warn "HTTP status: $status"
        warn "Check Apache logs if the site is not responding."
    fi
}


# ------------------------------------------------------------------------------
# FINAL VERIFICATION
# ------------------------------------------------------------------------------

final_verification() {
    section "FINAL VERIFICATION"

    get_laravel_version

    echo
    echo "Project"
    echo "-------"
    echo "Name:             $PROJ"
    echo "Directory:        $PROJECT_DIR"
    echo "URL:              $APP_URL_VALUE"
    echo "Type:             $(
        case "$PROJECT_TYPE" in
            1) echo "Normal Laravel" ;;
            2) echo "Vemto" ;;
            3) echo "GitHub" ;;
        esac
    )"

    echo
    echo "PHP"
    echo "---"
    echo "Selected PHP:     PHP $PHP_VER"
    echo "PHP binary:       $PHP_BIN"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$PHP_BIN" -v | head -1
    else
        echo "Version check:    DRY-RUN"
    fi

    echo
    echo "PHP-FPM"
    echo "-------"
    echo "Service:          $PHP_FPM_SERVICE"
    echo "Socket:           $PHP_FPM_SOCKET"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
            echo "Status:           ACTIVE"
        else
            echo "Status:           FAILED"
        fi

        if [[ -S "$PHP_FPM_SOCKET" ]]; then
            echo "Socket status:    OK"
        else
            echo "Socket status:    MISSING"
        fi
    else
        echo "Status:           DRY-RUN"
        echo "Socket status:    DRY-RUN"
    fi

    echo
    echo "Composer"
    echo "--------"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "Version:          $("$COMPOSER_BIN" --version | head -1)"
    else
        echo "Version:          DRY-RUN"
    fi

    echo
    echo "Node.js / npm"
    echo "-------------"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        if [[ "$NODE_BIN" == "nvm" ]]; then
            su - "$OWNER" -c "
                export NVM_DIR='$OWNER_HOME/.nvm'
                source '\$NVM_DIR/nvm.sh'
                echo \"Node:             \$(node --version)\"
                echo \"npm:              \$(npm --version)\"
            "
        else
            echo "Node:             $("$NODE_BIN" --version)"
            echo "npm:              $("$NPM_BIN" --version)"
        fi
    else
        echo "Status:           DRY-RUN"
    fi

    echo
    echo "Git"
    echo "---"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "$("$GIT_BIN" --version)"
    else
        echo "Status:           DRY-RUN"
    fi

    echo
    echo "Apache"
    echo "------"

    if [[ "$DRY_RUN" -eq 0 ]]; then
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
    else
        echo "Configuration:    DRY-RUN"
        echo "Service:          DRY-RUN"
    fi

    echo
    echo "Database"
    echo "--------"
    echo "Service:          $DB_SERVICE"
    echo "Database:         $DB_NAME"
    echo "Username:         $DB_USERNAME"

    if [[ "$PROJECT_TYPE" == "2" ]]; then
        echo "Laravel DB:       Deferred until Vemto generation."
    elif [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Laravel DB:       DRY-RUN"
    else
        if [[ -f "$PROJECT_DIR/artisan" ]] &&
            su - "$OWNER" -c "
                cd '$PROJECT_DIR' &&
                '$PHP_BIN' artisan migrate:status >/dev/null 2>&1
            "; then

            echo "Laravel DB:       OK"
        else
            echo "Laravel DB:       CHECK REQUIRED"
        fi
    fi

    echo
    echo "Permissions"
    echo "-----------"

    if [[ "$DRY_RUN" -eq 0 && -d "$PROJECT_DIR" ]]; then
        echo "Owner:            $(stat -c '%U' "$PROJECT_DIR")"
        echo "Group:            $(stat -c '%G' "$PROJECT_DIR")"

        if [[ -d "$PROJECT_DIR/storage" ]]; then
            echo "storage:          $(stat -c '%A' "$PROJECT_DIR/storage")"
        fi

        if [[ -d "$PROJECT_DIR/bootstrap/cache" ]]; then
            echo "bootstrap/cache:  $(stat -c '%A' "$PROJECT_DIR/bootstrap/cache")"
        fi
    else
        echo "Status:           DRY-RUN"
    fi

    echo
    echo "Laravel"
    echo "-------"
    echo "Version:          $LARAVEL_VERSION"
}


# ------------------------------------------------------------------------------
# FINAL INSTRUCTIONS
# ------------------------------------------------------------------------------

show_final_instructions() {
    section "PROJECT READY"

    echo
    echo "Project:"
    echo "  $PROJ"
    echo

    echo "Directory:"
    echo "  $PROJECT_DIR"
    echo

    echo "URL:"
    echo "  $APP_URL_VALUE"
    echo

    echo "PHP:"
    echo "  PHP $PHP_VER"
    echo

    echo "Laravel:"
    echo "  $LARAVEL_VERSION"
    echo

    echo "Database:"
    echo "  $DB_NAME"
    echo

    if [[ "$PROJECT_TYPE" == "1" ]]; then

        echo "Next steps:"
        echo
        echo "  cd $PROJECT_DIR"
        echo
        echo "  $PHP_BIN artisan migrate"
        echo
        echo "  npm install"
        echo "  npm run dev"
        echo

    elif [[ "$PROJECT_TYPE" == "2" ]]; then

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
        echo

    else

        echo "GitHub project:"
        echo
        echo "  cd $PROJECT_DIR"
        echo

        if [[ -f "$PROJECT_DIR/artisan" ]]; then
            echo "  $PHP_BIN artisan migrate"
        else
            echo "  Install/complete Laravel dependencies if required."
        fi

        echo
        echo "  npm install"
        echo "  npm run dev"
        echo
    fi

    echo "Apache configuration:"
    echo "  $VHOST_FILE"
    echo

    echo "PHP-FPM socket:"
    echo "  $PHP_FPM_SOCKET"
    echo

    echo "Log:"
    echo "  $LOG_FILE"
    echo

    info "Setup completed."
}


# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main() {

    parse_arguments "$@"

    determine_owner "$@"

    setup_logging

    section "STARTING $SCRIPT_NAME"

    show_version

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "DRY-RUN MODE ENABLED."
        warn "No intended system modifications will be performed."
    fi

    check_os

    check_basic_dependencies

    check_apache

    check_ports

    detect_php_fpm_versions

    if [[ ${#INSTALLED_PHP_VERSIONS[@]} -eq 0 ]]; then
        install_default_php
    fi

    select_php_version

    check_php_extensions

    start_php_fpm

    install_composer_if_needed

    check_git

    check_node

    select_laravel_version

    select_project_type

    select_project_name

    select_base_directory

    check_project_directory

    detect_database_service

    prepare_mysql_connection

    select_database

    create_database

    select_database_user

    case "$PROJECT_TYPE" in
        1)
            create_normal_laravel
            ;;
        2)
            prepare_vemto
            ;;
        3)
            select_github_url
            clone_github_project
            install_project_dependencies
            ;;
    esac

    prepare_laravel_directories

    prepare_env

    set_project_permissions

    configure_acl

    if [[ "$PROJECT_TYPE" == "1" || "$PROJECT_TYPE" == "3" ]]; then
        install_project_dependencies
        install_node_dependencies
    fi

    prepare_laravel_application

    select_ssl

    create_ssl_certificate

    create_apache_vhost

    configure_hosts

    enable_apache_modules

    enable_apache_site

    validate_apache

    reload_apache

    test_laravel_database

    test_http

    final_verification

    show_final_instructions
}


main "$@"
