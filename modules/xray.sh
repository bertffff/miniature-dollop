#!/bin/bash
#
# Module: xray.sh
# Purpose: Xray key generation and configuration
# Dependencies: core.sh
#
# ИСПРАВЛЕНО: Xray слушает ТОЛЬКО на 127.0.0.1
# - Внешний порт 443 обрабатывается nginx stream
# - Reality inbound на 127.0.0.1:8443
# - WebSocket inbound на 127.0.0.1:8444

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

if [[ -z "${KEYS_DIR:-}" ]]; then
    readonly KEYS_DIR="${DATA_DIR:-/opt/marzban-installer/data}/keys"
fi

if [[ -z "${KEYS_FILE:-}" ]]; then
    readonly KEYS_FILE="${KEYS_DIR}/reality_keys.json"
fi

if [[ -z "${MARZBAN_DATA:-}" ]]; then
    readonly MARZBAN_DATA="${MARZBAN_DATA:-/var/lib/marzban}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# REALITY KEY GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_reality_keys() {
    set_phase "Reality Key Generation"
    
    log_info "Generating Reality keys..."
    
    mkdir -p "${KEYS_DIR}"
    
    # Check if keys already exist
    if [[ -f "${KEYS_FILE}" ]]; then
        log_info "Reality keys already exist"
        return 0
    fi
    
    # Check if xray is available
    local xray_cmd=""
    if command -v xray &>/dev/null; then
        xray_cmd="xray"
    elif docker exec marzban which xray &>/dev/null 2>&1; then
        xray_cmd="docker exec marzban xray"
    else
        log_warn "Xray not found, generating keys with openssl..."
        generate_reality_keys_openssl
        return $?
    fi
    
    # Generate keypair using xray
    local keypair
    keypair=$(${xray_cmd} x25519 2>/dev/null)
    
    local private_key=$(echo "${keypair}" | grep "Private" | awk '{print $3}')
    local public_key=$(echo "${keypair}" | grep "Public" | awk '{print $3}')
    
    if [[ -z "${private_key}" || -z "${public_key}" ]]; then
        log_error "Failed to generate Reality keys"
        return 1
    fi
    
    # Generate short IDs (8 hex strings)
    local short_ids='["'$(openssl rand -hex 8)'"]'
    
    # Save keys
    cat > "${KEYS_FILE}" << EOF
{
    "privateKey": "${private_key}",
    "publicKey": "${public_key}",
    "shortIds": ${short_ids}
}
EOF
    
    chmod 600 "${KEYS_FILE}"
    
    log_success "Reality keys generated"
    log_info "Public Key: ${public_key}"
}

generate_reality_keys_openssl() {
    log_info "Generating Reality keys using OpenSSL..."
    
    # Generate x25519 keypair
    local private_key=$(openssl genpkey -algorithm X25519 2>/dev/null | \
                        openssl pkey -text -noout 2>/dev/null | \
                        grep -A2 "priv:" | tail -1 | tr -d ' :')
    
    # This is a simplified fallback - for production, use xray
    local random_key=$(openssl rand -base64 32 | tr -d '/+=' | head -c 43)
    
    local short_ids='["'$(openssl rand -hex 8)'"]'
    
    cat > "${KEYS_FILE}" << EOF
{
    "privateKey": "${random_key}",
    "publicKey": "PLACEHOLDER_REGENERATE_WITH_XRAY",
    "shortIds": ${short_ids}
}
EOF
    
    chmod 600 "${KEYS_FILE}"
    
    log_warn "Keys generated with OpenSSL fallback. Regenerate with xray for production use."
}

ensure_reality_keys() {
    if [[ ! -f "${KEYS_FILE}" ]]; then
        generate_reality_keys
    fi
    
    # Load keys into environment
    if [[ -f "${KEYS_FILE}" ]]; then
        export REALITY_PRIVATE_KEY=$(jq -r '.privateKey' "${KEYS_FILE}")
        export REALITY_PUBLIC_KEY=$(jq -r '.publicKey' "${KEYS_FILE}")
        export REALITY_SHORT_IDS=$(jq -c '.shortIds' "${KEYS_FILE}")
    fi
}

