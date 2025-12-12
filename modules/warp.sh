#!/bin/bash
# =============================================================================
# Module: warp.sh
# Description: Cloudflare WARP setup for Xray outbound
# =============================================================================

set -euo pipefail

# Source core module if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# WARP CONFIGURATION
# =============================================================================
readonly WARP_API="https://api.cloudflareclient.com/v0a2158/reg"
readonly WGCF_RELEASES="https://github.com/ViRb3/wgcf/releases"

# =============================================================================
# INSTALL WGCF
# =============================================================================
install_wgcf() {
    log_info "Installing wgcf..."
    
    if command -v wgcf &>/dev/null; then
        log_info "wgcf is already installed"
        return 0
    fi
    
    local arch="${ARCH:-amd64}"
    local wgcf_binary="wgcf_linux_${arch}"
    
    # Get latest release URL
    local download_url
    download_url=$(curl -s "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | \
        jq -r ".assets[] | select(.name | contains(\"${wgcf_binary}\")) | .browser_download_url" | head -1)
    
    if [[ -z "${download_url}" ]] || [[ "${download_url}" == "null" ]]; then
        # Fallback to direct URL construction
        local version="2.2.22"
        download_url="https://github.com/ViRb3/wgcf/releases/download/v${version}/wgcf_${version}_linux_${arch}"
    fi
    
    log_info "Downloading wgcf from: ${download_url}"
    
    if curl -sL "${download_url}" -o /usr/local/bin/wgcf; then
        chmod +x /usr/local/bin/wgcf
        log_success "wgcf installed"
    else
        log_error "Failed to download wgcf"
        return 1
    fi
}

# =============================================================================
# REGISTER WARP ACCOUNT
# =============================================================================
register_warp_account() {
    log_step "Registering WARP Account"
    
    local warp_dir="${MARZBAN_DIR:-/opt/marzban}/warp"
    mkdir -p "${warp_dir}"
    
    cd "${warp_dir}"
    
    # Check if already registered
    if [[ -f "wgcf-account.toml" ]]; then
        log_info "WARP account already exists"
        return 0
    fi
    
    # Register new account
    log_info "Registering new WARP account..."
    
    if wgcf register --accept-tos; then
        log_success "WARP account registered"
    else
        log_error "Failed to register WARP account"
        return 1
    fi
}

# =============================================================================
# GENERATE WARP CONFIG
# =============================================================================
generate_warp_config() {
    log_step "Generating WARP Configuration"
    
    local warp_dir="${MARZBAN_DIR:-/opt/marzban}/warp"
    
    cd "${warp_dir}"
    
    # Check if account exists
    if [[ ! -f "wgcf-account.toml" ]]; then
        log_error "WARP account not found. Run register_warp_account first."
        return 1
    fi
    
    # Generate WireGuard config
    if wgcf generate; then
        log_success "WARP WireGuard config generated"
    else
        log_error "Failed to generate WARP config"
        return 1
    fi
    
    # Parse the generated config
    if [[ -f "wgcf-profile.conf" ]]; then
        parse_warp_config "wgcf-profile.conf"
    else
        log_error "wgcf-profile.conf not found"
        return 1
    fi
}

# =============================================================================
# PARSE WARP CONFIG
# =============================================================================
parse_warp_config() {
    local config_file="$1"
    
    log_info "Parsing WARP configuration..."
    
    # Extract values from WireGuard config
    export WARP_PRIVATE_KEY=$(grep -E "^PrivateKey\s*=" "${config_file}" | cut -d= -f2 | tr -d ' ')
    export WARP_ADDRESS_V4=$(grep -E "^Address\s*=" "${config_file}" | cut -d= -f2 | tr -d ' ' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')
    export WARP_ADDRESS_V6=$(grep -E "^Address\s*=" "${config_file}" | cut -d= -f2 | tr -d ' ' | grep -oE '[a-f0-9:]+/[0-9]+')
    export WARP_PUBLIC_KEY=$(grep -E "^PublicKey\s*=" "${config_file}" | cut -d= -f2 | tr -d ' ')
    export WARP_ENDPOINT=$(grep -E "^Endpoint\s*=" "${config_file}" | cut -d= -f2 | tr -d ' ')
    
    # Remove CIDR notation for Xray
    export WARP_ADDRESS_V4_CLEAN="${WARP_ADDRESS_V4%/*}"
    export WARP_ADDRESS_V6_CLEAN="${WARP_ADDRESS_V6%/*}"
    
    log_debug "WARP Private Key: ${WARP_PRIVATE_KEY:0:10}..."
    log_debug "WARP IPv4: ${WARP_ADDRESS_V4}"
    log_debug "WARP IPv6: ${WARP_ADDRESS_V6}"
    log_debug "WARP Public Key: ${WARP_PUBLIC_KEY}"
    log_debug "WARP Endpoint: ${WARP_ENDPOINT}"
    
    log_success "WARP configuration parsed"
}

# =============================================================================
# REGISTER WARP VIA API (ALTERNATIVE)
# =============================================================================
register_warp_api() {
    log_step "Registering WARP via API"
    
    local warp_dir="${MARZBAN_DIR:-/opt/marzban}/warp"
    mkdir -p "${warp_dir}"
    
    # Generate WireGuard keypair
    local private_key
    local public_key
    
    if command -v wg &>/dev/null; then
        private_key=$(wg genkey)
        public_key=$(echo "${private_key}" | wg pubkey)
    else
        # Use openssl as fallback
        private_key=$(openssl rand -base64 32)
        log_warn "WireGuard tools not available, using OpenSSL for key generation"
        log_warn "Consider installing wireguard-tools for proper keys"
        return 1
    fi
    
    # Register with Cloudflare API
    local response
    response=$(curl -s -X POST "${WARP_API}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: okhttp/3.12.1" \
        -d "{
            \"key\": \"${public_key}\",
            \"install_id\": \"\",
            \"fcm_token\": \"\",
            \"tos\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
            \"type\": \"Android\",
            \"locale\": \"en_US\"
        }")
    
    # Parse response
    local config
    config=$(echo "${response}" | jq -r '.config // empty')
    
    if [[ -z "${config}" ]]; then
        log_error "Failed to register WARP account via API"
        log_debug "Response: ${response}"
        return 1
    fi
    
    # Extract configuration
    local cf_private_key
    local cf_public_key
    local ipv4
    local ipv6
    
    cf_private_key="${private_key}"
    cf_public_key=$(echo "${response}" | jq -r '.config.peers[0].public_key')
    ipv4=$(echo "${response}" | jq -r '.config.interface.addresses.v4')
    ipv6=$(echo "${response}" | jq -r '.config.interface.addresses.v6')
    
    # Save configuration
    cat > "${warp_dir}/warp_config.json" << EOF
{
    "private_key": "${cf_private_key}",
    "public_key": "${cf_public_key}",
    "address_v4": "${ipv4}",
    "address_v6": "${ipv6}",
    "endpoint": "engage.cloudflareclient.com:2408"
}
EOF
    
    chmod 600 "${warp_dir}/warp_config.json"
    
    # Export variables
    export WARP_PRIVATE_KEY="${cf_private_key}"
    export WARP_PUBLIC_KEY="${cf_public_key}"
    export WARP_ADDRESS_V4="${ipv4}"
    export WARP_ADDRESS_V6="${ipv6}"
    export WARP_ENDPOINT="engage.cloudflareclient.com:2408"
    
    log_success "WARP account registered via API"
}

# =============================================================================
# GENERATE XRAY WARP OUTBOUND
# =============================================================================
generate_xray_warp_outbound() {
    log_step "Generating Xray WARP Outbound Configuration"
    
    local warp_dir="${MARZBAN_DIR:-/opt/marzban}/warp"
    local output_file="${warp_dir}/warp_outbound.json"
    
    if [[ -z "${WARP_PRIVATE_KEY:-}" ]]; then
        log_error "WARP configuration not available"
        return 1
    fi
    
    # Generate Xray-compatible WARP outbound
    cat > "${output_file}" << EOF
{
    "tag": "warp",
    "protocol": "wireguard",
    "settings": {
        "secretKey": "${WARP_PRIVATE_KEY}",
        "address": [
            "${WARP_ADDRESS_V4_CLEAN:-${WARP_ADDRESS_V4%/*}}/32",
            "${WARP_ADDRESS_V6_CLEAN:-${WARP_ADDRESS_V6%/*}}/128"
        ],
        "peers": [
            {
                "publicKey": "${WARP_PUBLIC_KEY}",
                "allowedIPs": ["0.0.0.0/0", "::/0"],
                "endpoint": "${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}"
            }
        ],
        "reserved": [0, 0, 0],
        "mtu": 1280
    }
}
EOF

    log_success "WARP outbound configuration saved to: ${output_file}"
    
    # Also generate routing rules
    local routing_file="${warp_dir}/warp_routing.json"
    
    cat > "${routing_file}" << 'EOF'
{
    "rules": [
        {
            "type": "field",
            "domain": [
                "geosite:openai",
                "geosite:netflix",
                "geosite:disney",
                "geosite:spotify",
                "geosite:bing"
            ],
            "outboundTag": "warp"
        },
        {
            "type": "field",
            "domain": [
                "domain:openai.com",
                "domain:ai.com",
                "domain:chatgpt.com",
                "domain:anthropic.com",
                "domain:claude.ai",
                "domain:perplexity.ai"
            ],
            "outboundTag": "warp"
        },
        {
            "type": "field",
            "domain": [
                "domain:netflix.com",
                "domain:nflxvideo.net",
                "domain:disneyplus.com",
                "domain:hulu.com",
                "domain:hbomax.com"
            ],
            "outboundTag": "warp"
        }
    ]
}
EOF

    log_success "WARP routing rules saved to: ${routing_file}"
}

# =============================================================================
# TEST WARP CONNECTION
# =============================================================================
test_warp_connection() {
    log_step "Testing WARP Connection"
    
    # This would require the Xray to be running with WARP configured
    # For now, just verify the configuration files exist
    
    local warp_dir="${MARZBAN_DIR:-/opt/marzban}/warp"
    
    if [[ -f "${warp_dir}/warp_outbound.json" ]]; then
        log_info "WARP outbound configuration exists"
        
        # Validate JSON
        if validate_json "${warp_dir}/warp_outbound.json"; then
            log_success "WARP configuration is valid"
        else
            log_error "WARP configuration is invalid"
            return 1
        fi
    else
        log_error "WARP configuration not found"
        return 1
    fi
}

# =============================================================================
# SHOW WARP STATUS
# =============================================================================
show_warp_status() {
    log_step "WARP Status"
    
    local warp_dir="${MARZBAN_DIR:-/opt/marzban}/warp"
    
    echo ""
    echo "WARP Configuration Directory: ${warp_dir}"
    echo ""
    
    if [[ -f "${warp_dir}/wgcf-account.toml" ]]; then
        echo "Account Status: Registered"
        echo ""
        echo "Account Info:"
        grep -E "^(device_id|access_token)" "${warp_dir}/wgcf-account.toml" 2>/dev/null || true
    elif [[ -f "${warp_dir}/warp_config.json" ]]; then
        echo "Account Status: Registered (via API)"
    else
        echo "Account Status: Not Registered"
    fi
    
    echo ""
    
    if [[ -f "${warp_dir}/warp_outbound.json" ]]; then
        echo "Xray Outbound: Configured"
        echo ""
        echo "Configuration:"
        jq '.' "${warp_dir}/warp_outbound.json" 2>/dev/null || cat "${warp_dir}/warp_outbound.json"
    else
        echo "Xray Outbound: Not Configured"
    fi
}

# =============================================================================
# INSTALL WIREGUARD TOOLS (OPTIONAL)
# =============================================================================
install_wireguard_tools() {
    log_info "Installing WireGuard tools..."
    
    if command -v wg &>/dev/null; then
        log_info "WireGuard tools already installed"
        return 0
    fi
    
    install_packages wireguard-tools
    
    log_success "WireGuard tools installed"
}

# =============================================================================
# MAIN WARP SETUP
# =============================================================================
setup_warp() {
    log_step "=== CLOUDFLARE WARP SETUP ==="
    
    if [[ "${ENABLE_WARP:-false}" != "true" ]]; then
        log_info "WARP is disabled. Set ENABLE_WARP=true to enable."
        return 0
    fi
    
    # Install dependencies
    install_wgcf
    
    # Register account
    register_warp_account
    
    # Generate configuration
    generate_warp_config
    
    # Generate Xray outbound
    generate_xray_warp_outbound
    
    # Test configuration
    test_warp_connection
    
    log_success "WARP setup completed"
    
    log_info "To enable WARP in Xray, run: add_warp_outbound"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f install_wgcf
export -f register_warp_account
export -f generate_warp_config
export -f parse_warp_config
export -f register_warp_api
export -f generate_xray_warp_outbound
export -f test_warp_connection
export -f show_warp_status
export -f install_wireguard_tools
export -f setup_warp
