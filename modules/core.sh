#!/bin/bash
# =============================================================================
# Module: core.sh
# Description: Core utilities, logging, error handling, and global functions
# =============================================================================

# Strict mode
set -euo pipefail

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MODULES_DIR="${SCRIPT_DIR}/modules"
export TEMPLATES_DIR="${SCRIPT_DIR}/templates"
export CONFIG_FILE="${SCRIPT_DIR}/config.env"
export LOG_FILE="${SCRIPT_DIR}/install.log"
export BACKUP_DIR="${SCRIPT_DIR}/backups/$(date +%Y%m%d_%H%M%S)"

# Installation paths
export MARZBAN_DIR="/opt/marzban"
export MARZBAN_DATA_DIR="/var/lib/marzban"
export NGINX_CONF_DIR="/etc/nginx"
export FAKE_SITE_DIR="/var/www/html"

# State tracking for rollback
declare -a ROLLBACK_ACTIONS=()

# =============================================================================
# COLOR DEFINITIONS
# =============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

# =============================================================================
# BANNER / LOGO
# =============================================================================
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔══════════════════════════════════════════════════════════════════╗
    ║                                                                  ║
    ║   ███╗   ███╗ █████╗ ██████╗ ███████╗██████╗  █████╗ ███╗   ██╗  ║
    ║   ████╗ ████║██╔══██╗██╔══██╗╚══███╔╝██╔══██╗██╔══██╗████╗  ██║  ║
    ║   ██╔████╔██║███████║██████╔╝  ███╔╝ ██████╔╝███████║██╔██╗ ██║  ║
    ║   ██║╚██╔╝██║██╔══██║██╔══██╗ ███╔╝  ██╔══██╗██╔══██║██║╚██╗██║  ║
    ║   ██║ ╚═╝ ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║██║ ╚████║  ║
    ║   ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝  ║
    ║                                                                  ║
    ║               Ultimate VPN Installer v1.0.0                      ║
    ║           VLESS/Reality + Marzban + WARP Edition                 ║
    ╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo ""
}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Console output
    echo -e "${color}[${level}]${NC} ${message}"
    
    # File output (strip color codes)
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

log_info() {
    _log "INFO" "${GREEN}" "$1"
}

log_warn() {
    _log "WARN" "${YELLOW}" "$1"
}

log_error() {
    _log "ERROR" "${RED}" "$1"
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        _log "DEBUG" "${MAGENTA}" "$1"
    fi
}

log_step() {
    echo -e "\n${BLUE}${BOLD}▶ $1${NC}\n"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP] $1" >> "${LOG_FILE}" 2>/dev/null || true
}

log_success() {
    _log "✓" "${GREEN}" "$1"
}

log_input() {
    echo -e "${CYAN}${BOLD}$1${NC}"
}

# Progress spinner
spinner() {
    local pid=$1
    local message="${2:-Processing...}"
    local delay=0.1
    local spinstr='|/-\'
    
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " ${CYAN}[%c]${NC} %s\r" "$spinstr" "$message"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "    \r"
}

# =============================================================================
# ERROR HANDLING & ROLLBACK
# =============================================================================
error_handler() {
    local line_no="$1"
    local error_code="${2:-1}"
    
    log_error "Error occurred in script at line ${line_no} (exit code: ${error_code})"
    log_error "Check ${LOG_FILE} for details"
    
    if [[ ${#ROLLBACK_ACTIONS[@]} -gt 0 ]]; then
        echo ""
        log_warn "Installation failed. Would you like to rollback changes?"
        log_input "Rollback? [y/N]: "
        read -r response
        if [[ "${response,,}" == "y" ]]; then
            perform_rollback
        fi
    fi
    
    exit "${error_code}"
}

register_rollback() {
    local action="$1"
    ROLLBACK_ACTIONS+=("${action}")
    log_debug "Registered rollback action: ${action}"
}

perform_rollback() {
    log_step "Performing rollback..."
    
    # Execute rollback actions in reverse order
    for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
        local action="${ROLLBACK_ACTIONS[i]}"
        log_info "Rollback: ${action}"
        eval "${action}" 2>/dev/null || log_warn "Rollback action failed: ${action}"
    done
    
    log_success "Rollback completed"
}

# =============================================================================
# SYSTEM CHECKS
# =============================================================================
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root!"
        log_info "Please run: sudo $0"
        exit 1
    fi
}

check_os() {
    local os_name=""
    local os_version=""
    
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        os_name="${ID}"
        os_version="${VERSION_ID}"
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
    
    case "${os_name}" in
        ubuntu)
            if [[ "${os_version%%.*}" -lt 20 ]]; then
                log_error "Ubuntu ${os_version} is not supported. Minimum: 20.04"
                exit 1
            fi
            ;;
        debian)
            if [[ "${os_version%%.*}" -lt 11 ]]; then
                log_error "Debian ${os_version} is not supported. Minimum: 11"
                exit 1
            fi
            ;;
        *)
            log_warn "OS '${os_name}' is not officially supported. Proceeding anyway..."
            ;;
    esac
    
    log_success "OS Check: ${os_name} ${os_version}"
    export OS_NAME="${os_name}"
    export OS_VERSION="${os_version}"
}

check_architecture() {
    local arch
    arch="$(uname -m)"
    
    case "${arch}" in
        x86_64|amd64)
            export ARCH="amd64"
            log_success "Architecture: ${arch} (amd64)"
            ;;
        aarch64|arm64)
            export ARCH="arm64"
            log_success "Architecture: ${arch} (arm64)"
            ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac
}

