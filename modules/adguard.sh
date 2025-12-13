#!/bin/bash
# =============================================================================
# AdGuard Home Module - DNS-level ad blocking and privacy protection
# =============================================================================
# Provides DNS-over-HTTPS/TLS, ad blocking, and custom filtering
# Integrates with Marzban for DNS resolution
# =============================================================================

# Prevent direct execution
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && echo "This script should be sourced, not executed directly" && exit 1

# =============================================================================
# CONFIGURATION
# =============================================================================

ADGUARD_VERSION="${ADGUARD_VERSION:-latest}"
ADGUARD_CONFIG_DIR="${ADGUARD_CONFIG_DIR:-/opt/adguardhome}"
ADGUARD_WORK_DIR="${ADGUARD_WORK_DIR:-/opt/adguardhome/work}"
ADGUARD_CONF_DIR="${ADGUARD_CONF_DIR:-/opt/adguardhome/conf}"

# Default ports
ADGUARD_DNS_PORT="${ADGUARD_DNS_PORT:-53}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-3000}"
ADGUARD_SETUP_PORT="${ADGUARD_SETUP_PORT:-3000}"
ADGUARD_DOH_PORT="${ADGUARD_DOH_PORT:-443}"
ADGUARD_DOT_PORT="${ADGUARD_DOT_PORT:-853}"

# =============================================================================
# PORT 53 CONFLICT RESOLUTION
# =============================================================================

# Check if port 53 is in use
check_port_53_conflict() {
    log_step "Checking for port 53 conflicts"
    
    local conflicts=()
    
    # Check systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if ss -tulpn 2>/dev/null | grep -q ":53 .*systemd-resolve"; then
            conflicts+=("systemd-resolved")
        fi
    fi
    
    # Check dnsmasq
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        conflicts+=("dnsmasq")
    fi
    
    # Check any other service on port 53
    local port_53_service
    port_53_service=$(ss -tulpn 2>/dev/null | grep ":53 " | head -1)
    if [[ -n "${port_53_service}" ]]; then
        local service_name
        service_name=$(echo "${port_53_service}" | grep -oP 'users:\(\("\K[^"]+')
        if [[ -n "${service_name}" && ! " ${conflicts[*]} " =~ " ${service_name} " ]]; then
            conflicts+=("${service_name}")
        fi
    fi
    
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        log_warn "Port 53 conflicts detected: ${conflicts[*]}"
        return 1
    fi
    
    log_success "No port 53 conflicts detected"
    return 0
}

# Disable systemd-resolved stub listener
disable_systemd_resolved_stub() {
    log_step "Disabling systemd-resolved stub listener"
    
    local resolved_conf_dir="/etc/systemd/resolved.conf.d"
    local resolved_conf="${resolved_conf_dir}/no-stub.conf"
    
    # Create directory if not exists
    mkdir -p "${resolved_conf_dir}"
    
    # Backup existing resolv.conf
    if [[ -f /etc/resolv.conf ]]; then
        backup_file "/etc/resolv.conf"
    fi
    
    # Create configuration to disable stub
    cat > "${resolved_conf}" << 'EOF'
[Resolve]
DNSStubListener=no
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
EOF
    
    register_rollback "rm -f ${resolved_conf}" "normal"
    
    # Restart systemd-resolved
    systemctl restart systemd-resolved || true
    
    # Update resolv.conf to point to upstream DNS temporarily
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << 'EOF'
# Temporary DNS configuration during AdGuard setup
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    
    # Wait for port to be released
    local attempts=0
    while ss -tulpn 2>/dev/null | grep -q ":53 " && [[ ${attempts} -lt 10 ]]; do
        sleep 1
        ((attempts++))
    done
    
    if ss -tulpn 2>/dev/null | grep -q ":53 "; then
        log_error "Port 53 still in use after disabling systemd-resolved"
        return 1
    fi
    
    log_success "systemd-resolved stub listener disabled"
    return 0
}

