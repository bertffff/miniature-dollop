#!/bin/bash
#
# Module: system.sh
# Purpose: System preparation, dependencies, kernel tuning, XanMod, BBR
# Dependencies: core.sh
#

# Strict mode
set -euo pipefail

# Source core module
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/core.sh"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

readonly ESSENTIAL_PACKAGES=(
    curl
    wget
    jq
    openssl
    ca-certificates
    gnupg
    lsb-release
    software-properties-common
    apt-transport-https
    unzip
    tar
    netcat-openbsd
    nmap
    htop
    git
)

readonly OPTIONAL_PACKAGES=(
    tree
    ncdu
    iotop
)

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM UPDATE
# ═══════════════════════════════════════════════════════════════════════════════

system_update() {
    set_phase "System Update"
    
    log_info "Updating package lists..."
    apt-get update -y
    
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        if ask_yes_no "Run system upgrade? (May require reboot)" "n"; then
            log_info "Upgrading packages..."
            apt-get upgrade -y
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ESSENTIAL PACKAGES
# ═══════════════════════════════════════════════════════════════════════════════

install_essential_packages() {
    set_phase "Essential Packages"
    
    log_info "Installing essential packages..."
    install_packages "${ESSENTIAL_PACKAGES[@]}"
    
    log_success "Essential packages installed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# XANMOD KERNEL
# ═══════════════════════════════════════════════════════════════════════════════

check_cpu_compatibility() {
    log_info "Checking CPU compatibility for XanMod..."
    
    local temp_script
    temp_script=$(mktemp)
    
    # Download official checker
    if ! wget -qO "${temp_script}" https://dl.xanmod.org/check_x86-64_psabi.sh 2>/dev/null; then
        log_warn "Could not download CPU compatibility checker"
        rm -f "${temp_script}"
        echo "v1"
        return
    fi
    
    local check_result
    check_result=$(bash "${temp_script}" 2>&1 || true)
    rm -f "${temp_script}"
    
    # Parse result
    if echo "${check_result}" | grep -q "x86-64-v4"; then
        echo "v4"
    elif echo "${check_result}" | grep -q "x86-64-v3"; then
        echo "v3"
    elif echo "${check_result}" | grep -q "x86-64-v2"; then
        echo "v2"
    else
        echo "v1"
    fi
}

is_xanmod_installed() {
    uname -r | grep -q "xanmod"
}

install_xanmod_kernel() {
    set_phase "XanMod Kernel Installation"
    
    # Check if already installed
    if is_xanmod_installed; then
        log_info "XanMod kernel already active: $(uname -r)"
        return 0
    fi
    
    local cpu_level
    cpu_level=$(check_cpu_compatibility)
    
    log_info "CPU compatibility level: x86-64-${cpu_level}"
    
    if [[ "${cpu_level}" == "v1" ]]; then
        log_warn "CPU does not support optimized XanMod kernel"
        log_warn "Skipping kernel upgrade, using stock kernel"
        return 0
    fi
    
    log_info "Installing XanMod kernel (optimized for x86-64-${cpu_level})..."
    
    # 1. Import GPG key
    log_info "Importing XanMod GPG key..."
    wget -qO - https://dl.xanmod.org/archive.key | \
        gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
    
    register_rollback "rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg" "normal"
    
    # 2. Add repository
    log_info "Adding XanMod repository..."
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' \
        > /etc/apt/sources.list.d/xanmod-release.list
    
    register_rollback "rm -f /etc/apt/sources.list.d/xanmod-release.list" "normal"
    
    # 3. Update and install
    apt-get update
    
    local kernel_package
    case "${cpu_level}" in
        v4) kernel_package="linux-xanmod-x64v4" ;;
        v3) kernel_package="linux-xanmod-x64v3" ;;
        v2) kernel_package="linux-xanmod-x64v2" ;;
    esac
    
    log_info "Installing ${kernel_package}..."
    apt-get install -y "${kernel_package}"
    
    # 4. Mark reboot required
    touch "${DATA_DIR}/.reboot_required"
    echo "INSTALL_STATE=kernel_installed" > "${DATA_DIR}/.install_state"
    
    log_success "XanMod kernel installed"
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "REBOOT REQUIRED to activate new kernel"
    log_warn "After reboot, run: ./install.sh --resume"
    log_warn "═══════════════════════════════════════════════════════"
    
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        if ask_yes_no "Reboot now?" "y"; then
            reboot
        fi
    fi
    
    return 0
}

# Resume installation after reboot
resume_after_reboot() {
    if [[ -f "${DATA_DIR}/.install_state" ]]; then
        source "${DATA_DIR}/.install_state"
        
        case "${INSTALL_STATE:-}" in
            kernel_installed)
                if is_xanmod_installed; then
                    log_success "XanMod kernel active: $(uname -r)"
                    rm -f "${DATA_DIR}/.reboot_required"
                    rm -f "${DATA_DIR}/.install_state"
                    return 0
                else
                    log_warn "XanMod kernel not active. Current: $(uname -r)"
                    log_warn "You may need to reboot again or check GRUB configuration"
                    return 1
                fi
                ;;
            *)
                log_info "Resuming installation..."
                ;;
        esac
    fi
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# BBR CONGESTION CONTROL
# ═══════════════════════════════════════════════════════════════════════════════

