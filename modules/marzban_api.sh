#!/bin/bash
#
# Module: marzban_api.sh
# Purpose: Marzban REST API integration for inbound management
# Dependencies: core.sh, marzban.sh
#

# Strict mode
set -euo pipefail

# Source core module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/core.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

MARZBAN_API_BASE="http://127.0.0.1:${MARZBAN_PORT:-8000}/api"
MARZBAN_API_TOKEN=""

# ═══════════════════════════════════════════════════════════════════════════════
# API AUTHENTICATION
# ═══════════════════════════════════════════════════════════════════════════════

get_admin_token() {
    local username="${1:-${ADMIN_USERNAME:-admin}}"
    local password="${2:-${ADMIN_PASSWORD:-}}"
    
    if [[ -z "${password}" ]]; then
        # Try to load from credentials file
        if [[ -f "${DATA_DIR}/credentials.env" ]]; then
            source "${DATA_DIR}/credentials.env"
            password="${ADMIN_PASSWORD:-}"
        fi
    fi
    
    if [[ -z "${password}" ]]; then
        log_error "Admin password not set"
        return 1
    fi
    
    log_info "Authenticating with Marzban API..."
    
    local response
    response=$(curl -sf -X POST "${MARZBAN_API_BASE}/admin/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "username=${username}" \
        --data-urlencode "password=${password}" \
        2>/dev/null) || {
        log_error "Failed to authenticate with Marzban API"
        return 1
    }
    
    MARZBAN_API_TOKEN=$(echo "${response}" | jq -r '.access_token' 2>/dev/null)
    
    if [[ -z "${MARZBAN_API_TOKEN}" ]] || [[ "${MARZBAN_API_TOKEN}" == "null" ]]; then
        log_error "Failed to obtain API token"
        log_debug "Response: ${response}"
        return 1
    fi
    
    log_success "API authentication successful"
    export MARZBAN_API_TOKEN
}

# ═══════════════════════════════════════════════════════════════════════════════
# API HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

api_request() {
    local method="${1}"
    local endpoint="${2}"
    local data="${3:-}"
    
    local curl_opts=(
        -sf
        -X "${method}"
        -H "Authorization: Bearer ${MARZBAN_API_TOKEN}"
        -H "Content-Type: application/json"
    )
    
    if [[ -n "${data}" ]]; then
        curl_opts+=(-d "${data}")
    fi
    
    curl "${curl_opts[@]}" "${MARZBAN_API_BASE}${endpoint}" 2>/dev/null
}

wait_for_api() {
    local max_attempts="${1:-30}"
    local attempt=0
    
    log_info "Waiting for Marzban API..."
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if curl -sf "${MARZBAN_API_BASE}/admin" -o /dev/null 2>&1; then
            log_success "Marzban API is ready"
            return 0
        fi
        
        ((attempt++))
        sleep 2
        printf "\r  Waiting... %d/%d attempts" "${attempt}" "${max_attempts}"
    done
    
    echo
    log_error "Marzban API not available after ${max_attempts} attempts"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# INBOUND MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

get_inbounds() {
    api_request "GET" "/inbounds"
}

get_inbound() {
    local tag="${1}"
    api_request "GET" "/inbounds/${tag}"
}

create_inbound() {
    local json_payload="${1}"
    local inbound_tag="${2:-}"
    
    log_info "Creating inbound${inbound_tag:+: ${inbound_tag}}..."
    
    local response
    response=$(api_request "POST" "/inbounds" "${json_payload}") || {
        log_error "Failed to create inbound"
        return 1
    }
    
    if echo "${response}" | jq -e '.tag' > /dev/null 2>&1; then
        log_success "Inbound created: $(echo "${response}" | jq -r '.tag')"
        return 0
    else
        log_error "Failed to create inbound: ${response}"
        return 1
    fi
}

update_inbound() {
    local tag="${1}"
    local json_payload="${2}"
    
    log_info "Updating inbound: ${tag}..."
    
    local response
    response=$(api_request "PUT" "/inbounds/${tag}" "${json_payload}") || {
        log_error "Failed to update inbound"
        return 1
    }
    
    log_success "Inbound updated: ${tag}"
}

delete_inbound() {
    local tag="${1}"
    
    log_info "Deleting inbound: ${tag}..."
    
    api_request "DELETE" "/inbounds/${tag}" || {
        log_error "Failed to delete inbound"
        return 1
    }
    
    log_success "Inbound deleted: ${tag}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROFILE CREATION VIA API
# ═══════════════════════════════════════════════════════════════════════════════

create_reality_inbound() {
    set_phase "Creating Reality Inbound"
    
    # Load or generate keys
    local private_key public_key short_ids
    
    if [[ -f "${KEYS_DIR}/reality_keys.json" ]]; then
        private_key=$(jq -r '.privateKey' "${KEYS_DIR}/reality_keys.json")
        public_key=$(jq -r '.publicKey' "${KEYS_DIR}/reality_keys.json")
        short_ids=$(jq -c '.shortIds' "${KEYS_DIR}/reality_keys.json")
    else
        log_error "Reality keys not found. Run xray.sh first."
        return 1
    fi
    
    local reality_dest="${REALITY_DEST:-www.microsoft.com}"
    local reality_port="${REALITY_PORT:-8443}"
    
    local payload
    payload=$(cat << EOF
{
    "tag": "vless-reality",
    "protocol": "vless",
    "port": ${reality_port},
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
            "serverNames": ["${reality_dest}", "www.${reality_dest}"],
            "privateKey": "${private_key}",
            "shortIds": ${short_ids}
        },
        "tcpSettings": {
            "header": {
                "type": "none"
            }
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
    }
}
EOF
)
    
    create_inbound "${payload}" "vless-reality"
}

create_websocket_inbound() {
    set_phase "Creating WebSocket Inbound"
    
    local ws_port="${WS_PORT:-8444}"
    local ws_path="${WS_PATH:-/vless-ws}"
    local cdn_domain="${CDN_DOMAIN:-}"
    
    local payload
    payload=$(cat << EOF
{
    "tag": "vless-ws",
    "protocol": "vless",
    "port": ${ws_port},
    "settings": {
        "clients": [],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
            "path": "${ws_path}",
            "headers": {
                "Host": "${cdn_domain}"
            }
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
    }
}
EOF
)
    
    create_inbound "${payload}" "vless-ws"
}

create_xhttp_inbound() {
    set_phase "Creating XHTTP Inbound"
    
    local xhttp_port="${XHTTP_PORT:-8445}"
    local xhttp_path="${XHTTP_PATH:-/xhttp}"
    local cdn_domain="${CDN_DOMAIN:-}"
    
    local payload
    payload=$(cat << EOF
{
    "tag": "vless-xhttp",
    "protocol": "vless",
    "port": ${xhttp_port},
    "settings": {
        "clients": [],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
            "path": "${xhttp_path}",
            "host": "${cdn_domain}"
        }
    },
    "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
    }
}
EOF
)
    
    create_inbound "${payload}" "vless-xhttp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# USER MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

