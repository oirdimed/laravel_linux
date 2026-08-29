#!/usr/bin/env bash

# ============================================================
# add-laravel-project.sh
#
# Laravel/Vemto project creator for Debian/Ubuntu
#
# Features:
#   - Dynamic PHP CLI/FPM detection
#   - Installs PHP if missing
#   - Installs missing PHP-FPM when necessary
#   - Dynamic PHP/Laravel compatibility selection
#   - Normal Laravel project via Composer
#   - Vemto project preparation
#   - Dynamic project directory
#   - MySQL database + dedicated user
#   - Apache .test virtual host
#   - Per-project PHP-FPM
#   - ACL permissions for /home/user/www or /var/www
#   - No Docker
#
# Usage:
#   sudo /home/oirdimed/applications/add-laravel-project.sh
#
# ============================================================

set -Eeuo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

DEFAULT_BASE_DIR="/var/www"

APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
HOSTS_FILE="/etc/hosts"

PHP_INSTALL_VERSION="8.3"

MYSQL_OPTS_FILE=""

# ============================================================
# COLORS / OUTPUT
# ============================================================

info() {
    echo -e "[\e[32mINFO\e[0m] $*"
}

warn() {
    echo -e "[\e[33mWARN\e[0m] $*"
}

error() {
    echo -e "[\e[31mERROR\e[0m] $*" >&2
}

title() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
    echo
}

die() {
    error "$*"
    exit 1
}

# ============================================================
# CLEANUP
# ============================================================

cleanup() {
    if [[ -n "${MYSQL_OPTS_FILE:-}" && -f "$MYSQL_OPTS_FILE" ]]; then
        rm -f "$MYSQL_OPTS_FILE"
    fi
}

trap cleanup EXIT INT TERM

# ============================================================
# ROOT / SUDO
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E "$0" "$@"
fi

if [[ -z "${SUDO_USER:-}" ]]; then
    die "Run this script with sudo from your normal user account."
fi

OWNER="$SUDO_USER"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"

if [[ -z "$OWNER_HOME" || ! -d "$OWNER_HOME" ]]; then
    die "Could not determine home directory for user: $OWNER"
fi

# ============================================================
# OS DETECTION
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found."
fi

source /etc/os-release

case "${ID:-}" in
    debian|ubuntu)
        ;;
    *)
        die "Unsupported OS: ${ID:-unknown}. This script supports Debian and Ubuntu."
        ;;
esac

info "Detected OS: ${PRETTY_NAME:-$ID}"

# ============================================================
# BASIC REQUIREMENTS
# ============================================================

command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
command -v systemctl >/dev/null 2>&1 || die "systemctl is required."

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# INSTALL BASIC PACKAGES
# ============================================================

title "SYSTEM REQUIREMENTS"

info "Updating package information..."

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    unzip \
    git \
    acl \
    apache2 \
    mysql-client

# ============================================================
# PHP REPOSITORY
# ============================================================

setup_php_repository() {

    if [[ "${ID}" == "ubuntu" ]]; then

        info "Ubuntu detected."

        if ! apt-cache show "php${PHP_INSTALL_VERSION}" >/dev/null 2>&1; then

            warn "PHP ${PHP_INSTALL_VERSION} is not available in the current Ubuntu repositories."

            info "Adding Ondrej PHP repository..."

            apt-get install -y \
                software-properties-common

            if ! grep -Rqs "ppa.launchpad.net/ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
                add-apt-repository -y ppa:ondrej/php
            fi

            apt-get update
        fi

    elif [[ "${ID}" == "debian" ]]; then

        info "Debian detected."

        if ! apt-cache show "php${PHP_INSTALL_VERSION}" >/dev/null 2>&1; then

            warn "PHP ${PHP_INSTALL_VERSION} is not available in the current Debian repositories."

            info "Adding packages.sury.org PHP repository..."

            apt-get install -y \
                ca-certificates \
                curl \
                gnupg

            install -d -m 0755 /etc/apt/keyrings

            if [[ ! -f /etc/apt/keyrings/debsuryorg-archive-keyring.gpg ]]; then

                curl -fsSL \
                    https://packages.sury.org/debsuryorg-archive-keyring.deb \
                    -o /tmp/debsuryorg-archive-keyring.deb

                dpkg -i /tmp/debsuryorg-archive-keyring.deb

                rm -f /tmp/debsuryorg-archive-keyring.deb
            fi

            CODENAME="${VERSION_CODENAME:-}"

            if [[ -z "$CODENAME" ]]; then
                CODENAME="$(lsb_release -sc)"
            fi

            cat > /etc/apt/sources.list.d/php.list <<EOF
deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${CODENAME} main
EOF

            apt-get update
        fi
    fi
}

