#!/bin/bash
# =============================================================================
# Module: firewall.sh
# Description: UFW configuration, SSH port detection, Cloudflare IP whitelist
# =============================================================================

set -euo pipefail

# Source core module if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# SSH PORT DETECTION
# =============================================================================
detect_ssh_port() {
    local ssh_port=""
    
    # Method 1: Check sshd_config
    if [[ -f /etc/ssh/sshd_config ]]; then
        ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    fi
    
    # Method 2: Check sshd_config.d directory
    if [[ -z "${ssh_port}" ]] && [[ -d /etc/ssh/sshd_config.d ]]; then
        ssh_port=$(grep -rh "^Port\s+" /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | head -1)
    fi
    
    # Method 3: Check active connections
    if [[ -z "${ssh_port}" ]]; then
        ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oE '[0-9]+$' | head -1)
    fi
    
    # Method 4: Check current connection
    if [[ -z "${ssh_port}" ]] && [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_port=$(echo "${SSH_CONNECTION}" | awk '{print $4}')
    fi
    
    # Default to 22
    if [[ -z "${ssh_port}" ]]; then
        ssh_port="22"
    fi
    
    echo "${ssh_port}"
}

# =============================================================================
# CLOUDFLARE IP RANGES
# =============================================================================
get_cloudflare_ips() {
    log_info "Fetching Cloudflare IP ranges..."
    
    local cf_ipv4=""
    local cf_ipv6=""
    
    # Try to fetch from Cloudflare
    cf_ipv4=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
    cf_ipv6=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null || true)
    
    # Fallback to hardcoded values if fetch fails
    if [[ -z "${cf_ipv4}" ]]; then
        cf_ipv4="173.245.48.0/20
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
        log_warn "Using cached Cloudflare IPv4 ranges"
    fi
    
    if [[ -z "${cf_ipv6}" ]]; then
        cf_ipv6="2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
        log_warn "Using cached Cloudflare IPv6 ranges"
    fi
    
    echo "${cf_ipv4}"
    echo "${cf_ipv6}"
}

# =============================================================================
# UFW INSTALLATION
# =============================================================================
install_ufw() {
    log_step "Installing UFW Firewall"
    
    if ! is_package_installed ufw; then
        install_packages ufw
    fi
    
    log_success "UFW installed"
}

# =============================================================================
# UFW CONFIGURATION
# =============================================================================
configure_firewall() {
    log_step "Configuring Firewall (UFW)"
    
    # Install UFW if needed
    install_ufw
    
    # Detect SSH port
    local ssh_port
    ssh_port=$(detect_ssh_port)
    export SSH_PORT="${ssh_port}"
    log_info "Detected SSH port: ${ssh_port}"
    
    # Backup existing rules
    if [[ -f /etc/ufw/user.rules ]]; then
        backup_file /etc/ufw/user.rules
    fi
    
    # Reset UFW (careful!)
    log_warn "This will reset UFW rules. SSH access on port ${ssh_port} will be preserved."
    
    # Disable UFW first
    ufw --force disable 2>/dev/null || true
    
    # Reset to default
    yes | ufw --force reset 2>/dev/null || true
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH (CRITICAL - DO THIS FIRST!)
    ufw allow "${ssh_port}/tcp" comment 'SSH'
    log_success "SSH port ${ssh_port} allowed"
    
    # Allow HTTP and HTTPS
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    log_success "HTTP/HTTPS ports allowed"
    
    # Allow additional ports if configured
    if [[ -n "${ADDITIONAL_PORTS:-}" ]]; then
        IFS=',' read -ra ports <<< "${ADDITIONAL_PORTS}"
        for port in "${ports[@]}"; do
            port=$(echo "${port}" | tr -d ' ')
            if validate_port "${port}"; then
                ufw allow "${port}" comment 'Custom port'
                log_info "Custom port ${port} allowed"
            fi
        done
    fi
    
    # Cloudflare IP whitelist (optional)
    if [[ "${WHITELIST_CLOUDFLARE:-false}" == "true" ]]; then
        log_info "Adding Cloudflare IP whitelist..."
        
        while IFS= read -r ip; do
            [[ -n "${ip}" ]] && ufw allow from "${ip}" to any port 443 comment 'Cloudflare'
        done <<< "$(get_cloudflare_ips)"
        
        log_success "Cloudflare IPs whitelisted"
    fi
    
    # Rate limiting for SSH (anti-brute-force)
    ufw limit "${ssh_port}/tcp" comment 'SSH rate limit'
    
    # Enable UFW
    ufw --force enable
    
    register_rollback "ufw --force disable"
    
    # Show status
    log_info "Firewall status:"
    ufw status numbered | head -20
    
    log_success "Firewall configured successfully"
}

