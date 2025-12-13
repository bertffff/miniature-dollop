#!/bin/bash
# =============================================================================
# Module: marzban_api.sh
# Description: Marzban API Integration for dynamic Inbound configuration
# Version: 2.0.0 - API-driven config management
# =============================================================================

set -euo pipefail

if [[ -z "${CORE_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

readonly API_RETRY_MAX=5
readonly API_RETRY_DELAY=3
readonly API_TIMEOUT=30

declare -g MARZBAN_API_URL=""
declare -g MARZBAN_API_TOKEN=""

# =============================================================================
# INITIALIZE API
# =============================================================================
init_marzban_api() {
    local panel_url="$1"
    local username="$2"
    local password="$3"
    local max_retries="${4:-$API_RETRY_MAX}"
    
    MARZBAN_API_URL="${panel_url}"
    
    log_info "Authenticating with Marzban API..."
    
    local retry=0
    local delay=${API_RETRY_DELAY}
    
    while [[ $retry -lt $max_retries ]]; do
        local response
        response=$(curl -sf -k \
            --connect-timeout 10 \
            --max-time ${API_TIMEOUT} \
            "${panel_url}/api/admin/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data "username=${username}&password=${password}" \
            2>/dev/null) || true
        
        if [[ -n "${response}" ]]; then
            MARZBAN_API_TOKEN=$(echo "${response}" | jq -r '.access_token // empty')
            
            if [[ -n "${MARZBAN_API_TOKEN}" && "${MARZBAN_API_TOKEN}" != "null" ]]; then
                log_success "API authenticated"
                export MARZBAN_API_TOKEN
                return 0
            fi
        fi
        
        retry=$((retry + 1))
        [[ $retry -lt $max_retries ]] && { log_warn "Auth failed, retry ${retry}/${max_retries}..."; sleep ${delay}; delay=$((delay * 2)); }
    done
    
    log_error "API authentication failed after ${max_retries} attempts"
    return 1
}

# =============================================================================
# API REQUEST WITH RETRY
# =============================================================================
marzban_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local max_retries="${4:-3}"
    
    [[ -z "${MARZBAN_API_TOKEN}" ]] && { log_error "API token not initialized"; return 1; }
    
    local retry=0
    local delay=2
    
    while [[ $retry -lt $max_retries ]]; do
        local curl_args=(
            -sf -k
            -X "${method}"
            --connect-timeout 10
            --max-time ${API_TIMEOUT}
            -H "Authorization: Bearer ${MARZBAN_API_TOKEN}"
            -H "Content-Type: application/json"
        )
        
        [[ -n "${data}" ]] && curl_args+=(-d "${data}")
        
        local response http_code
        response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "${MARZBAN_API_URL}${endpoint}" 2>/dev/null) || true
        http_code=$(echo "${response}" | tail -1)
        response=$(echo "${response}" | sed '$d')
        
        case "${http_code}" in
            200|201|204) echo "${response}"; return 0 ;;
            401) log_error "API auth failed (401)"; return 1 ;;
            422) log_debug "Validation error (422): ${response}"; echo "${response}"; return 0 ;;
        esac
        
        retry=$((retry + 1))
        [[ $retry -lt $max_retries ]] && { log_debug "API failed (HTTP ${http_code}), retry..."; sleep ${delay}; delay=$((delay * 2)); }
    done
    
    log_error "API request failed after ${max_retries} attempts"
    return 1
}

# =============================================================================
# GET ENDPOINTS
# =============================================================================
get_system_settings() { marzban_api_request "GET" "/api/system"; }
get_inbounds() { marzban_api_request "GET" "/api/inbounds"; }
get_hosts_config() { marzban_api_request "GET" "/api/hosts"; }

# =============================================================================
# UPDATE HOSTS
# =============================================================================
update_hosts_config() {
    local config_json="$1"
    local max_retries="${2:-$API_RETRY_MAX}"
    
    log_info "Updating hosts configuration..."
    
    echo "${config_json}" | jq -e '.' &>/dev/null || { log_error "Invalid hosts JSON"; return 1; }
    
    local retry=0
    local delay=${API_RETRY_DELAY}
    
    while [[ $retry -lt $max_retries ]]; do
        local response http_code
        response=$(curl -sf -k -w "\n%{http_code}" \
            --connect-timeout 10 --max-time ${API_TIMEOUT} \
            -X PUT \
            -H "Authorization: Bearer ${MARZBAN_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${config_json}" \
            "${MARZBAN_API_URL}/api/hosts" 2>/dev/null) || true
        
        http_code=$(echo "${response}" | tail -1)
        
        [[ "${http_code}" == "200" ]] && { log_success "Hosts updated"; return 0; }
        
        retry=$((retry + 1))
        [[ $retry -lt $max_retries ]] && { log_warn "Update failed, retry ${retry}/${max_retries}..."; sleep ${delay}; delay=$((delay * 2)); }
    done
    
    log_error "Failed to update hosts"
    return 1
}

