#!/bin/bash
# =============================================================================
# Module: xray.sh
# Description: Xray configuration generation, Reality key generation
# =============================================================================

set -euo pipefail

# Source core module if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# XRAY DOCKER IMAGE
# =============================================================================
readonly XRAY_IMAGE="ghcr.io/xtls/xray-core:latest"

# =============================================================================
# GENERATE X25519 KEYPAIR
# =============================================================================
generate_x25519_keypair() {
    log_info "Generating X25519 keypair for Reality..."
    
    local output
    
    # Use Docker to generate keys
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        output=$(docker run --rm "${XRAY_IMAGE}" x25519 2>/dev/null)
    else
        # Fallback: try local xray binary if available
        if command -v xray &>/dev/null; then
            output=$(xray x25519 2>/dev/null)
        else
            log_error "Neither Docker nor local Xray binary available for key generation"
            return 1
        fi
    fi
    
    # Parse output
    local private_key
    local public_key
    
    private_key=$(echo "${output}" | grep -i "private" | awk '{print $NF}')
    public_key=$(echo "${output}" | grep -i "public" | awk '{print $NF}')
    
    if [[ -z "${private_key}" ]] || [[ -z "${public_key}" ]]; then
        log_error "Failed to parse X25519 keypair"
        return 1
    fi
    
    echo "PRIVATE_KEY=${private_key}"
    echo "PUBLIC_KEY=${public_key}"
    
    export XRAY_PRIVATE_KEY="${private_key}"
    export XRAY_PUBLIC_KEY="${public_key}"
    
    log_success "X25519 keypair generated"
}

# =============================================================================
# GENERATE SHORT ID
# =============================================================================
generate_short_ids() {
    local count="${1:-1}"
    local short_ids=""
    
    for ((i=0; i<count; i++)); do
        local sid
        sid=$(generate_hex 8)
        if [[ -n "${short_ids}" ]]; then
            short_ids+=",\"${sid}\""
        else
            short_ids="\"${sid}\""
        fi
    done
    
    echo "${short_ids}"
}

# =============================================================================
# GENERATE XRAY CONFIGURATION
# =============================================================================
generate_xray_config() {
    log_step "Generating Xray Configuration"
    
    local config_file="${MARZBAN_DIR:-/opt/marzban}/xray_config.json"
    local xray_port="${XRAY_PORT:-8443}"
    local reality_dest="${REALITY_DEST:-www.microsoft.com}"
    local reality_sni="${REALITY_SNI:-www.microsoft.com}"
    
    # Generate keys if not already set
    if [[ -z "${XRAY_PRIVATE_KEY:-}" ]]; then
        eval "$(generate_x25519_keypair)"
    fi
    
    # Generate short IDs
    local short_ids
    short_ids=$(generate_short_ids 3)
    
    # Create config directory
    mkdir -p "$(dirname "${config_file}")"
    
    # Check if template exists
    if [[ -f "${TEMPLATES_DIR}/xray_config.json.tpl" ]]; then
        # Export variables for envsubst
        export XRAY_PORT="${xray_port}"
        export REALITY_DEST="${reality_dest}"
        export REALITY_SNI="${reality_sni}"
        export SHORT_IDS="${short_ids}"
        
        process_template "${TEMPLATES_DIR}/xray_config.json.tpl" "${config_file}"
    else
        # Generate inline
        cat > "${config_file}" << EOF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/lib/marzban/access.log",
        "error": "/var/lib/marzban/error.log"
    },
    "api": {
        "tag": "api",
        "services": [
            "HandlerService",
            "LoggerService",
            "StatsService"
        ]
    },
    "stats": {},
    "policy": {
        "levels": {
            "0": {
                "statsUserUplink": true,
                "statsUserDownlink": true
            }
        },
        "system": {
            "statsInboundUplink": true,
            "statsInboundDownlink": true,
            "statsOutboundUplink": true,
            "statsOutboundDownlink": true
        }
    },
    "inbounds": [
        {
            "tag": "api",
            "listen": "127.0.0.1",
            "port": 62789,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "127.0.0.1"
            }
        },
        {
            "tag": "VLESS_REALITY",
            "listen": "0.0.0.0",
            "port": ${xray_port},
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${reality_dest}:443",
                    "xver": 0,
                    "serverNames": [
                        "${reality_sni}"
                    ],
                    "privateKey": "${XRAY_PRIVATE_KEY}",
                    "shortIds": [
                        ${short_ids}
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "tag": "direct",
            "protocol": "freedom",
            "settings": {}
        },
        {
            "tag": "blocked",
            "protocol": "blackhole",
            "settings": {}
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "inboundTag": [
                    "api"
                ],
                "outboundTag": "api"
            },
            {
                "type": "field",
                "ip": [
                    "geoip:private"
                ],
                "outboundTag": "blocked"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:category-ads-all"
                ],
                "outboundTag": "blocked"
            }
        ]
    }
}
EOF
    fi
    
    # Validate JSON
    if ! validate_json "${config_file}"; then
        log_error "Generated Xray config is invalid JSON"
        return 1
    fi
    
    # Save keys to a secure file for reference
    local keys_file="${MARZBAN_DIR}/reality_keys.txt"
    cat > "${keys_file}" << EOF
# Reality Keys - Generated $(date)
# KEEP THIS FILE SECURE!

