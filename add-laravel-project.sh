```bash
#!/usr/bin/env bash
#
# add-laravel-project.sh
#
# Creates and configures a Laravel/Vemto project on Debian/Ubuntu.
#
# Features:
#   - Dynamic invoking-user detection
#   - Dynamic base-directory selection
#   - /var/www default
#   - Automatically shows /home/<user>/www
#   - Offers to create a missing base directory
#   - Dynamic PHP-FPM detection
#   - Installs PHP if no PHP-FPM is available
#   - Multiple PHP versions supported
#   - PHP-FPM version selection
#   - Laravel version recommendation
#   - Normal Laravel mode using Composer
#   - Vemto mode for an empty project directory
#   - Composer executed with selected PHP version
#   - MySQL/MariaDB database creation
#   - Optional dedicated database user
#   - Apache VirtualHost
#   - Per-project PHP-FPM socket
#   - ACL support for projects under /home/...
#   - Laravel storage/bootstrap/cache permissions
#   - .env generation
#   - Laravel application key generation
#   - Apache configuration validation
#   - PHP-FPM verification
#   - Laravel version verification
#   - Laravel database connection verification
#   - HTTP verification
#
# Supported:
#   Debian
#   Ubuntu
#
# Usage:
#   sudo ./add-laravel-project.sh
#
# ============================================================================

set -Eeuo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

DEFAULT_BASE_DIR="/var/www"

APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
HOSTS_FILE="/etc/hosts"

WEB_USER="www-data"
WEB_GROUP="www-data"

MYSQL_CLIENT="mysql"
MYSQL_HOST="127.0.0.1"

# ============================================================================
# COLORS / OUTPUT
# ============================================================================

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
    echo -e "[${YELLOW}WARN${RESET}] $*"
}

error() {
    echo -e "[${RED}ERROR${RESET}] $*" >&2
}

section() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}

die() {
    error "$*"
    exit 1
}

# ============================================================================
# ERROR HANDLER
# ============================================================================

trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR

# ============================================================================
# HELP
# ============================================================================

show_help() {
    cat <<EOF

Usage:
  sudo $0

Description:
  Creates and configures a Laravel/Vemto project with:

    - PHP-FPM
    - Laravel
    - Apache VirtualHost
    - MySQL/MariaDB database
    - .test local domain
    - Laravel permissions
    - ACL support for /home/... projects
    - Multi-PHP support

Project types:

  1) Normal Laravel
     Composer creates the Laravel application.

  2) Vemto
     Creates an empty Laravel-ready directory.
     Vemto generates the application afterwards.

Default project location:

  /var/www

Examples:

  /var/www
  /home/<current-user>/www
  /srv/www

EOF
}

# ============================================================================
# ROOT / SUDO USER
# ============================================================================

if [[ "$EUID" -ne 0 ]]; then
    info "Root privileges are required. Re-running with sudo..."
    exec sudo -E "$0" "$@"
fi

if [[ -z "${SUDO_USER:-}" ]]; then
    die "Run this script with sudo from a normal user account."
fi

OWNER="$SUDO_USER"

OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"

[[ -n "$OWNER_HOME" ]] || \
    die "Unable to determine home directory for user: $OWNER"

info "Running as root."
info "Project owner: $OWNER"
info "Owner home: $OWNER_HOME"

# ============================================================================
# OPERATING SYSTEM
# ============================================================================

section "OPERATING SYSTEM"

[[ -f /etc/os-release ]] || die "/etc/os-release not found."

source /etc/os-release

case "${ID:-}" in
    debian|ubuntu)
        info "Detected: ${PRETTY_NAME}"
        ;;
    *)
        die "This script supports Debian and Ubuntu only."
        ;;
esac

# ============================================================================
# PACKAGE MANAGER
# ============================================================================

export DEBIAN_FRONTEND=noninteractive

APT_UPDATED=false

apt_update_once() {
    if [[ "$APT_UPDATED" == false ]]; then
        info "Updating APT package information..."
        apt-get update
        APT_UPDATED=true
    fi
}

install_packages() {
    apt_update_once
    apt-get install -y "$@"
}

# ============================================================================
# BASIC DEPENDENCIES
# ============================================================================

section "CHECKING BASIC DEPENDENCIES"

if ! command -v apache2 >/dev/null 2>&1; then
    info "Apache is not installed. Installing..."
    install_packages apache2
fi

if ! command -v "$MYSQL_CLIENT" >/dev/null 2>&1; then
    info "MySQL client is not installed. Installing..."
    install_packages default-mysql-client
fi

if ! command -v setfacl >/dev/null 2>&1; then
    info "ACL support is not installed. Installing..."
    install_packages acl
fi

if ! command -v curl >/dev/null 2>&1; then
    info "curl is not installed. Installing..."
    install_packages curl
fi

if ! command -v git >/dev/null 2>&1; then
    info "Git is not installed. Installing..."
    install_packages git
fi

# ============================================================================
# APACHE
# ============================================================================

section "APACHE"

APACHE_VERSION="$(apache2 -v 2>/dev/null | head -1 || true)"

if [[ ! "$APACHE_VERSION" =~ Apache/2\.4 ]]; then
    die "Apache 2.4 or newer is required. Detected: $APACHE_VERSION"
fi

info "$APACHE_VERSION"

systemctl enable --now apache2

# ============================================================================
# PHP-FPM DETECTION
# ============================================================================

detect_php_fpm_versions() {

    mapfile -t INSTALLED_PHP_VERSIONS < <(
        find /usr/sbin \
            -maxdepth 1 \
            -type f \
            -name 'php-fpm*' \
            -printf '%f\n' 2>/dev/null |
        sed -nE 's/^php-fpm([0-9]+\.[0-9]+)$/\1/p' |
        sort -uV
    )
}

detect_php_fpm_versions

# ============================================================================
# INSTALL PHP IF NONE EXISTS
# ============================================================================

if [[ ${#INSTALLED_PHP_VERSIONS[@]} -eq 0 ]]; then

    section "PHP NOT INSTALLED"

    warn "No PHP-FPM installation was detected."

    echo
    echo "The script can install the default PHP version"
    echo "available from the current Debian/Ubuntu repositories."
    echo

    read -rp "Install PHP-FPM now? [Y/n]: " INSTALL_PHP
    INSTALL_PHP="${INSTALL_PHP:-Y}"

    if [[ ! "$INSTALL_PHP" =~ ^[Yy]$ ]]; then
        die "PHP-FPM is required."
    fi

    install_packages \
        php \
        php-cli \
        php-fpm \
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

    [[ ${#INSTALLED_PHP_VERSIONS[@]} -gt 0 ]] || \
        die "PHP-FPM installation completed but no PHP-FPM version was detected."

fi

# ============================================================================
# PHP VERSION LIST
# ============================================================================

section "INSTALLED PHP-FPM VERSIONS"

for i in "${!INSTALLED_PHP_VERSIONS[@]}"; do
    echo "  $((i + 1))) PHP ${INSTALLED_PHP_VERSIONS[$i]}"
done

HIGHEST_PHP="${INSTALLED_PHP_VERSIONS[-1]}"

echo
info "Highest installed PHP-FPM version: PHP $HIGHEST_PHP"

# ============================================================================
# PHP VERSION SELECTION
# ============================================================================

while true; do

    echo

    DEFAULT_PHP_INDEX="${#INSTALLED_PHP_VERSIONS[@]}"

    read -rp \
        "Select PHP version [default: ${DEFAULT_PHP_INDEX} - PHP ${HIGHEST_PHP}]: " \
        PHP_SELECTION

    PHP_SELECTION="${PHP_SELECTION:-$DEFAULT_PHP_INDEX}"

    if [[ "$PHP_SELECTION" =~ ^[0-9]+$ ]] &&
       (( PHP_SELECTION >= 1 &&
          PHP_SELECTION <= ${#INSTALLED_PHP_VERSIONS[@]} )); then

        PHP_VER="${INSTALLED_PHP_VERSIONS[$((PHP_SELECTION - 1))]}"
        break

    fi

    if printf '%s\n' "${INSTALLED_PHP_VERSIONS[@]}" |
       grep -qx "$PHP_SELECTION"; then

        PHP_VER="$PHP_SELECTION"
        break
    fi

    warn "Invalid PHP selection."

done

info "Selected PHP: $PHP_VER"

PHP_BIN="/usr/bin/php${PHP_VER}"
PHP_FPM_SERVICE="php${PHP_VER}-fpm"
PHP_FPM_SOCKET="/run/php/php${PHP_VER}-fpm.sock"

[[ -x "$PHP_BIN" ]] ||
    die "PHP binary not found: $PHP_BIN"

# ============================================================================
# PHP EXTENSIONS
# ============================================================================

section "PHP EXTENSIONS"

# These are the common Laravel extensions that the installer should ensure
# are available for the selected PHP version.

PHP_EXTENSIONS=(
    mysql
    mbstring
    xml
    curl
    zip
    bcmath
    intl
    gd
)

MISSING_EXTENSIONS=()

PHP_MODULES="$("$PHP_BIN" -m 2>/dev/null || true)"

for EXT in "${PHP_EXTENSIONS[@]}"; do

    if ! grep -qiE "^${EXT}$" <<< "$PHP_MODULES"; then
        MISSING_EXTENSIONS+=("$EXT")
    fi

done

if [[ ${#MISSING_EXTENSIONS[@]} -gt 0 ]]; then

    warn "Missing PHP extensions for PHP $PHP_VER:"
    printf '  %s\n' "${MISSING_EXTENSIONS[@]}"

    read -rp \
        "Install missing extensions now? [Y/n]: " \
        INSTALL_EXTENSIONS

    INSTALL_EXTENSIONS="${INSTALL_EXTENSIONS:-Y}"

    if [[ "$INSTALL_EXTENSIONS" =~ ^[Yy]$ ]]; then

        PACKAGES=()

        for EXT in "${MISSING_EXTENSIONS[@]}"; do
            PACKAGES+=("php${PHP_VER}-${EXT}")
        done

        install_packages "${PACKAGES[@]}"

    else

        die "Required PHP extensions are missing."

    fi

fi

info "PHP extensions verified."

# ============================================================================
# PHP-FPM SERVICE
# ============================================================================

section "PHP-FPM SERVICE"

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

    warn "PHP-FPM socket not found immediately."
    sleep 2

fi

[[ -S "$PHP_FPM_SOCKET" ]] || {
    systemctl status "$PHP_FPM_SERVICE" --no-pager || true
    die "PHP-FPM socket not found: $PHP_FPM_SOCKET"
}

info "PHP-FPM socket: $PHP_FPM_SOCKET"

# ============================================================================
# LARAVEL VERSION RECOMMENDATION
# ============================================================================

section "LARAVEL VERSION"

echo
echo "Selected PHP: PHP $PHP_VER"
echo

LARAVEL_OPTIONS=()

case "$PHP_VER" in

    8.5)
        LARAVEL_OPTIONS=("13" "12")
        ;;

    8.4)
        LARAVEL_OPTIONS=("13" "12" "11")
        ;;

    8.3)
        LARAVEL_OPTIONS=("13" "12" "11" "10")
        ;;

    8.2)
        LARAVEL_OPTIONS=("12" "11" "10")
        ;;

    8.1)
        LARAVEL_OPTIONS=("10")
        ;;

    8.0)
        LARAVEL_OPTIONS=("9")
        ;;

    7.4)
        LARAVEL_OPTIONS=("8")
        ;;

    7.3)
        LARAVEL_OPTIONS=("8")
        ;;

    *)
        die "No Laravel recommendation available for PHP $PHP_VER."
        ;;

esac

RECOMMENDED_LARAVEL="${LARAVEL_OPTIONS[0]}"

echo "Recommended Laravel version:"
echo "  Laravel $RECOMMENDED_LARAVEL"

echo
echo "Available choices compatible with this PHP selection:"

for i in "${!LARAVEL_OPTIONS[@]}"; do

    VERSION="${LARAVEL_OPTIONS[$i]}"

    if (( i == 0 )); then
        echo "  $((i + 1))) Laravel $VERSION [RECOMMENDED]"
    else
        echo "  $((i + 1))) Laravel $VERSION"
    fi

done

while true; do

    read -rp \
        "Select Laravel version [default: 1]: " \
        LARAVEL_SELECTION

    LARAVEL_SELECTION="${LARAVEL_SELECTION:-1}"

    if [[ "$LARAVEL_SELECTION" =~ ^[0-9]+$ ]] &&
       (( LARAVEL_SELECTION >= 1 &&
          LARAVEL_SELECTION <= ${#LARAVEL_OPTIONS[@]} )); then

        LARAVEL_MAJOR="${LARAVEL_OPTIONS[$((LARAVEL_SELECTION - 1))]}"
        break

    fi

    warn "Invalid Laravel selection."

done

LARAVEL_CONSTRAINT="^${LARAVEL_MAJOR}.0"

info "Selected Laravel constraint: $LARAVEL_CONSTRAINT"

# ============================================================================
# PROJECT TYPE
# ============================================================================

section "PROJECT TYPE"

echo
echo "  1) Normal Laravel"
echo "     Composer creates the Laravel application."
echo
echo "  2) Vemto"
echo "     Creates an empty Laravel-ready directory."
echo "     Vemto generates the application afterwards."
echo

while true; do

    read -rp "Select project type [1]: " PROJECT_TYPE
    PROJECT_TYPE="${PROJECT_TYPE:-1}"

    case "$PROJECT_TYPE" in
        1|2)
            break
            ;;
        *)
            warn "Please choose 1 or 2."
            ;;
    esac

done

# ============================================================================
# PROJECT NAME
# ============================================================================

section "PROJECT NAME"

while true; do

    read -rp "Enter project name (example: myapp): " PROJ

    if [[ "$PROJ" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        break
    fi

    warn "Invalid project name."
    warn "Use letters, numbers, underscores and hyphens."
    warn "The first character must be alphanumeric."

done

SERVER_NAME="${PROJ}.test"

# ============================================================================
# BASE DIRECTORY
# ============================================================================

section "PROJECT DIRECTORY"

echo
echo "Choose where the project should be stored."
echo
echo "Examples:"
echo "  /var/www"
echo "  ${OWNER_HOME}/www"
echo "  /srv/www"
echo

read -rp \
    "Enter base directory for projects [default: $DEFAULT_BASE_DIR]: " \
    BASE_DIR

BASE_DIR="${BASE_DIR:-$DEFAULT_BASE_DIR}"

# Expand ~ using the actual user running the script.
if [[ "$BASE_DIR" == "~" ]]; then

    BASE_DIR="$OWNER_HOME"

elif [[ "$BASE_DIR" == "~/"* ]]; then

    BASE_DIR="${OWNER_HOME}/${BASE_DIR#~/}"

fi

# Remove trailing slash.
BASE_DIR="${BASE_DIR%/}"

[[ -n "$BASE_DIR" ]] ||
    die "Invalid base directory."

info "Selected base directory: $BASE_DIR"

# ============================================================================
# CREATE BASE DIRECTORY IF NECESSARY
# ============================================================================

if [[ ! -d "$BASE_DIR" ]]; then

    warn "The selected directory does not exist:"
    echo
    echo "  $BASE_DIR"
    echo

    read -rp "Create this directory? [Y/n]: " CREATE_BASE_DIR
    CREATE_BASE_DIR="${CREATE_BASE_DIR:-Y}"

    if [[ "$CREATE_BASE_DIR" =~ ^[Yy]$ ]]; then

        info "Creating base directory..."

        mkdir -p "$BASE_DIR"

        chown "$OWNER:$WEB_GROUP" "$BASE_DIR"

        info "Base directory created successfully."

    else

        die "Base directory does not exist and was not created."

    fi

fi

PROJECT_DIR="${BASE_DIR}/${PROJ}"

info "Base directory:    $BASE_DIR"
info "Project directory: $PROJECT_DIR"

# ============================================================================
# PROJECT DIRECTORY SAFETY
# ============================================================================

if [[ -e "$PROJECT_DIR" ]]; then

    if [[ "$PROJECT_TYPE" == "2" ]]; then

        warn "Project directory already exists:"
        echo "  $PROJECT_DIR"

        if find "$PROJECT_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -print \
            -quit 2>/dev/null |
            grep -q .; then

            warn "The directory is not empty."

        else

            info "The directory is empty."

        fi

        read -rp \
            "Continue and configure this existing Vemto directory? [y/N]: " \
            CONTINUE_EXISTING

        if [[ ! "$CONTINUE_EXISTING" =~ ^[Yy]$ ]]; then
            die "Operation cancelled."
        fi

    else

        die "Project directory already exists: $PROJECT_DIR"

    fi

fi

# ============================================================================
# DATABASE SERVICE
# ============================================================================

section "DATABASE SERVICE"

DB_SERVICE=""

if systemctl is-active --quiet mysql 2>/dev/null; then

    DB_SERVICE="mysql"

elif systemctl is-active --quiet mariadb 2>/dev/null; then

    DB_SERVICE="mariadb"

else

    if systemctl list-unit-files |
       grep -q '^mysql.service'; then

        info "Starting MySQL..."
        systemctl enable --now mysql
        DB_SERVICE="mysql"

    elif systemctl list-unit-files |
         grep -q '^mariadb.service'; then

        info "Starting MariaDB..."
        systemctl enable --now mariadb
        DB_SERVICE="mariadb"

    else

        die "Neither MySQL nor MariaDB is installed."

    fi

fi

info "Database service: $DB_SERVICE"

# ============================================================================
# MYSQL ROOT CONNECTION
# ============================================================================

section "DATABASE CONNECTION"

MYSQL_OPTS_FILE=""

cleanup_mysql() {

    if [[ -n "${MYSQL_OPTS_FILE:-}" &&
          -f "$MYSQL_OPTS_FILE" ]]; then

        rm -f "$MYSQL_OPTS_FILE"

    fi

}

trap cleanup_mysql EXIT

echo

read -rsp \
    "Enter MySQL/MariaDB root password (leave blank for socket authentication): " \
    MYSQL_ROOT_PASSWORD

echo

if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then

    MYSQL_CMD=("$MYSQL_CLIENT" -u root)

else

    MYSQL_OPTS_FILE="$(mktemp)"

    chmod 600 "$MYSQL_OPTS_FILE"

    MYSQL_ROOT_PASSWORD_SQL="${MYSQL_ROOT_PASSWORD//\'/\'\'}"

    cat > "$MYSQL_OPTS_FILE" <<EOF
[client]
user=root
password='${MYSQL_ROOT_PASSWORD_SQL}'
EOF

    MYSQL_CMD=(
        "$MYSQL_CLIENT"
        "--defaults-extra-file=$MYSQL_OPTS_FILE"
    )

fi

if ! "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1; then

    die "Unable to connect to MySQL/MariaDB as root."

fi

info "Database connection successful."

# ============================================================================
# DATABASE NAME
# ============================================================================

section "DATABASE"

DB_NAME="$PROJ"

read -rp \
    "Database name [default: $DB_NAME]: " \
    INPUT_DB_NAME

DB_NAME="${INPUT_DB_NAME:-$DB_NAME}"

if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
    die "Invalid database name."
fi

DB_NAME_SQL="${DB_NAME//\`/\`\`}"

info "Creating database: $DB_NAME"

"${MYSQL_CMD[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME_SQL}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;
SQL

info "Database ready."

# ============================================================================
# DATABASE USER
# ============================================================================

echo

read -rp \
    "Create a dedicated MySQL user for this project? [Y/n]: " \
    CREATE_DB_USER

CREATE_DB_USER="${CREATE_DB_USER:-Y}"

DB_USERNAME="root"
DB_PASSWORD=""

if [[ "$CREATE_DB_USER" =~ ^[Yy]$ ]]; then

    DB_USERNAME="${PROJ}_user"

    echo

    read -rsp \
        "Password for '$DB_USERNAME' (leave blank to generate): " \
        DB_PASSWORD

    echo

    if [[ -z "$DB_PASSWORD" ]]; then

        DB_PASSWORD="$(
            tr -dc 'A-Za-z0-9!@#%+=_' </dev/urandom |
            head -c 24 || true
        )"

        [[ ${#DB_PASSWORD} -ge 20 ]] ||
            die "Unable to generate a secure database password."

        info "Generated secure database password."

    fi

    DB_PASSWORD_SQL="${DB_PASSWORD//\'/\'\'}"

    DB_USERNAME_SQL="${DB_USERNAME//\'/\'\'}"

    info "Creating database user: ${DB_USERNAME}@${MYSQL_HOST}"

    "${MYSQL_CMD[@]}" <<SQL
CREATE USER IF NOT EXISTS '${DB_USERNAME_SQL}'@'${MYSQL_HOST}'
IDENTIFIED BY '${DB_PASSWORD_SQL}';

ALTER USER '${DB_USERNAME_SQL}'@'${MYSQL_HOST}'
IDENTIFIED BY '${DB_PASSWORD_SQL}';

GRANT ALL PRIVILEGES
ON \`${DB_NAME_SQL}\`.*
TO '${DB_USERNAME_SQL}'@'${MYSQL_HOST}';

FLUSH PRIVILEGES;
SQL

    info "Dedicated database user created."

else

    warn "Using database root credentials in .env."

fi

# ============================================================================
# NORMAL LARAVEL MODE
# ============================================================================

if [[ "$PROJECT_TYPE" == "1" ]]; then

    section "CREATING LARAVEL APPLICATION"

    [[ ! -e "$PROJECT_DIR" ]] ||
        die "Target directory already exists."

    COMPOSER_BIN="$(command -v composer || true)"

    if [[ -z "$COMPOSER_BIN" ]]; then

        info "Composer is not installed."

        install_packages composer

        COMPOSER_BIN="$(command -v composer || true)"

    fi

    [[ -n "$COMPOSER_BIN" ]] ||
        die "Composer could not be installed."

    info "Composer: $COMPOSER_BIN"
    info "Composer PHP: $PHP_BIN"

    mkdir -p "$PROJECT_DIR"

    chown "$OWNER:$WEB_GROUP" "$PROJECT_DIR"

    info "Installing Laravel $LARAVEL_MAJOR with PHP $PHP_VER..."

    su - "$OWNER" -c \
        "$PHP_BIN -d memory_limit=-1 '$COMPOSER_BIN' create-project laravel/laravel '$PROJECT_DIR' '$LARAVEL_CONSTRAINT' --prefer-dist"

    info "Laravel application created."

else

    # =========================================================================
    # VEMTO MODE
    # =========================================================================

    section "PREPARING VEMTO PROJECT"

    mkdir -p "$PROJECT_DIR"

    info "Vemto project directory prepared:"
    info "$PROJECT_DIR"

    info "Vemto will generate the Laravel application here."

fi

# ============================================================================
# LARAVEL DIRECTORIES
# ============================================================================

section "LARAVEL DIRECTORIES"

mkdir -p "$PROJECT_DIR/storage"
mkdir -p "$PROJECT_DIR/bootstrap/cache"
mkdir -p "$PROJECT_DIR/public"

info "storage: OK"
info "bootstrap/cache: OK"
info "public: OK"

# ============================================================================
# .ENV
# ============================================================================

section "ENVIRONMENT CONFIGURATION"

ENV_FILE="$PROJECT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then

    warn ".env already exists. Keeping existing file."

else

    cat > "$ENV_FILE" <<EOF
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

    chmod 640 "$ENV_FILE"

    info ".env created."

fi

# ============================================================================
# OWNERSHIP / BASIC PERMISSIONS
# ============================================================================

section "PROJECT PERMISSIONS"

# Developer owns the project.
# www-data belongs to the group so Apache can access the application.
chown -R "$OWNER:$WEB_GROUP" "$PROJECT_DIR"

# Standard application permissions.
find "$PROJECT_DIR" \
    -type d \
    -exec chmod 755 {} \;

find "$PROJECT_DIR" \
    -type f \
    -exec chmod 644 {} \;

# Laravel writable directories.
chmod -R 775 "$PROJECT_DIR/storage"
chmod -R 775 "$PROJECT_DIR/bootstrap/cache"

# Protect .env.
chmod 640 "$ENV_FILE"

info "Ownership: $OWNER:$WEB_GROUP"
info "Application permissions configured."

# ============================================================================
# ACL / APACHE TRAVERSAL
# ============================================================================

section "ACL / WEB SERVER ACCESS"

grant_traversal() {

    local TARGET="$1"
    local CURRENT="/"

    IFS='/' read -ra PARTS <<< "${TARGET#/}"

    for PART in "${PARTS[@]}"; do

        [[ -z "$PART" ]] && continue

        CURRENT="${CURRENT%/}/${PART}"

        if [[ -d "$CURRENT" ]]; then

            setfacl \
                -m "u:${WEB_USER}:--x" \
                "$CURRENT" \
                2>/dev/null || true

        fi

    done
}

# Apache must be able to traverse the complete path.
grant_traversal "$PROJECT_DIR"

# Apache can read/write Laravel's required writable directories.
setfacl \
    -R \
    -m "u:${WEB_USER}:rwX" \
    "$PROJECT_DIR/storage"

setfacl \
    -R \
    -m "u:${WEB_USER}:rwX" \
    "$PROJECT_DIR/bootstrap/cache"

# Default ACLs ensure future files/directories inherit access.
setfacl \
    -R \
    -d \
    -m "u:${WEB_USER}:rwX" \
    "$PROJECT_DIR/storage"

setfacl \
    -R \
    -d \
    -m "u:${WEB_USER}:rwX" \
    "$PROJECT_DIR/bootstrap/cache"

info "ACL permissions configured."

# ============================================================================
# LARAVEL APPLICATION KEY
# ============================================================================

if [[ "$PROJECT_TYPE" == "1" ]] &&
   [[ -f "$PROJECT_DIR/artisan" ]]; then

    section "LARAVEL APPLICATION KEY"

    info "Generating application key using PHP $PHP_VER..."

    su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan key:generate --force"

    info "Application key generated."

else

    info "Application key generation deferred until Vemto finishes."

fi

# ============================================================================
# APACHE VIRTUALHOST
# ============================================================================

section "APACHE VIRTUALHOST"

VHOST_FILE="${APACHE_SITES_AVAILABLE}/${PROJ}.test.conf"

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

    # Prevent direct access to hidden files such as .env
    <FilesMatch "^\.">
        Require all denied
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${PROJ}_error.log
    CustomLog \${APACHE_LOG_DIR}/${PROJ}_access.log combined

</VirtualHost>
EOF

info "VirtualHost created:"
info "$VHOST_FILE"

# ============================================================================
# /etc/HOSTS
# ============================================================================

section "LOCAL DOMAIN"

if grep -qE \
    "^[[:space:]]*127\.0\.0\.1[[:space:]]+${SERVER_NAME}([[:space:]]|$)" \
    "$HOSTS_FILE"; then

    info "$SERVER_NAME already exists in /etc/hosts."

else

    echo "127.0.0.1    ${SERVER_NAME}" >> "$HOSTS_FILE"

    info "Added $SERVER_NAME to /etc/hosts."

fi

# ============================================================================
# APACHE MODULES
# ============================================================================

section "APACHE MODULES"

for MOD in rewrite proxy proxy_fcgi setenvif; do

    if ! a2query -m "$MOD" >/dev/null 2>&1; then

        info "Enabling Apache module: $MOD"

        a2enmod "$MOD" >/dev/null

    else

        info "Apache module already enabled: $MOD"

    fi

done

# ============================================================================
# ENABLE SITE
# ============================================================================

section "APACHE SITE"

if ! a2query -s "${PROJ}.test" >/dev/null 2>&1; then

    a2ensite "${PROJ}.test.conf" >/dev/null

    info "Enabled site: ${PROJ}.test"

else

    info "Site already enabled: ${PROJ}.test"

fi

# ============================================================================
# APACHE CONFIGURATION TEST
# ============================================================================

section "APACHE CONFIGURATION TEST"

APACHE_TEST_OUTPUT="$(apache2ctl configtest 2>&1)" || {

    echo
    echo "---------------- APACHE ERROR ----------------"
    echo "$APACHE_TEST_OUTPUT"
    echo "-----------------------------------------------"
    echo

    error "Apache configuration test FAILED."
    error "Apache was NOT reloaded."

    exit 1
}

echo "$APACHE_TEST_OUTPUT"

info "Apache configuration: OK"

# ============================================================================
# LARAVEL DATABASE TEST
# ============================================================================

if [[ "$PROJECT_TYPE" == "1" ]] &&
   [[ -f "$PROJECT_DIR/artisan" ]]; then

    section "LARAVEL DATABASE TEST"

    if su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan tinker --execute='DB::connection()->getPdo(); echo \"Database connection OK\\n\";'" \
        2>&1; then

        info "Laravel database connection: OK"

    else

        warn "Laravel database connection test failed."
        warn "Check the database credentials in .env."

    fi

else

    info "Laravel database test deferred until Vemto generation."

fi

# ============================================================================
# LARAVEL VERSION CHECK
# ============================================================================

LARAVEL_VERSION="N/A"

if [[ -f "$PROJECT_DIR/artisan" ]]; then

    LARAVEL_VERSION="$(
        su - "$OWNER" -c \
            "cd '$PROJECT_DIR' && '$PHP_BIN' artisan --version" \
            2>/dev/null ||
        echo "Unable to determine"
    )"

    info "Laravel version: $LARAVEL_VERSION"

fi

# ============================================================================
# RELOAD APACHE
# ============================================================================

section "RELOADING APACHE"

if ! systemctl reload apache2; then

    error "Apache reload failed."

    systemctl status apache2 --no-pager || true

    exit 1

fi

info "Apache reloaded successfully."

# ============================================================================
# FINAL VERIFICATION
# ============================================================================

section "FINAL VERIFICATION"

echo

echo "Project"
echo "-------"
echo "Name:              $PROJ"
echo "Directory:         $PROJECT_DIR"
echo "URL:               http://${SERVER_NAME}"

if [[ "$PROJECT_TYPE" == "1" ]]; then
    echo "Type:              Normal Laravel"
else
    echo "Type:              Vemto"
fi

echo
echo "PHP"
echo "---"
echo "Selected PHP:      PHP $PHP_VER"
echo "PHP binary:        $PHP_BIN"

"$PHP_BIN" -v | head -1

echo
echo "PHP-FPM"
echo "-------"
echo "Service:           $PHP_FPM_SERVICE"

if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
    echo "Status:            ACTIVE"
else
    echo "Status:            FAILED"
fi

echo "Socket:            $PHP_FPM_SOCKET"

if [[ -S "$PHP_FPM_SOCKET" ]]; then
    echo "Socket status:     OK"
else
    echo "Socket status:     MISSING"
fi

echo
echo "Apache"
echo "------"

if apache2ctl configtest >/dev/null 2>&1; then
    echo "Configuration:     OK"
else
    echo "Configuration:     FAILED"
fi

if systemctl is-active --quiet apache2; then
    echo "Service:            ACTIVE"
else
    echo "Service:            FAILED"
fi

echo
echo "Database"
echo "--------"
echo "Service:           $DB_SERVICE"
echo "Database:          $DB_NAME"
echo "Username:          $DB_USERNAME"

if [[ "$PROJECT_TYPE" == "1" ]] &&
   [[ -f "$PROJECT_DIR/artisan" ]]; then

    if su - "$OWNER" -c \
        "cd '$PROJECT_DIR' && '$PHP_BIN' artisan migrate:status >/dev/null 2>&1"; then

        echo "Laravel DB:        OK"

    else

        echo "Laravel DB:        CHECK REQUIRED"

    fi

else

    echo "Laravel DB:        Deferred until Vemto generation"

fi

echo
echo "HTTP Access"
echo "-----------"

HTTP_STATUS="$(
    curl \
        -s \
        -o /dev/null \
        -w "%{http_code}" \
        -H "Host: ${SERVER_NAME}" \
        http://127.0.0.1/ \
        2>/dev/null ||
    echo "000"
)"

if [[ "$HTTP_STATUS" =~ ^[23][0-9][0-9]$ ]]; then

    echo "HTTP Status:       $HTTP_STATUS (OK)"

elif [[ "$HTTP_STATUS" == "000" ]]; then

    echo "HTTP Status:       Connection failed"

else

    echo "HTTP Status:       $HTTP_STATUS (Check logs)"

fi

echo
echo "Permissions"
echo "-----------"
echo "Owner:             $(stat -c '%U' "$PROJECT_DIR")"
echo "Group:             $(stat -c '%G' "$PROJECT_DIR")"
echo "Project mode:      $(stat -c '%A' "$PROJECT_DIR")"
echo "storage:           $(stat -c '%A' "$PROJECT_DIR/storage")"
echo "bootstrap/cache:   $(stat -c '%A' "$PROJECT_DIR/bootstrap/cache")"

echo
echo "Laravel"
echo "-------"
echo "Version:           $LARAVEL_VERSION"

# ============================================================================
# FINAL INSTRUCTIONS
# ============================================================================

section "PROJECT READY"

echo

echo "URL:"
echo "  http://${SERVER_NAME}"

echo

echo "Directory:"
echo "  ${PROJECT_DIR}"

echo

echo "PHP:"
echo "  PHP ${PHP_VER}"

echo

echo "Laravel:"
echo "  ${LARAVEL_VERSION}"

echo

echo "Database:"
echo "  ${DB_NAME}"

echo

if [[ "$PROJECT_TYPE" == "1" ]]; then

    echo "Next steps:"
    echo
    echo "  cd ${PROJECT_DIR}"
    echo
    echo "  ${PHP_BIN} artisan migrate"
    echo
    echo "  npm install"
    echo "  npm run dev"
    echo

else

    echo "Vemto next steps:"
    echo
    echo "  1. Open Vemto."
    echo "  2. Select:"
    echo
    echo "       ${PROJECT_DIR}"
    echo
    echo "  3. Let Vemto generate the Laravel application."
    echo
    echo "  4. Then run:"
    echo
    echo "       cd ${PROJECT_DIR}"
    echo "       ${PHP_BIN} artisan key:generate"
    echo "       ${PHP_BIN} artisan migrate"
    echo

fi

echo
echo "Apache configuration:"
echo "  ${VHOST_FILE}"

echo
echo "PHP-FPM socket:"
echo "  ${PHP_FPM_SOCKET}"

echo

info "Everything completed successfully."
```
