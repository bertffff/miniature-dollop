#!/bin/bash
#
# Module: warp.sh
# Purpose: Cloudflare WARP setup with automatic WARP+ key generation
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

# GitHub releases for warp-go and warp-api
readonly WARP_GO_VERSION="1.3.11"
readonly WARP_GO_URL="https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/warp-go/warp-go-latest-linux-amd64"
readonly WARP_API_URL="https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/warp-api/warp-api-latest-linux-amd64"

# Local paths
readonly WARP_TOOLS_DIR="${TOOLS_DIR}/warp"
readonly WARP_GO_BIN="${WARP_TOOLS_DIR}/warp-go"
readonly WARP_API_BIN="${WARP_TOOLS_DIR}/warp-api"
readonly WARP_CONFIG_FILE="${KEYS_DIR}/warp.conf"
readonly WARP_PROXY_FILE="${KEYS_DIR}/warp-proxy.conf"
readonly WARP_KEY_FILE="${KEYS_DIR}/warp-plus-key.txt"
readonly WARP_OUTBOUND_FILE="${KEYS_DIR}/warp_config.json"

# Cloudflare WARP endpoints
readonly WARP_ENDPOINT_V4="162.159.192.8"
readonly WARP_ENDPOINT_V6="2606:4700:d0::a29f:c008"
readonly WARP_PEER_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITIES INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

download_warp_tools() {
    set_phase "WARP Tools Download"
    
    log_info "Downloading WARP utilities..."
    
    mkdir -p "${WARP_TOOLS_DIR}"
    
    # Download warp-go
    if [[ ! -f "${WARP_GO_BIN}" ]]; then
        log_info "Downloading warp-go..."
        if wget -q -O "${WARP_GO_BIN}" "${WARP_GO_URL}"; then
            chmod +x "${WARP_GO_BIN}"
            log_success "warp-go downloaded"
        else
            log_error "Failed to download warp-go"
            return 1
        fi
    else
        log_info "warp-go already exists"
    fi
    
    # Download warp-api
    if [[ ! -f "${WARP_API_BIN}" ]]; then
        log_info "Downloading warp-api..."
        if wget -q -O "${WARP_API_BIN}" "${WARP_API_URL}"; then
            chmod +x "${WARP_API_BIN}"
            log_success "warp-api downloaded"
        else
            log_error "Failed to download warp-api"
            return 1
        fi
    else
        log_info "warp-api already exists"
    fi
    
    register_rollback "rm -rf ${WARP_TOOLS_DIR}" "cleanup"
    
    log_success "WARP tools ready"
}

