#!/bin/bash
#
# Module: core.sh
# Purpose: Core functions - logging, error handling, rollback system, validations
# Dependencies: None (this is the base module)
#

# Strict mode
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

readonly INSTALLER_VERSION="2.0.0"
readonly INSTALLER_NAME="Marzban Ultimate Installer"

# Paths
readonly INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MODULES_DIR="${INSTALLER_DIR}/modules"
readonly TEMPLATES_DIR="${INSTALLER_DIR}/templates"
readonly TOOLS_DIR="${INSTALLER_DIR}/tools"
readonly DATA_DIR="${INSTALLER_DIR}/data"
readonly KEYS_DIR="${DATA_DIR}/keys"
readonly BACKUPS_DIR="${DATA_DIR}/backups"

# Marzban paths
readonly MARZBAN_DIR="/opt/marzban"
readonly MARZBAN_DATA_DIR="/var/lib/marzban"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'  # No Color

# ═══════════════════════════════════════════════════════════════════════════════
# LOGGING FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

log_input() {
    echo -en "${CYAN}[INPUT]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_step() {
    echo -e "\n${BOLD}${BLUE}▶${NC} ${BOLD}$*${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════════════════════

show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║                                                                   ║
    ║   ███╗   ███╗ █████╗ ██████╗ ███████╗██████╗  █████╗ ███╗   ██╗  ║
    ║   ████╗ ████║██╔══██╗██╔══██╗╚══███╔╝██╔══██╗██╔══██╗████╗  ██║  ║
    ║   ██╔████╔██║███████║██████╔╝  ███╔╝ ██████╔╝███████║██╔██╗ ██║  ║
    ║   ██║╚██╔╝██║██╔══██║██╔══██╗ ███╔╝  ██╔══██╗██╔══██║██║╚██╗██║  ║
    ║   ██║ ╚═╝ ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║██║ ╚████║  ║
    ║   ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝  ║
    ║                                                                   ║
    ║                    ULTIMATE VPN INSTALLER v2.0                    ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "    ${YELLOW}Stealth VPN Solution for Hostile Network Environments${NC}"
    echo -e "    ${BLUE}────────────────────────────────────────────────────${NC}"
    echo
}

# ═══════════════════════════════════════════════════════════════════════════════
# ROLLBACK SYSTEM (Three-tier priority)
# ═══════════════════════════════════════════════════════════════════════════════

# Rollback stacks
declare -a CRITICAL_ROLLBACK=()   # SSH, Firewall (executed last, most important)
declare -a NORMAL_ROLLBACK=()     # Configs, containers
declare -a CLEANUP_ROLLBACK=()    # Temporary files (executed first)

# Current installation phase
CURRENT_PHASE=""

register_rollback() {
    local command="${1}"
    local priority="${2:-normal}"
    
    case "${priority}" in
        critical)
            CRITICAL_ROLLBACK+=("${command}")
            ;;
        normal)
            NORMAL_ROLLBACK+=("${command}")
            ;;
        cleanup)
            CLEANUP_ROLLBACK+=("${command}")
            ;;
        *)
            log_warn "Unknown rollback priority: ${priority}, using normal"
            NORMAL_ROLLBACK+=("${command}")
            ;;
    esac
    
    log_debug "Registered rollback [${priority}]: ${command}"
}

