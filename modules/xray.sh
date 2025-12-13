#!/bin/bash
#
# Module: xray.sh
# Purpose: Xray key generation, configuration assembly
# Dependencies: core.sh, docker.sh
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

readonly XRAY_IMAGE="ghcr.io/xtls/xray-core:latest"
readonly KEYS_FILE="${KEYS_DIR}/reality_keys.json"

# ═══════════════════════════════════════════════════════════════════════════════
# KEY GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_x25519_keypair() {
    log_info "Generating X25519 key pair..."
    
    local output
    
    # Prefer Docker-based generation for consistency
    if command -v docker &> /dev/null; then
        output=$(docker run --rm "${XRAY_IMAGE}" x25519 2>/dev/null)
    else
        log_error "Docker not available for key generation"
        return 1
    fi
    
    local private_key public_key
    private_key=$(echo "${output}" | grep "Private key:" | awk '{print $3}')
    public_key=$(echo "${output}" | grep "Public key:" | awk '{print $3}')
    
    if [[ -z "${private_key}" ]] || [[ -z "${public_key}" ]]; then
        log_error "Failed to parse X25519 keys"
        return 1
    fi
    
    echo "${private_key}:${public_key}"
}

generate_short_ids() {
    local count="${1:-4}"
    local ids="[]"
    
    for ((i=0; i<count; i++)); do
        local id
        id=$(openssl rand -hex 8)
        ids=$(echo "${ids}" | jq --arg id "${id}" '. + [$id]')
    done
    
    echo "${ids}"
}

generate_uuid() {
    # Use Xray's UUID generation for full compatibility
    if command -v docker &> /dev/null; then
        docker run --rm "${XRAY_IMAGE}" uuid 2>/dev/null
    else
        # Fallback to system UUID
        cat /proc/sys/kernel/random/uuid
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# KEY MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

ensure_reality_keys() {
    set_phase "Reality Key Generation"
    
    mkdir -p "${KEYS_DIR}"
    chmod 700 "${KEYS_DIR}"
    
    # Check if keys already exist
    if [[ -f "${KEYS_FILE}" ]]; then
        log_info "Reality keys already exist"
        
        # Validate keys
        if jq -e '.privateKey and .publicKey and .shortIds' "${KEYS_FILE}" > /dev/null 2>&1; then
            log_success "Existing keys are valid"
            
            # Load keys into environment
            export REALITY_PRIVATE_KEY=$(jq -r '.privateKey' "${KEYS_FILE}")
            export REALITY_PUBLIC_KEY=$(jq -r '.publicKey' "${KEYS_FILE}")
            export REALITY_SHORT_IDS=$(jq -c '.shortIds' "${KEYS_FILE}")
            
            return 0
        else
            log_warn "Existing keys are invalid, regenerating..."
        fi
    fi
    
    log_info "Generating new Reality keys..."
    
    # Generate X25519 keypair
    local keypair
    keypair=$(generate_x25519_keypair)
    
    local private_key="${keypair%%:*}"
    local public_key="${keypair##*:}"
    
    # Generate short IDs
    local short_ids
    short_ids=$(generate_short_ids 4)
    
    # Save keys
    cat > "${KEYS_FILE}" << EOF
{
    "privateKey": "${private_key}",
    "publicKey": "${public_key}",
    "shortIds": ${short_ids},
    "generatedAt": "$(date -Iseconds)"
}
EOF
    
    chmod 600 "${KEYS_FILE}"
    
    # Export to environment
    export REALITY_PRIVATE_KEY="${private_key}"
    export REALITY_PUBLIC_KEY="${public_key}"
    export REALITY_SHORT_IDS="${short_ids}"
    
    log_success "Reality keys generated and saved"
    log_info "Public key (for clients): ${public_key}"
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
# ═══════════════════════════════════════════════════════════════════════════════

generate_reality_inbound_json() {
    local port="${1:-8443}"
    local dest="${2:-www.microsoft.com}"
    
    ensure_reality_keys
    
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
    
    local output_file="${1:-${MARZBAN_DATA:-/var/lib/marzban}/xray_config.json}"
    
    log_info "Generating full Xray configuration..."
    
    ensure_reality_keys
    
    local inbounds="[]"
    local outbounds="[]"
    local routing_rules="[]"
    
    # API inbound (always present)
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
    
    # Reality inbound (Standard profile)
    if [[ "${PROFILE_STANDARD_ENABLED:-true}" == "true" ]]; then
        local reality_inbound
        reality_inbound=$(generate_reality_inbound_json "${REALITY_PORT:-8443}" "${REALITY_DEST:-www.microsoft.com}")
        inbounds=$(echo "${inbounds}" | jq --argjson new "${reality_inbound}" '. + [$new]')
    fi
    
    # WebSocket inbound (Whitelist/CDN profile)
    if [[ "${PROFILE_WHITELIST_ENABLED:-false}" == "true" ]]; then
        local ws_inbound
        ws_inbound=$(generate_websocket_inbound_json "${WS_PORT:-8444}" "${WS_PATH:-/vless-ws}" "${CDN_DOMAIN:-}")
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
    
    # Validate
    if ! echo "${config}" | jq . > /dev/null 2>&1; then
        log_error "Generated configuration is invalid JSON"
        return 1
    fi
    
    # Write atomically
    local temp_file
    temp_file=$(mktemp)
    echo "${config}" | jq . > "${temp_file}"
    mv "${temp_file}" "${output_file}"
    
    log_success "Xray configuration generated: ${output_file}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

validate_xray_config() {
    local config_file="${1:-${MARZBAN_DATA:-/var/lib/marzban}/xray_config.json}"
    
    log_info "Validating Xray configuration..."
    
    if [[ ! -f "${config_file}" ]]; then
        log_error "Configuration file not found: ${config_file}"
        return 1
    fi
    
    # JSON validation
    if ! validate_json "${config_file}"; then
        return 1
    fi
    
    # Structure validation
    local required_keys=("log" "inbounds" "outbounds" "routing")
    for key in "${required_keys[@]}"; do
        if ! jq -e ".${key}" "${config_file}" > /dev/null 2>&1; then
            log_error "Missing required key: ${key}"
            return 1
        fi
    done
    
    log_success "Configuration is valid"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

setup_xray() {
    ensure_reality_keys
    
    # Configuration is typically managed by Marzban
    # This generates keys for use by the API module
    
    log_success "Xray setup completed"
}

# Export functions
export -f setup_xray
export -f ensure_reality_keys
export -f generate_x25519_keypair
export -f generate_uuid
export -f generate_short_ids
export -f show_reality_keys
export -f validate_xray_config