install_python_deps() {
    log_info "Installing Python dependencies for WARP+ key generator..."
    
    # Check Python 3
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 not found"
        return 1
    fi
    
    # Install httpx
    if ! python3 -c "import httpx" 2>/dev/null; then
        log_info "Installing httpx..."
        pip3 install httpx --break-system-packages 2>/dev/null || \
        python3 -m pip install httpx --break-system-packages 2>/dev/null || {
            log_warn "Could not install httpx via pip, trying apt..."
            apt-get install -y python3-httpx 2>/dev/null || {
                log_error "Failed to install httpx"
                return 1
            }
        }
    fi
    
    # Install requests
    if ! python3 -c "import requests" 2>/dev/null; then
        log_info "Installing requests..."
        pip3 install requests --break-system-packages 2>/dev/null || \
        python3 -m pip install requests --break-system-packages 2>/dev/null || \
        apt-get install -y python3-requests 2>/dev/null || true
    fi
    
    log_success "Python dependencies installed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WARP+ KEY GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_warp_plus_key() {
    log_step "WARP+ Key Generation"
    
    # Check if key already exists
    if [[ -f "${WARP_KEY_FILE}" ]]; then
        local existing_key
        existing_key=$(cat "${WARP_KEY_FILE}")
        if [[ -n "${existing_key}" ]] && [[ "${existing_key}" =~ ^[A-Z0-9a-z]{8}-[A-Z0-9a-z]{8}-[A-Z0-9a-z]{8}$ ]]; then
            log_info "WARP+ key already exists: ${existing_key}"
            export WARP_PLUS_KEY="${existing_key}"
            return 0
        fi
    fi
    
    log_info "Generating new WARP+ key..."
    
    # Install Python dependencies
    install_python_deps || {
        log_error "Failed to install Python dependencies"
        return 1
    }
    
    # Call the Python generator
    local generator_script="${TOOLS_DIR}/warp-plus-keygen.py"
    
    if [[ ! -f "${generator_script}" ]]; then
        log_error "WARP+ key generator script not found: ${generator_script}"
        return 1
    fi
    
    local generated_key
    generated_key=$(python3 "${generator_script}" 2>/dev/null | grep -oP '^[A-Z0-9a-z]{8}-[A-Z0-9a-z]{8}-[A-Z0-9a-z]{8}$' | head -1)
    
    if [[ -z "${generated_key}" ]]; then
        log_error "Failed to generate WARP+ key"
        return 1
    fi
    
    # Save key
    echo "${generated_key}" > "${WARP_KEY_FILE}"
    chmod 600 "${WARP_KEY_FILE}"
    
    export WARP_PLUS_KEY="${generated_key}"
    
    log_success "WARP+ key generated: ${generated_key}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WARP ACCOUNT REGISTRATION
# ═══════════════════════════════════════════════════════════════════════════════

register_warp_account() {
    local account_type="${1:-free}"  # free, plus, teams
    local license_key="${2:-}"
    
    log_step "WARP Account Registration (${account_type})"
    
    # Generate initial account using warp-api
    log_info "Creating WARP account..."
    
    cd "${WARP_TOOLS_DIR}" || return 1
    
    local result_output
    result_output=$("${WARP_API_BIN}" 2>&1)
    
    local device_id private_key warp_token
    device_id=$(echo "$result_output" | awk -F ': ' '/device_id/{print $2}')
    private_key=$(echo "$result_output" | awk -F ': ' '/private_key/{print $2}')
    warp_token=$(echo "$result_output" | awk -F ': ' '/token/{print $2}')
    
    if [[ -z "${device_id}" ]] || [[ -z "${private_key}" ]] || [[ -z "${warp_token}" ]]; then
        log_error "Failed to parse warp-api output"
        log_debug "Output: ${result_output}"
        return 1
    fi
    
    log_success "WARP account created"
    log_info "Device ID: ${device_id}"
    
    # Create base configuration
    cat > "${WARP_CONFIG_FILE}" << EOF
[Account]
Device = ${device_id}
PrivateKey = ${private_key}
Token = ${warp_token}
Type = free
Name = WARP
MTU = 1280

[Peer]
PublicKey = ${WARP_PEER_PUBLIC_KEY}
Endpoint = ${WARP_ENDPOINT_V4}:0
Endpoint6 = [${WARP_ENDPOINT_V6}]:0
KeepAlive = 30
EOF
    
    chmod 600 "${WARP_CONFIG_FILE}"
    
    # Upgrade to WARP+ if key provided or account_type is plus
    if [[ "${account_type}" == "plus" ]]; then
        if [[ -z "${license_key}" ]]; then
            # Generate WARP+ key
            generate_warp_plus_key || {
                log_warn "Failed to generate WARP+ key, using free account"
                return 0
            }
            license_key="${WARP_PLUS_KEY}"
        fi
        
        log_info "Upgrading to WARP+..."
        
        local device_name
        device_name="marzban-$(date +%s%N | md5sum | cut -c 1-6)"
        
        if "${WARP_GO_BIN}" --update --config="${WARP_CONFIG_FILE}" --license="${license_key}" --device-name="${device_name}" 2>&1; then
            log_success "Upgraded to WARP+"
            sed -i 's/Type = free/Type = plus/' "${WARP_CONFIG_FILE}"
        else
            log_warn "Failed to upgrade to WARP+, using free account"
        fi
    fi
    
    # Export WireGuard configuration
    log_info "Generating WireGuard proxy configuration..."
    
    if "${WARP_GO_BIN}" --config="${WARP_CONFIG_FILE}" --export-wireguard="${WARP_PROXY_FILE}" 2>&1; then
        log_success "WireGuard configuration exported"
    else
        log_error "Failed to export WireGuard configuration"
        return 1
    fi
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# XRAY WARP OUTBOUND GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_xray_warp_outbound() {
    log_step "Xray WARP Outbound Generation"
    
    if [[ ! -f "${WARP_PROXY_FILE}" ]]; then
        log_error "WARP proxy configuration not found"
        return 1
    fi
    
    log_info "Parsing WireGuard configuration..."
    
    # Parse WireGuard config
    local private_key address endpoint peer_public_key allowed_ips
    
    while IFS= read -r line; do
        if [[ "${line}" =~ ^PrivateKey[[:space:]]*=[[:space:]]*(.*) ]]; then
            private_key="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^Address[[:space:]]*=[[:space:]]*(.*) ]]; then
            address="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^Endpoint[[:space:]]*=[[:space:]]*(.*) ]]; then
            endpoint="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*) ]]; then
            peer_public_key="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.*) ]]; then
            allowed_ips="${BASH_REMATCH[1]}"
        fi
    done < "${WARP_PROXY_FILE}"
    
    # Extract IPv4 and IPv6 from address
    local ipv4 ipv6
    if [[ "${address}" == *","* ]]; then
        ipv4=$(echo "${address}" | cut -d',' -f1 | tr -d ' ')
        ipv6=$(echo "${address}" | cut -d',' -f2 | tr -d ' ')
    else
        ipv4="${address}"
        ipv6="2606:4700:110::/128"  # Default if not present
    fi
    
    # Parse endpoint
    local endpoint_host endpoint_port
    endpoint_host="${endpoint%:*}"
    endpoint_port="${endpoint##*:}"
    
    log_info "Creating Xray outbound configuration..."
    
    # Generate Xray-compatible outbound
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
        "reserved": [0, 0, 0],
        "mtu": 1280,
        "workers": 2
    }
}
EOF
    
    chmod 600 "${WARP_OUTBOUND_FILE}"
    
    # Validate JSON
    if ! jq . "${WARP_OUTBOUND_FILE}" > /dev/null 2>&1; then
        log_error "Generated Xray outbound is invalid JSON"
        return 1
    fi
    
    log_success "Xray WARP outbound generated: ${WARP_OUTBOUND_FILE}"
    
    # Display config summary
    log_info "═══════════════════════════════════════════════════════"
    log_info "WARP Configuration Summary:"
    log_info "  Private Key: ${private_key:0:20}..."
    log_info "  IPv4: ${ipv4}"
    log_info "  IPv6: ${ipv6}"
    log_info "  Endpoint: ${endpoint}"
    log_info "  Peer Public Key: ${peer_public_key:0:20}..."
    log_info "═══════════════════════════════════════════════════════"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WARP ROUTING RULES