check_virtualization() {
    local virt_type="bare-metal"
    
    if command -v systemd-detect-virt &>/dev/null; then
        virt_type="$(systemd-detect-virt 2>/dev/null || echo 'none')"
    elif [[ -f /proc/1/cgroup ]]; then
        if grep -q docker /proc/1/cgroup 2>/dev/null; then
            virt_type="docker"
        elif grep -q lxc /proc/1/cgroup 2>/dev/null; then
            virt_type="lxc"
        fi
    fi
    
    log_info "Virtualization: ${virt_type}"
    
    if [[ "${virt_type}" == "openvz" ]]; then
        log_warn "OpenVZ detected. Some features may not work correctly."
    fi
    
    export VIRT_TYPE="${virt_type}"
}

check_memory() {
    local total_mem
    total_mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    
    if [[ "${total_mem}" -lt 512 ]]; then
        log_error "Insufficient memory: ${total_mem}MB. Minimum required: 512MB"
        exit 1
    elif [[ "${total_mem}" -lt 1024 ]]; then
        log_warn "Low memory detected: ${total_mem}MB. Recommended: 1024MB+"
    else
        log_success "Memory: ${total_mem}MB"
    fi
    
    export TOTAL_MEMORY="${total_mem}"
}

check_disk_space() {
    local available_space
    available_space=$(df -BG / | awk 'NR==2 {print int($4)}')
    
    if [[ "${available_space}" -lt 5 ]]; then
        log_error "Insufficient disk space: ${available_space}GB. Minimum required: 5GB"
        exit 1
    elif [[ "${available_space}" -lt 10 ]]; then
        log_warn "Low disk space: ${available_space}GB. Recommended: 10GB+"
    else
        log_success "Disk Space: ${available_space}GB available"
    fi
}

# =============================================================================
# PACKAGE MANAGEMENT
# =============================================================================
update_package_cache() {
    log_info "Updating package cache..."
    apt-get update -qq
}

install_packages() {
    local packages=("$@")
    
    log_info "Installing packages: ${packages[*]}"
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" \
        || { log_error "Failed to install packages"; return 1; }
    
    log_success "Packages installed successfully"
}

is_package_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
generate_password() {
    local length="${1:-16}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "${length}"
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

generate_hex() {
    local length="${1:-8}"
    openssl rand -hex "${length}"
}

generate_shortid() {
    # Generate random hex string for Xray shortId (1-16 chars, even number)
    local length="${1:-8}"
    openssl rand -hex $((length / 2))
}

validate_domain() {
    local domain="$1"
    if [[ "${domain}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    return 1
}

validate_email() {
    local email="$1"
    if [[ "${email}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

validate_ip() {
    local ip="$1"
    if [[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

validate_port() {
    local port="$1"
    if [[ "${port}" =~ ^[0-9]+$ ]] && [[ "${port}" -ge 1 ]] && [[ "${port}" -le 65535 ]]; then
        return 0
    fi
    return 1
}

get_public_ip() {
    local ip=""
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ipecho.net/plain"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -s --max-time 5 "${service}" 2>/dev/null || true)
        if validate_ip "${ip}"; then
            echo "${ip}"
            return 0
        fi
    done
    
    log_error "Failed to detect public IP address"
    return 1
}

backup_file() {
    local file="$1"
    
    if [[ -f "${file}" ]]; then
        mkdir -p "${BACKUP_DIR}"
        cp "${file}" "${BACKUP_DIR}/$(basename "${file}").bak"
        log_debug "Backed up: ${file}"
    fi
}

# Template processing with envsubst
process_template() {
    local template="$1"
    local output="$2"
    
    if [[ ! -f "${template}" ]]; then
        log_error "Template not found: ${template}"
        return 1
    fi
    
    # Export all variables for envsubst
    envsubst < "${template}" > "${output}"
    log_debug "Processed template: ${template} -> ${output}"
}

# JSON validation
validate_json() {
    local file="$1"
    
    if ! command -v jq &>/dev/null; then
        log_warn "jq not installed, skipping JSON validation"
        return 0
    fi
    
    if jq empty "${file}" 2>/dev/null; then
        log_debug "JSON valid: ${file}"
        return 0
    else
        log_error "Invalid JSON: ${file}"
        return 1
    fi
}

# Wait for service to be ready
wait_for_service() {
    local service="$1"
    local max_attempts="${2:-30}"
    local attempt=1
    
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if systemctl is-active --quiet "${service}"; then
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    
    return 1
}

# Wait for port to be available
wait_for_port() {
    local port="$1"
    local host="${2:-127.0.0.1}"
    local max_attempts="${3:-30}"
    local attempt=1
    
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if nc -z "${host}" "${port}" 2>/dev/null; then
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    
    return 1
}

# Confirm action
confirm() {
    local message="${1:-Continue?}"
    local default="${2:-n}"
    
    if [[ "${default,,}" == "y" ]]; then
        log_input "${message} [Y/n]: "
    else
        log_input "${message} [y/N]: "
    fi
    
    read -r response
    response="${response:-${default}}"
    
    [[ "${response,,}" == "y" ]]
}

# =============================================================================
# INITIALIZATION
# =============================================================================
init_core() {
    # Create log file
    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}"
    
    # Set up error handler
    trap 'error_handler $LINENO $?' ERR
    
    log_debug "Core module initialized"
}

# Auto-initialize when sourced
init_core