# ============================================================
# PHP INSTALLATION
# ============================================================

PHP_PACKAGES_COMMON=(
    "php${PHP_INSTALL_VERSION}"
    "php${PHP_INSTALL_VERSION}-cli"
    "php${PHP_INSTALL_VERSION}-fpm"
    "php${PHP_INSTALL_VERSION}-mysql"
    "php${PHP_INSTALL_VERSION}-mbstring"
    "php${PHP_INSTALL_VERSION}-xml"
    "php${PHP_INSTALL_VERSION}-curl"
    "php${PHP_INSTALL_VERSION}-zip"
    "php${PHP_INSTALL_VERSION}-bcmath"
    "php${PHP_INSTALL_VERSION}-intl"
    "php${PHP_INSTALL_VERSION}-gd"
)

install_php_version() {

    local VERSION="$1"

    title "INSTALL PHP ${VERSION}"

    setup_php_repository

    local PACKAGES=(
        "php${VERSION}"
        "php${VERSION}-cli"
        "php${VERSION}-fpm"
        "php${VERSION}-mysql"
        "php${VERSION}-mbstring"
        "php${VERSION}-xml"
        "php${VERSION}-curl"
        "php${VERSION}-zip"
        "php${VERSION}-bcmath"
        "php${VERSION}-intl"
        "php${VERSION}-gd"
    )

    info "Installing PHP ${VERSION}..."

    apt-get install -y "${PACKAGES[@]}"

    systemctl enable --now "php${VERSION}-fpm"

    info "PHP ${VERSION} installed successfully."
}

# ============================================================
# DETECT PHP CLI
# ============================================================

detect_php_cli() {

    PHP_CLI_VERSIONS=()

    for BIN in /usr/bin/php[0-9]*.[0-9]*; do

        [[ -x "$BIN" ]] || continue

        VERSION="$("$BIN" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"

        [[ -n "$VERSION" ]] || continue

        if [[ ! " ${PHP_CLI_VERSIONS[*]} " =~ " ${VERSION} " ]]; then
            PHP_CLI_VERSIONS+=("$VERSION")
        fi
    done

    if command -v php >/dev/null 2>&1; then

        VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"

        if [[ -n "$VERSION" ]]; then

            if [[ ! " ${PHP_CLI_VERSIONS[*]} " =~ " ${VERSION} " ]]; then
                PHP_CLI_VERSIONS+=("$VERSION")
            fi

        fi
    fi

    printf '%s\n' "${PHP_CLI_VERSIONS[@]}" | sort -uV
}

# ============================================================
# DETECT PHP FPM
# ============================================================