execute_rollback() {
    local exit_code="${1:-1}"
    
    log_error "Installation failed at phase: ${CURRENT_PHASE:-unknown}"
    log_warn "Executing rollback..."
    
    # 1. Cleanup (temp files, downloads)
    if [[ ${#CLEANUP_ROLLBACK[@]} -gt 0 ]]; then
        log_info "Phase 1: Cleanup..."
        for ((i=${#CLEANUP_ROLLBACK[@]}-1; i>=0; i--)); do
            log_debug "Cleanup: ${CLEANUP_ROLLBACK[i]}"
            eval "${CLEANUP_ROLLBACK[i]}" 2>/dev/null || true
        done
    fi
    
    # 2. Normal (configs, services)
    if [[ ${#NORMAL_ROLLBACK[@]} -gt 0 ]]; then
        log_info "Phase 2: Reverting configurations..."
        for ((i=${#NORMAL_ROLLBACK[@]}-1; i>=0; i--)); do
            log_debug "Normal: ${NORMAL_ROLLBACK[i]}"
            eval "${NORMAL_ROLLBACK[i]}" 2>/dev/null || true
        done
    fi
    
    # 3. Critical (restore access)
    if [[ ${#CRITICAL_ROLLBACK[@]} -gt 0 ]]; then
        log_info "Phase 3: Restoring critical services..."
        for ((i=${#CRITICAL_ROLLBACK[@]}-1; i>=0; i--)); do
            log_warn "Critical: ${CRITICAL_ROLLBACK[i]}"
            eval "${CRITICAL_ROLLBACK[i]}" 2>/dev/null || true
        done
    fi
    
    log_info "Rollback completed"
    exit "${exit_code}"
}

# Error handler with context
error_handler() {
    local line_number="${1}"
    local error_code="${2:-1}"
    local command="${3:-unknown}"
    
    echo
    log_error "═══════════════════════════════════════════════════════"
    log_error "FATAL ERROR"
    log_error "═══════════════════════════════════════════════════════"
    log_error "Line:    ${line_number}"
    log_error "Command: ${command}"
    log_error "Exit:    ${error_code}"
    log_error "Phase:   ${CURRENT_PHASE:-unknown}"
    log_error "═══════════════════════════════════════════════════════"
    
    # Check if any rollback actions registered
    local total_rollback=$((${#CRITICAL_ROLLBACK[@]} + ${#NORMAL_ROLLBACK[@]} + ${#CLEANUP_ROLLBACK[@]}))
    
    if [[ ${total_rollback} -gt 0 ]]; then
        echo
        read -p "Do you want to rollback changes? [Y/n] " -n 1 -r
        echo
        
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            execute_rollback "${error_code}"
        else
            log_warn "Rollback skipped. System may be in inconsistent state."
            exit "${error_code}"
        fi
    else
        exit "${error_code}"
    fi
}

# Set error trap
set_error_trap() {
    trap 'error_handler ${LINENO} $? "${BASH_COMMAND}"' ERR
}

# Disable error trap temporarily
disable_error_trap() {
    trap - ERR
}

# Phase management
set_phase() {
    CURRENT_PHASE="${1}"
    log_step "${CURRENT_PHASE}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        log_info "Please run: sudo $0"
        exit 1
    fi
}

check_os() {
    local os_id=""
    local os_version=""
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        os_id="${ID}"
        os_version="${VERSION_ID}"
    else
        log_error "Cannot determine OS version"
        exit 1
    fi
    
    case "${os_id}" in
        ubuntu)
            if [[ "${os_version%%.*}" -lt 22 ]]; then
                log_error "Ubuntu 22.04 or higher is required (found: ${os_version})"
                exit 1
            fi
            ;;
        debian)
            if [[ "${os_version%%.*}" -lt 11 ]]; then
                log_error "Debian 11 or higher is required (found: ${os_version})"
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported OS: ${os_id}"
            log_info "Supported: Ubuntu 22.04+, Debian 11+"
            exit 1
            ;;
    esac
    
    log_info "Operating System: ${os_id} ${os_version} ✓"
    
    export OS_ID="${os_id}"
    export OS_VERSION="${os_version}"
}

check_architecture() {
    local arch
    arch=$(uname -m)
    
    if [[ "${arch}" != "x86_64" ]]; then
        log_error "Only x86_64 (amd64) architecture is supported"
        log_error "Detected: ${arch}"
        exit 1
    fi
    
    log_info "Architecture: ${arch} ✓"
}

check_virtualization() {
    local virt_type=""
    
    if command -v systemd-detect-virt &> /dev/null; then
        virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    elif [[ -f /proc/cpuinfo ]]; then
        if grep -q "hypervisor" /proc/cpuinfo; then
            virt_type="vm"
        fi
    fi
    
    log_info "Virtualization: ${virt_type:-none}"
    
    # Warn about OpenVZ (limited kernel features)
    if [[ "${virt_type}" == "openvz" ]]; then
        log_warn "OpenVZ detected. Some features may not work properly."
    fi
    
    export VIRT_TYPE="${virt_type}"
}

check_resources() {
    # Memory check (minimum 512MB)
    local total_mem
    total_mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    
    if [[ ${total_mem} -lt 512 ]]; then
        log_warn "Low memory: ${total_mem}MB (recommended: 1024MB+)"
    else
        log_info "Memory: ${total_mem}MB ✓"
    fi
    
    # Disk space check (minimum 2GB free in /var)
    local free_space
    free_space=$(df -BM /var 2>/dev/null | awk 'NR==2 {gsub(/M/,""); print $4}')
    
    if [[ ${free_space} -lt 2048 ]]; then
        log_warn "Low disk space: ${free_space}MB free (recommended: 5GB+)"
    else
        log_info "Disk space: ${free_space}MB free ✓"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Install packages with retry logic
install_packages() {
    local packages=("$@")
    local max_retries=3
    local retry=0
    
    while [[ ${retry} -lt ${max_retries} ]]; do
        log_info "Installing: ${packages[*]}"
        
        if apt-get install -y "${packages[@]}" 2>/dev/null; then
            return 0
        fi
        
        ((retry++))
        log_warn "Installation failed, retry ${retry}/${max_retries}..."
        sleep 2
    done
    
    log_error "Failed to install packages after ${max_retries} attempts"
    return 1
}

# Validate JSON file
validate_json() {
    local file="$1"
    
    if [[ ! -f "${file}" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi
    
    if ! jq . "${file}" > /dev/null 2>&1; then
        log_error "Invalid JSON: ${file}"
        jq . "${file}" 2>&1 | head -5
        return 1
    fi
    
    return 0
}

# Validate YAML file
validate_yaml() {
    local file="$1"
    
    if [[ ! -f "${file}" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi
    
    # Use Python for YAML validation
    if command -v python3 &> /dev/null; then
        if ! python3 -c "import yaml; yaml.safe_load(open('${file}'))" 2>/dev/null; then
            log_error "Invalid YAML: ${file}"
            return 1
        fi
    fi
    
    return 0
}

# Generate random string
generate_random_string() {
    local length="${1:-32}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "${length}"
}

# Generate password
generate_password() {
    local length="${1:-16}"
    openssl rand -base64 "${length}" | tr -dc 'a-zA-Z0-9!@#$%' | head -c "${length}"
}

# Backup file
backup_file() {
    local file="$1"
    local backup_dir="${BACKUPS_DIR}/$(date +%Y%m%d_%H%M%S)"
    
    if [[ -f "${file}" ]]; then
        mkdir -p "${backup_dir}"
        cp -a "${file}" "${backup_dir}/"
        log_debug "Backed up: ${file} -> ${backup_dir}/"
    fi
}

# Wait for service with timeout
wait_for_service() {
    local service="$1"
    local port="$2"
    local timeout="${3:-60}"
    local elapsed=0
    
    log_info "Waiting for ${service} on port ${port}..."
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if nc -z 127.0.0.1 "${port}" 2>/dev/null; then
            log_info "${service} is ready"
            return 0
        fi
        sleep 2
        ((elapsed+=2))
    done
    
    log_error "${service} did not start within ${timeout} seconds"
    return 1
}

# Get public IP
get_public_ip() {
    local ip=""
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ipecho.net/plain"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -sf -m 5 "${service}" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "${ip}" ]] && [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip}"
            return 0
        fi
    done
    
    return 1
}

# Detect SSH port
detect_ssh_port() {
    local ssh_port
    
    # Try sshd config first
    if [[ -f /etc/ssh/sshd_config ]]; then
        ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    fi
    
    # Fall back to listening ports
    if [[ -z "${ssh_port}" ]]; then
        ssh_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
    fi
    
    echo "${ssh_port:-22}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

# Load configuration from file
load_config() {
    local config_file="${1:-${DATA_DIR}/config.env}"
    
    if [[ -f "${config_file}" ]]; then
        log_info "Loading configuration from: ${config_file}"
        set -a
        source "${config_file}"
        set +a
    fi
}

# Save configuration
save_config() {
    local config_file="${DATA_DIR}/config.env"
    
    mkdir -p "${DATA_DIR}"
    
    cat > "${config_file}" << EOF
# Marzban Ultimate Installer Configuration
# Generated: $(date -Iseconds)

# Deployment Mode
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-exit}"

# Domains
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
CDN_DOMAIN="${CDN_DOMAIN:-}"

# Admin
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

# Database
DATABASE_TYPE="${DATABASE_TYPE:-sqlite}"

# Kernel
INSTALL_XANMOD="${INSTALL_XANMOD:-false}"

# Profiles
PROFILE_STANDARD_ENABLED="${PROFILE_STANDARD_ENABLED:-true}"
PROFILE_WARP_ENABLED="${PROFILE_WARP_ENABLED:-false}"
PROFILE_WHITELIST_ENABLED="${PROFILE_WHITELIST_ENABLED:-false}"

# Optional Components
ADGUARD_ENABLED="${ADGUARD_ENABLED:-false}"
FAIL2BAN_ENABLED="${FAIL2BAN_ENABLED:-false}"

# Reality Settings
REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"
REALITY_PORT="${REALITY_PORT:-8443}"

# WebSocket Settings
WS_PORT="${WS_PORT:-8444}"
WS_PATH="${WS_PATH:-/vless-ws}"

# CDN
CDN_PROVIDER="${CDN_PROVIDER:-gcore}"

# Ports
MARZBAN_PORT="${MARZBAN_PORT:-8000}"
EOF
    
    chmod 600 "${config_file}"
    log_info "Configuration saved to: ${config_file}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# INTERACTIVE INPUT FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Ask yes/no question
ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer
    
    if [[ "${default}" == "y" ]]; then
        prompt="${prompt} [Y/n]"
    else
        prompt="${prompt} [y/N]"
    fi
    
    while true; do
        log_input "${prompt} "
        read -r answer
        
        answer="${answer:-${default}}"
        answer="${answer,,}"  # lowercase
        
        case "${answer}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) log_warn "Please answer y or n" ;;
        esac
    done
}

# Ask for input with default value
ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local value
    
    if [[ -n "${default}" ]]; then
        prompt="${prompt} [${default}]"
    fi
    
    log_input "${prompt}: "
    read -r value
    
    echo "${value:-${default}}"
}

# Ask for password (hidden input)
ask_password() {
    local prompt="$1"
    local password
    
    log_input "${prompt}: "
    read -rs password
    echo
    
    echo "${password}"
}

# Select from menu
select_option() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice
    
    echo
    log_info "${prompt}"
    echo
    
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[i]}"
    done
    
    echo
    while true; do
        log_input "Select option [1-${#options[@]}]: "
        read -r choice
        
        if [[ "${choice}" =~ ^[0-9]+$ ]] && \
           [[ "${choice}" -ge 1 ]] && \
           [[ "${choice}" -le "${#options[@]}" ]]; then
            echo "$((choice-1))"
            return 0
        fi
        
        log_warn "Invalid selection"
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

init_directories() {
    mkdir -p "${DATA_DIR}"
    mkdir -p "${KEYS_DIR}"
    mkdir -p "${BACKUPS_DIR}"
    
    # Secure keys directory
    chmod 700 "${KEYS_DIR}"
}

# Export functions for use in other modules
export -f log_info log_warn log_error log_debug log_input log_success log_step
export -f register_rollback execute_rollback set_phase
export -f check_root check_os check_architecture
export -f install_packages validate_json validate_yaml
export -f generate_random_string generate_password backup_file
export -f wait_for_service get_public_ip detect_ssh_port
export -f ask_yes_no ask_input ask_password select_option