# ═══════════════════════════════════════════════════════════════════════════════

get_warp_routing_rules() {
    cat << 'EOF'
[
    {
        "type": "field",
        "domain": ["geosite:openai", "domain:anthropic.com", "domain:claude.ai"],
        "outboundTag": "warp"
    },
    {
        "type": "field",
        "domain": ["geosite:netflix", "geosite:spotify"],
        "outboundTag": "warp"
    },
    {
        "type": "field",
        "domain": ["geosite:google", "geosite:youtube"],
        "outboundTag": "warp"
    }
]
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATUS AND TESTING
# ═══════════════════════════════════════════════════════════════════════════════

show_warp_status() {
    echo ""
    log_info "═══ WARP Status ═══"
    
    if [[ -f "${WARP_CONFIG_FILE}" ]]; then
        echo "✓ WARP account: Registered"
        
        local account_type
        account_type=$(grep -E "^Type = " "${WARP_CONFIG_FILE}" | cut -d'=' -f2 | tr -d ' ')
        echo "  Account Type: ${account_type}"
        
        if [[ -f "${WARP_KEY_FILE}" ]]; then
            local key
            key=$(cat "${WARP_KEY_FILE}")
            echo "  WARP+ Key: ${key}"
        fi
        
        if [[ -f "${WARP_OUTBOUND_FILE}" ]]; then
            echo "✓ Xray outbound: Generated"
        else
            echo "✗ Xray outbound: Not generated"
        fi
    else
        echo "✗ WARP account: Not registered"
    fi
    
    echo ""
}

test_warp_config() {
    log_info "Testing WARP configuration..."
    
    if [[ ! -f "${WARP_OUTBOUND_FILE}" ]]; then
        log_error "WARP outbound configuration not found"
        return 1
    fi
    
    if validate_json "${WARP_OUTBOUND_FILE}"; then
        log_success "WARP configuration is valid"
        return 0
    else
        log_error "WARP configuration is invalid"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_warp() {
    set_phase "WARP Setup"
    
    if [[ "${PROFILE_WARP_ENABLED:-false}" != "true" ]]; then
        log_info "WARP profile not enabled, skipping"
        return 0
    fi
    
    # Download tools
    download_warp_tools || {
        log_error "Failed to download WARP tools"
        return 1
    }
    
    # Determine account type
    local account_type="plus"  # Default to WARP+ with auto-generated key
    
    # Register account
    if register_warp_account "${account_type}"; then
        log_success "WARP account registered"
    else
        log_error "═══════════════════════════════════════════════════════"
        log_error "WARP Registration Failed"
        log_error "═══════════════════════════════════════════════════════"
        
        if ask_yes_no "Continue installation without WARP profile?" "y"; then
            export PROFILE_WARP_ENABLED="false"
            log_info "WARP profile disabled, continuing..."
            return 0
        else
            return 1
        fi
    fi
    
    # Generate Xray outbound
    if generate_xray_warp_outbound; then
        log_success "Xray WARP outbound configured"
    else
        log_error "Failed to generate Xray outbound"
        return 1
    fi
    
    # Show status
    show_warp_status
    
    log_success "WARP setup completed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════

cleanup_warp() {
    log_info "Cleaning up WARP temporary files..."
    
    rm -f "${WARP_TOOLS_DIR}"/*.log
    rm -f "${WARP_TOOLS_DIR}"/wgcf-*.toml
    
    log_success "WARP cleanup completed"
}

# Export functions
export -f setup_warp
export -f generate_warp_plus_key
export -f show_warp_status
export -f test_warp_config
export -f get_warp_routing_rules
