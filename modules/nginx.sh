#!/bin/bash
#
# Module: nginx.sh
# Purpose: Nginx installation, fake website setup (No SNI routing on 443)
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

readonly NGINX_CONF_DIR="/etc/nginx"
readonly NGINX_SITES_DIR="${NGINX_CONF_DIR}/sites-available"
readonly NGINX_ENABLED_DIR="${NGINX_CONF_DIR}/sites-enabled"
readonly NGINX_STREAM_DIR="${NGINX_CONF_DIR}/stream.conf.d"
readonly NGINX_HTML_DIR="/var/www/html"

# Fake website template sources
readonly FAKE_SITE_SOURCES=(
    "https://github.com/cortez24rus/simple-web-templates/archive/refs/heads/main.zip"
)

# ═══════════════════════════════════════════════════════════════════════════════
# NGINX INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

is_nginx_installed() {
    command -v nginx &> /dev/null
}

install_nginx() {
    set_phase "Nginx Installation"
    
    if is_nginx_installed; then
        log_info "Nginx already installed: $(nginx -v 2>&1 | cut -d'/' -f2)"
        return 0
    fi
    
    log_info "Installing Nginx..."
    
    # Add Nginx mainline repository for latest version
    if [[ "${OS_ID}" == "ubuntu" ]]; then
        install_packages software-properties-common
        add-apt-repository -y ppa:ondrej/nginx-mainline 2>/dev/null || true
        apt-get update
    fi
    
    # Принудительная очистка
    apt-get purge -y nginx nginx-common libnginx-mod-stream 2>/dev/null || true
    
    install_packages nginx libnginx-mod-stream
    
    register_rollback "apt-get remove -y nginx && rm -rf ${NGINX_CONF_DIR}" "normal"
    
    log_info "Nginx installed: $(nginx -v 2>&1 | cut -d'/' -f2)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# NGINX CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

configure_nginx_main() {
    set_phase "Nginx Main Configuration"
    
    log_info "Configuring main Nginx settings..."
    
    backup_file "${NGINX_CONF_DIR}/nginx.conf"
    
    cat > "${NGINX_CONF_DIR}/nginx.conf" << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

worker_rlimit_nofile 65535;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    client_body_buffer_size 16K;
    client_header_buffer_size 1k;
    client_max_body_size 50m;
    large_client_header_buffers 4 8k;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

# Stream module is kept enabled but empty by default
stream {
    map_hash_bucket_size 128;
    log_format stream_log '$remote_addr [$time_local] $protocol $status $bytes_sent $bytes_received $session_time';
    access_log /var/log/nginx/stream.log stream_log;
    include /etc/nginx/stream.conf.d/*.conf;
}
EOF
    
    register_rollback "rm -f ${NGINX_CONF_DIR}/nginx.conf" "normal"
    mkdir -p "${NGINX_STREAM_DIR}"
}

# Функция configure_sni_routing удалена или закомментирована, 
# так как она занимала 443 порт для Nginx Stream.
# configure_sni_routing() { ... }

configure_marzban_panel_server() {
    local domain="${PANEL_DOMAIN:-}"
    local marzban_port="${MARZBAN_PORT:-8000}"
    # Используем порт 8443 для панели, чтобы освободить 443 для Xray
    local panel_listen_port="8443" 
    
    if [[ -z "${domain}" ]]; then return 0; fi
    
    log_info "Configuring Marzban Panel SSL termination on port ${panel_listen_port}..."
    
    cat > "${NGINX_CONF_DIR}/conf.d/marzban-panel.conf" << EOF
server {
    listen 0.0.0.0:${panel_listen_port} ssl http2;
    server_name ${domain};
    
    # SSL Certificates
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000" always;

    # Proxy to Marzban
    location / {
        proxy_pass http://127.0.0.1:${marzban_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    log_success "Marzban Panel SSL config created (Port: ${panel_listen_port})"
}

configure_fake_site_server() {
    set_phase "Fake Site Server Configuration"
    
    log_info "Configuring fake website server (Port 8080)..."
    
    cat > "${NGINX_CONF_DIR}/conf.d/fake-site.conf" << 'EOF'
server {
    listen 127.0.0.1:8080;
    server_name _;
    
    root /var/www/html;
    index index.html index.htm;
    
    location / {
        try_files $uri $uri/ =404;
    }
    
    error_page 404 /404.html;
}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# FAKE WEBSITE CONTENT GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_random_title() {
    local titles=("Welcome" "Home" "Professional Services" "Portfolio" "About Us" "Company" "Solutions")
    echo "${titles[$RANDOM % ${#titles[@]}]}"
}

create_default_fake_site() {
    local site_dir="${1:-${NGINX_HTML_DIR}}"
    mkdir -p "${site_dir}"
    local random_title=$(generate_random_title)
    
    cat > "${site_dir}/index.html" << EOF
<!DOCTYPE html>
<html><head><title>${random_title}</title></head><body><h1>${random_title}</h1><p>Site under maintenance.</p></body></html>
EOF
    chown -R www-data:www-data "${site_dir}"
}

setup_fake_website() {
    set_phase "Fake Website Setup"
    local site_dir="${NGINX_HTML_DIR}"
    local temp_dir=$(mktemp -d)
    log_info "Setting up fake website..."
    
    # Try download template
    local source_url="${FAKE_SITE_SOURCES[$RANDOM % ${#FAKE_SITE_SOURCES[@]}]}"
    if wget -q -O "${temp_dir}/templates.zip" "${source_url}" 2>/dev/null; then
        unzip -q "${temp_dir}/templates.zip" -d "${temp_dir}/extracted" 2>/dev/null || true
        # Simple extraction logic...
        if cp -r "${temp_dir}/extracted/"*/* "${site_dir}/" 2>/dev/null; then
            log_success "Fake website installed"
        else
            create_default_fake_site "${site_dir}"
        fi
    else
        create_default_fake_site "${site_dir}"
    fi
    rm -rf "${temp_dir}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DH PARAMETERS
# ═══════════════════════════════════════════════════════════════════════════════

generate_dhparam() {
    local dhparam_file="${NGINX_CONF_DIR}/dhparam.pem"
    if [[ ! -f "${dhparam_file}" ]]; then
        log_info "Generating DH parameters..."
        openssl dhparam -out "${dhparam_file}" 2048 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONTROL
# ═══════════════════════════════════════════════════════════════════════════════

test_nginx_config() {
    nginx -t &>/dev/null
}

restart_nginx() {
    if test_nginx_config; then systemctl restart nginx; fi
}

reload_nginx() {
    if test_nginx_config; then systemctl reload nginx; fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

setup_nginx() {
    install_nginx
    rm -f "${NGINX_ENABLED_DIR}/default" "${NGINX_SITES_DIR}/default"
    configure_nginx_main
    
    # configure_sni_routing  <-- УДАЛЕНО: Чтобы не занимать 443 порт Nginx'ом
    
    configure_fake_site_server
    setup_fake_website
    generate_dhparam
    
    if test_nginx_config; then
        systemctl enable nginx
        systemctl restart nginx
        log_success "Nginx setup completed (Panel will be on port 8443)"
    else
        log_error "Nginx setup failed"
        return 1
    fi
}

export -f setup_nginx install_nginx configure_marzban_panel_server restart_nginx reload_nginx
