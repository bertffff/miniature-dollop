#!/bin/bash
# =============================================================================
# Module: system.sh
# Description: OS preparation, dependencies, kernel tuning (BBR), sysctl
# =============================================================================

set -euo pipefail

# Source core module if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# TIMEZONE CONFIGURATION
# =============================================================================
configure_timezone() {
    log_step "Configuring Timezone"
    
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")
    
    log_info "Current timezone: ${current_tz}"
    
    if [[ "${CONFIGURE_TIMEZONE:-auto}" == "auto" ]]; then
        log_info "Keeping current timezone"
    elif [[ -n "${TIMEZONE:-}" ]]; then
        timedatectl set-timezone "${TIMEZONE}"
        log_success "Timezone set to: ${TIMEZONE}"
    fi
    
    # Enable NTP sync
    timedatectl set-ntp true 2>/dev/null || true
    log_success "NTP synchronization enabled"
}

# =============================================================================
# ESSENTIAL PACKAGES
# =============================================================================
install_essential_packages() {
    log_step "Installing Essential Packages"
    
    local packages=(
        # Essential tools
        curl
        wget
        git
        unzip
        zip
        tar
        
        # Network tools
        net-tools
        dnsutils
        netcat-openbsd
        
        # SSL/TLS
        ca-certificates
        openssl
        
        # Process management
        htop
        
        # Text processing
        jq
        sed
        gawk
        
        # System utilities
        gnupg
        lsb-release
        software-properties-common
        apt-transport-https
        
        # Build essentials (for some dependencies)
        build-essential
        
        # Cron
        cron
        
        # Logging
        rsyslog
    )
    
    update_package_cache
    
    # Install missing packages only
    local missing_packages=()
    for pkg in "${packages[@]}"; do
        if ! is_package_installed "${pkg}"; then
            missing_packages+=("${pkg}")
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        install_packages "${missing_packages[@]}"
    else
        log_info "All essential packages already installed"
    fi
    
    log_success "Essential packages ready"
}

# =============================================================================
# SYSTEM HARDENING
# =============================================================================
configure_sysctl() {
    log_step "Configuring System Parameters (sysctl)"
    
    local sysctl_conf="/etc/sysctl.d/99-marzban-vpn.conf"
    
    backup_file "${sysctl_conf}"
    
    cat > "${sysctl_conf}" << 'EOF'
# =============================================================================
# Marzban VPN Installer - Optimized Sysctl Configuration
# =============================================================================

# ----- Network Performance -----
# Increase socket buffer sizes
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 65536

# TCP buffer sizes (min, default, max)
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432

# UDP buffer sizes
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Increase connection tracking table size
net.netfilter.nf_conntrack_max = 1048576

# ----- TCP Optimization -----
# Enable TCP Fast Open
net.ipv4.tcp_fastopen = 3

# Enable BBR congestion control (if available)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Reduce TCP connection time-wait
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Increase max SYN backlog
net.ipv4.tcp_max_syn_backlog = 65536

# TCP keepalive parameters
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# Enable timestamps
net.ipv4.tcp_timestamps = 1

# Enable selective acknowledgments
net.ipv4.tcp_sack = 1

# Enable window scaling
net.ipv4.tcp_window_scaling = 1

# MTU probing
net.ipv4.tcp_mtu_probing = 1

# ----- Security -----
# Disable IPv6 (optional - enable if you need IPv6)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1

# Ignore ICMP broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Enable reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable SYN cookies (DoS protection)
net.ipv4.tcp_syncookies = 1

# ----- IP Forwarding (Required for VPN) -----
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# ----- File Descriptors -----
fs.file-max = 2097152
fs.nr_open = 2097152

# ----- Virtual Memory -----
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 5
EOF

    # Apply sysctl settings
    sysctl -p "${sysctl_conf}" 2>/dev/null || log_warn "Some sysctl settings could not be applied"
    
    register_rollback "rm -f ${sysctl_conf} && sysctl --system"
    
    log_success "System parameters configured"
}