# Stop conflicting DNS services
stop_conflicting_dns_services() {
    log_step "Stopping conflicting DNS services"
    
    # Stop and disable dnsmasq if running
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        log_info "Stopping dnsmasq..."
        systemctl stop dnsmasq
        systemctl disable dnsmasq
        register_rollback "systemctl enable dnsmasq && systemctl start dnsmasq" "normal"
    fi
    
    # Handle systemd-resolved
    if ! disable_systemd_resolved_stub; then
        return 1
    fi
    
    return 0
}

# =============================================================================
# ADGUARD INSTALLATION
# =============================================================================

# Create AdGuard Home directories
create_adguard_directories() {
    log_step "Creating AdGuard Home directories"
    
    mkdir -p "${ADGUARD_WORK_DIR}" "${ADGUARD_CONF_DIR}"
    chmod 755 "${ADGUARD_CONFIG_DIR}"
    
    register_rollback "rm -rf ${ADGUARD_CONFIG_DIR}" "normal"
    
    log_success "AdGuard directories created"
}

# Generate initial AdGuard configuration
generate_adguard_config() {
    local admin_username="${1:-admin}"
    local admin_password="${2}"
    local panel_domain="${3}"
    
    log_step "Generating AdGuard Home configuration"
    
    # Generate bcrypt hash for password
    local password_hash
    if command -v htpasswd &> /dev/null; then
        password_hash=$(htpasswd -bnBC 10 "" "${admin_password}" | tr -d ':\n' | sed 's/$2y/$2a/')
    else
        # Use Python if htpasswd not available
        password_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw('${admin_password}'.encode(), bcrypt.gensalt(10)).decode())" 2>/dev/null || echo "")
        if [[ -z "${password_hash}" ]]; then
            # Fallback - will need to set password via web UI
            log_warn "Could not generate password hash, will use setup wizard"
            password_hash=""
        fi
    fi
    
    # Generate configuration
    cat > "${ADGUARD_CONF_DIR}/AdGuardHome.yaml" << EOF
bind_host: 0.0.0.0
bind_port: ${ADGUARD_WEB_PORT}
users:
  - name: ${admin_username}
    password: ${password_hash}
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: en
theme: auto
debug_pprof: false
web_session_ttl: 720
dns:
  bind_hosts:
    - 0.0.0.0
  port: ${ADGUARD_DNS_PORT}
  anonymize_client_ip: false
  protection_enabled: true
  blocking_mode: default
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_response_ttl: 10
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  ratelimit: 0
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - tls://1.1.1.1
    - tls://8.8.8.8
  upstream_dns_file: ""
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
    - 9.9.9.9
  all_servers: false
  fastest_addr: true
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: true
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: true
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  filtering_enabled: true
  filters_update_interval: 24
  parental_enabled: false
  safesearch_enabled: false
  safebrowsing_enabled: true
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  rewrites: []
  blocked_services: []
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
tls:
  enabled: false
  server_name: ${panel_domain:-""}
  force_https: false
  port_https: ${ADGUARD_DOH_PORT}
  port_dns_over_tls: ${ADGUARD_DOT_PORT}
  port_dns_over_quic: 784
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  enabled: true
  file_enabled: true
  interval: 24h
  size_memory: 1000
  ignored: []
statistics:
  enabled: true
  interval: 24h
  ignored: []
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
    url: https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt
    name: Dandelion Sprout's Anti-Malware List
    id: 3
  - enabled: true
    url: https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext
    name: Peter Lowe's List
    id: 4
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log_file: ""
log_max_backups: 0
log_max_size: 100
log_max_age: 3
log_compress: false
log_localtime: false
verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 24
EOF
    
    chmod 600 "${ADGUARD_CONF_DIR}/AdGuardHome.yaml"
    
    log_success "AdGuard Home configuration generated"
}

# Generate Docker Compose service for AdGuard
generate_adguard_compose_service() {
    cat << 'EOF'
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/adguardhome/work:/opt/adguardhome/work
      - /opt/adguardhome/conf:/opt/adguardhome/conf
    cap_add:
      - NET_ADMIN
    environment:
      - TZ=UTC
EOF
}