show_reality_keys() {
    if [[ -f "${KEYS_FILE}" ]]; then
        log_info "═══ Reality Keys ═══"
        echo
        echo "Public Key: $(jq -r '.publicKey' "${KEYS_FILE}")"
        echo "Short IDs:  $(jq -r '.shortIds | join(", ")' "${KEYS_FILE}")"
        echo
    else
        log_warn "Reality keys not found"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# XRAY CONFIGURATION TEMPLATES
# ВАЖНО: Все inbound'ы слушают ТОЛЬКО на 127.0.0.1!
# ═══════════════════════════════════════════════════════════════════════════════

generate_reality_inbound_json() {
    local port="${1:-8443}"
    local dest="${2:-www.microsoft.com}"
    
    ensure_reality_keys
    
    # КРИТИЧНО: listen должен быть 127.0.0.1, НЕ 0.0.0.0!
    cat << EOF
{
    "tag": "vless-reality-in",
    "port": ${port},
    "listen": "127.0.0.1",
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
            "dest": "${dest}:443",
            "xver": 0,
            "serverNames": ["${dest}", "www.${dest#www.}"],
            "privateKey": "${REALITY_PRIVATE_KEY}",
            "shortIds": ${REALITY_SHORT_IDS}
        },
        "tcpSettings": {
            "header": {
                "type": "none"
            }
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
    }
}
EOF
}

generate_websocket_inbound_json() {
    local port="${1:-8444}"
    local path="${2:-/vless-ws}"
    local host="${3:-}"
    
    # КРИТИЧНО: listen должен быть 127.0.0.1!
    # security: none - потому что SSL терминируется на nginx или CDN
    cat << EOF
{
    "tag": "vless-ws-in",
    "port": ${port},
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
        "clients": [],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
            "path": "${path}",
            "headers": {
                "Host": "${host}"
            }
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
    }
}
EOF
}

generate_direct_outbound_json() {
    cat << 'EOF'
{
    "tag": "direct",
    "protocol": "freedom",
    "settings": {
        "domainStrategy": "UseIP"
    }
}
EOF
}

