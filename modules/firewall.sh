#!/bin/bash
# =============================================================================
# Module: firewall.sh
# Description: UFW configuration, SSH port detection, Cloudflare IP whitelist
# =============================================================================

set -euo pipefail

if [[ -z "${CORE_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# SSH PORT DETECTION
# =============================================================================
detect_ssh_port() {
    local ssh_port=""
    
    # Method 1: sshd_config
    [[ -f /etc/ssh/sshd_config ]] && \
        ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    
    # Method 2: sshd_config.d
    [[ -z "${ssh_port}" ]] && [[ -d /etc/ssh/sshd_config.d ]] && \
        ssh_port=$(grep -rh "^Port\s+" /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | head -1)
    
    # Method 3: Active connections
    [[ -z "${ssh_port}" ]] && \
        ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oE '[0-9]+$' | head -1)
    
    # Method 4: SSH_CONNECTION
    [[ -z "${ssh_port}" ]] && [[ -n "${SSH_CONNECTION:-}" ]] && \
        ssh_port=$(echo "${SSH_CONNECTION}" | awk '{print $4}')
    
    export SSH_PORT="${ssh_port:-22}"
    echo "${SSH_PORT}"
}

# =============================================================================
# CLOUDFLARE IPS
# =============================================================================
get_cloudflare_ips() {
    log_info "Fetching Cloudflare IP ranges..."
    
    local cf_ipv4=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
    local cf_ipv6=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null || true)
    
    # Fallback
    [[ -z "${cf_ipv4}" ]] && cf_ipv4="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22"
    
    [[ -z "${cf_ipv6}" ]] && cf_ipv6="2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
    
    echo "${cf_ipv4}"
    echo "${cf_ipv6}"
}

# =============================================================================
# UFW INSTALLATION
# =============================================================================
install_ufw() {
    log_step "Installing UFW Firewall"
    is_package_installed ufw || install_packages ufw
    log_success "UFW installed"
}

# =============================================================================
# CONFIGURE FIREWALL
# =============================================================================
configure_firewall() {
    log_step "Configuring Firewall (UFW)"
    
    install_ufw
    
    local ssh_port=$(detect_ssh_port)
    log_info "Detected SSH port: ${ssh_port}"
    
    # Backup existing rules
    [[ -f /etc/ufw/user.rules ]] && backup_file /etc/ufw/user.rules
    
    log_warn "Resetting UFW rules. SSH on port ${ssh_port} will be preserved."
    
    # Store current UFW state for rollback
    local ufw_was_active="false"
    ufw status | grep -q "Status: active" && ufw_was_active="true"
    
    # Register critical rollback for firewall
    register_rollback "Restore UFW access" "ufw allow ${ssh_port}/tcp comment 'SSH Emergency'" "critical"
    
    # Disable and reset
    ufw --force disable 2>/dev/null || true
    yes | ufw --force reset 2>/dev/null || true
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # CRITICAL: Allow SSH first
    ufw allow "${ssh_port}/tcp" comment 'SSH'
    log_success "SSH port ${ssh_port} allowed"
    
    # HTTP/HTTPS
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    log_success "HTTP/HTTPS allowed"
    
    # Additional ports from config
    if [[ -n "${ADDITIONAL_PORTS:-}" ]]; then
        IFS=',' read -ra ports <<< "${ADDITIONAL_PORTS}"
        for port in "${ports[@]}"; do
            port=$(echo "${port}" | tr -d ' ')
            validate_port "${port}" && ufw allow "${port}" comment 'Custom'
        done
    fi
    
    # Xray port
    [[ -n "${XRAY_PORT:-}" ]] && ufw allow "${XRAY_PORT}/tcp" comment 'Xray'
    
    # AdGuard DNS port (if enabled)
    [[ "${INSTALL_ADGUARD:-false}" == "true" ]] && ufw allow 53 comment 'AdGuard DNS'
    
    # Cloudflare whitelist (optional)
    if [[ "${WHITELIST_CLOUDFLARE:-false}" == "true" ]]; then
        log_info "Adding Cloudflare IP whitelist..."
        while IFS= read -r ip; do
            [[ -n "${ip}" ]] && ufw allow from "${ip}" to any port 443 comment 'Cloudflare'
        done <<< "$(get_cloudflare_ips)"
        log_success "Cloudflare IPs whitelisted"
    fi
    
    # Rate limiting for SSH
    ufw limit "${ssh_port}/tcp" comment 'SSH rate limit'
    
    # Enable UFW
    ufw --force enable
    
    register_rollback "Disable UFW" "ufw --force disable" "normal"
    
    log_info "Firewall status:"
    ufw status numbered | head -20
    
    log_success "Firewall configured"
}

# =============================================================================
# PORT CHECKING
# =============================================================================
check_port_available() {
    local port="$1"
    ! ss -tlnp | grep -q ":${port}\s"
}

check_required_ports() {
    log_step "Checking Required Ports"
    
    local required_ports=("80" "443" "${XRAY_PORT:-8443}" "${MARZBAN_PORT:-8000}")
    local blocked=()
    
    for port in "${required_ports[@]}"; do
        if ! check_port_available "${port}"; then
            local process=$(ss -tlnp | grep ":${port}\s" | awk '{print $NF}' | head -1)
            log_warn "Port ${port} in use by: ${process}"
            blocked+=("${port}")
        fi
    done
    
    if [[ ${#blocked[@]} -gt 0 ]]; then
        log_error "Blocked ports: ${blocked[*]}"
        confirm "Continue anyway?" || exit 1
    else
        log_success "All required ports available"
    fi
}

# =============================================================================
# UTILITIES
# =============================================================================
show_firewall_status() {
    log_step "Firewall Status"
    command -v ufw &>/dev/null && ufw status | grep -q "Status: active" && ufw status verbose || \
        command -v iptables &>/dev/null && iptables -L -n -v | head -30 || \
        log_warn "No firewall detected"
}

open_port() {
    local port="$1" protocol="${2:-tcp}" comment="${3:-Custom}"
    command -v ufw &>/dev/null && ufw allow "${port}/${protocol}" comment "${comment}" && log_success "Opened ${port}/${protocol}"
}

close_port() {
    local port="$1" protocol="${2:-tcp}"
    command -v ufw &>/dev/null && ufw delete allow "${port}/${protocol}" 2>/dev/null || true && log_success "Closed ${port}/${protocol}"
}

# =============================================================================
# MAIN
# =============================================================================
setup_firewall() {
    log_step "=== FIREWALL SETUP ==="
    check_required_ports
    configure_firewall
    log_success "Firewall setup completed"
}

export -f detect_ssh_port get_cloudflare_ips install_ufw configure_firewall
export -f check_port_available check_required_ports show_firewall_status
export -f open_port close_port setup_firewall