create_user() {
    local username="${1}"
    local data_limit="${2:-0}"  # 0 = unlimited
    local expire_days="${3:-0}"  # 0 = never
    
    log_info "Creating user: ${username}..."
    
    local expire_timestamp=0
    if [[ ${expire_days} -gt 0 ]]; then
        expire_timestamp=$(( $(date +%s) + (expire_days * 86400) ))
    fi
    
    local payload
    payload=$(cat << EOF
{
    "username": "${username}",
    "proxies": {
        "vless": {
            "flow": "xtls-rprx-vision"
        }
    },
    "inbounds": {
        "vless-reality": {},
        "vless-ws": {}
    },
    "expire": ${expire_timestamp},
    "data_limit": ${data_limit},
    "data_limit_reset_strategy": "no_reset",
    "status": "active"
}
EOF
)
    
    local response
    response=$(api_request "POST" "/user" "${payload}") || {
        log_error "Failed to create user"
        return 1
    }
    
    if echo "${response}" | jq -e '.username' > /dev/null 2>&1; then
        log_success "User created: ${username}"
        
        # Get subscription link
        local sub_url
        sub_url=$(echo "${response}" | jq -r '.subscription_url')
        log_info "Subscription URL: ${sub_url}"
        
        return 0
    else
        log_error "Failed to create user: ${response}"
        return 1
    fi
}

get_users() {
    api_request "GET" "/users"
}

get_user() {
    local username="${1}"
    api_request "GET" "/user/${username}"
}

delete_user() {
    local username="${1}"
    
    log_info "Deleting user: ${username}..."
    api_request "DELETE" "/user/${username}" || {
        log_error "Failed to delete user"
        return 1
    }
    
    log_success "User deleted: ${username}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM INFO
# ═══════════════════════════════════════════════════════════════════════════════

get_system_stats() {
    api_request "GET" "/system"
}

get_core_config() {
    api_request "GET" "/core/config"
}

restart_xray_core() {
    log_info "Restarting Xray core..."
    api_request "POST" "/core/restart" || {
        log_error "Failed to restart Xray core"
        return 1
    }
    log_success "Xray core restarted"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_profiles_via_api() {
    set_phase "Profile Setup via API"
    
    # Wait for API
    wait_for_api 60 || return 1
    
    # Authenticate
    get_admin_token || return 1
    
    # Create Reality inbound (standard profile)
    if [[ "${PROFILE_STANDARD_ENABLED:-true}" == "true" ]]; then
        create_reality_inbound || log_warn "Failed to create Reality inbound"
    fi
    
    # Create WebSocket inbound (CDN/whitelist profile)
    if [[ "${PROFILE_WHITELIST_ENABLED:-false}" == "true" ]]; then
        create_websocket_inbound || log_warn "Failed to create WebSocket inbound"
    fi
    
    log_success "Profiles configured via API"
}

# Export functions
export -f wait_for_api
export -f get_admin_token
export -f setup_profiles_via_api
export -f create_inbound
export -f get_inbounds
export -f create_user
export -f get_users
export -f get_system_stats
export -f restart_xray_core