detect_php_fpm() {

    PHP_FPM_VERSIONS=()

    for BIN in /usr/sbin/php-fpm[0-9]*.[0-9]*; do

        [[ -x "$BIN" ]] || continue

        VERSION="$(basename "$BIN" | sed -E 's/php-fpm([0-9]+\.[0-9]+)/\1/')"

        [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || continue

        if [[ ! " ${PHP_FPM_VERSIONS[*]} " =~ " ${VERSION} " ]]; then
            PHP_FPM_VERSIONS+=("$VERSION")
        fi
    done

    printf '%s\n' "${PHP_FPM_VERSIONS[@]}" | sort -uV
}

# ============================================================
# INITIAL PHP DETECTION
# ============================================================

mapfile -t PHP_CLI_VERSIONS < <(detect_php_cli)
mapfile -t PHP_FPM_VERSIONS < <(detect_php_fpm)

if [[ ${#PHP_CLI_VERSIONS[@]} -eq 0 && ${#PHP_FPM_VERSIONS[@]} -eq 0 ]]; then

    title "PHP NOT INSTALLED"

    echo "No PHP CLI or PHP-FPM installation was detected."
    echo
    echo "The script needs PHP to continue."
    echo
    read -rp "Install PHP ${PHP_INSTALL_VERSION}? [Y/n]: " INSTALL_PHP

    INSTALL_PHP="${INSTALL_PHP:-Y}"

    if [[ ! "$INSTALL_PHP" =~ ^[Yy]$ ]]; then
        die "PHP is required."
    fi

    install_php_version "$PHP_INSTALL_VERSION"

fi

# ============================================================
# RE-DETECT PHP
# ============================================================

mapfile -t PHP_CLI_VERSIONS < <(detect_php_cli)
mapfile -t PHP_FPM_VERSIONS < <(detect_php_fpm)

# ============================================================
# DISPLAY PHP CLI
# ============================================================

title "PHP ENVIRONMENT"

if [[ ${#PHP_CLI_VERSIONS[@]} -gt 0 ]]; then

    echo "Installed PHP CLI versions:"

    for VERSION in "${PHP_CLI_VERSIONS[@]}"; do
        echo "  PHP ${VERSION}"
    done

else

    warn "No PHP CLI detected."

fi

echo

if [[ ${#PHP_FPM_VERSIONS[@]} -gt 0 ]]; then

    echo "Installed PHP-FPM versions:"

    for VERSION in "${PHP_FPM_VERSIONS[@]}"; do
        echo "  PHP ${VERSION}"
    done

else

    warn "No PHP-FPM detected."

fi

# ============================================================
# SELECT HIGHEST PHP FPM
# ============================================================

if [[ ${#PHP_FPM_VERSIONS[@]} -eq 0 ]]; then

    if [[ ${#PHP_CLI_VERSIONS[@]} -eq 0 ]]; then
        die "No usable PHP installation detected."
    fi

    HIGHEST_PHP="${PHP_CLI_VERSIONS[-1]}"

    warn "PHP-FPM is missing."

    read -rp "Install PHP ${HIGHEST_PHP}-FPM and required extensions? [Y/n]: " INSTALL_FPM

    INSTALL_FPM="${INSTALL_FPM:-Y}"

    if [[ "$INSTALL_FPM" =~ ^[Yy]$ ]]; then
        install_php_version "$HIGHEST_PHP"
    else
        die "PHP-FPM is required for Apache."
    fi

    mapfile -t PHP_FPM_VERSIONS < <(detect_php_fpm)

else

    HIGHEST_PHP="${PHP_FPM_VERSIONS[-1]}"

fi

info "Highest installed PHP-FPM version: PHP ${HIGHEST_PHP}"

# ============================================================
# PHP VERSION SELECTION
# ============================================================

title "SELECT PHP VERSION"

for i in "${!PHP_FPM_VERSIONS[@]}"; do
    echo "  $((i + 1))) PHP ${PHP_FPM_VERSIONS[$i]}"
done

DEFAULT_INDEX=$((${#PHP_FPM_VERSIONS[@]}))

echo

read -rp \
"Select PHP version [default: ${DEFAULT_INDEX} - PHP ${PHP_FPM_VERSIONS[-1]}]: " \
PHP_SELECTION

PHP_SELECTION="${PHP_SELECTION:-$DEFAULT_INDEX}"

if [[ "$PHP_SELECTION" =~ ^[0-9]+$ ]] &&
   (( PHP_SELECTION >= 1 && PHP_SELECTION <= ${#PHP_FPM_VERSIONS[@]} )); then

    PHP_VER="${PHP_FPM_VERSIONS[$((PHP_SELECTION - 1))]}"

else

    if [[ " ${PHP_FPM_VERSIONS[*]} " =~ " ${PHP_SELECTION} " ]]; then
        PHP_VER="$PHP_SELECTION"
    else
        die "Invalid PHP selection."
    fi

fi

info "Selected PHP: ${PHP_VER}"

# ============================================================
# ENSURE CLI EXISTS FOR SELECTED PHP
# ============================================================

if [[ ! -x "/usr/bin/php${PHP_VER}" ]]; then

    warn "PHP ${PHP_VER} CLI is missing."

    read -rp "Install PHP ${PHP_VER} CLI and required extensions? [Y/n]: " INSTALL_CLI

    INSTALL_CLI="${INSTALL_CLI:-Y}"

    if [[ "$INSTALL_CLI" =~ ^[Yy]$ ]]; then
        install_php_version "$PHP_VER"
    else
        die "PHP ${PHP_VER} CLI is required for Composer."
    fi

fi

PHP_BIN="/usr/bin/php${PHP_VER}"

if [[ ! -x "$PHP_BIN" ]]; then
    die "PHP binary not found: $PHP_BIN"
fi

# ============================================================
# LARAVEL COMPATIBILITY
# ============================================================

laravel_versions_for_php() {

    local PHP="$1"

    case "$PHP" in

        8.5)
            echo "13 12"
            ;;

        8.4)
            echo "13 12 11"
            ;;

        8.3)
            echo "13 12 11 10"
            ;;

        8.2)
            echo "12 11 10"
            ;;

        8.1)
            echo "10"
            ;;

        8.0)
            echo "9"
            ;;

        7.4)
            echo "8"
            ;;

        7.3)
            echo "8"
            ;;

        *)
            echo ""
            ;;

    esac
}

recommended_laravel_for_php() {

    local PHP="$1"

    case "$PHP" in

        8.5|8.4|8.3)
            echo "13"
            ;;

        8.2)
            echo "12"
            ;;

        8.1)
            echo "10"
            ;;

        8.0)
            echo "9"
            ;;

        7.4|7.3)
            echo "8"
            ;;

        *)
            echo ""
            ;;

    esac
}

COMPATIBLE_LARAVEL="$(laravel_versions_for_php "$PHP_VER")"
RECOMMENDED_LARAVEL="$(recommended_laravel_for_php "$PHP_VER")"

if [[ -z "$COMPATIBLE_LARAVEL" ]]; then
    die "No supported Laravel version is compatible with PHP ${PHP_VER}."
fi

# ============================================================
# LARAVEL VERSION SELECTION
# ============================================================

title "LARAVEL VERSION"

echo "PHP selected: PHP ${PHP_VER}"
echo

echo "Compatible Laravel versions:"

LARAVEL_ARRAY=($COMPATIBLE_LARAVEL)

for i in "${!LARAVEL_ARRAY[@]}"; do

    VERSION="${LARAVEL_ARRAY[$i]}"

    if [[ "$VERSION" == "$RECOMMENDED_LARAVEL" ]]; then
        echo "  $((i + 1))) Laravel ${VERSION}  <-- RECOMMENDED"
    else
        echo "  $((i + 1))) Laravel ${VERSION}"
    fi

done

echo

DEFAULT_LARAVEL_INDEX=1

read -rp \
"Select Laravel version [default: ${DEFAULT_LARAVEL_INDEX} - Laravel ${RECOMMENDED_LARAVEL}]: " \
LARAVEL_SELECTION

LARAVEL_SELECTION="${LARAVEL_SELECTION:-$DEFAULT_LARAVEL_INDEX}"

if [[ "$LARAVEL_SELECTION" =~ ^[0-9]+$ ]] &&
   (( LARAVEL_SELECTION >= 1 && LARAVEL_SELECTION <= ${#LARAVEL_ARRAY[@]} )); then

    LARAVEL_VER="${LARAVEL_ARRAY[$((LARAVEL_SELECTION - 1))]}"

else

    if [[ " ${LARAVEL_ARRAY[*]} " =~ " ${LARAVEL_SELECTION} " ]]; then
        LARAVEL_VER="$LARAVEL_SELECTION"
    else
        die "Invalid Laravel selection."
    fi

fi

info "Selected Laravel: ${LARAVEL_VER}"

# ============================================================
# PROJECT TYPE
# ============================================================

title "PROJECT TYPE"

echo "  1) Normal Laravel"
echo "     Create Laravel project with Composer"
echo
echo "  2) Vemto project"
echo "     Create empty project directory for Vemto generation"
echo

read -rp "Select project type [1]: " PROJECT_TYPE

PROJECT_TYPE="${PROJECT_TYPE:-1}"

case "$PROJECT_TYPE" in
    1)
        PROJECT_MODE="normal"
        ;;
    2)
        PROJECT_MODE="vemto"
        ;;
    *)
        die "Invalid project type."
        ;;
esac

# ============================================================
# PROJECT NAME
# ============================================================

title "PROJECT"

read -rp "Enter project name (e.g. test2): " PROJ_NAME

PROJ="$(echo "$PROJ_NAME" | tr -cd '[:alnum:]_-')"

if [[ -z "$PROJ" ]]; then
    die "Invalid project name."
fi

if [[ ! "$PROJ" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    die "Project name contains invalid characters."
fi

SERVER_NAME="${PROJ}.test"

# ============================================================
# BASE DIRECTORY
# ============================================================

echo
read -rp \
"Enter base directory for projects [${DEFAULT_BASE_DIR}]: " \
INPUT_BASE_DIR

BASE_DIR="${INPUT_BASE_DIR:-$DEFAULT_BASE_DIR}"

# Expand ~

if [[ "$BASE_DIR" == "~"* ]]; then
    BASE_DIR="${BASE_DIR/#\~/$OWNER_HOME}"
fi

BASE_DIR="$(readlink -m "$BASE_DIR")"

PROJECT_DIR="${BASE_DIR}/${PROJ}"

info "Base directory: ${BASE_DIR}"
info "Project directory: ${PROJECT_DIR}"

# ============================================================
# SAFETY CHECK
# ============================================================

if [[ -e "$PROJECT_DIR" ]]; then

    if [[ "$PROJECT_MODE" == "normal" ]]; then
        die "Project directory already exists: $PROJECT_DIR"
    fi

    warn "Project directory already exists: $PROJECT_DIR"

    read -rp "Continue with Vemto project? [y/N]: " CONTINUE_EXISTING

    if [[ ! "$CONTINUE_EXISTING" =~ ^[Yy]$ ]]; then
        exit 0
    fi

fi

# ============================================================
# CREATE BASE / PROJECT DIRECTORY
# ============================================================

mkdir -p "$PROJECT_DIR"

# ============================================================
# VEMTO MODE
# ============================================================

if [[ "$PROJECT_MODE" == "vemto" ]]; then

    title "VEMTO PROJECT"

    info "Preparing empty directory for Vemto..."

    mkdir -p "$PROJECT_DIR"

    # Do NOT create fake Laravel folders here.
    # Vemto will generate the Laravel structure.

    info "Project directory ready:"
    echo "  ${PROJECT_DIR}"

fi

# ============================================================
# NORMAL LARAVEL MODE
# ============================================================

if [[ "$PROJECT_MODE" == "normal" ]]; then

    title "LARAVEL INSTALLATION"

    if [[ -n "$(find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        die "Directory is not empty: $PROJECT_DIR"
    fi

    command -v composer >/dev/null 2>&1 || die "Composer is not installed."

    COMPOSER_BIN="$(command -v composer)"

    info "Composer: ${COMPOSER_BIN}"
    info "PHP: ${PHP_BIN}"
    info "Laravel: ${LARAVEL_VER}"

    info "Creating Laravel ${LARAVEL_VER} project..."

    su - "$OWNER" -c \
        "$PHP_BIN -d memory_limit=-1 '$COMPOSER_BIN' create-project laravel/laravel '$PROJECT_DIR' '^${LARAVEL_VER}.0'"

    info "Laravel ${LARAVEL_VER} installed."

fi

# ============================================================
# PROJECT STRUCTURE DETECTION
# ============================================================

if [[ "$PROJECT_MODE" == "normal" ]]; then

    if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
        die "Laravel installation failed: artisan not found."
    fi

fi

# ============================================================
# CREATE REQUIRED DIRECTORIES
# ============================================================

mkdir -p \
    "$PROJECT_DIR/storage" \
    "$PROJECT_DIR/bootstrap/cache"

# ============================================================
# DATABASE
# ============================================================

title "DATABASE"

command -v mysql >/dev/null 2>&1 || die "MySQL client is not installed."

read -rp \
"Enter MySQL root password (leave blank for Unix socket authentication): " \
MYSQL_ROOT_PWD

if [[ -z "$MYSQL_ROOT_PWD" ]]; then

    MYSQL_CMD=(mysql -u root)

else

    MYSQL_OPTS_FILE="$(mktemp)"

    chmod 600 "$MYSQL_OPTS_FILE"

    cat > "$MYSQL_OPTS_FILE" <<EOF
[client]
user=root
password=${MYSQL_ROOT_PWD}
EOF

    MYSQL_CMD=(mysql "--defaults-extra-file=$MYSQL_OPTS_FILE")

fi

if ! "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    die "Could not connect to MySQL."
fi

info "Connected to MySQL."

DB_NAME="$PROJ"
DB_USER="${PROJ}_user"

echo
read -rp \
"Create database '${DB_NAME}'? [Y/n]: " CREATE_DB

CREATE_DB="${CREATE_DB:-Y}"

if [[ "$CREATE_DB" =~ ^[Yy]$ ]]; then

    "${MYSQL_CMD[@]}" -e \
        "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    info "Database '${DB_NAME}' ready."

fi

echo
read -rp \
"Create dedicated MySQL user '${DB_USER}'? [Y/n]: " CREATE_DB_USER

CREATE_DB_USER="${CREATE_DB_USER:-Y}"

if [[ "$CREATE_DB_USER" =~ ^[Yy]$ ]]; then

    read -rsp \
    "Enter password for '${DB_USER}' (leave blank to generate): " \
    DB_PASS

    echo

    if [[ -z "$DB_PASS" ]]; then

        DB_PASS="$(tr -dc 'A-Za-z0-9!@#%^+=' < /dev/urandom | head -c 24 || true)"

        if [[ -z "$DB_PASS" ]]; then
            DB_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
        fi

        info "Generated database password."

    fi

    # Escape single quotes for SQL
    DB_PASS_SQL="${DB_PASS//\'/\'\'}"

    "${MYSQL_CMD[@]}" -e "
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
"

    info "MySQL user '${DB_USER}' configured."

else

    DB_USER="root"
    DB_PASS="$MYSQL_ROOT_PWD"

fi

# ============================================================
# .ENV
# ============================================================

ENV_FILE="${PROJECT_DIR}/.env"

if [[ "$PROJECT_MODE" == "normal" ]]; then

    if [[ ! -f "$ENV_FILE" ]]; then

        cat > "$ENV_FILE" <<EOF
APP_NAME=${PROJ}
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://${SERVER_NAME}

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

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

        info "Created .env"

    fi

else

    # Vemto may create its own .env.
    # We create one only if it doesn't exist.

    if [[ ! -f "$ENV_FILE" ]]; then

        cat > "$ENV_FILE" <<EOF
APP_NAME=${PROJ}
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://${SERVER_NAME}

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

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

        info "Created .env for Vemto."

    fi

fi

# ============================================================
# APACHE
# ============================================================

title "APACHE"

command -v apache2 >/dev/null 2>&1 || die "Apache2 is not installed."

for MODULE in rewrite proxy proxy_fcgi setenvif; do

    if ! a2query -m "$MODULE" >/dev/null 2>&1; then
        a2enmod "$MODULE" >/dev/null
        info "Enabled Apache module: ${MODULE}"
    fi

done

VHOST_FILE="${APACHE_SITES_AVAILABLE}/${PROJ}.test.conf"

cat > "$VHOST_FILE" <<EOF
<VirtualHost *:80>

    ServerName ${SERVER_NAME}
    ServerAlias www.${SERVER_NAME}

    DocumentRoot ${PROJECT_DIR}/public

    <Directory ${PROJECT_DIR}/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    <Directory ${PROJECT_DIR}>
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${PROJ}_test_error.log
    CustomLog \${APACHE_LOG_DIR}/${PROJ}_test_access.log combined

</VirtualHost>
EOF

info "Created Apache VirtualHost:"
echo "  ${VHOST_FILE}"

# ============================================================
# /ETC/HOSTS
# ============================================================

if ! grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${SERVER_NAME}([[:space:]]|$)" "$HOSTS_FILE"; then

    echo "127.0.0.1    ${SERVER_NAME}" >> "$HOSTS_FILE"

    info "Added ${SERVER_NAME} to /etc/hosts."

else

    info "${SERVER_NAME} already exists in /etc/hosts."

fi

# ============================================================
# ENABLE SITE
# ============================================================

a2ensite "${PROJ}.test.conf" >/dev/null 2>&1 || true

# ============================================================
# PHP-FPM
# ============================================================

systemctl enable --now "php${PHP_VER}-fpm"

SOCKET="/run/php/php${PHP_VER}-fpm.sock"

if [[ ! -S "$SOCKET" ]]; then
    sleep 2
fi

if [[ ! -S "$SOCKET" ]]; then
    die "PHP-FPM socket not found: ${SOCKET}"
fi

info "PHP-FPM socket verified: ${SOCKET}"

# ============================================================
# PERMISSIONS
# ============================================================

title "PERMISSIONS"

# ------------------------------------------------------------
# Ownership
# ------------------------------------------------------------

chown -R "${OWNER}:www-data" "$PROJECT_DIR"

# ------------------------------------------------------------
# Base project permissions
# ------------------------------------------------------------

find "$PROJECT_DIR" -type d -exec chmod 755 {} \;
find "$PROJECT_DIR" -type f -exec chmod 644 {} \;

# ------------------------------------------------------------
# Laravel writable directories
# ------------------------------------------------------------

chmod -R 775 \
    "$PROJECT_DIR/storage" \
    "$PROJECT_DIR/bootstrap/cache"

chown -R "${OWNER}:www-data" \
    "$PROJECT_DIR/storage" \
    "$PROJECT_DIR/bootstrap/cache"

# ------------------------------------------------------------
# ACL: Apache traversal
# ------------------------------------------------------------

if command -v setfacl >/dev/null 2>&1; then

    # Allow www-data to traverse the parent directory.
    setfacl -m u:www-data:--x "$OWNER_HOME"

    # Allow www-data to traverse the selected base directory.
    setfacl -m u:www-data:--x "$BASE_DIR"

    # Project traversal.
    setfacl -m u:www-data:--x "$PROJECT_DIR"

    # Laravel writable directories.
    setfacl -R -m u:www-data:rwX \
        "$PROJECT_DIR/storage" \
        "$PROJECT_DIR/bootstrap/cache"

    # Default ACLs so newly created files/directories inherit access.
    setfacl -R -d -m u:www-data:rwX \
        "$PROJECT_DIR/storage" \
        "$PROJECT_DIR/bootstrap/cache"

    info "ACL permissions configured for www-data."

else

    warn "setfacl not found. Installing acl..."

    apt-get install -y acl

    setfacl -m u:www-data:--x "$OWNER_HOME"
    setfacl -m u:www-data:--x "$BASE_DIR"
    setfacl -m u:www-data:--x "$PROJECT_DIR"

    setfacl -R -m u:www-data:rwX \
        "$PROJECT_DIR/storage" \
        "$PROJECT_DIR/bootstrap/cache"

    setfacl -R -d -m u:www-data:rwX \
        "$PROJECT_DIR/storage" \
        "$PROJECT_DIR/bootstrap/cache"

fi

info "Permissions configured."

# ============================================================
# LARAVEL KEY
# ============================================================

if [[ -f "$PROJECT_DIR/artisan" ]]; then

    title "LARAVEL CONFIGURATION"

    if grep -q "^APP_KEY=$" "$ENV_FILE"; then

        info "Generating application key..."

        su - "$OWNER" -c \
            "cd '$PROJECT_DIR' && '$PHP_BIN' artisan key:generate --force"

    else

        info "Application key already exists."

    fi

    # Clear Laravel configuration cache.
    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan config:clear" || true

fi

# ============================================================
# COMPOSER AUTOLOAD
# ============================================================

if [[ "$PROJECT_MODE" == "normal" && -f "$PROJECT_DIR/composer.json" ]]; then

    info "Running Composer dump-autoload..."

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' '$COMPOSER_BIN' dump-autoload"

fi

# ============================================================
# DATABASE MIGRATION
# ============================================================

if [[ "$PROJECT_MODE" == "normal" ]]; then

    title "DATABASE MIGRATION"

    read -rp \
    "Run 'php artisan migrate --seed' now? [Y/n]: " RUN_MIGRATE

    RUN_MIGRATE="${RUN_MIGRATE:-Y}"

    if [[ "$RUN_MIGRATE" =~ ^[Yy]$ ]]; then

        su - "$OWNER" -c \
            "cd '$PROJECT_DIR' && '$PHP_BIN' artisan migrate --seed"

    fi

else

    title "VEMTO"

    echo "The Vemto project is prepared."
    echo
    echo "Project directory:"
    echo "  ${PROJECT_DIR}"
    echo
    echo "Selected PHP:"
    echo "  PHP ${PHP_VER}"
    echo
    echo "Selected Laravel:"
    echo "  Laravel ${LARAVEL_VER}"
    echo
    echo "Vemto should generate the Laravel application into:"
    echo "  ${PROJECT_DIR}"
    echo

fi

# ============================================================
# APACHE TEST
# ============================================================

title "APACHE FINALIZATION"

if ! apache2ctl configtest; then

    error "Apache configuration test failed."

    error "VirtualHost:"
    error "  ${VHOST_FILE}"

    exit 1

fi

systemctl reload apache2

info "Apache reloaded successfully."

# ============================================================
# FINAL PERMISSIONS
# ============================================================

chown -R "${OWNER}:www-data" "$PROJECT_DIR"

find "$PROJECT_DIR" -type d -exec chmod 755 {} \;
find "$PROJECT_DIR" -type f -exec chmod 644 {} \;

chmod -R 775 \
    "$PROJECT_DIR/storage" \
    "$PROJECT_DIR/bootstrap/cache"

setfacl -m u:www-data:--x "$OWNER_HOME"
setfacl -m u:www-data:--x "$BASE_DIR"
setfacl -m u:www-data:--x "$PROJECT_DIR"

setfacl -R -m u:www-data:rwX \
    "$PROJECT_DIR/storage" \
    "$PROJECT_DIR/bootstrap/cache"

setfacl -R -d -m u:www-data:rwX \
    "$PROJECT_DIR/storage" \
    "$PROJECT_DIR/bootstrap/cache"

# ============================================================
# FINAL SUMMARY
# ============================================================

title "PROJECT CREATED SUCCESSFULLY"

echo "Project type:"
echo "  ${PROJECT_MODE}"

echo
echo "Project:"
echo "  ${PROJ}"

echo
echo "Directory:"
echo "  ${PROJECT_DIR}"

echo
echo "URL:"
echo "  http://${SERVER_NAME}"

echo
echo "PHP:"
echo "  PHP ${PHP_VER}"

echo
echo "PHP-FPM:"
echo "  /run/php/php${PHP_VER}-fpm.sock"

echo
echo "Laravel:"
echo "  Laravel ${LARAVEL_VER}"

echo
echo "Database:"
echo "  ${DB_NAME}"

echo
echo "Database user:"
echo "  ${DB_USER}"

echo
echo "Apache:"
echo "  ${VHOST_FILE}"

echo

if [[ "$PROJECT_MODE" == "normal" ]]; then

    echo "Next steps:"
    echo
    echo "  cd ${PROJECT_DIR}"
    echo "  ${PHP_BIN} artisan serve"
    echo
    echo "Or simply open:"
    echo "  http://${SERVER_NAME}"

else

    echo "Next steps:"
    echo
    echo "  1. Open Vemto."
    echo "  2. Generate the project into:"
    echo "     ${PROJECT_DIR}"
    echo "  3. Make sure Vemto uses:"
    echo "     PHP ${PHP_VER}"
    echo "  4. After generation:"
    echo
    echo "     cd ${PROJECT_DIR}"
    echo "     ${PHP_BIN} artisan migrate:fresh --seed"
    echo
    echo "  5. Open:"
    echo "     http://${SERVER_NAME}"

fi

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