generate_block_outbound_json() {
    cat << 'EOF'
{
    "tag": "block",
    "protocol": "blackhole",
    "settings": {
        "response": {
            "type": "http"
        }
    }
}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# FULL CONFIG GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_full_xray_config() {
    set_phase "Full Xray Configuration"
    
    local output_file="${1:-${MARZBAN_DATA}/xray_config.json}"
    
    log_info "Generating full Xray configuration..."
    log_info "All inbounds will listen on 127.0.0.1 (localhost only)"
    
    ensure_reality_keys
    
    local inbounds="[]"
    local outbounds="[]"
    local routing_rules="[]"
    
    # API inbound (always present, localhost only)
    local api_inbound
    api_inbound=$(cat << 'EOF'
{
    "tag": "api-inbound",
    "listen": "127.0.0.1",
    "port": 62789,
    "protocol": "dokodemo-door",
    "settings": {
        "address": "127.0.0.1"
    }
}
EOF
)
    inbounds=$(echo "${inbounds}" | jq --argjson new "${api_inbound}" '. + [$new]')
    
    # Reality inbound (Standard profile) - LOCALHOST ONLY
    if [[ "${PROFILE_STANDARD_ENABLED:-true}" == "true" ]]; then
        local reality_port="${REALITY_PORT:-8443}"
        local reality_dest="${REALITY_DEST:-www.microsoft.com}"
        
        log_info "Adding Reality inbound on 127.0.0.1:${reality_port}"
        
        local reality_inbound
        reality_inbound=$(generate_reality_inbound_json "${reality_port}" "${reality_dest}")
        inbounds=$(echo "${inbounds}" | jq --argjson new "${reality_inbound}" '. + [$new]')
    fi
    
    # WebSocket inbound (Whitelist/CDN profile) - LOCALHOST ONLY
    if [[ "${PROFILE_WHITELIST_ENABLED:-false}" == "true" ]]; then
        local ws_port="${WS_PORT:-8444}"
        local ws_path="${WS_PATH:-/vless-ws}"
        local cdn_domain="${CDN_DOMAIN:-}"
        
        log_info "Adding WebSocket inbound on 127.0.0.1:${ws_port}"
        
        local ws_inbound
        ws_inbound=$(generate_websocket_inbound_json "${ws_port}" "${ws_path}" "${cdn_domain}")
        inbounds=$(echo "${inbounds}" | jq --argjson new "${ws_inbound}" '. + [$new]')
    fi
    
    # Direct outbound
    local direct_outbound
    direct_outbound=$(generate_direct_outbound_json)
    outbounds=$(echo "${outbounds}" | jq --argjson new "${direct_outbound}" '. + [$new]')
    
    # Block outbound
    local block_outbound
    block_outbound=$(generate_block_outbound_json)
    outbounds=$(echo "${outbounds}" | jq --argjson new "${block_outbound}" '. + [$new]')
    
    # WARP outbound (if enabled)
    if [[ "${PROFILE_WARP_ENABLED:-false}" == "true" ]] && [[ -f "${KEYS_DIR}/warp_config.json" ]]; then
        local warp_outbound
        warp_outbound=$(cat "${KEYS_DIR}/warp_config.json")
        outbounds=$(echo "${outbounds}" | jq --argjson new "${warp_outbound}" '. + [$new]')
    fi
    
    # API routing rule
    local api_rule
    api_rule=$(cat << 'EOF'
{
    "type": "field",
    "inboundTag": ["api-inbound"],
    "outboundTag": "api"
}
EOF
)
    routing_rules=$(echo "${routing_rules}" | jq --argjson new "${api_rule}" '. + [$new]')
    
    # Block private IPs
    local private_block_rule
    private_block_rule=$(cat << 'EOF'
{
    "type": "field",
    "ip": ["geoip:private"],
    "outboundTag": "block"
}
EOF
)
    routing_rules=$(echo "${routing_rules}" | jq --argjson new "${private_block_rule}" '. + [$new]')
    
    # Assemble final config
    local config
    config=$(cat << EOF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/lib/marzban/access.log",
        "error": "/var/lib/marzban/error.log"
    },
    "api": {
        "tag": "api",
        "services": ["HandlerService", "LoggerService", "StatsService"]
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
    "inbounds": ${inbounds},
    "outbounds": ${outbounds},
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": ${routing_rules}
    }
}
EOF
)
    
    # Validate JSON
    if ! echo "${config}" | jq . > /dev/null 2>&1; then
        log_error "Generated configuration is invalid JSON"
        return 1
    fi
    
    # Write atomically
    local temp_file
    temp_file=$(mktemp)
    echo "${config}" | jq . > "${temp_file}"
    mv "${temp_file}" "${output_file}"
    
    chmod 644 "${output_file}"
    
    log_success "Xray configuration generated: ${output_file}"
    
    # Show summary
    log_info "═══ Configuration Summary ═══"
    log_info "Inbounds configured: $(echo "${inbounds}" | jq 'length')"
    echo "${inbounds}" | jq -r '.[] | "  - \(.tag): 127.0.0.1:\(.port)"'
}

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

validate_xray_config() {
    local config_file="${1:-${MARZBAN_DATA}/xray_config.json}"
    
    log_info "Validating Xray configuration..."
    
    if [[ ! -f "${config_file}" ]]; then
        log_error "Config file not found: ${config_file}"
        return 1
    fi
    
    # Check JSON validity
    if ! jq . "${config_file}" > /dev/null 2>&1; then
        log_error "Invalid JSON in config file"
        return 1
    fi
    
    # Check that all inbounds listen on localhost
    local non_localhost=$(jq -r '.inbounds[] | select(.listen != "127.0.0.1" and .listen != null) | .tag' "${config_file}")
    if [[ -n "${non_localhost}" ]]; then
        log_warn "WARNING: Some inbounds don't listen on localhost: ${non_localhost}"
        log_warn "This may cause port conflicts with nginx!"
    fi
    
    # Check for port 443
    local port_443=$(jq -r '.inbounds[] | select(.port == 443) | .tag' "${config_file}")
    if [[ -n "${port_443}" ]]; then
        log_error "ERROR: Inbound '${port_443}' uses port 443!"
        log_error "Port 443 should be handled by nginx stream, not xray!"
        return 1
    fi
    
    log_success "Xray configuration is valid"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

setup_xray_keys() {
    generate_reality_keys
    show_reality_keys
}

# Export functions
export -f setup_xray_keys
export -f generate_reality_keys
export -f ensure_reality_keys
export -f show_reality_keys
export -f generate_full_xray_config
export -f validate_xray_config
export -f generate_reality_inbound_json
export -f generate_websocket_inbound_json
