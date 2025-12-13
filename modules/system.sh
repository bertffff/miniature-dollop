#!/bin/bash
# =============================================================================
# Module: system.sh
# Description: OS preparation, XanMod kernel, BBR, sysctl optimization
# Version: 2.0.0 - With XanMod kernel support
# =============================================================================

set -euo pipefail

# Source core module
if [[ -z "${CORE_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# CPU COMPATIBILITY CHECK FOR XANMOD
# =============================================================================
check_cpu_compatibility() {
    log_info "Checking CPU compatibility for XanMod kernel..."
    
    local cpu_level=""
    
    # Method 1: Use XanMod's checker script
    if wget -qO /tmp/check_x86-64_psabi.sh https://dl.xanmod.org/check_x86-64_psabi.sh 2>/dev/null; then
        cpu_level=$(awk -f /tmp/check_x86-64_psabi.sh 2>/dev/null | grep -oP 'x86-64-v\K[0-9]+' | head -1)
        rm -f /tmp/check_x86-64_psabi.sh
    fi
    
    # Method 2: Manual check via cpuinfo
    if [[ -z "${cpu_level}" ]]; then
        local flags
        flags=$(grep -m1 'flags' /proc/cpuinfo 2>/dev/null || echo "")
        
        # Check for v4 (AVX-512)
        if echo "${flags}" | grep -qw 'avx512f'; then
            cpu_level="4"
        # Check for v3 (AVX2, BMI1, BMI2, FMA)
        elif echo "${flags}" | grep -qwE 'avx2.*bmi1.*bmi2|bmi1.*avx2.*bmi2'; then
            cpu_level="3"
        # Check for v2 (CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSE4.1, SSE4.2, SSSE3)
        elif echo "${flags}" | grep -qwE 'sse4_2.*popcnt|popcnt.*sse4_2'; then
            cpu_level="2"
        else
            cpu_level="1"
        fi
    fi
    
    export CPU_MICROARCH_LEVEL="${cpu_level:-1}"
    log_info "CPU microarchitecture level: x86-64-v${CPU_MICROARCH_LEVEL}"
    
    if [[ "${CPU_MICROARCH_LEVEL}" -ge 3 ]]; then
        log_success "CPU supports XanMod x64v3 (recommended)"
        return 0
    elif [[ "${CPU_MICROARCH_LEVEL}" -ge 2 ]]; then
        log_warn "CPU supports XanMod x64v2 (older CPUs)"
        return 0
    else
        log_warn "CPU may not fully support XanMod optimization"
        return 1
    fi
}

# =============================================================================
# CHECK IF XANMOD IS ALREADY INSTALLED
# =============================================================================
is_xanmod_installed() {
    local current_kernel
    current_kernel=$(uname -r)
    
    if [[ "${current_kernel}" == *"xanmod"* ]]; then
        log_info "XanMod kernel is already active: ${current_kernel}"
        return 0
    fi
    
    # Check if XanMod package is installed but not booted
    if dpkg -l | grep -q "linux-xanmod"; then
        log_warn "XanMod is installed but not active. Reboot required."
        return 2
    fi
    
    return 1
}

# =============================================================================
# INSTALL XANMOD KERNEL
# =============================================================================
install_xanmod_kernel() {
    log_step "Installing XanMod Kernel"
    
    # Check if already installed
    local xanmod_status
    is_xanmod_installed
    xanmod_status=$?
    
    if [[ ${xanmod_status} -eq 0 ]]; then
        log_success "XanMod kernel is already running"
        return 0
    elif [[ ${xanmod_status} -eq 2 ]]; then
        set_reboot_required
        return 0
    fi
    
    # Check CPU compatibility
    if ! check_cpu_compatibility; then
        log_warn "CPU may not be optimal for XanMod. Proceeding with caution..."
    fi
    
    # Determine which version to install
    local xanmod_pkg="linux-xanmod-x64v3"
    if [[ "${CPU_MICROARCH_LEVEL:-1}" -lt 3 ]]; then
        xanmod_pkg="linux-xanmod-x64v2"
    fi
    
    log_info "Selected package: ${xanmod_pkg}"
    
    # Register GPG key
    log_info "Adding XanMod repository..."
    
    wget -qO - https://dl.xanmod.org/archive.key | \
        gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null
    
    register_rollback "Remove XanMod keyring" "rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg" "cleanup"
    
    # Add repository
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | \
        tee /etc/apt/sources.list.d/xanmod-release.list > /dev/null
    
    register_rollback "Remove XanMod repo" "rm -f /etc/apt/sources.list.d/xanmod-release.list" "cleanup"
    
    # Update and install
    apt-get update -qq
    
    log_info "Installing ${xanmod_pkg}..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "${xanmod_pkg}"; then
        log_success "XanMod kernel installed successfully"
        
        # Mark reboot required
        set_reboot_required
        save_install_state "xanmod_installed"
        
        log_warn "System MUST be rebooted to use the new kernel"
        log_info "After reboot, run this script again to continue installation"
        
        return 0
    else
        log_error "Failed to install XanMod kernel"
        return 1
    fi
}

# =============================================================================
# TIMEZONE CONFIGURATION
# =============================================================================
configure_timezone() {
    log_step "Configuring Timezone"
    
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")
    log_info "Current timezone: ${current_tz}"
    
    if [[ -n "${TIMEZONE:-}" ]]; then
        timedatectl set-timezone "${TIMEZONE}"
        log_success "Timezone set to: ${TIMEZONE}"
    fi
    
    # Enable NTP
    timedatectl set-ntp true 2>/dev/null || true
    log_success "NTP synchronization enabled"
}

# =============================================================================
# ESSENTIAL PACKAGES
# =============================================================================
install_essential_packages() {
    log_step "Installing Essential Packages"
    
    local packages=(
        curl wget git unzip zip tar
        net-tools dnsutils netcat-openbsd
        ca-certificates openssl
        htop jq sed gawk
        gnupg lsb-release software-properties-common apt-transport-https
        cron rsyslog
    )
    
    update_package_cache
    
    local missing=()
    for pkg in "${packages[@]}"; do
        is_package_installed "${pkg}" || missing+=("${pkg}")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        install_packages "${missing[@]}"
    else
        log_info "All essential packages already installed"
    fi
    
    log_success "Essential packages ready"
}

# =============================================================================
# SYSCTL OPTIMIZATION
# =============================================================================
configure_sysctl() {
    log_step "Configuring System Parameters (sysctl)"
    
    local sysctl_conf="/etc/sysctl.d/99-marzban-vpn.conf"
    backup_file "${sysctl_conf}"
    
    cat > "${sysctl_conf}" << 'EOF'
# =============================================================================
# Marzban VPN - Optimized Sysctl Configuration
# =============================================================================

# Network Performance
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 65536

# TCP buffers
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432

# UDP buffers
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# TCP Optimization
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1

# Security
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1

# IP Forwarding (Required for VPN)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# File Descriptors
fs.file-max = 2097152
fs.nr_open = 2097152

# Virtual Memory
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 5
EOF

    sysctl -p "${sysctl_conf}" 2>/dev/null || log_warn "Some sysctl settings could not be applied"
    
    register_rollback "Remove sysctl config" "rm -f ${sysctl_conf} && sysctl --system" "cleanup"
    
    log_success "System parameters configured"
}

# =============================================================================
# BBR CONGESTION CONTROL
# =============================================================================
enable_bbr() {
    log_step "Enabling BBR Congestion Control"
    
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    
    if [[ "${current_cc}" == "bbr" ]]; then
        log_success "BBR is already enabled"
        return 0
    fi
    
    # Load BBR module
    if ! modprobe tcp_bbr 2>/dev/null; then
        log_warn "BBR module not available. Kernel may need upgrade."
        return 0
    fi
    
    # Persist module loading
    echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
    
    # Apply BBR
    sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
    
    # Verify
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "${current_cc}" == "bbr" ]]; then
        log_success "BBR enabled successfully"
    else
        log_warn "Could not enable BBR. Current: ${current_cc}"
    fi
}