PRIVATE_KEY=${XRAY_PRIVATE_KEY}
PUBLIC_KEY=${XRAY_PUBLIC_KEY}
SHORT_IDS=${short_ids}
SNI=${reality_sni}
DEST=${reality_dest}
EOF
    chmod 600 "${keys_file}"
    
    register_rollback "rm -f ${config_file} ${keys_file}"
    
    log_success "Xray configuration generated"
    log_info "Reality Public Key: ${XRAY_PUBLIC_KEY}"
}

# =============================================================================
# ADD WARP OUTBOUND TO CONFIG
# =============================================================================
add_warp_outbound() {
    local config_file="${1:-${MARZBAN_DIR}/xray_config.json}"
    local warp_endpoint="${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}"
    local warp_private_key="${WARP_PRIVATE_KEY:-}"
    local warp_public_key="${WARP_PUBLIC_KEY:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}"
    local warp_address_v4="${WARP_ADDRESS_V4:-172.16.0.2}"
    local warp_address_v6="${WARP_ADDRESS_V6:-2606:4700:110:8a36:df92:102a:9602:fa18}"
    
    if [[ -z "${warp_private_key}" ]]; then
        log_warn "WARP private key not set, skipping WARP outbound"
        return 0
    fi
    
    log_info "Adding WARP outbound to Xray config..."
    
    # Read current config
    local config
    config=$(cat "${config_file}")
    
    # Add WARP outbound using jq
    config=$(echo "${config}" | jq --arg endpoint "${warp_endpoint}" \
        --arg privkey "${warp_private_key}" \
        --arg pubkey "${warp_public_key}" \
        --arg addr4 "${warp_address_v4}" \
        --arg addr6 "${warp_address_v6}" \
        '.outbounds += [{
            "tag": "warp",
            "protocol": "wireguard",
            "settings": {
                "secretKey": $privkey,
                "address": [$addr4 + "/32", $addr6 + "/128"],
                "peers": [{
                    "publicKey": $pubkey,
                    "endpoint": $endpoint
                }],
                "reserved": [0, 0, 0],
                "mtu": 1280
            }
        }]')
    
    # Add routing rules for WARP
    config=$(echo "${config}" | jq '.routing.rules += [
        {
            "type": "field",
            "domain": [
                "geosite:openai",
                "geosite:netflix",
                "geosite:disney",
                "geosite:spotify"
            ],
            "outboundTag": "warp"
        },
        {
            "type": "field",
            "domain": [
                "domain:openai.com",
                "domain:ai.com",
                "domain:chatgpt.com"
            ],
            "outboundTag": "warp"
        }
    ]')
    
    # Write updated config
    echo "${config}" | jq . > "${config_file}"
    
    if validate_json "${config_file}"; then
        log_success "WARP outbound added to Xray config"
    else
        log_error "Failed to add WARP outbound - config invalid"
        return 1
    fi
}

# =============================================================================
# VALIDATE XRAY CONFIG
# =============================================================================
validate_xray_config() {
    local config_file="${1:-${MARZBAN_DIR}/xray_config.json}"
    
    log_info "Validating Xray configuration..."
    
    # Check file exists
    if [[ ! -f "${config_file}" ]]; then
        log_error "Xray config file not found: ${config_file}"
        return 1
    fi
    
    # Validate JSON syntax
    if ! validate_json "${config_file}"; then
        return 1
    fi
    
    # Validate with Xray binary
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        if docker run --rm -v "${config_file}:/config.json:ro" "${XRAY_IMAGE}" test -c /config.json; then
            log_success "Xray configuration is valid"
            return 0
        else
            log_error "Xray configuration validation failed"
            return 1
        fi
    else
        log_warn "Cannot validate with Xray binary (Docker not available)"
        return 0
    fi
}

# =============================================================================
# SHOW XRAY CLIENT CONFIG
# =============================================================================
show_client_config() {
    local uuid="${1:-}"
    local public_key="${XRAY_PUBLIC_KEY:-}"
    local sni="${REALITY_SNI:-www.microsoft.com}"
    local server_ip
    server_ip=$(get_public_ip)
    local port="${XRAY_PORT:-8443}"
    
    if [[ -z "${uuid}" ]]; then
        uuid=$(generate_uuid)
    fi
    
    if [[ -z "${public_key}" ]]; then
        log_error "Public key not available"
        return 1
    fi
    
    # Get first short ID
    local short_id
    short_id=$(generate_hex 8)
    
    log_step "Client Configuration"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  VLESS Reality Client Configuration"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Server:      ${server_ip}"
    echo "  Port:        ${port}"
    echo "  UUID:        ${uuid}"
    echo "  Flow:        xtls-rprx-vision"
    echo "  Encryption:  none"
    echo "  Network:     tcp"
    echo "  Security:    reality"
    echo "  SNI:         ${sni}"
    echo "  Fingerprint: chrome"
    echo "  Public Key:  ${public_key}"
    echo "  Short ID:    ${short_id}"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    # Generate VLESS link
    local vless_link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#VLESS-Reality"
    
    echo "VLESS Link:"
    echo "${vless_link}"
    echo ""
}

# =============================================================================
# MAIN XRAY SETUP
# =============================================================================
setup_xray() {
    log_step "=== XRAY SETUP ==="
    
    # Generate X25519 keypair
    eval "$(generate_x25519_keypair)"
    
    # Generate Xray configuration
    generate_xray_config
    
    # Validate configuration
    validate_xray_config
    
    log_success "Xray setup completed"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f generate_x25519_keypair
export -f generate_short_ids
export -f generate_xray_config
export -f add_warp_outbound
export -f validate_xray_config
export -f show_client_config
export -f setup_xray
