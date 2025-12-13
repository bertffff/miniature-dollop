#!/bin/bash
# =============================================================================
# Module: core.sh
# Description: Core utilities, logging, error handling, and enhanced rollback
# Version: 2.0.0 - Enhanced with priority-based rollback system
# =============================================================================

set -o pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================
export SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MODULES_DIR="${SCRIPT_DIR}/modules"
export TEMPLATES_DIR="${SCRIPT_DIR}/templates"
export CONFIG_FILE="${SCRIPT_DIR}/config.env"
export LOG_FILE="${LOG_FILE:-/var/log/marzban-installer.log}"
export BACKUP_DIR="${SCRIPT_DIR}/backups/$(date +%Y%m%d_%H%M%S)"

# Installation paths
export MARZBAN_DIR="${MARZBAN_DIR:-/opt/marzban}"
export MARZBAN_DATA_DIR="${MARZBAN_DATA_DIR:-/var/lib/marzban}"
export NGINX_CONF_DIR="/etc/nginx"
export FAKE_SITE_DIR="/var/www/html"
export ADGUARD_DIR="${ADGUARD_DIR:-/opt/marzban/adguard}"

# Marker files
export REBOOT_MARKER="/tmp/.marzban_reboot_required"
export INSTALL_STATE_FILE="/tmp/.marzban_install_state"

# =============================================================================
# COLORS
# =============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# =============================================================================
# LOGGING
# =============================================================================
declare -g LOG_LEVEL="${LOG_LEVEL:-1}"
declare -g DEBUG_MODE="${DEBUG_MODE:-false}"

# =============================================================================
# ENHANCED ROLLBACK SYSTEM
# Priority: CRITICAL > NORMAL > CLEANUP
# =============================================================================
declare -ga CRITICAL_ROLLBACK=()
declare -ga NORMAL_ROLLBACK=()
declare -ga CLEANUP_ROLLBACK=()
declare -ga CREATED_FILES=()
declare -ga STARTED_SERVICES=()
declare -ga BACKUP_FILES=()
declare -g ROLLBACK_IN_PROGRESS="${ROLLBACK_IN_PROGRESS:-false}"
declare -g CURRENT_INSTALL_PHASE=""

# =============================================================================
# BANNER
# =============================================================================
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔══════════════════════════════════════════════════════════════════╗
    ║   ███╗   ███╗ █████╗ ██████╗ ███████╗██████╗  █████╗ ███╗   ██╗  ║
    ║   ████╗ ████║██╔══██╗██╔══██╗╚══███╔╝██╔══██╗██╔══██╗████╗  ██║  ║
    ║   ██╔████╔██║███████║██████╔╝  ███╔╝ ██████╔╝███████║██╔██╗ ██║  ║
    ║   ██║╚██╔╝██║██╔══██║██╔══██╗ ███╔╝  ██╔══██╗██╔══██║██║╚██╗██║  ║
    ║   ██║ ╚═╝ ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║██║ ╚████║  ║
    ║   ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝  ║
    ║              Ultimate VPN Installer v2.0.0                       ║
    ║      VLESS/Reality + Marzban + WARP + AdGuard Edition            ║
    ╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
_log() {
    local level="$1" color="$2" prefix="$3"
    shift 3
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${color}[${prefix}]${NC} ${timestamp} - ${message}"
    
    if [[ -n "${LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
        echo "[${prefix}] ${timestamp} - ${message}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

log_debug() { [[ "${DEBUG_MODE}" == "true" ]] && _log 0 "${CYAN}" "DEBUG" "$*"; return 0; }
log_info() { [[ "${LOG_LEVEL:-1}" -le 1 ]] && _log 1 "${BLUE}" "INFO" "$*"; return 0; }
log_success() { [[ "${LOG_LEVEL:-1}" -le 1 ]] && _log 1 "${GREEN}" "✓" "$*"; return 0; }
log_warn() { [[ "${LOG_LEVEL:-1}" -le 2 ]] && _log 2 "${YELLOW}" "WARNING" "$*"; return 0; }
log_error() { _log 3 "${RED}" "ERROR" "$*" >&2; return 0; }

log_step() {
    echo ""
    echo -e "${BOLD}${GREEN}▶ $*${NC}"
    echo ""
    CURRENT_INSTALL_PHASE="$*"
}

log_input() { echo -e "${CYAN}${BOLD}$1${NC}"; }

# =============================================================================
# ROLLBACK REGISTRATION
# =============================================================================
register_rollback() {
    local description="$1"
    local command="${2:-$1}"
    local priority="${3:-normal}"
    
    [[ -z "$description" ]] && return 1
    
    local entry="${description}|||${command}"
    
    case "$priority" in
        critical) CRITICAL_ROLLBACK+=("$entry"); log_debug "CRITICAL rollback: ${description}" ;;
        cleanup)  CLEANUP_ROLLBACK+=("$entry"); log_debug "CLEANUP rollback: ${description}" ;;
        *)        NORMAL_ROLLBACK+=("$entry"); log_debug "NORMAL rollback: ${description}" ;;
    esac
}