# Setup AdGuard Home standalone (without Docker)
setup_adguard_standalone() {
    log_step "Setting up AdGuard Home (standalone)"
    
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            return 1
            ;;
    esac
    
    local download_url="https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${arch}.tar.gz"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    log_info "Downloading AdGuard Home..."
    if ! curl -sSL "${download_url}" -o "${temp_dir}/adguardhome.tar.gz"; then
        log_error "Failed to download AdGuard Home"
        rm -rf "${temp_dir}"
        return 1
    fi
    
    log_info "Extracting AdGuard Home..."
    tar -xzf "${temp_dir}/adguardhome.tar.gz" -C "${temp_dir}"
    
    # Install
    mkdir -p /opt/AdGuardHome
    cp -r "${temp_dir}/AdGuardHome/"* /opt/AdGuardHome/
    chmod +x /opt/AdGuardHome/AdGuardHome
    
    # Create symlink
    ln -sf /opt/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome
    
    # Install as service
    /opt/AdGuardHome/AdGuardHome -s install
    
    rm -rf "${temp_dir}"
    
    register_rollback "/opt/AdGuardHome/AdGuardHome -s uninstall && rm -rf /opt/AdGuardHome" "normal"
    
    log_success "AdGuard Home installed (standalone)"
}

# =============================================================================
# MAIN SETUP FUNCTION
# =============================================================================

setup_adguard() {
    local admin_username="${1:-admin}"
    local admin_password="${2}"
    local panel_domain="${3:-}"
    local use_docker="${4:-true}"
    
    log_step "Setting up AdGuard Home"
    
    # Generate password if not provided
    if [[ -z "${admin_password}" ]]; then
        admin_password=$(generate_password 16)
        log_info "Generated AdGuard admin password"
    fi
    
    # Resolve port 53 conflicts
    if ! check_port_53_conflict; then
        if ! stop_conflicting_dns_services; then
            log_error "Failed to resolve port 53 conflicts"
            return 1
        fi
    fi
    
    # Create directories
    create_adguard_directories
    
    # Generate configuration
    generate_adguard_config "${admin_username}" "${admin_password}" "${panel_domain}"
    
    # Save credentials
    local creds_file="${INSTALLER_DATA_DIR:-/home/claude/marzban-installer/data}/adguard_credentials.env"
    cat > "${creds_file}" << EOF
# AdGuard Home Credentials
# Generated: $(date -Iseconds)
ADGUARD_ADMIN_USERNAME=${admin_username}
ADGUARD_ADMIN_PASSWORD=${admin_password}
ADGUARD_WEB_URL=http://localhost:${ADGUARD_WEB_PORT}
ADGUARD_DNS_PORT=${ADGUARD_DNS_PORT}
EOF
    chmod 600 "${creds_file}"
    
    log_success "AdGuard Home setup complete"
    log_info "Web interface: http://localhost:${ADGUARD_WEB_PORT}"
    log_info "DNS Server: 127.0.0.1:${ADGUARD_DNS_PORT}"
    
    # Export for use by other modules
    export ADGUARD_ADMIN_PASSWORD="${admin_password}"
    export ADGUARD_DNS_ADDRESS="127.0.0.1:${ADGUARD_DNS_PORT}"
    
    return 0
}