# =============================================================================
# SYSTEM LIMITS
# =============================================================================
configure_limits() {
    log_step "Configuring System Limits"
    
    local limits_conf="/etc/security/limits.d/99-marzban-vpn.conf"
    backup_file "${limits_conf}"
    
    cat > "${limits_conf}" << 'EOF'
# Marzban VPN - File descriptor limits
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 65535
root hard nproc 65535
EOF

    register_rollback "Remove limits config" "rm -f ${limits_conf}" "cleanup"
    
    # Systemd limits
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF

    systemctl daemon-reload 2>/dev/null || true
    log_success "System limits configured"
}

# =============================================================================
# DNS CONFIGURATION
# =============================================================================
configure_dns() {
    log_step "Configuring DNS"
    
    # Check if systemd-resolved is active
    if ! systemctl is-active --quiet systemd-resolved; then
        log_info "systemd-resolved not active, skipping"
        return 0
    fi
    
    local resolved_conf="/etc/systemd/resolved.conf.d/marzban.conf"
    mkdir -p "$(dirname "${resolved_conf}")"
    
    cat > "${resolved_conf}" << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 8.8.4.4
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
EOF

    systemctl restart systemd-resolved || true
    
    register_rollback "Remove DNS config" "rm -f ${resolved_conf} && systemctl restart systemd-resolved" "cleanup"
    
    log_success "DNS configured"
}

