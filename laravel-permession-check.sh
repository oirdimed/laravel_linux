#!/usr/bin/env bash

# ==============================================================================
# Laravel Permission Diagnostic & Repair Tool
# Version: 1.0
# ==============================================================================

set -u

# ------------------------------------------------------------------------------
# COLORS
# ------------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

WEB_USER="www-data"
WEB_GROUP="www-data"

PROJECT_DIR=""
STORAGE_DIR=""
LOG_DIR=""
CACHE_DIR=""
LOG_FILE=""

REQUIRED_PROBLEM=0
FIXED_SOMETHING=0

# ------------------------------------------------------------------------------
# OUTPUT FUNCTIONS
# ------------------------------------------------------------------------------

section() {
    echo
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

subsection() {
    echo
    echo "------------------------------------------------------------"
    echo " $1"
    echo "------------------------------------------------------------"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ------------------------------------------------------------------------------
# ROOT CHECK
# ------------------------------------------------------------------------------

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run with sudo."
        echo
        echo "Run:"
        echo
        echo "  sudo $0"
        echo
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# ASK PROJECT DIRECTORY
# ------------------------------------------------------------------------------

ask_project_directory() {

    section "LARAVEL PROJECT DIRECTORY"

    while true; do

        read -rp "Enter Laravel project directory: " PROJECT_DIR

        PROJECT_DIR="${PROJECT_DIR/#\~/$HOME}"

        if [[ -z "$PROJECT_DIR" ]]; then
            warn "Directory cannot be empty."
            continue
        fi

        if [[ ! -d "$PROJECT_DIR" ]]; then
            error "Directory does not exist:"
            echo "  $PROJECT_DIR"
            echo
            continue
        fi

        PROJECT_DIR="$(realpath "$PROJECT_DIR")"

        if [[ ! -f "$PROJECT_DIR/artisan" ]]; then
            warn "artisan was not found in:"
            echo "  $PROJECT_DIR"
            echo
            read -rp "Use this directory anyway? [y/N]: " answer

            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                echo
                continue
            fi
        fi

        break
    done

    STORAGE_DIR="$PROJECT_DIR/storage"
    LOG_DIR="$PROJECT_DIR/storage/logs"
    CACHE_DIR="$PROJECT_DIR/bootstrap/cache"
    LOG_FILE="$PROJECT_DIR/storage/logs/laravel.log"

    echo
    info "Laravel project directory:"
    echo "       $PROJECT_DIR"
}

# ------------------------------------------------------------------------------
# CHECK LARAVEL PROJECT
# ------------------------------------------------------------------------------

check_laravel_project() {

    section "LARAVEL PROJECT"

    if [[ -f "$PROJECT_DIR/artisan" ]]; then
        ok "artisan exists"
    else
        error "artisan is missing"
    fi

    if [[ -d "$STORAGE_DIR" ]]; then
        ok "storage directory exists"
    else
        error "storage directory is missing"
        REQUIRED_PROBLEM=1
    fi

    if [[ -d "$CACHE_DIR" ]]; then
        ok "bootstrap/cache exists"
    else
        error "bootstrap/cache is missing"
        REQUIRED_PROBLEM=1
    fi
}

# ------------------------------------------------------------------------------
# WEB SERVER USER
# ------------------------------------------------------------------------------

check_web_user() {

    section "WEB SERVER USER"

    if id "$WEB_USER" >/dev/null 2>&1; then
        info "Web server user: $WEB_USER"
    else
        error "User $WEB_USER does not exist."
        REQUIRED_PROBLEM=1
    fi

    if getent group "$WEB_GROUP" >/dev/null 2>&1; then
        info "Web server group: $WEB_GROUP"
    else
        error "Group $WEB_GROUP does not exist."
        REQUIRED_PROBLEM=1
    fi
}

# ------------------------------------------------------------------------------
# PROJECT OWNERSHIP
# ------------------------------------------------------------------------------

check_project_ownership() {

    section "PROJECT OWNERSHIP"

    local owner
    local group

    owner="$(stat -c '%U' "$PROJECT_DIR")"
    group="$(stat -c '%G' "$PROJECT_DIR")"

    echo "Project owner : $owner"
    echo "Project group : $group"

    if [[ "$group" == "$WEB_GROUP" ]]; then
        ok "Project group is $WEB_GROUP"
    else
        warn "Project group is $group"
        warn "Expected group: $WEB_GROUP"
        info "This is not automatically a Laravel failure."
    fi
}

# ------------------------------------------------------------------------------
# DIRECTORY INFORMATION
# ------------------------------------------------------------------------------

show_directory_info() {

    local dir="$1"

    echo
    echo "Directory: $dir"

    if [[ ! -d "$dir" ]]; then
        error "Directory does not exist"
        return
    fi

    echo "  Permissions: $(stat -c '%A' "$dir")"
    echo "  Owner:       $(stat -c '%U' "$dir")"
    echo "  Group:       $(stat -c '%G' "$dir")"
}

# ------------------------------------------------------------------------------
# DIRECTORY WRITE TEST
# ------------------------------------------------------------------------------

test_www_write_directory() {

    local dir="$1"
    local label="$2"
    local test_file

    if [[ ! -d "$dir" ]]; then
        error "$label does not exist"
        REQUIRED_PROBLEM=1
        return 1
    fi

    test_file="$dir/.laravel-permission-test-$$"

    if sudo -u "$WEB_USER" touch "$test_file" 2>/dev/null; then

        rm -f "$test_file"

        ok "Writable by www-data: $label"
        return 0

    else

        error "NOT writable by www-data: $label"
        REQUIRED_PROBLEM=1
        return 1
    fi
}

# ------------------------------------------------------------------------------
# DIRECTORY PERMISSIONS
# ------------------------------------------------------------------------------

check_directories() {

    section "REQUIRED LARAVEL DIRECTORIES"

    subsection "storage/"

    show_directory_info "$STORAGE_DIR"

    test_www_write_directory \
        "$STORAGE_DIR" \
        "storage/"

    subsection "storage/logs/"

    show_directory_info "$LOG_DIR"

    test_www_write_directory \
        "$LOG_DIR" \
        "storage/logs/"

    subsection "bootstrap/cache/"

    show_directory_info "$CACHE_DIR"

    test_www_write_directory \
        "$CACHE_DIR" \
        "bootstrap/cache/"
}

# ------------------------------------------------------------------------------
# LARAVEL LOG
# ------------------------------------------------------------------------------

check_laravel_log() {

    section "LARAVEL LOG"

    if [[ ! -f "$LOG_FILE" ]]; then

        warn "laravel.log does not exist."

        info "Testing whether www-data can create it..."

        if sudo -u "$WEB_USER" touch "$LOG_FILE" 2>/dev/null; then
            ok "www-data can create laravel.log"
            rm -f "$LOG_FILE"
        else
            error "www-data cannot create laravel.log"
            REQUIRED_PROBLEM=1
        fi

        return
    fi

    echo
    echo "File: $LOG_FILE"
    echo "  Permissions: $(stat -c '%A' "$LOG_FILE")"
    echo "  Owner:       $(stat -c '%U' "$LOG_FILE")"
    echo "  Group:       $(stat -c '%G' "$LOG_FILE")"

    echo
    info "Testing append access as www-data..."

    if sudo -u "$WEB_USER" sh -c "printf '%s\n' 'permission-test' >> '$LOG_FILE'" \
        2>/dev/null; then

        ok "Laravel log append test PASSED"

    else

        error "Laravel log append test FAILED"
        REQUIRED_PROBLEM=1
    fi
}

# ------------------------------------------------------------------------------
# DIRECTORY TRAVERSAL
# ------------------------------------------------------------------------------

check_traversal() {

    section "DIRECTORY TRAVERSAL"

    local current="/"
    local relative

    IFS='/' read -ra parts <<< "${PROJECT_DIR#/}"

    for part in "${parts[@]}"; do

        [[ -n "$part" ]] || continue

        current="$current$part"

        if sudo -u "$WEB_USER" test -x "$current" 2>/dev/null; then
            ok "www-data can access: $current"
        else
            error "www-data CANNOT access: $current"
            REQUIRED_PROBLEM=1
        fi

        current="$current/"
    done
}

# ------------------------------------------------------------------------------
# PATH PERMISSIONS
# ------------------------------------------------------------------------------

show_namei() {

    section "PATH PERMISSIONS (namei)"

    if command -v namei >/dev/null 2>&1; then
        namei -l "$LOG_FILE" 2>/dev/null || true
    else
        warn "namei is not installed."
    fi
}

# ------------------------------------------------------------------------------
# NON-REQUIRED PERMISSIONS
# ------------------------------------------------------------------------------

check_non_required_permissions() {

    subsection "Non-required write permissions"

    if sudo -u "$WEB_USER" test -w "$PROJECT_DIR" 2>/dev/null; then
        ok "Project root is writable by www-data"
    else
        info "Project root is NOT writable by www-data"
        info "This is normally NOT required by Laravel."
    fi

    if sudo -u "$WEB_USER" test -w "$PROJECT_DIR/bootstrap" 2>/dev/null; then
        ok "bootstrap/ is writable by www-data"
    else
        info "bootstrap/ is NOT writable by www-data"
        info "This is normally NOT required by Laravel."
    fi

    info "Laravel requires bootstrap/cache/ to be writable."
}

# ------------------------------------------------------------------------------
# FIX PERMISSIONS
# ------------------------------------------------------------------------------

fix_permissions() {

    section "PERMISSION REPAIR"

    info "Applying Laravel-safe permissions..."

    # --------------------------------------------------------------------------
    # Project ownership
    # --------------------------------------------------------------------------

    if [[ -d "$PROJECT_DIR" ]]; then
        chown "$SUDO_USER:$WEB_GROUP" "$PROJECT_DIR" 2>/dev/null || \
            chown "$(stat -c '%U' "$PROJECT_DIR"):$WEB_GROUP" "$PROJECT_DIR"
    fi

    # --------------------------------------------------------------------------
    # Make sure required directories exist
    # --------------------------------------------------------------------------

    mkdir -p "$STORAGE_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$CACHE_DIR"

    # --------------------------------------------------------------------------
    # Set group ownership
    # --------------------------------------------------------------------------

    chown -R :"$WEB_GROUP" "$STORAGE_DIR"
    chown -R :"$WEB_GROUP" "$CACHE_DIR"

    # --------------------------------------------------------------------------
    # Directory permissions
    # --------------------------------------------------------------------------

    find "$STORAGE_DIR" -type d -exec chmod 775 {} \;
    find "$CACHE_DIR" -type d -exec chmod 775 {} \;

    # --------------------------------------------------------------------------
    # File permissions
    # --------------------------------------------------------------------------

    find "$STORAGE_DIR" -type f -exec chmod 664 {} \;
    find "$CACHE_DIR" -type f -exec chmod 664 {} \;

    # --------------------------------------------------------------------------
    # Laravel log
    # --------------------------------------------------------------------------

    if [[ -f "$LOG_FILE" ]]; then
        chown :"$WEB_GROUP" "$LOG_FILE"
        chmod 664 "$LOG_FILE"
    fi

    # --------------------------------------------------------------------------
    # Ensure current user keeps access
    # --------------------------------------------------------------------------

    if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then

        usermod -aG "$WEB_GROUP" "$SUDO_USER" 2>/dev/null || true

        info "User $SUDO_USER remains the project owner."
        info "Added $SUDO_USER to group $WEB_GROUP if necessary."
    fi

    FIXED_SOMETHING=1

    ok "Laravel permission repair completed."
}

# ------------------------------------------------------------------------------
# ASK TO FIX
# ------------------------------------------------------------------------------

offer_fix() {

    if [[ "$REQUIRED_PROBLEM" -eq 0 ]]; then
        return
    fi

    section "PERMISSION PROBLEMS DETECTED"

    warn "One or more REQUIRED Laravel permission tests failed."
    echo
    echo "Laravel normally requires www-data to be able to write to:"
    echo
    echo "  storage/"
    echo "  storage/logs/"
    echo "  bootstrap/cache/"
    echo
    echo "The project root and bootstrap/ itself do NOT need to be writable"
    echo "by www-data."
    echo

    read -rp "Fix detected Laravel permission problems now? [Y/n]: " answer
    answer="${answer:-Y}"

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        fix_permissions
    else
        warn "No changes were made."
    fi
}

# ------------------------------------------------------------------------------
# FINAL TEST
# ------------------------------------------------------------------------------

reset_problem_status() {
    REQUIRED_PROBLEM=0
}

run_required_tests_again() {

    reset_problem_status

    check_laravel_project
    check_directories
    check_laravel_log
    check_traversal
}

# ------------------------------------------------------------------------------
# FINAL CONCLUSION
# ------------------------------------------------------------------------------

final_conclusion() {

    section "FINAL CONCLUSION"

    echo
    echo "Project:"
    echo "  $PROJECT_DIR"

    echo
    echo "Web server:"
    echo "  $WEB_USER"

    echo
    echo "Required Laravel writable directories:"
    echo "  storage/"
    echo "  storage/logs/"
    echo "  bootstrap/cache/"

    echo

    if [[ "$REQUIRED_PROBLEM" -eq 0 ]]; then

        echo -e "${GREEN}============================================================${NC}"
        echo -e "${GREEN} NO LARAVEL PERMISSION ERROR DETECTED${NC}"
        echo -e "${GREEN}============================================================${NC}"

        echo
        ok "www-data can access the Laravel project path."
        ok "www-data can write to storage/."
        ok "www-data can write to storage/logs/."
        ok "www-data can write to bootstrap/cache/."
        ok "Laravel log append test passed."

        echo
        info "Project root does not need to be writable by www-data."
        info "bootstrap/ does not need to be writable by www-data."

        if [[ "$FIXED_SOMETHING" -eq 1 ]]; then
            echo
            ok "Permission repair was applied successfully."
            ok "All required tests pass after repair."
        fi

    else

        echo -e "${RED}============================================================${NC}"
        echo -e "${RED} LARAVEL PERMISSION PROBLEM REMAINS${NC}"
        echo -e "${RED}============================================================${NC}"

        echo
        error "One or more required permission tests are still failing."

        echo
        echo "Review the errors above."
        echo "The problem is specifically related to Laravel's required"
        echo "www-data access."
    fi

    echo
    info "Diagnostic completed."
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main() {

    check_root

    ask_project_directory

    section "LARAVEL PERMISSION DIAGNOSTIC"

    echo
    echo "Project: $PROJECT_DIR"

    check_laravel_project
    check_web_user
    check_project_ownership
    check_directories
    check_laravel_log
    check_non_required_permissions
    check_traversal
    show_namei

    offer_fix

    if [[ "$FIXED_SOMETHING" -eq 1 ]]; then

        section "VERIFYING REPAIR"

        info "Running all required permission tests again..."

        run_required_tests_again
    fi

    final_conclusion
}

main "$@"