register_file() {
    local filepath="$1"
    [[ -z "$filepath" ]] && return 1
    for f in "${CREATED_FILES[@]:-}"; do [[ "$f" == "$filepath" ]] && return 0; done
    CREATED_FILES+=("$filepath")
}

register_service() {
    local service="$1"
    [[ -z "$service" ]] && return 1
    STARTED_SERVICES+=("$service")
}

# =============================================================================
# ERROR HANDLER
# =============================================================================
error_handler() {
    local exit_code=$?
    local line_no="${1:-unknown}"
    local func_name="${FUNCNAME[1]:-main}"
    
    [[ $exit_code -eq 0 ]] && return 0
    
    log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_error "Error during: ${CURRENT_INSTALL_PHASE:-unknown phase}"
    log_error "Function: ${func_name}() at line ${line_no}"
    log_error "Exit code: ${exit_code}"
    log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    echo ""
    log_warn "Installation failed. Would you like to rollback changes?"
    
    if confirm "Execute rollback?" "y"; then
        execute_rollback
    fi
    
    exit "$exit_code"
}

# =============================================================================
# EXECUTE ROLLBACK
# =============================================================================
execute_rollback() {
    [[ "${ROLLBACK_IN_PROGRESS}" == "true" ]] && return 0
    ROLLBACK_IN_PROGRESS="true"
    
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗"
    echo "║                   ROLLBACK IN PROGRESS                         ║"
    echo -e "╚════════════════════════════════════════════════════════════════╝${NC}"
    
    process_rollback_stack() {
        local stack_name=$1
        shift
        local -a stack=("$@")
        for (( i=${#stack[@]}-1; i>=0; i-- )); do
            if [[ -n "${stack[$i]:-}" ]]; then
                local description="${stack[$i]%%|||*}"
                local command="${stack[$i]##*|||}"
                log_info "[${stack_name}] Rolling back: ${description}"
                timeout 60 bash -c "$command" 2>/dev/null || log_warn "Rollback failed: ${description}"
            fi
        done
    }

    # Stop services
    for service in "${STARTED_SERVICES[@]:-}"; do
        [[ -n "$service" ]] && systemctl stop "$service" 2>/dev/null || true
    done
    
    # Stop Docker
    if command -v docker &>/dev/null; then
        [[ -d "${MARZBAN_DIR}" ]] && (cd "${MARZBAN_DIR}" && docker compose down 2>/dev/null) || true
        [[ -d "${ADGUARD_DIR}" ]] && (cd "${ADGUARD_DIR}" && docker compose down 2>/dev/null) || true
    fi
    
    # Execute rollbacks by priority
    [[ ${#CRITICAL_ROLLBACK[@]} -gt 0 ]] && process_rollback_stack "CRITICAL" "${CRITICAL_ROLLBACK[@]}"
    [[ ${#NORMAL_ROLLBACK[@]} -gt 0 ]] && process_rollback_stack "NORMAL" "${NORMAL_ROLLBACK[@]}"
    [[ ${#CLEANUP_ROLLBACK[@]} -gt 0 ]] && process_rollback_stack "CLEANUP" "${CLEANUP_ROLLBACK[@]}"
    
    # Remove created files
    for filepath in "${CREATED_FILES[@]:-}"; do
        [[ -n "$filepath" && -e "$filepath" ]] && rm -rf "$filepath" 2>/dev/null || true
    done
    
    # Restore backups
    for backup in "${BACKUP_FILES[@]:-}"; do
        if [[ -n "$backup" && -f "$backup" ]]; then
            local original="${backup%.backup.*}"
            [[ -n "$original" ]] && mv "$backup" "$original" 2>/dev/null || true
        fi
    done
    
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗"
    echo "║                   ROLLBACK COMPLETED                           ║"
    echo -e "╚════════════════════════════════════════════════════════════════╝${NC}"
    
    ROLLBACK_IN_PROGRESS="false"
}

setup_error_trap() { set -eE; trap 'error_handler ${LINENO}' ERR; }
disable_error_trap() { set +eE; trap - ERR; }

# =============================================================================
# SYSTEM CHECKS
# =============================================================================
check_root() {
    [[ $EUID -ne 0 ]] && { log_error "Run as root (use sudo)"; exit 1; }
}

check_os() {
    [[ ! -f /etc/os-release ]] && { log_error "Cannot detect OS"; exit 1; }
    source /etc/os-release
    
    case "${ID}" in
        ubuntu) [[ "${VERSION_ID%%.*}" -lt 20 ]] && { log_error "Ubuntu 20.04+ required"; exit 1; } ;;
        debian) [[ "${VERSION_ID%%.*}" -lt 11 ]] && { log_error "Debian 11+ required"; exit 1; } ;;
        *) log_warn "OS '${ID}' not officially supported" ;;
    esac
    
    log_success "OS: ${ID} ${VERSION_ID}"
    export OS_NAME="${ID}" OS_VERSION="${VERSION_ID}"
}

check_architecture() {
    local arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64) export ARCH="amd64" ARCH_FULL="x86_64" ;;
        aarch64|arm64) export ARCH="arm64" ARCH_FULL="aarch64" ;;
        *) log_error "Unsupported architecture: ${arch}"; exit 1 ;;
    esac
    log_success "Architecture: ${arch}"
}

check_memory() {
    local min_mb="${1:-512}"
    local total_mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    [[ "${total_mem}" -lt "${min_mb}" ]] && { log_error "Memory: ${total_mem}MB < ${min_mb}MB"; exit 1; }
    log_success "Memory: ${total_mem}MB"
    export TOTAL_MEMORY="${total_mem}"
}

check_disk_space() {
    local min_gb="${1:-5}"
    local avail=$(df -BG / | awk 'NR==2 {print int($4)}')
    [[ "${avail}" -lt "${min_gb}" ]] && { log_error "Disk: ${avail}GB < ${min_gb}GB"; exit 1; }
    log_success "Disk: ${avail}GB available"
}

# =============================================================================
# PACKAGE MANAGEMENT
# =============================================================================
update_package_cache() { log_info "Updating packages..."; apt-get update -qq; }

install_packages() {
    log_info "Installing: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" || { log_error "Install failed"; return 1; }
    log_success "Packages installed"
}

is_package_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }

# =============================================================================
# UTILITIES
# =============================================================================
generate_password() {
    local length="${1:-16}"
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${length}"
}

generate_uuid() { cat /proc/sys/kernel/random/uuid; }
generate_hex() { openssl rand -hex "${1:-8}"; }
generate_short_id() { openssl rand -hex 4; }

validate_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; }
validate_email() { [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }
validate_ip() { [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]; }

get_public_ip() {
    local services=("https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com")
    for svc in "${services[@]}"; do
        local ip=$(curl -4sf --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        validate_ip "$ip" && { echo "$ip"; return 0; }
    done
    return 1
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "${BACKUP_DIR}"
        local backup="${BACKUP_DIR}/$(basename "$file").bak.$(date +%s)"
        cp "$file" "$backup"
        BACKUP_FILES+=("$backup")
        log_debug "Backed up: $file"
    fi
}

process_template() {
    local template="$1" output="$2"
    [[ ! -f "$template" ]] && { log_error "Template not found: $template"; return 1; }
    envsubst < "$template" > "$output"
}

validate_json() {
    command -v jq &>/dev/null || return 0
    jq empty "$1" 2>/dev/null
}

wait_for_service() {
    local service="$1" max="${2:-30}" i=1
    while [[ $i -le $max ]]; do
        systemctl is-active --quiet "$service" && return 0
        sleep 1; ((i++))
    done
    return 1
}

wait_for_port() {
    local port="$1" host="${2:-127.0.0.1}" max="${3:-30}" i=1
    while [[ $i -le $max ]]; do
        nc -z "$host" "$port" 2>/dev/null && return 0
        sleep 1; ((i++))
    done
    return 1
}

check_port_listening() { ss -tlnp 2>/dev/null | grep -q ":$1 "; }

confirm() {
    local message="${1:-Continue?}" default="${2:-n}"
    [[ "${NON_INTERACTIVE:-false}" == "true" ]] && { [[ "${default,,}" == "y" ]]; return $?; }
    [[ "${default,,}" == "y" ]] && log_input "$message [Y/n]: " || log_input "$message [y/N]: "
    read -r response
    response="${response:-$default}"
    [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

# State management
save_install_state() { echo "$1" > "${INSTALL_STATE_FILE}"; }
get_install_state() { [[ -f "${INSTALL_STATE_FILE}" ]] && cat "${INSTALL_STATE_FILE}" || echo ""; }
clear_install_state() { rm -f "${INSTALL_STATE_FILE}"; }
is_reboot_required() { [[ -f "${REBOOT_MARKER}" ]]; }
set_reboot_required() { touch "${REBOOT_MARKER}"; log_warn "Reboot required"; }
clear_reboot_marker() { rm -f "${REBOOT_MARKER}"; }

# Init
init_core() {
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || true
}

init_core
export CORE_LOADED="true"