# =============================================================================
# IPTABLES CONFIGURATION (ALTERNATIVE)
# =============================================================================
configure_iptables() {
    log_step "Configuring iptables (alternative method)"
    
    # Detect SSH port
    local ssh_port
    ssh_port=$(detect_ssh_port)
    
    # Flush existing rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    
    # Default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow SSH
    iptables -A INPUT -p tcp --dport "${ssh_port}" -j ACCEPT
    
    # Allow HTTP/HTTPS
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    
    # Allow ICMP (ping)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    # Rate limit SSH
    iptables -I INPUT -p tcp --dport "${ssh_port}" -m conntrack --ctstate NEW -m recent --set
    iptables -I INPUT -p tcp --dport "${ssh_port}" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    
    # Save rules
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables.rules
        
        # Create restore script
        cat > /etc/network/if-pre-up.d/iptables << 'EOF'
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
        chmod +x /etc/network/if-pre-up.d/iptables
    fi
    
    log_success "iptables configured"
}

# =============================================================================
# PORT CHECKING
# =============================================================================
check_port_available() {
    local port="$1"
    
    if ss -tlnp | grep -q ":${port}\s"; then
        return 1  # Port is in use
    fi
    return 0  # Port is available
}

check_required_ports() {
    log_step "Checking Required Ports"
    
    local required_ports=("80" "443" "${XRAY_PORT:-8443}" "${MARZBAN_PORT:-8000}")
    local blocked_ports=()
    
    for port in "${required_ports[@]}"; do
        if ! check_port_available "${port}"; then
            local process
            process=$(ss -tlnp | grep ":${port}\s" | awk '{print $NF}' | head -1)
            log_warn "Port ${port} is in use by: ${process}"
            blocked_ports+=("${port}")
        fi
    done
    
    if [[ ${#blocked_ports[@]} -gt 0 ]]; then
        log_error "The following ports are blocked: ${blocked_ports[*]}"
        log_info "Please free these ports or configure alternative ports in config.env"
        
        if ! confirm "Continue anyway?"; then
            exit 1
        fi
    else
        log_success "All required ports are available"
    fi
}

# =============================================================================
# FIREWALL STATUS
# =============================================================================
show_firewall_status() {
    log_step "Firewall Status"
    
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw status verbose
    elif command -v iptables &>/dev/null; then
        iptables -L -n -v | head -30
    else
        log_warn "No firewall detected"
    fi
}

# =============================================================================
# OPEN CUSTOM PORT
# =============================================================================
open_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    local comment="${3:-Custom}"
    
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/${protocol}" comment "${comment}"
        log_success "Opened port ${port}/${protocol}"
    else
        iptables -A INPUT -p "${protocol}" --dport "${port}" -j ACCEPT
        log_success "Opened port ${port}/${protocol} (iptables)"
    fi
}

# =============================================================================
# CLOSE PORT
# =============================================================================
close_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    
    if command -v ufw &>/dev/null; then
        ufw delete allow "${port}/${protocol}" 2>/dev/null || true
        log_success "Closed port ${port}/${protocol}"
    else
        iptables -D INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null || true
        log_success "Closed port ${port}/${protocol} (iptables)"
    fi
}

# =============================================================================
# MAIN FIREWALL SETUP
# =============================================================================
setup_firewall() {
    log_step "=== FIREWALL SETUP ==="
    
    check_required_ports
    configure_firewall
    
    log_success "Firewall setup completed"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f detect_ssh_port
export -f get_cloudflare_ips
export -f install_ufw
export -f configure_firewall
export -f check_port_available
export -f check_required_ports
export -f show_firewall_status
export -f open_port
export -f close_port
export -f setup_firewall
