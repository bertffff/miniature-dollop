#!/bin/bash
#
# Module: firewall.sh
# Purpose: UFW firewall configuration, SSH detection, Fail2Ban setup
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
# SSH PORT DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

detect_ssh_port() {
    local ssh_port=""
    
    # Method 1: Parse sshd_config
    if [[ -f /etc/ssh/sshd_config ]]; then
        ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    fi
    
    # Method 2: Check listening sockets
    if [[ -z "${ssh_port}" ]]; then
        ssh_port=$(ss -tlnp 2>/dev/null | grep -E "sshd|ssh" | \
                   grep -oP ':\K\d+(?=\s)' | head -1)
    fi
    
    # Method 3: Check current SSH connection
    if [[ -z "${ssh_port}" ]] && [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_port=$(echo "${SSH_CONNECTION}" | awk '{print $4}')
    fi
    
    # Default fallback
    echo "${ssh_port:-22}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLOUDFLARE IP RANGES
# ═══════════════════════════════════════════════════════════════════════════════

get_cloudflare_ips() {
    local cf_ipv4_url="https://www.cloudflare.com/ips-v4"
    local cf_ipv6_url="https://www.cloudflare.com/ips-v6"
    
    local ipv4_ranges
    local ipv6_ranges
    
    ipv4_ranges=$(curl -sf "${cf_ipv4_url}" 2>/dev/null || true)
    ipv6_ranges=$(curl -sf "${cf_ipv6_url}" 2>/dev/null || true)
    
    echo "${ipv4_ranges}"
    echo "${ipv6_ranges}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# UFW CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

is_ufw_installed() {
    command -v ufw &> /dev/null
}

is_ufw_active() {
    ufw status 2>/dev/null | grep -q "Status: active"
}

install_ufw() {
    if is_ufw_installed; then
        log_info "UFW already installed"
        return 0
    fi
    
    log_info "Installing UFW..."
    install_packages ufw
}

configure_ufw() {
    set_phase "Firewall Configuration"
    
    install_ufw
    
    # Detect SSH port BEFORE making any changes
    local ssh_port
    ssh_port=$(detect_ssh_port)
    log_info "Detected SSH port: ${ssh_port}"
    
    # CRITICAL: Register SSH rollback first
    register_rollback "ufw allow ${ssh_port}/tcp comment 'SSH'" "critical"
    register_rollback "ufw --force disable && ufw --force reset" "critical"
    
    # Reset UFW to clean state
    log_info "Resetting UFW to default state..."
    ufw --force reset > /dev/null 2>&1
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # CRITICAL: Allow SSH first
    log_info "Allowing SSH on port ${ssh_port}..."
    ufw allow "${ssh_port}/tcp" comment "SSH"
    
    # Allow HTTP/HTTPS
    log_info "Allowing HTTP (80) and HTTPS (443)..."
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    
    # Allow Marzban panel port if different from 443
    if [[ "${MARZBAN_PORT:-8000}" != "443" ]]; then
        log_info "Allowing Marzban panel port ${MARZBAN_PORT:-8000}..."
        ufw allow "${MARZBAN_PORT:-8000}/tcp" comment "Marzban Panel"
    fi
    
    # Allow AdGuard ports if enabled
    if [[ "${ADGUARD_ENABLED:-false}" == "true" ]]; then
        log_info "Allowing AdGuard ports..."
        ufw allow 53/tcp comment "AdGuard DNS TCP"
        ufw allow 53/udp comment "AdGuard DNS UDP"
        ufw allow 3000/tcp comment "AdGuard Web"
    fi
    
    # Optional: Allow from Cloudflare IPs only for CDN profile
    if [[ "${PROFILE_WHITELIST_ENABLED:-false}" == "true" ]] && \
       [[ "${CLOUDFLARE_UFW_RULES:-false}" == "true" ]]; then
        log_info "Adding Cloudflare IP ranges..."
        
        local cf_ips
        cf_ips=$(get_cloudflare_ips)
        
        if [[ -n "${cf_ips}" ]]; then
            while IFS= read -r ip_range; do
                [[ -z "${ip_range}" ]] && continue
                ufw allow from "${ip_range}" to any port 443 proto tcp comment "Cloudflare"
            done <<< "${cf_ips}"
        fi
    fi
    
    # Enable UFW
    log_info "Enabling UFW..."
    echo "y" | ufw enable
    
    # Show status
    log_info "UFW Status:"
    ufw status verbose
    
    log_success "Firewall configured successfully"
    
    # Store SSH port for reference
    export DETECTED_SSH_PORT="${ssh_port}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# FAIL2BAN CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

is_fail2ban_installed() {
    command -v fail2ban-client &> /dev/null
}

install_fail2ban() {
    set_phase "Fail2Ban Installation"
    
    if is_fail2ban_installed; then
        log_info "Fail2Ban already installed"
        return 0
    fi
    
    log_info "Installing Fail2Ban..."
    install_packages fail2ban
    
    register_rollback "systemctl stop fail2ban && apt-get remove -y fail2ban" "normal"
}

configure_fail2ban() {
    set_phase "Fail2Ban Configuration"
    
    install_fail2ban
    
    local ssh_port
    ssh_port=$(detect_ssh_port)
    
    # Create local jail configuration
    log_info "Configuring Fail2Ban jails..."
    
    cat > /etc/fail2ban/jail.local << EOF
# Fail2Ban Local Configuration
# Generated by Marzban Ultimate Installer

[DEFAULT]
# Ban hosts for 1 hour
bantime = 3600

# A host is banned if it has generated "maxretry" during the last "findtime"
findtime = 600
maxretry = 5

# Use UFW for banning
banaction = ufw

# Ignore localhost
ignoreip = 127.0.0.1/8 ::1

# Email notifications (optional)
# destemail = admin@example.com
# sender = fail2ban@example.com
# mta = sendmail
# action = %(action_mwl)s

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600

# Aggressive SSH jail (repeated offenders)
[sshd-aggressive]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 10
findtime = 86400
bantime = 604800
EOF
    
    register_rollback "rm -f /etc/fail2ban/jail.local" "normal"
    
    # Restart Fail2Ban
    systemctl restart fail2ban
    systemctl enable fail2ban
    
    # Show status
    log_info "Fail2Ban Status:"
    fail2ban-client status
    
    log_success "Fail2Ban configured successfully"
}

# ═══════════════════════════════════════════════════════════════════════════════
# FIREWALL STATUS
# ═══════════════════════════════════════════════════════════════════════════════

show_firewall_status() {
    echo
    log_info "═══ Firewall Status ═══"
    
    if is_ufw_active; then
        ufw status numbered
    else
        log_warn "UFW is not active"
    fi
    
    if is_fail2ban_installed; then
        echo
        log_info "═══ Fail2Ban Status ═══"
        fail2ban-client status 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

setup_firewall() {
    configure_ufw
    
    if [[ "${FAIL2BAN_ENABLED:-false}" == "true" ]]; then
        configure_fail2ban
    fi
    
    show_firewall_status
}

# Export functions
export -f setup_firewall
export -f configure_ufw
export -f configure_fail2ban
export -f detect_ssh_port
export -f show_firewall_status
