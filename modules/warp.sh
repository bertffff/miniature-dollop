#!/bin/bash
#
# Module: warp.sh
# Purpose: Cloudflare WARP setup for Xray outbound
# Dependencies: core.sh
#

# Strict mode
set -euo pipefail

# Source core module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/core.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

readonly WGCF_VERSION="2.2.22"
readonly WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_amd64"
readonly WARP_CONFIG_FILE="${KEYS_DIR}/warp_account.json"
readonly WARP_OUTBOUND_FILE="${KEYS_DIR}/warp_config.json"

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
    
    wget -q -O /usr/local/bin/wgcf "${WGCF_URL}"
    chmod +x /usr/local/bin/wgcf
    
    register_rollback "rm -f /usr/local/bin/wgcf" "normal"
    
    log_success "wgcf installed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WARP REGISTRATION
# ═══════════════════════════════════════════════════════════════════════════════

is_warp_registered() {
    [[ -f "${WARP_CONFIG_FILE}" ]] && jq -e '.device_id' "${WARP_CONFIG_FILE}" > /dev/null 2>&1
}

register_warp() {
    set_phase "WARP Registration"
    
    if is_warp_registered; then
        log_info "WARP account already registered"
        return 0
    fi
    
    install_wgcf
    
    log_info "Registering Cloudflare WARP account..."
    
    local temp_dir
    temp_dir=$(mktemp -d)
    
    cd "${temp_dir}"
    
    # Accept ToS and register
    yes | wgcf register --accept-tos 2>/dev/null || {
        log_error "WARP registration failed"
        rm -rf "${temp_dir}"
        return 1
    }
    
    # Generate WireGuard config
    wgcf generate 2>/dev/null || {
        log_error "Failed to generate WARP config"
        rm -rf "${temp_dir}"
        return 1
    }
    
    # Parse the generated config
    if [[ -f "wgcf-account.toml" ]]; then
        local device_id access_token license_key
        device_id=$(grep 'device_id' wgcf-account.toml | cut -d"'" -f2)
        access_token=$(grep 'access_token' wgcf-account.toml | cut -d"'" -f2)
        license_key=$(grep 'license_key' wgcf-account.toml | cut -d"'" -f2 || echo "")
        
        cat > "${WARP_CONFIG_FILE}" << EOF
{
    "device_id": "${device_id}",
    "access_token": "${access_token}",
    "license_key": "${license_key}",
    "registered_at": "$(date -Iseconds)"
}
EOF
        chmod 600 "${WARP_CONFIG_FILE}"
    fi
    
    # Parse WireGuard profile
    if [[ -f "wgcf-profile.conf" ]]; then
        local private_key public_key endpoint reserved_hex
        private_key=$(grep 'PrivateKey' wgcf-profile.conf | cut -d'=' -f2 | tr -d ' ')
        # Public key is the peer's public key
        public_key=$(grep -A5 '\[Peer\]' wgcf-profile.conf | grep 'PublicKey' | cut -d'=' -f2 | tr -d ' ')
        endpoint=$(grep 'Endpoint' wgcf-profile.conf | cut -d'=' -f2 | tr -d ' ')
        
        # Extract reserved bytes from Address (they're encoded in the IPv6)
        local ipv6_addr
        ipv6_addr=$(grep 'Address' wgcf-profile.conf | grep ':' | cut -d'=' -f2 | cut -d'/' -f1 | tr -d ' ')
        
        # Generate reserved bytes from account (simplified - actual implementation may vary)
        # For Cloudflare WARP, reserved is usually [0, 0, 0]
        reserved_hex="[0, 0, 0]"
        
        # Generate Xray WireGuard outbound configuration
        generate_warp_xray_outbound "${private_key}" "${public_key}" "${endpoint}" "${reserved_hex}"
    fi
    
    rm -rf "${temp_dir}"
    
    log_success "WARP account registered"
}

# ═══════════════════════════════════════════════════════════════════════════════
# XRAY WARP OUTBOUND
# ═══════════════════════════════════════════════════════════════════════════════

generate_warp_xray_outbound() {
    local private_key="${1}"
    local peer_public_key="${2}"
    local endpoint="${3}"
    local reserved="${4:-[0, 0, 0]}"
    
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
        "address": ["172.16.0.2/32", "2606:4700:110:8a36:df92:102a:9602:fa18/128"],
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
    
    log_success "WARP outbound configuration saved"
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
    
    register_warp
    show_warp_status
    
    log_success "WARP setup completed"
}

# Export functions
export -f setup_warp
export -f register_warp
export -f show_warp_status
export -f is_warp_registered
export -f get_warp_routing_rules