# =============================================================================
# GENERATE VLESS REALITY INBOUND JSON
# =============================================================================
generate_vless_reality_inbound() {
    local tag="$1"
    local port="$2"
    local sni="$3"
    local private_key="$4"
    local short_ids="$5"
    local fingerprint="${6:-chrome}"
    
    local short_ids_json
    short_ids_json=$(echo "${short_ids}" | tr ',' '\n' | jq -R . | jq -s .)
    
    cat << EOF
{
  "tag": "${tag}",
  "listen": "0.0.0.0",
  "port": ${port},
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "tcpSettings": {},
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "${sni}:443",
      "xver": 0,
      "serverNames": ["${sni}"],
      "privateKey": "${private_key}",
      "shortIds": ${short_ids_json},
      "fingerprint": "${fingerprint}"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
EOF
}

# =============================================================================
# GENERATE FULL XRAY CONFIG (API-READY BASE)
# Only contains system config - Inbounds managed via API
# =============================================================================
generate_api_xray_config() {
    log_info "Generating API-ready Xray base configuration..."
    
    cat << 'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/lib/marzban/logs/access.log",
    "error": "/var/lib/marzban/logs/error.log"
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
  "inbounds": [
    {
      "tag": "api-inbound",
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
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
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api-inbound"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
}

# =============================================================================
# GENERATE FULL XRAY CONFIG WITH ALL PROFILES
# =============================================================================
generate_full_xray_config() {
    local private_key="$1"
    local short_ids="$2"
    local profile1_port="$3"
    local profile1_sni="$4"
    local profile2_port="$5"
    local profile2_sni="$6"
    local profile3_port="$7"
    local profile3_sni="$8"
    local warp_outbound_file="${9:-}"
    
    log_info "Generating full Xray configuration..."
    
    [[ -z "${private_key}" || -z "${short_ids}" ]] && { log_error "Missing Reality keys"; return 1; }
    
    local short_ids_json
    short_ids_json=$(echo "${short_ids}" | tr ',' '\n' | jq -R . | jq -s .)
    
    local warp_outbound=""
    local warp_routing=""
    
    if [[ -n "${warp_outbound_file}" && -f "${warp_outbound_file}" ]]; then
        warp_outbound=",$(cat "${warp_outbound_file}")"
        warp_routing=',{"type":"field","inboundTag":["VLESS_REALITY_WARP"],"outboundTag":"warp"}'
        log_info "Including WARP outbound"
    fi
    
    cat << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/lib/marzban/logs/access.log",
    "error": "/var/lib/marzban/logs/error.log"
  },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "LoggerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
    "system": {
      "statsInboundUplink": true, "statsInboundDownlink": true,
      "statsOutboundUplink": true, "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api-inbound",
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {"address": "127.0.0.1"}
    },
    {
      "tag": "VLESS_REALITY_MAIN",
      "listen": "0.0.0.0",
      "port": ${profile1_port},
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${profile1_sni}:443",
          "xver": 0,
          "serverNames": ["${profile1_sni}"],
          "privateKey": "${private_key}",
          "shortIds": ${short_ids_json},
          "fingerprint": "chrome"
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    },
    {
      "tag": "VLESS_REALITY_STANDARD",
      "listen": "0.0.0.0",
      "port": ${profile2_port},
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${profile2_sni}:443",
          "xver": 0,
          "serverNames": ["${profile2_sni}"],
          "privateKey": "${private_key}",
          "shortIds": ${short_ids_json},
          "fingerprint": "chrome"
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    },
    {
      "tag": "VLESS_REALITY_WARP",
      "listen": "0.0.0.0",
      "port": ${profile3_port},
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${profile3_sni}:443",
          "xver": 0,
          "serverNames": ["${profile3_sni}"],
          "privateKey": "${private_key}",
          "shortIds": ${short_ids_json},
          "fingerprint": "chrome"
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {}},
    {"tag": "blocked", "protocol": "blackhole", "settings": {}}
    ${warp_outbound}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "inboundTag": ["api-inbound"], "outboundTag": "api"}
      ${warp_routing},
      {"type": "field", "outboundTag": "direct", "network": "tcp,udp"}
    ]
  }
}
EOF
}