is_bbr_available() {
    grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

is_bbr_enabled() {
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]
}

enable_bbr() {
    set_phase "BBR Congestion Control"
    
    # Check if BBR is available
    if ! is_bbr_available; then
        log_warn "BBR not available in current kernel"
        log_info "Installing XanMod kernel will provide BBRv3 support"
        return 0
    fi
    
    # Check if already enabled
    if is_bbr_enabled; then
        log_info "BBR already enabled"
        return 0
    fi
    
    log_info "Enabling BBR congestion control..."
    
    # Backup existing sysctl config
    backup_file "/etc/sysctl.d/99-bbr.conf"
    
    # Create BBR configuration
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
# BBR Congestion Control
# Generated by Marzban Ultimate Installer

# Enable BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP optimizations for high-throughput VPN
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Enable TCP Fast Open
net.ipv4.tcp_fastopen = 3

# Reduce TIME_WAIT connections
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Increase somaxconn for high connection counts
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# Disable IPv6 if not needed (optional, commented out)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF
    
    register_rollback "rm -f /etc/sysctl.d/99-bbr.conf && sysctl --system" "normal"
    
    # Apply settings
    sysctl -p /etc/sysctl.d/99-bbr.conf
    
    # Verify
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    
    if [[ "${current_cc}" == "bbr" ]]; then
        log_success "BBR enabled: ${current_cc}"
    else
        log_warn "BBR activation may require reboot. Current: ${current_cc}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEMD-RESOLVED (PORT 53)
# ═══════════════════════════════════════════════════════════════════════════════

is_port53_in_use_by_resolved() {
    ss -tulpn 2>/dev/null | grep -q ":53.*systemd-resolve"
}

disable_resolved_stub() {
    set_phase "Systemd-Resolved Configuration"
    
    if ! is_port53_in_use_by_resolved; then
        log_info "Port 53 is not bound by systemd-resolved"
        return 0
    fi
    
    log_info "Disabling systemd-resolved stub listener to free port 53..."
    
    # Backup
    backup_file "/etc/systemd/resolved.conf"
    
    # Create override directory
    local config_dir="/etc/systemd/resolved.conf.d"
    local config_file="${config_dir}/no-stub.conf"
    
    mkdir -p "${config_dir}"
    
    # Register critical rollback (DNS is critical)
    register_rollback "rm -f ${config_file} && systemctl restart systemd-resolved" "critical"
    
    # Create override config
    cat > "${config_file}" << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 8.8.4.4
FallbackDNS=9.9.9.9
DNSStubListener=no
EOF
    
    # Update resolv.conf symlink
    if [[ -L /etc/resolv.conf ]]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
    
    # Restart service
    systemctl restart systemd-resolved
    
    # Verify
    sleep 2
    if is_port53_in_use_by_resolved; then
        log_error "Failed to free port 53"
        return 1
    fi
    
    log_success "Port 53 released from systemd-resolved"
}

restore_resolved_stub() {
    log_info "Restoring systemd-resolved configuration..."
    
    rm -f /etc/systemd/resolved.conf.d/no-stub.conf
    
    if [[ -L /etc/resolv.conf ]]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
    
    systemctl restart systemd-resolved
}

# ═══════════════════════════════════════════════════════════════════════════════
# TIMEZONE CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

configure_timezone() {
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
    
    log_info "Current timezone: ${current_tz}"
    
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        if ask_yes_no "Keep current timezone?" "y"; then
            return 0
        fi
        
        log_info "Common timezones:"
        echo "  1) UTC"
        echo "  2) Europe/Moscow"
        echo "  3) Europe/London"
        echo "  4) America/New_York"
        echo "  5) Asia/Singapore"
        echo "  6) Enter custom"
        
        log_input "Select timezone [1-6]: "
        read -r choice
        
        case "${choice}" in
            1) timedatectl set-timezone UTC ;;
            2) timedatectl set-timezone Europe/Moscow ;;
            3) timedatectl set-timezone Europe/London ;;
            4) timedatectl set-timezone America/New_York ;;
            5) timedatectl set-timezone Asia/Singapore ;;
            6)
                log_input "Enter timezone (e.g., Europe/Berlin): "
                read -r tz
                timedatectl set-timezone "${tz}"
                ;;
        esac
        
        log_info "Timezone set to: $(timedatectl show --property=Timezone --value)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN SYSTEM PREPARATION
# ═══════════════════════════════════════════════════════════════════════════════

prepare_system() {
    log_step "System Preparation"
    
    # Check for resume state
    if [[ -f "${DATA_DIR}/.install_state" ]]; then
        resume_after_reboot
    fi
    
    # Update and install packages
    system_update
    install_essential_packages
    
    # Enable BBR (works with stock kernel too)
    enable_bbr
    
    # XanMod kernel (optional)
    if [[ "${INSTALL_XANMOD:-false}" == "true" ]]; then
        install_xanmod_kernel
    fi
    
    log_success "System preparation completed"
}

# Export functions
export -f prepare_system
export -f install_xanmod_kernel
export -f enable_bbr
export -f disable_resolved_stub
export -f check_cpu_compatibility
export -f is_bbr_enabled
