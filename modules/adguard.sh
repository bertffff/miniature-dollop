#!/bin/bash
# =============================================================================
# Module: adguard.sh
# Description: AdGuard Home DNS Server Integration
# Version: 2.0.0 - With systemd-resolved conflict resolution
# =============================================================================

set -euo pipefail

if [[ -z "${CORE_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

readonly ADGUARD_DIR="${ADGUARD_DIR:-/opt/marzban/adguard}"
readonly ADGUARD_CONFIG="${ADGUARD_DIR}/conf/AdGuardHome.yaml"
readonly ADGUARD_IMAGE="adguard/adguardhome:latest"

readonly FALLBACK_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")

# =============================================================================
# CHECK PORT 53 CONFLICT
# =============================================================================
check_port53_conflict() {
    if ss -lptn 'sport = :53' 2>/dev/null | grep -q 'systemd-res'; then
        log_info "systemd-resolved is using port 53"
        return 0
    fi
    return 1
}

# =============================================================================
# CONFIGURE SYSTEMD-RESOLVED (Safe port 53 release)
# =============================================================================
configure_systemd_resolved() {
    log_info "Configuring systemd-resolved to release port 53..."
    
    if ! check_port53_conflict; then
        log_info "Port 53 is free"
        return 0
    fi
    
    local config_dir="/etc/systemd/resolved.conf.d"
    local config_file="${config_dir}/adguard.conf"
    
    mkdir -p "${config_dir}"
    
    # Backup resolv.conf state
    local resolv_link=""
    [[ -L /etc/resolv.conf ]] && resolv_link=$(readlink /etc/resolv.conf)
    
    cat > "${config_file}" << EOF
# AdGuard Home compatibility
# Created by Marzban Installer
[Resolve]
DNS=${FALLBACK_DNS[0]}
FallbackDNS=${FALLBACK_DNS[1]} ${FALLBACK_DNS[2]}
DNSStubListener=no
EOF
    
    chmod 0644 "${config_file}"
    
    # Update resolv.conf symlink
    [[ -L /etc/resolv.conf ]] && ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    
    systemctl restart systemd-resolved 2>/dev/null && log_success "systemd-resolved: DNSStubListener disabled" || log_warn "Failed to restart systemd-resolved"
    
    register_rollback "Restore systemd-resolved" "rm -f '${config_file}' && [[ -n '${resolv_link}' ]] && ln -sf '${resolv_link}' /etc/resolv.conf; systemctl restart systemd-resolved" "critical"
    
    sleep 2
    
    check_port53_conflict && { log_warn "Port 53 still in use"; return 1; }
    
    return 0
}

# =============================================================================
# GENERATE BCRYPT HASH
# =============================================================================
generate_bcrypt_hash() {
    local password="$1"
    local hash=""
    
    # Method 1: htpasswd
    if command -v htpasswd &>/dev/null; then
        hash=$(htpasswd -nbBC 10 "" "${password}" 2>/dev/null | tr -d ':\n' | sed 's/$2y/$2a/')
        [[ -n "${hash}" && "${hash}" == '$2'* ]] && { echo "${hash}"; return 0; }
    fi
    
    # Method 2: Python
    if command -v python3 &>/dev/null; then
        hash=$(python3 -c "
try:
    import bcrypt
    print(bcrypt.hashpw(b'${password}', bcrypt.gensalt(10)).decode())
except:
    pass
" 2>/dev/null)
        [[ -n "${hash}" && "${hash}" == '$2'* ]] && { echo "${hash}"; return 0; }
    fi
    
    # Method 3: Docker
    if command -v docker &>/dev/null; then
        hash=$(docker run --rm python:3-slim python3 -c "
import bcrypt
print(bcrypt.hashpw(b'${password}', bcrypt.gensalt(10)).decode())
" 2>/dev/null)
        [[ -n "${hash}" && "${hash}" == '$2'* ]] && { echo "${hash}"; return 0; }
    fi
    
    log_error "Cannot generate bcrypt hash"
    return 1
}

# =============================================================================
# INSTALL BCRYPT DEPENDENCIES
# =============================================================================
install_bcrypt_deps() {
    log_info "Installing bcrypt dependencies..."
    apt-get update -qq
    apt-get install -y -qq apache2-utils python3-pip 2>/dev/null || true
    pip3 install bcrypt 2>/dev/null || true
    log_success "Bcrypt dependencies installed"
}

# =============================================================================
# CREATE ADGUARD CONFIG
# =============================================================================
create_adguard_config() {
    local username="$1"
    local password="$2"
    local web_port="${3:-3000}"
    local dns_port="${4:-53}"
    
    log_info "Creating AdGuard Home configuration..."
    
    local password_hash
    password_hash=$(generate_bcrypt_hash "${password}")
    [[ -z "${password_hash}" ]] && { log_error "Password hash failed"; return 1; }
    
    mkdir -p "${ADGUARD_DIR}/conf" "${ADGUARD_DIR}/work"
    
    cat > "${ADGUARD_CONFIG}" << EOF
bind_host: 0.0.0.0
bind_port: ${web_port}
users:
  - name: ${username}
    password: ${password_hash}
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: en
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: ${dns_port}
  protection_enabled: true
  blocking_mode: default
  ratelimit: 100
  refuse_any: true
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - tls://1.1.1.1
    - tls://8.8.8.8
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
    - 9.9.9.9
  fastest_addr: true
  cache_size: 4194304
  cache_ttl_min: 60
  cache_ttl_max: 86400
  cache_optimistic: true
  enable_dnssec: true
  filtering_enabled: true
  filters_update_interval: 24
  safebrowsing_enabled: true
tls:
  enabled: false
querylog:
  enabled: true
  file_enabled: true
  interval: 24h
  size_memory: 1000
statistics:
  enabled: true
  interval: 24h
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adaway.org/hosts.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext
    name: Peter Lowe's List
    id: 3
dhcp:
  enabled: false
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
schema_version: 24
EOF
    
    chmod 0644 "${ADGUARD_CONFIG}"
    register_file "${ADGUARD_CONFIG}"
    log_success "AdGuard config created"
}

# =============================================================================
# CREATE DOCKER COMPOSE
# =============================================================================
create_adguard_compose() {
    local web_port="${1:-3000}"
    local dns_port="${2:-53}"
    local compose_file="${ADGUARD_DIR}/docker-compose.yml"
    
    log_info "Creating AdGuard Docker Compose..."
    
    cat > "${compose_file}" << EOF
version: "3.8"

services:
  adguardhome:
    image: ${ADGUARD_IMAGE}
    container_name: adguardhome
    restart: unless-stopped
    hostname: adguardhome
    network_mode: host
    volumes:
      - ${ADGUARD_DIR}/work:/opt/adguardhome/work
      - ${ADGUARD_DIR}/conf:/opt/adguardhome/conf
    cap_add:
      - NET_ADMIN
    environment:
      - TZ=\${TZ:-UTC}
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:${web_port}"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
EOF
    
    chmod 0644 "${compose_file}"
    register_file "${compose_file}"
    log_success "AdGuard Compose file created"
}

# =============================================================================
# START ADGUARD
# =============================================================================
start_adguard() {
    log_info "Starting AdGuard Home..."
    
    cd "${ADGUARD_DIR}" || return 1
    
    docker compose pull --quiet 2>/dev/null || true
    docker compose up -d || { log_error "Failed to start AdGuard"; return 1; }
    
    register_rollback "Stop AdGuard" "cd '${ADGUARD_DIR}' && docker compose down" "normal"
    log_success "AdGuard started"
}

# =============================================================================
# WAIT FOR ADGUARD
# =============================================================================
wait_for_adguard() {
    local web_port="${1:-3000}"
    local timeout="${2:-60}"
    
    log_info "Waiting for AdGuard..."
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        docker ps --format '{{.Names}}' | grep -q '^adguardhome$' || { sleep 3; elapsed=$((elapsed + 3)); continue; }
        curl -sf "http://127.0.0.1:${web_port}/" -o /dev/null 2>/dev/null && { log_success "AdGuard ready"; return 0; }
        sleep 3
        elapsed=$((elapsed + 3))
    done
    
    log_warn "AdGuard may not be fully ready"
    return 1
}

# =============================================================================
# CHECK HEALTH
# =============================================================================
check_adguard_health() {
    local web_port="${1:-3000}"
    local dns_port="${2:-53}"
    
    log_info "Checking AdGuard health..."
    
    docker ps --format '{{.Names}}' | grep -q '^adguardhome$' || { log_error "Container not running"; return 1; }
    
    curl -sf "http://127.0.0.1:${web_port}/" -o /dev/null 2>/dev/null && log_success "Web UI accessible" || log_warn "Web UI not ready"
    
    command -v dig &>/dev/null && dig @127.0.0.1 -p "${dns_port}" google.com +short +time=3 &>/dev/null && log_success "DNS responding" || log_warn "DNS not ready"
    
    return 0
}

# =============================================================================
# MAIN SETUP
# =============================================================================
setup_adguard() {
    local username="${1:-admin}"
    local password="${2:-}"
    local web_port="${3:-3000}"
    local dns_port="${4:-53}"
    
    log_step "Setting up AdGuard Home"
    
    # Check if enabled
    [[ "${INSTALL_ADGUARD:-false}" != "true" ]] && { log_info "AdGuard disabled"; return 0; }
    
    configure_systemd_resolved || true
    
    [[ -z "${password}" ]] && { password=$(generate_password 24); log_info "Generated AdGuard password"; }
    
    install_bcrypt_deps
    
    mkdir -p "${ADGUARD_DIR}/conf" "${ADGUARD_DIR}/work"
    
    create_adguard_config "${username}" "${password}" "${web_port}" "${dns_port}" || return 1
    create_adguard_compose "${web_port}" "${dns_port}"
    
    # Ensure Docker network exists
    docker network inspect marzban-network &>/dev/null || docker network create marzban-network
    
    start_adguard || return 1
    wait_for_adguard "${web_port}" 60
    check_adguard_health "${web_port}" "${dns_port}" || true
    
    # Save credentials
    local creds_file="${ADGUARD_DIR}/credentials.txt"
    cat > "${creds_file}" << EOF
# AdGuard Home Credentials
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

Web Interface: http://SERVER_IP:${web_port}
Username: ${username}
Password: ${password}

Internal DNS: 127.0.0.1:${dns_port}
EOF
    chmod 0600 "${creds_file}"
    
    echo ""
    log_success "AdGuard Home Setup Complete"
    echo "Web Port: ${web_port}"
    echo "DNS Port: ${dns_port}"
    echo "Username: ${username}"
    echo "Password: ${password}"
    echo ""
    
    export ADGUARD_DNS="127.0.0.1:${dns_port}"
    export ADGUARD_USER="${username}"
    export ADGUARD_PASS="${password}"
}

export -f check_port53_conflict configure_systemd_resolved generate_bcrypt_hash
export -f create_adguard_config create_adguard_compose start_adguard
export -f wait_for_adguard check_adguard_health setup_adguard