# =============================================================================
# CREATE HOSTS MAPPING
# =============================================================================
create_hosts_mapping() {
    local server_ip="$1"
    local public_key="$2"
    local short_id="$3"
    local profile1_port="$4"
    local profile1_sni="$5"
    local profile1_name="$6"
    local profile2_port="$7"
    local profile2_sni="$8"
    local profile2_name="$9"
    local profile3_port="${10}"
    local profile3_sni="${11}"
    local profile3_name="${12}"
    
    cat << EOF
{
  "VLESS_REALITY_MAIN": [
    {
      "remark": "${profile1_name}",
      "address": "${server_ip}",
      "port": ${profile1_port},
      "sni": "${profile1_sni}",
      "host": "",
      "path": "",
      "security": "reality",
      "alpn": "h2,http/1.1",
      "fingerprint": "chrome",
      "allowinsecure": false,
      "is_disabled": false,
      "mux_enable": false,
      "weight": 1
    }
  ],
  "VLESS_REALITY_STANDARD": [
    {
      "remark": "${profile2_name}",
      "address": "${server_ip}",
      "port": ${profile2_port},
      "sni": "${profile2_sni}",
      "host": "",
      "path": "",
      "security": "reality",
      "alpn": "h2,http/1.1",
      "fingerprint": "chrome",
      "allowinsecure": false,
      "is_disabled": false,
      "mux_enable": false,
      "weight": 1
    }
  ],
  "VLESS_REALITY_WARP": [
    {
      "remark": "${profile3_name}",
      "address": "${server_ip}",
      "port": ${profile3_port},
      "sni": "${profile3_sni}",
      "host": "",
      "path": "",
      "security": "reality",
      "alpn": "h2,http/1.1",
      "fingerprint": "chrome",
      "allowinsecure": false,
      "is_disabled": false,
      "mux_enable": false,
      "weight": 1
    }
  ]
}
EOF
}

# =============================================================================
# VALIDATE XRAY CONFIG
# =============================================================================
validate_xray_config() {
    local config_json="$1"
    
    echo "${config_json}" | jq -e '.' &>/dev/null || { log_error "Invalid JSON"; return 1; }
    
    for section in "log" "inbounds" "outbounds" "routing"; do
        echo "${config_json}" | jq -e ".${section}" &>/dev/null || { log_error "Missing: ${section}"; return 1; }
    done
    
    log_debug "Xray config valid"
    return 0
}

# =============================================================================
# APPLY XRAY CONFIG
# =============================================================================
apply_xray_config() {
    local config_json="$1"
    local config_file="${2:-/var/lib/marzban/xray_config.json}"
    
    log_info "Applying Xray configuration..."
    
    validate_xray_config "${config_json}" || return 1
    
    [[ -f "${config_file}" ]] && cp "${config_file}" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    mkdir -p "$(dirname "${config_file}")"
    echo "${config_json}" | jq '.' > "${config_file}"
    chmod 0644 "${config_file}"
    
    # Also save to Marzban dir
    local marzban_config="${MARZBAN_DIR:-/opt/marzban}/xray_config.json"
    mkdir -p "$(dirname "${marzban_config}")"
    echo "${config_json}" | jq '.' > "${marzban_config}"
    
    log_success "Xray configuration applied"
}

# =============================================================================
# CONFIGURE PROFILES VIA API
# =============================================================================
configure_profiles_via_api() {
    local server_ip="$1"
    local panel_url="$2"
    local admin_user="$3"
    local admin_pass="$4"
    local private_key="$5"
    local public_key="$6"
    local short_ids="$7"
    local profile1_port="$8"
    local profile1_sni="$9"
    local profile1_name="${10}"
    local profile2_port="${11}"
    local profile2_sni="${12}"
    local profile2_name="${13}"
    local profile3_port="${14}"
    local profile3_sni="${15}"
    local profile3_name="${16}"
    local warp_file="${17:-}"
    
    log_step "Configuring VPN Profiles via API"
    
    init_marzban_api "${panel_url}" "${admin_user}" "${admin_pass}" || return 1
    
    local first_short_id="${short_ids%%,*}"
    
    local xray_config
    xray_config=$(generate_full_xray_config \
        "${private_key}" "${short_ids}" \
        "${profile1_port}" "${profile1_sni}" \
        "${profile2_port}" "${profile2_sni}" \
        "${profile3_port}" "${profile3_sni}" \
        "${warp_file}")
    
    apply_xray_config "${xray_config}" || return 1
    
    local hosts_config
    hosts_config=$(create_hosts_mapping \
        "${server_ip}" "${public_key}" "${first_short_id}" \
        "${profile1_port}" "${profile1_sni}" "${profile1_name}" \
        "${profile2_port}" "${profile2_sni}" "${profile2_name}" \
        "${profile3_port}" "${profile3_sni}" "${profile3_name}")
    
    update_hosts_config "${hosts_config}" || log_warn "Manual host config may be needed"
    
    log_info "Restarting Marzban..."
    (cd "${MARZBAN_DIR:-/opt/marzban}" && docker compose restart marzban) || true
    sleep 10
    
    log_success "VPN profiles configured"
    
    echo ""
    echo "Profile 1: ${profile1_name} - Port ${profile1_port} (Direct)"
    echo "Profile 2: ${profile2_name} - Port ${profile2_port} (Direct)"
    echo "Profile 3: ${profile3_name} - Port ${profile3_port} (WARP)"
    echo "Public Key: ${public_key}"
    echo "Short ID: ${first_short_id}"
}

export -f init_marzban_api marzban_api_request get_system_settings get_inbounds get_hosts_config
export -f update_hosts_config generate_vless_reality_inbound generate_api_xray_config
export -f generate_full_xray_config create_hosts_mapping validate_xray_config
export -f apply_xray_config configure_profiles_via_api