# Configure AdGuard TLS (after certificates are obtained)
configure_adguard_tls() {
    local domain="${1}"
    local cert_path="${2:-/etc/letsencrypt/live/${domain}/fullchain.pem}"
    local key_path="${3:-/etc/letsencrypt/live/${domain}/privkey.pem}"
    
    log_step "Configuring AdGuard Home TLS"
    
    if [[ ! -f "${cert_path}" ]] || [[ ! -f "${key_path}" ]]; then
        log_warn "TLS certificates not found, skipping TLS configuration"
        return 0
    fi
    
    local config_file="${ADGUARD_CONF_DIR}/AdGuardHome.yaml"
    
    if [[ ! -f "${config_file}" ]]; then
        log_error "AdGuard configuration not found"
        return 1
    fi
    
    # Update TLS settings using Python (more reliable for YAML)
    python3 << EOF
import yaml

with open('${config_file}', 'r') as f:
    config = yaml.safe_load(f)

config['tls']['enabled'] = True
config['tls']['server_name'] = '${domain}'
config['tls']['certificate_path'] = '${cert_path}'
config['tls']['private_key_path'] = '${key_path}'
config['tls']['force_https'] = False

with open('${config_file}', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
EOF
    
    if [[ $? -ne 0 ]]; then
        log_warn "Failed to update TLS config with Python, trying sed..."
        # Fallback to sed (less reliable for YAML but might work)
        sed -i "s|enabled: false|enabled: true|" "${config_file}"
        sed -i "s|certificate_path: \"\"|certificate_path: \"${cert_path}\"|" "${config_file}"
        sed -i "s|private_key_path: \"\"|private_key_path: \"${key_path}\"|" "${config_file}"
    fi
    
    log_success "AdGuard TLS configured"
}

# Add custom filtering rules
add_adguard_custom_rules() {
    local rules_file="${ADGUARD_CONF_DIR}/custom_rules.txt"
    
    log_step "Adding custom filtering rules"
    
    cat > "${rules_file}" << 'EOF'
# Custom AdGuard Rules for VPN Server
# Block telemetry and tracking

# Microsoft telemetry
||telemetry.microsoft.com^
||vortex.data.microsoft.com^
||settings-win.data.microsoft.com^

# Google telemetry
||clientservices.googleapis.com^
||update.googleapis.com^

# Apple telemetry
||metrics.apple.com^
||xp.apple.com^

# Facebook tracking
||graph.facebook.com^
||pixel.facebook.com^

# Amazon tracking
||device-metrics-us.amazon.com^

# Allow VPN-related domains
@@||cloudflare.com^
@@||cloudflare-dns.com^
@@||warp.cloudflareaccess.org^
@@||api.cloudflare.com^
EOF
    
    chmod 644 "${rules_file}"
    
    log_success "Custom filtering rules added"
}

# Get AdGuard status
get_adguard_status() {
    echo "=== AdGuard Home Status ==="
    
    # Check if running
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "adguardhome"; then
        echo "Container: Running (Docker)"
        docker ps --filter "name=adguardhome" --format "table {{.Status}}\t{{.Ports}}"
    elif systemctl is-active --quiet AdGuardHome 2>/dev/null; then
        echo "Service: Running (standalone)"
        systemctl status AdGuardHome --no-pager -l | head -5
    else
        echo "Status: Not running"
    fi
    
    # Check DNS port
    if ss -tulpn 2>/dev/null | grep -q ":53 "; then
        echo ""
        echo "DNS Port 53: Listening"
        ss -tulpn | grep ":53 " | head -2
    else
        echo ""
        echo "DNS Port 53: Not listening"
    fi
    
    # Check web interface
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${ADGUARD_WEB_PORT}" 2>/dev/null | grep -q "200\|301\|302"; then
        echo ""
        echo "Web Interface: Available at http://localhost:${ADGUARD_WEB_PORT}"
    fi
}

# Restart AdGuard
restart_adguard() {
    log_step "Restarting AdGuard Home"
    
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "adguardhome"; then
        docker restart adguardhome
    elif systemctl is-active --quiet AdGuardHome 2>/dev/null; then
        systemctl restart AdGuardHome
    else
        log_warn "AdGuard Home not found"
        return 1
    fi
    
    log_success "AdGuard Home restarted"
}

# Test DNS resolution through AdGuard
test_adguard_dns() {
    local test_domain="${1:-cloudflare.com}"
    
    log_step "Testing AdGuard DNS resolution"
    
    local result
    if command -v dig &> /dev/null; then
        result=$(dig @127.0.0.1 -p ${ADGUARD_DNS_PORT} "${test_domain}" +short 2>/dev/null)
    elif command -v nslookup &> /dev/null; then
        result=$(nslookup "${test_domain}" 127.0.0.1 2>/dev/null | grep -A1 "Name:" | tail -1)
    else
        log_warn "No DNS lookup tool available (dig/nslookup)"
        return 1
    fi
    
    if [[ -n "${result}" ]]; then
        log_success "DNS resolution working: ${test_domain} -> ${result}"
        return 0
    else
        log_error "DNS resolution failed for ${test_domain}"
        return 1
    fi
}
