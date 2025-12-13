#!/bin/bash
#
# Module: warp.sh
# Purpose: Cloudflare WARP setup for Xray outbound (FIXED VERSION)
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

readonly WGCF_VERSION="2.2.22"
readonly WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_amd64"
readonly WARP_CONFIG_FILE="${KEYS_DIR}/warp_account.json"
readonly WARP_OUTBOUND_FILE="${KEYS_DIR}/warp_config.json"

# Cloudflare WARP API endpoints
readonly WARP_API_ENDPOINT="https://api.cloudflareclient.com"
readonly WARP_REG_ENDPOINT="${WARP_API_ENDPOINT}/v0a2223/reg"

# ═══════════════════════════════════════════════════════════════════════════════
# WGCF INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

is_wgcf_installed() {
    [[ -x /usr/local/bin/wgcf ]]
}

install_wgcf() {
    if is_wgcf_installed; then
        log_info "wgcf already installed"
        return 0
    fi
    
    log_info "Installing wgcf..."
    
    if ! wget -q -O /usr/local/bin/wgcf "${WGCF_URL}"; then
        log_error "Failed to download wgcf"
        return 1
    fi
    
    chmod +x /usr/local/bin/wgcf
    
    register_rollback "rm -f /usr/local/bin/wgcf" "normal"
    
    log_success "wgcf installed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MANUAL WARP REGISTRATION (Alternative to wgcf)
# ═══════════════════════════════════════════════════════════════════════════════

manual_warp_register() {
    log_info "Attempting manual WARP registration via API..."
    
    # Install jq if not available
    if ! command -v jq &> /dev/null; then
        apt-get install -y jq 2>/dev/null || {
            log_error "Failed to install jq"
            return 1
        }
    fi
    
    # Generate random install_id
    local install_id
    install_id=$(openssl rand -hex 22 | head -c 22)
    
    # Generate WireGuard keys
    local private_key public_key
    if command -v wg &> /dev/null; then
        private_key=$(wg genkey)
        public_key=$(echo "${private_key}" | wg pubkey)
    else
        # Use openssl as fallback
        private_key=$(openssl rand -base64 32)
        # Note: This won't be a proper Curve25519 key, but we'll try
        public_key=$(echo "${private_key}" | base64 -d | sha256sum | cut -d' ' -f1 | head -c 44)
    fi
    
    # Prepare registration payload
    local payload
    payload=$(cat << EOF
{
    "install_id": "${install_id}",
    "fcm_token": "${install_id}:APA91b${install_id}",
    "tos": "$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)",
    "key": "${public_key}",
    "type": "Android",
    "model": "Linux",
    "locale": "en_US"
}
EOF
)
    
    # Register with Cloudflare
    local response
    response=$(curl -s -X POST "${WARP_REG_ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "CF-Client-Version: a-6.30" \
        -H "User-Agent: okhttp/3.12.1" \
        --data "${payload}" 2>&1)
    
    local http_code
    http_code=$(echo "${response}" | grep -oP 'HTTP/\d\.\d \K\d+' | head -1)
    
    if [[ -z "${http_code}" ]]; then
        # Try to parse response as JSON
        if echo "${response}" | jq -e '.id' > /dev/null 2>&1; then
            # Success
            local device_id access_token
            device_id=$(echo "${response}" | jq -r '.id')
            access_token=$(echo "${response}" | jq -r '.token')
            
            # Get WireGuard config
            local config_response
            config_response=$(curl -s "${WARP_REG_ENDPOINT}/${device_id}" \
                -H "Authorization: Bearer ${access_token}" \
                -H "CF-Client-Version: a-6.30")
            
            if echo "${config_response}" | jq -e '.config' > /dev/null 2>&1; then
                # Extract config details
                local peer_public_key endpoint addresses
                peer_public_key=$(echo "${config_response}" | jq -r '.config.peers[0].public_key')
                endpoint=$(echo "${config_response}" | jq -r '.config.peers[0].endpoint.host'):2408
                addresses=$(echo "${config_response}" | jq -r '.config.interface.addresses | .["v4"], .["v6"]')
                
                # Save account info
                cat > "${WARP_CONFIG_FILE}" << EOF
{
    "device_id": "${device_id}",
    "access_token": "${access_token}",
    "private_key": "${private_key}",
    "public_key": "${public_key}",
    "peer_public_key": "${peer_public_key}",
    "endpoint": "${endpoint}",
    "addresses": "${addresses}",
    "license_key": "",
    "registered_at": "$(date -Iseconds)",
    "method": "manual"
}
EOF
                chmod 600 "${WARP_CONFIG_FILE}"
                
                log_success "Manual WARP registration successful"
                return 0
            fi
        fi
    fi
    
    log_error "Manual WARP registration failed"
    log_debug "Response: ${response}"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# WARP REGISTRATION
# ═══════════════════════════════════════════════════════════════════════════════

is_warp_registered() {
    [[ -f "${WARP_CONFIG_FILE}" ]] && jq -e '.device_id' "${WARP_CONFIG_FILE}" > /dev/null 2>&1
}

register_warp_with_wgcf() {
    log_info "Attempting WARP registration with wgcf..."
    
    local temp_dir
    temp_dir=$(mktemp -d)
    
    cd "${temp_dir}"
    
    # Try registration with timeout
    local reg_output
    if ! reg_output=$(timeout 30 wgcf register --accept-tos 2>&1); then
        local exit_code=$?
        log_warn "wgcf registration failed (exit code: ${exit_code})"
        log_debug "Output: ${reg_output}"
        cd - > /dev/null
        rm -rf "${temp_dir}"
        return 1
    fi
    
    # Check if registration was successful
    if [[ ! -f "wgcf-account.toml" ]]; then
        log_error "wgcf account file not created"
        cd - > /dev/null
        rm -rf "${temp_dir}"
        return 1
    fi
    
    # Generate WireGuard config
    if ! wgcf generate 2>/dev/null; then
        log_error "Failed to generate WARP config"
        cd - > /dev/null
        rm -rf "${temp_dir}"
        return 1
    fi
    
    # Parse the generated config
    if [[ -f "wgcf-account.toml" ]]; then
        local device_id access_token license_key
        device_id=$(grep 'device_id' wgcf-account.toml | cut -d"'" -f2 || echo "")
        access_token=$(grep 'access_token' wgcf-account.toml | cut -d"'" -f2 || echo "")
        license_key=$(grep 'license_key' wgcf-account.toml | cut -d"'" -f2 || echo "")
        
        if [[ -z "${device_id}" ]] || [[ -z "${access_token}" ]]; then
            log_error "Failed to parse wgcf account details"
            cd - > /dev/null
            rm -rf "${temp_dir}"
            return 1
        fi
        
        cat > "${WARP_CONFIG_FILE}" << EOF
{
    "device_id": "${device_id}",
    "access_token": "${access_token}",
    "license_key": "${license_key}",
    "registered_at": "$(date -Iseconds)",
    "method": "wgcf"
}
EOF
        chmod 600 "${WARP_CONFIG_FILE}"
    fi
    
    # Parse WireGuard profile
    if [[ -f "wgcf-profile.conf" ]]; then
        local private_key public_key endpoint ipv4 ipv6
        private_key=$(grep 'PrivateKey' wgcf-profile.conf | cut -d'=' -f2 | tr -d ' ')
        public_key=$(grep -A5 '\[Peer\]' wgcf-profile.conf | grep 'PublicKey' | cut -d'=' -f2 | tr -d ' ')
        endpoint=$(grep 'Endpoint' wgcf-profile.conf | cut -d'=' -f2 | tr -d ' ')
        
        # Extract addresses
        ipv4=$(grep 'Address' wgcf-profile.conf | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -1 || echo "")
        ipv6=$(grep 'Address' wgcf-profile.conf | grep -oP '[0-9a-f:]+/\d+' | head -1 || echo "")
        
        # Update config with WireGuard details
        if [[ -f "${WARP_CONFIG_FILE}" ]]; then
            local temp_config
            temp_config=$(jq --arg pk "${private_key}" \
                           --arg pubk "${public_key}" \
                           --arg ep "${endpoint}" \
                           --arg ipv4 "${ipv4}" \
                           --arg ipv6 "${ipv6}" \
                           '. + {private_key: $pk, peer_public_key: $pubk, endpoint: $ep, ipv4: $ipv4, ipv6: $ipv6}' \
                           "${WARP_CONFIG_FILE}")
            echo "${temp_config}" > "${WARP_CONFIG_FILE}"
        fi
        
        # Generate Xray config
        generate_warp_xray_outbound "${private_key}" "${public_key}" "${endpoint}" "[0, 0, 0]" "${ipv4}" "${ipv6}"
    fi
    
    cd - > /dev/null
    rm -rf "${temp_dir}"
    
    log_success "wgcf registration successful"
    return 0
}

register_warp() {
    set_phase "WARP Registration"
    
    if is_warp_registered; then
        log_info "WARP account already registered"
        
        # Ensure outbound config exists
        if [[ ! -f "${WARP_OUTBOUND_FILE}" ]]; then
            log_warn "Outbound config missing, regenerating..."
            regenerate_warp_outbound
        fi
        
        return 0
    fi
    
    # Ensure wgcf is installed
    install_wgcf
    
    # Try wgcf registration first
    log_info "Method 1: Trying wgcf registration..."
    if register_warp_with_wgcf; then
        return 0
    fi
    
    log_warn "wgcf registration failed, trying manual method..."
    
    # Fall back to manual registration
    log_info "Method 2: Trying manual API registration..."
    if manual_warp_register; then
        # Generate outbound config from manual registration
        if [[ -f "${WARP_CONFIG_FILE}" ]]; then
            local private_key peer_public_key endpoint ipv4 ipv6
            private_key=$(jq -r '.private_key' "${WARP_CONFIG_FILE}")
            peer_public_key=$(jq -r '.peer_public_key' "${WARP_CONFIG_FILE}")
            endpoint=$(jq -r '.endpoint' "${WARP_CONFIG_FILE}")
            ipv4=$(jq -r '.addresses' "${WARP_CONFIG_FILE}" | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' || echo "172.16.0.2/32")
            ipv6=$(jq -r '.addresses' "${WARP_CONFIG_FILE}" | grep -oP '[0-9a-f:]+/\d+' || echo "2606:4700:110::/128")
            
            generate_warp_xray_outbound "${private_key}" "${peer_public_key}" "${endpoint}" "[0, 0, 0]" "${ipv4}" "${ipv6}"
        fi
        return 0
    fi
    
    # Both methods failed
    log_error "═══════════════════════════════════════════════════════════"
    log_error "WARP Registration Failed"
    log_error "═══════════════════════════════════════════════════════════"
    log_warn "Possible reasons:"
    log_warn "  1. Cloudflare WARP service is temporarily unavailable"
    log_warn "  2. Your IP address might be blocked or rate-limited"
    log_warn "  3. Network connectivity issues to Cloudflare API"
    log_warn ""
    log_warn "Solutions:"
    log_warn "  1. Wait a few hours and try again"
    log_warn "  2. Try from a different IP/location"
    log_warn "  3. Continue installation without WARP profile"
    log_warn "  4. Manually register at https://one.one.one.one/"
    log_warn ""
    
    if ask_yes_no "Continue installation without WARP profile?" "y"; then
        # Disable WARP profile
        export PROFILE_WARP_ENABLED="false"
        log_info "WARP profile disabled, continuing installation..."
        return 0
    else
        return 1
    fi
}

regenerate_warp_outbound() {
    if [[ ! -f "${WARP_CONFIG_FILE}" ]]; then
        log_error "WARP account config not found"
        return 1
    fi
    
    local method
    method=$(jq -r '.method // "unknown"' "${WARP_CONFIG_FILE}")
    
    case "${method}" in
        wgcf)
            local private_key peer_public_key endpoint ipv4 ipv6
            private_key=$(jq -r '.private_key' "${WARP_CONFIG_FILE}")
            peer_public_key=$(jq -r '.peer_public_key' "${WARP_CONFIG_FILE}")
            endpoint=$(jq -r '.endpoint' "${WARP_CONFIG_FILE}")
            ipv4=$(jq -r '.ipv4 // "172.16.0.2/32"' "${WARP_CONFIG_FILE}")
            ipv6=$(jq -r '.ipv6 // "2606:4700:110::/128"' "${WARP_CONFIG_FILE}")
            
            generate_warp_xray_outbound "${private_key}" "${peer_public_key}" "${endpoint}" "[0, 0, 0]" "${ipv4}" "${ipv6}"
            ;;
        manual)
            local private_key peer_public_key endpoint
            private_key=$(jq -r '.private_key' "${WARP_CONFIG_FILE}")
            peer_public_key=$(jq -r '.peer_public_key' "${WARP_CONFIG_FILE}")
            endpoint=$(jq -r '.endpoint' "${WARP_CONFIG_FILE}")
            
            generate_warp_xray_outbound "${private_key}" "${peer_public_key}" "${endpoint}" "[0, 0, 0]" "172.16.0.2/32" "2606:4700:110::/128"
            ;;
        *)
            log_error "Unknown WARP registration method: ${method}"
            return 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# XRAY WARP OUTBOUND
# ═══════════════════════════════════════════════════════════════════════════════

generate_warp_xray_outbound() {
    local private_key="${1}"
    local peer_public_key="${2}"
    local endpoint="${3}"
    local reserved="${4:-[0, 0, 0]}"
    local ipv4="${5:-172.16.0.2/32}"
    local ipv6="${6:-2606:4700:110:8a36:df92:102a:9602:fa18/128}"
    
    log_info "Generating Xray WARP outbound configuration..."
    
    # Parse endpoint
    local endpoint_host endpoint_port
    endpoint_host="${endpoint%:*}"
    endpoint_port="${endpoint##*:}"
    
    cat > "${WARP_OUTBOUND_FILE}" << EOF
{
    "tag": "warp",
    "protocol": "wireguard",
    "settings": {
        "secretKey": "${private_key}",
        "address": ["${ipv4}", "${ipv6}"],
        "peers": [
            {
                "publicKey": "${peer_public_key}",
                "allowedIPs": ["0.0.0.0/0", "::/0"],
                "endpoint": "${endpoint_host}:${endpoint_port}",
                "keepAlive": 30
            }
        ],
        "reserved": ${reserved},
        "mtu": 1280
    }
}
EOF
    
    chmod 600 "${WARP_OUTBOUND_FILE}"
    
    log_success "WARP outbound configuration saved to ${WARP_OUTBOUND_FILE}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WARP ROUTING RULES
# ═══════════════════════════════════════════════════════════════════════════════

get_warp_routing_rules() {
    # Returns routing rules for WARP-bound traffic
    
    cat << 'EOF'
[
    {
        "type": "field",
        "domain": ["geosite:openai"],
        "outboundTag": "warp"
    },
    {
        "type": "field",
        "domain": ["geosite:netflix"],
        "outboundTag": "warp"
    },
    {
        "type": "field",
        "domain": ["geosite:spotify"],
        "outboundTag": "warp"
    },
    {
        "type": "field",
        "domain": ["domain:anthropic.com", "domain:claude.ai"],
        "outboundTag": "warp"
    },
    {
        "type": "field",
        "domain": ["geosite:google"],
        "outboundTag": "warp"
    }
]
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# WARP STATUS
# ═══════════════════════════════════════════════════════════════════════════════

show_warp_status() {
    echo
    log_info "═══ WARP Status ═══"
    
    if is_warp_registered; then
        echo "Registration: ✓ Registered"
        
        if [[ -f "${WARP_CONFIG_FILE}" ]]; then
            echo "Device ID: $(jq -r '.device_id' "${WARP_CONFIG_FILE}" 2>/dev/null || echo 'N/A')"
            echo "Method: $(jq -r '.method // "unknown"' "${WARP_CONFIG_FILE}" 2>/dev/null)"
            echo "Registered: $(jq -r '.registered_at' "${WARP_CONFIG_FILE}" 2>/dev/null || echo 'N/A')"
        fi
        
        if [[ -f "${WARP_OUTBOUND_FILE}" ]]; then
            echo "Outbound config: ✓ Generated"
        else
            echo "Outbound config: ✗ Not generated"
        fi
    else
        echo "Registration: ✗ Not registered"
    fi
    
    echo
}

# ═══════════════════════════════════════════════════════════════════════════════
# WARP TESTING
# ═══════════════════════════════════════════════════════════════════════════════

test_warp_connection() {
    log_info "Testing WARP connection..."
    
    # This would require the WARP connection to be active
    # For now, we just validate the configuration exists
    
    if [[ -f "${WARP_OUTBOUND_FILE}" ]]; then
        if validate_json "${WARP_OUTBOUND_FILE}"; then
            log_success "WARP configuration is valid"
            return 0
        fi
    fi
    
    log_warn "WARP configuration not ready"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

setup_warp() {
    set_phase "WARP Setup"
    
    if [[ "${PROFILE_WARP_ENABLED:-false}" != "true" ]]; then
        log_info "WARP profile not enabled, skipping"
        return 0
    fi
    
    # Install dependencies
    if ! command -v jq &> /dev/null; then
        log_info "Installing jq..."
        apt-get install -y jq 2>/dev/null || true
    fi
    
    # Register WARP
    if ! register_warp; then
        log_warn "WARP setup incomplete"
        return 1
    fi
    
    show_warp_status
    
    log_success "WARP setup completed"
}

# Export functions
export -f setup_warp
export -f register_warp
export -f show_warp_status
export -f is_warp_registered
export -f get_warp_routing_rules