# =============================================================================
# BBR CONGESTION CONTROL
# =============================================================================
enable_bbr() {
    log_step "Enabling BBR Congestion Control"
    
    # Check if BBR is already enabled
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    
    if [[ "${current_cc}" == "bbr" ]]; then
        log_success "BBR is already enabled"
        return 0
    fi
    
    # Check if BBR module is available
    if ! modprobe tcp_bbr 2>/dev/null; then
        log_warn "BBR module not available. Kernel may need upgrade."
        log_info "Current congestion control: ${current_cc}"
        return 0
    fi
    
    # Load BBR module on boot
    if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    fi
    
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
# LIMITS CONFIGURATION
# =============================================================================
configure_limits() {
    log_step "Configuring System Limits"
    
    local limits_conf="/etc/security/limits.d/99-marzban-vpn.conf"
    
    backup_file "${limits_conf}"
    
    cat > "${limits_conf}" << 'EOF'
# Marzban VPN Installer - File descriptor limits
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 65535
root hard nproc 65535
EOF

    register_rollback "rm -f ${limits_conf}"
    
    # Update systemd limits
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF

    # Reload systemd
    systemctl daemon-reload 2>/dev/null || true
    
    log_success "System limits configured"
}

# =============================================================================
# SYSTEMD-RESOLVED CONFIGURATION
# =============================================================================
configure_resolved() {
    log_step "Configuring DNS Resolver"
    
    # Check if systemd-resolved is running
    if ! systemctl is-active --quiet systemd-resolved; then
        log_info "systemd-resolved is not active, skipping"
        return 0
    fi
    
    local resolved_conf="/etc/systemd/resolved.conf.d/marzban-vpn.conf"
    mkdir -p "$(dirname "${resolved_conf}")"
    
    backup_file "${resolved_conf}"
    
    # Check if we need to disable stub listener (for port 53 conflict)
    if [[ "${DISABLE_DNS_STUB:-false}" == "true" ]]; then
        cat > "${resolved_conf}" << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
DNSStubListener=no
EOF
        
        # Update resolv.conf
        if [[ -L /etc/resolv.conf ]]; then
            rm /etc/resolv.conf
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        fi
        
        systemctl restart systemd-resolved
        log_success "DNS stub listener disabled (port 53 freed)"
    else
        cat > "${resolved_conf}" << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 8.8.4.4
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
EOF
        
        systemctl restart systemd-resolved || true
        log_success "DNS resolver configured"
    fi
    
    register_rollback "rm -f ${resolved_conf} && systemctl restart systemd-resolved"
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
    
    # Only create swap if memory is low
    if [[ "${TOTAL_MEMORY:-2048}" -lt 2048 ]]; then
        log_info "Low memory detected, creating swap file..."
        
        local swap_file="/swapfile"
        local swap_size="2G"
        
        if [[ ! -f "${swap_file}" ]]; then
            fallocate -l "${swap_size}" "${swap_file}" 2>/dev/null || dd if=/dev/zero of="${swap_file}" bs=1M count=2048
            chmod 600 "${swap_file}"
            mkswap "${swap_file}"
            swapon "${swap_file}"
            
            # Add to fstab
            if ! grep -q "${swap_file}" /etc/fstab; then
                echo "${swap_file} none swap sw 0 0" >> /etc/fstab
            fi
            
            register_rollback "swapoff ${swap_file}; rm -f ${swap_file}"
            
            log_success "Swap file created: ${swap_size}"
        fi
    else
        log_info "Sufficient memory, skipping swap creation"
    fi
}

# =============================================================================
# AUTOMATIC SECURITY UPDATES
# =============================================================================
configure_auto_updates() {
    log_step "Configuring Automatic Security Updates"
    
    if [[ "${ENABLE_AUTO_UPDATES:-true}" != "true" ]]; then
        log_info "Automatic updates disabled by configuration"
        return 0
    fi
    
    if ! is_package_installed unattended-upgrades; then
        install_packages unattended-upgrades
    fi
    
    # Configure unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    # Enable automatic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

    log_success "Automatic security updates configured"
}

# =============================================================================
# FAIL2BAN CONFIGURATION (OPTIONAL)
# =============================================================================
install_fail2ban() {
    log_step "Installing Fail2Ban"
    
    if [[ "${ENABLE_FAIL2BAN:-false}" != "true" ]]; then
        log_info "Fail2Ban installation skipped"
        return 0
    fi
    
    if ! is_package_installed fail2ban; then
        install_packages fail2ban
    fi
    
    # Configure fail2ban for SSH
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT:-22}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    
    register_rollback "systemctl stop fail2ban; systemctl disable fail2ban"
    
    log_success "Fail2Ban configured"
}

# =============================================================================
# CLEAN UP UNUSED PACKAGES
# =============================================================================
cleanup_system() {
    log_step "Cleaning Up System"
    
    # Remove unused packages
    apt-get autoremove -y -qq 2>/dev/null || true
    apt-get autoclean -y -qq 2>/dev/null || true
    
    # Clear apt cache
    apt-get clean 2>/dev/null || true
    
    # Clear journal logs older than 7 days
    journalctl --vacuum-time=7d 2>/dev/null || true
    
    log_success "System cleanup completed"
}

# =============================================================================
# MAIN SYSTEM PREPARATION FUNCTION
# =============================================================================
prepare_system() {
    log_step "=== SYSTEM PREPARATION ==="
    
    # Run all system preparation tasks
    configure_timezone
    install_essential_packages
    configure_sysctl
    enable_bbr
    configure_limits
    configure_resolved
    configure_swap
    configure_auto_updates
    install_fail2ban
    cleanup_system
    
    log_success "System preparation completed"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f configure_timezone
export -f install_essential_packages
export -f configure_sysctl
export -f enable_bbr
export -f configure_limits
export -f configure_resolved
export -f configure_swap
export -f configure_auto_updates
export -f install_fail2ban
export -f cleanup_system
export -f prepare_system