# =============================================================================
# SWAP CONFIGURATION
# =============================================================================
configure_swap() {
    log_step "Checking Swap Configuration"
    
    local current_swap
    current_swap=$(free -m | awk '/^Swap:/ {print $2}')
    
    if [[ "${current_swap}" -gt 0 ]]; then
        log_info "Swap already configured: ${current_swap}MB"
        return 0
    fi
    
    # Create swap only if memory is low
    if [[ "${TOTAL_MEMORY:-2048}" -lt 2048 ]]; then
        log_info "Low memory, creating swap..."
        
        local swap_file="/swapfile"
        if [[ ! -f "${swap_file}" ]]; then
            fallocate -l 2G "${swap_file}" 2>/dev/null || dd if=/dev/zero of="${swap_file}" bs=1M count=2048
            chmod 600 "${swap_file}"
            mkswap "${swap_file}"
            swapon "${swap_file}"
            
            grep -q "${swap_file}" /etc/fstab || echo "${swap_file} none swap sw 0 0" >> /etc/fstab
            
            register_rollback "Remove swap" "swapoff ${swap_file}; rm -f ${swap_file}" "cleanup"
            
            log_success "Swap created: 2GB"
        fi
    else
        log_info "Sufficient memory, skipping swap creation"
    fi
}

# =============================================================================
# FAIL2BAN (OPTIONAL)
# =============================================================================
install_fail2ban() {
    log_step "Installing Fail2Ban"
    
    if [[ "${INSTALL_FAIL2BAN:-false}" != "true" ]]; then
        log_info "Fail2Ban installation skipped"
        return 0
    fi
    
    is_package_installed fail2ban || install_packages fail2ban
    
    local ssh_port="${SSH_PORT:-22}"
    
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    
    register_rollback "Stop Fail2Ban" "systemctl stop fail2ban; systemctl disable fail2ban" "normal"
    register_service "fail2ban"
    
    log_success "Fail2Ban configured"
}

# =============================================================================
# CLEANUP
# =============================================================================
cleanup_system() {
    log_step "Cleaning Up System"
    
    apt-get autoremove -y -qq 2>/dev/null || true
    apt-get autoclean -y -qq 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    journalctl --vacuum-time=7d 2>/dev/null || true
    
    log_success "System cleanup completed"
}

# =============================================================================
# MAIN SYSTEM PREPARATION
# =============================================================================
prepare_system() {
    log_step "=== SYSTEM PREPARATION ==="
    
    # Check if resuming after reboot
    local install_state
    install_state=$(get_install_state)
    
    if [[ "${install_state}" == "xanmod_installed" ]]; then
        log_info "Resuming installation after XanMod reboot..."
        clear_reboot_marker
        clear_install_state
    fi
    
    configure_timezone
    install_essential_packages
    configure_sysctl
    enable_bbr
    configure_limits
    configure_dns
    configure_swap
    install_fail2ban
    cleanup_system
    
    log_success "System preparation completed"
}

# =============================================================================
# XANMOD SETUP (SEPARATE FUNCTION)
# =============================================================================
setup_xanmod() {
    if [[ "${INSTALL_XANMOD:-false}" != "true" ]]; then
        log_info "XanMod installation skipped (--kernel xanmod not specified)"
        return 0
    fi
    
    # Check architecture
    if [[ "${ARCH:-}" != "amd64" ]]; then
        log_warn "XanMod is only supported on x86_64 architecture"
        return 0
    fi
    
    install_xanmod_kernel
    
    if is_reboot_required; then
        echo ""
        log_warn "╔════════════════════════════════════════════════════════════════╗"
        log_warn "║  REBOOT REQUIRED to activate XanMod kernel                     ║"
        log_warn "║  Run this script again after reboot to continue installation  ║"
        log_warn "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        
        if confirm "Reboot now?" "y"; then
            log_info "Rebooting in 5 seconds..."
            sleep 5
            reboot
        else
            log_warn "Please reboot manually and run this script again"
            exit 0
        fi
    fi
}

# Export functions
export -f check_cpu_compatibility
export -f is_xanmod_installed
export -f install_xanmod_kernel
export -f configure_timezone
export -f install_essential_packages
export -f configure_sysctl
export -f enable_bbr
export -f configure_limits
export -f configure_dns
export -f configure_swap
export -f install_fail2ban
export -f cleanup_system
export -f prepare_system
export -f setup_xanmod
