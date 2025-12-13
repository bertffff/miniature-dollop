#!/bin/bash
# =============================================================================
# Module: nginx.sh
# Description: Nginx installation, SNI routing, random fake website generator
# Version: 2.0.0 - With template randomization
# =============================================================================

set -euo pipefail

if [[ -z "${CORE_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# FAKE WEBSITE TEMPLATE SOURCES
# =============================================================================
readonly FAKE_SITE_TEMPLATES=(
    "https://github.com/cortez24rus/simple-web-templates/archive/refs/heads/main.zip"
    "https://github.com/learning-zone/website-templates/archive/refs/heads/master.zip"
)

# =============================================================================
# RANDOM FAKE SITE SETUP
# =============================================================================
setup_random_fake_site() {
    log_step "Setting up Random Fake Website (Camouflage)"
    
    local site_dir="${FAKE_SITE_DIR:-/var/www/html}"
    mkdir -p "${site_dir}"
    
    # Backup existing
    [[ -d "${site_dir}" ]] && [[ "$(ls -A "${site_dir}" 2>/dev/null)" ]] && rm -rf "${site_dir:?}"/*
    
    local download_success=false
    local temp_dir="/tmp/fake_site_$$"
    mkdir -p "${temp_dir}"
    
    # Try custom URL first
    if [[ -n "${FAKE_SITE_URL:-}" ]]; then
        log_info "Downloading custom template: ${FAKE_SITE_URL}"
        if wget -q --timeout=30 -O "${temp_dir}/template.zip" "${FAKE_SITE_URL}" 2>/dev/null; then
            if unzip -q "${temp_dir}/template.zip" -d "${temp_dir}/extracted" 2>/dev/null; then
                download_success=true
            fi
        fi
    fi
    
    # Try predefined templates
    if [[ "${download_success}" != "true" ]]; then
        for url in "${FAKE_SITE_TEMPLATES[@]}"; do
            log_info "Trying template source: ${url}"
            if wget -q --timeout=30 --tries=3 -O "${temp_dir}/template.zip" "${url}" 2>/dev/null; then
                if unzip -q "${temp_dir}/template.zip" -d "${temp_dir}/extracted" 2>/dev/null; then
                    download_success=true
                    break
                fi
            fi
        done
    fi
    
    if [[ "${download_success}" == "true" ]]; then
        # Find template directories
        local templates_root
        templates_root=$(find "${temp_dir}/extracted" -type d -maxdepth 2 -mindepth 1 | head -1)
        
        if [[ -d "${templates_root}" ]]; then
            cd "${templates_root}"
            
            # Remove junk files
            rm -rf assets ".gitattributes" "README.md" "_config.yml" ".git" 2>/dev/null || true
            
            # Find subdirectories (actual templates)
            local subdirs=()
            while IFS= read -r -d '' dir; do
                subdirs+=("$dir")
            done < <(find . -maxdepth 1 -type d ! -name '.' -print0 2>/dev/null)
            
            if [[ ${#subdirs[@]} -gt 0 ]]; then
                # Select random template
                local random_idx=$((RANDOM % ${#subdirs[@]}))
                local selected="${subdirs[$random_idx]}"
                
                log_info "Selected random template: $(basename "${selected}")"
                
                # Copy to site directory
                cp -a "${selected}/." "${site_dir}/" 2>/dev/null || true
                
                # Clean up template junk
                find "${site_dir}" -name "README*" -delete 2>/dev/null || true
                find "${site_dir}" -name ".git*" -exec rm -rf {} + 2>/dev/null || true
                find "${site_dir}" -name "*.md" -delete 2>/dev/null || true
                
                download_success=true
            elif [[ -f "${templates_root}/index.html" ]]; then
                # Single template, use directly
                cp -a "${templates_root}/." "${site_dir}/"
                download_success=true
            fi
        fi
    fi
    
    # Cleanup temp
    rm -rf "${temp_dir}"
    
    # Fallback to minimal site
    if [[ "${download_success}" != "true" ]] || [[ ! -f "${site_dir}/index.html" ]]; then
        log_warn "Using fallback minimal template"
        create_minimal_fake_site "${site_dir}"
    fi
    
    # Create robots.txt
    cat > "${site_dir}/robots.txt" << 'EOF'
User-agent: *
Disallow: /
EOF
    
    # Set permissions
    chown -R www-data:www-data "${site_dir}" 2>/dev/null || true
    chmod -R 755 "${site_dir}"
    
    register_rollback "Remove fake site" "rm -rf ${site_dir}" "cleanup"
    
    log_success "Fake website configured at ${site_dir}"
}

# =============================================================================
# MINIMAL FALLBACK TEMPLATE
# =============================================================================
create_minimal_fake_site() {
    local site_dir="$1"
    mkdir -p "${site_dir}"
    
    # Generate random company name elements
    local prefixes=("Tech" "Digital" "Cloud" "Smart" "Pro" "Global" "Net" "Web" "Data" "Cyber")
    local suffixes=("Solutions" "Systems" "Services" "Labs" "Works" "Hub" "Zone" "Base" "Core" "Point")
    local company="${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
    company+=" ${suffixes[$((RANDOM % ${#suffixes[@]}))]}"
    
    cat > "${site_dir}/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${company} - Professional Services</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            text-align: center;
            color: white;
            padding: 2rem;
        }
        h1 { font-size: 3rem; margin-bottom: 1rem; text-shadow: 2px 2px 4px rgba(0,0,0,0.3); }
        p { font-size: 1.2rem; opacity: 0.9; max-width: 600px; line-height: 1.6; }
        .status {
            margin-top: 2rem;
            padding: 1rem 2rem;
            background: rgba(255,255,255,0.2);
            border-radius: 50px;
            display: inline-block;
        }
        .status::before { content: '●'; color: #4ade80; margin-right: 0.5rem; }
    </style>
</head>
<body>
    <div class="container">
        <h1>${company}</h1>
        <p>Delivering excellence in digital solutions. We help businesses transform and grow.</p>
        <div class="status">System Online</div>
    </div>
</body>
</html>
EOF

    touch "${site_dir}/favicon.ico"
    log_success "Minimal fake site created"
}

# =============================================================================
# INSTALL NGINX
# =============================================================================
install_nginx() {
    log_step "Installing Nginx"
    
    if is_package_installed nginx; then
        local nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        log_info "Nginx already installed: ${nginx_ver}"
        return 0
    fi
    
    install_packages nginx libnginx-mod-stream
    
    register_rollback "Remove Nginx" "apt-get remove -y nginx libnginx-mod-stream" "normal"
    
    nginx -V 2>&1 | grep -q "with-stream" && log_success "Nginx with stream module" || log_warn "Stream module may be missing"
}

# =============================================================================
# DH PARAMETERS
# =============================================================================
generate_dhparam() {
    log_step "Generating DH Parameters"
    
    local dhparam_file="/etc/nginx/ssl/dhparam.pem"
    mkdir -p "$(dirname "${dhparam_file}")"
    
    [[ -f "${dhparam_file}" ]] && { log_info "DH parameters exist"; return 0; }
    
    log_warn "Generating DH parameters (this takes several minutes)..."
    
    openssl dhparam -out "${dhparam_file}" 2048 &
    local pid=$!
    
    local count=0
    while kill -0 "${pid}" 2>/dev/null; do
        printf "\r  Generating... %ds" "${count}"
        sleep 5
        ((count+=5))
    done
    printf "\r"
    
    wait "${pid}"
    
    [[ -f "${dhparam_file}" ]] && { chmod 600 "${dhparam_file}"; log_success "DH parameters generated"; } || { log_error "DH generation failed"; return 1; }
}

# =============================================================================
# CONFIGURE NGINX
# =============================================================================
configure_nginx() {
    log_step "Configuring Nginx"
    
    local nginx_conf="/etc/nginx/nginx.conf"
    backup_file "${nginx_conf}"
    
    # Remove default site
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    
    # Create directories
    mkdir -p /etc/nginx/stream.d /etc/nginx/snippets /etc/nginx/ssl
    
    cat > "${nginx_conf}" << 'EOF'
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
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript 
               application/rss+xml application/atom+xml image/svg+xml;

    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=addr:10m;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

stream {
    log_format stream '$remote_addr [$time_local] $protocol $status $bytes_sent $bytes_received $session_time "$ssl_preread_server_name"';
    access_log /var/log/nginx/stream.log stream;
    
    include /etc/nginx/stream.d/*.conf;
}
EOF

    register_rollback "Restore Nginx config" "apt-get install --reinstall -y nginx" "normal"
    log_success "Nginx main configuration created"
}

# =============================================================================
# SNI ROUTING CONFIGURATION
# =============================================================================
configure_sni_routing() {
    log_step "Configuring SNI Routing"
    
    local stream_conf="/etc/nginx/stream.d/sni-routing.conf"
    local panel_domain="${PANEL_DOMAIN:-}"
    local reality_dest="${REALITY_DEST:-}"
    local xray_port="${XRAY_PORT:-8443}"
    local marzban_port="${MARZBAN_PORT:-8000}"
    
    [[ -z "${panel_domain}" ]] && { log_error "PANEL_DOMAIN not set"; return 1; }
    
    cat > "${stream_conf}" << EOF
# SNI-based routing
# Generated by Marzban Installer

upstream xray_backend {
    server 127.0.0.1:${xray_port};
}

upstream marzban_backend {
    server 127.0.0.1:${marzban_port};
}

upstream fake_site_backend {
    server 127.0.0.1:8080;
}

map \$ssl_preread_server_name \$backend_name {
    ${panel_domain}     marzban_backend;
EOF

    # Add Reality domains
    [[ -n "${reality_dest}" ]] && echo "    ${reality_dest}     xray_backend;" >> "${stream_conf}"
    
    cat >> "${stream_conf}" << 'EOF'
    default             fake_site_backend;
}

server {
    listen 443;
    listen [::]:443;
    
    ssl_preread on;
    proxy_pass $backend_name;
    
    proxy_connect_timeout 10s;
    proxy_timeout 300s;
    proxy_buffer_size 16k;
}
EOF

    register_rollback "Remove SNI routing" "rm -f ${stream_conf}" "cleanup"
    log_success "SNI routing configured"
}

# =============================================================================
# FAKE SITE SERVER BLOCK
# =============================================================================
configure_fake_site_server() {
    log_step "Configuring Fake Site Server Block"
    
    local site_conf="/etc/nginx/sites-available/fake-site"
    local site_dir="${FAKE_SITE_DIR:-/var/www/html}"
    
    cat > "${site_conf}" << EOF
server {
    listen 127.0.0.1:8080 default_server;
    listen [::1]:8080 default_server;
    
    server_name _;
    root ${site_dir};
    index index.html index.htm;
    
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location ~ /\. {
        deny all;
    }
    
    error_page 404 /index.html;
    error_page 500 502 503 504 /index.html;
}
EOF

    ln -sf "${site_conf}" "/etc/nginx/sites-enabled/fake-site"
    register_rollback "Remove fake site config" "rm -f ${site_conf} /etc/nginx/sites-enabled/fake-site" "cleanup"
    log_success "Fake site server configured"
}

# =============================================================================
# MARZBAN PANEL PROXY
# =============================================================================
configure_panel_proxy() {
    log_step "Configuring Marzban Panel Proxy"
    
    local panel_domain="${PANEL_DOMAIN:-}"
    local marzban_port="${MARZBAN_PORT:-8000}"
    local panel_conf="/etc/nginx/sites-available/marzban-panel"
    
    [[ -z "${panel_domain}" ]] && { log_error "PANEL_DOMAIN not set"; return 1; }
    
    cat > "${panel_conf}" << EOF
server {
    listen 127.0.0.1:${marzban_port} ssl http2;
    
    server_name ${panel_domain};
    
    ssl_certificate /etc/nginx/ssl/self-signed.crt;
    ssl_certificate_key /etc/nginx/ssl/self-signed.key;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    
    limit_req zone=general burst=20 nodelay;
    limit_conn addr 10;
    
    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
    
    location /api/ {
        proxy_pass http://127.0.0.1:8001/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    create_self_signed_cert
    ln -sf "${panel_conf}" "/etc/nginx/sites-enabled/marzban-panel"
    
    register_rollback "Remove panel proxy" "rm -f ${panel_conf} /etc/nginx/sites-enabled/marzban-panel" "cleanup"
    log_success "Marzban panel proxy configured"
}

# =============================================================================
# SELF-SIGNED CERTIFICATE
# =============================================================================
create_self_signed_cert() {
    local ssl_dir="/etc/nginx/ssl"
    local cert_file="${ssl_dir}/self-signed.crt"
    local key_file="${ssl_dir}/self-signed.key"
    
    [[ -f "${cert_file}" ]] && [[ -f "${key_file}" ]] && { log_info "Self-signed cert exists"; return 0; }
    
    mkdir -p "${ssl_dir}"
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${key_file}" -out "${cert_file}" \
        -subj "/CN=localhost" 2>/dev/null
    
    chmod 600 "${key_file}"
    chmod 644 "${cert_file}"
    
    log_success "Self-signed certificate created"
}

# =============================================================================
# TEST & START NGINX
# =============================================================================
test_nginx_config() {
    log_info "Testing Nginx configuration..."
    nginx -t 2>&1 && { log_success "Nginx config valid"; return 0; } || { log_error "Nginx config invalid"; nginx -t; return 1; }
}

start_nginx() {
    log_step "Starting Nginx"
    
    test_nginx_config || return 1
    
    systemctl enable nginx
    
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
        log_success "Nginx reloaded"
    else
        systemctl start nginx
        log_success "Nginx started"
    fi
    
    wait_for_service nginx 10 || { log_error "Nginx failed to start"; systemctl status nginx; return 1; }
    
    register_service "nginx"
    log_success "Nginx is running"
}

# =============================================================================
# MAIN
# =============================================================================
setup_nginx() {
    log_step "=== NGINX SETUP ==="
    
    install_nginx
    generate_dhparam
    configure_nginx
    
    if [[ "${INSTALL_FAKE_SITE:-true}" == "true" ]]; then
        setup_random_fake_site
    fi
    
    configure_sni_routing
    configure_fake_site_server
    configure_panel_proxy
    test_nginx_config
    start_nginx
    
    log_success "Nginx setup completed"
}

# Legacy function name for compatibility
setup_fake_website() {
    setup_random_fake_site
}

export -f setup_random_fake_site create_minimal_fake_site setup_fake_website
export -f install_nginx generate_dhparam configure_nginx
export -f configure_sni_routing configure_fake_site_server configure_panel_proxy
export -f create_self_signed_cert test_nginx_config start_nginx setup_nginx
