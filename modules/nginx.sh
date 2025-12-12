#!/bin/bash
# =============================================================================
# Module: nginx.sh
# Description: Host Nginx installation, SNI stream config, fake website setup
# =============================================================================

set -euo pipefail

# Source core module if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# FAKE WEBSITE TEMPLATES
# =============================================================================
# List of GitHub repositories with HTML templates
readonly FAKE_SITE_SOURCES=(
    "https://github.com/learning-zone/website-templates/archive/master.zip"
    "https://github.com/designmodo/starter/archive/master.zip"
)

# Fallback minimal template
create_minimal_fake_site() {
    local site_dir="$1"
    
    mkdir -p "${site_dir}"
    
    cat > "${site_dir}/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
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
        h1 {
            font-size: 3rem;
            margin-bottom: 1rem;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }
        p {
            font-size: 1.2rem;
            opacity: 0.9;
            max-width: 600px;
            line-height: 1.6;
        }
        .status {
            margin-top: 2rem;
            padding: 1rem 2rem;
            background: rgba(255,255,255,0.2);
            border-radius: 50px;
            display: inline-block;
        }
        .status::before {
            content: '●';
            color: #4ade80;
            margin-right: 0.5rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome</h1>
        <p>This server is operational and serving content securely.</p>
        <div class="status">System Online</div>
    </div>
</body>
</html>
EOF

    # Create robots.txt
    cat > "${site_dir}/robots.txt" << 'EOF'
User-agent: *
Disallow: /
EOF

    # Create favicon
    touch "${site_dir}/favicon.ico"
    
    log_success "Minimal fake site created"
}

# =============================================================================
# DOWNLOAD FAKE WEBSITE
# =============================================================================
setup_fake_website() {
    log_step "Setting up Fake Website (Camouflage)"
    
    local site_dir="${FAKE_SITE_DIR:-/var/www/html}"
    
    # Backup existing site
    if [[ -d "${site_dir}" ]] && [[ "$(ls -A "${site_dir}" 2>/dev/null)" ]]; then
        backup_file "${site_dir}/index.html"
        rm -rf "${site_dir:?}"/*
    fi
    
    mkdir -p "${site_dir}"
    
    # Try to download a template
    local download_success=false
    
    if [[ "${FAKE_SITE_URL:-}" != "" ]]; then
        log_info "Downloading custom fake site from: ${FAKE_SITE_URL}"
        if curl -sL "${FAKE_SITE_URL}" -o /tmp/fake-site.zip && unzip -q /tmp/fake-site.zip -d /tmp/fake-site; then
            # Find HTML files and copy
            local html_dir
            html_dir=$(find /tmp/fake-site -name "index.html" -printf '%h\n' | head -1)
            if [[ -n "${html_dir}" ]]; then
                cp -r "${html_dir}"/* "${site_dir}/"
                download_success=true
            fi
            rm -rf /tmp/fake-site /tmp/fake-site.zip
        fi
    fi
    
    if [[ "${download_success}" != "true" ]]; then
        log_info "Creating minimal fake site..."
        create_minimal_fake_site "${site_dir}"
    fi
    
    # Set permissions
    chown -R www-data:www-data "${site_dir}"
    chmod -R 755 "${site_dir}"
    
    register_rollback "rm -rf ${site_dir}"
    
    log_success "Fake website configured at ${site_dir}"
}

# =============================================================================
# INSTALL NGINX
# =============================================================================
install_nginx() {
    log_step "Installing Nginx"
    
    if is_package_installed nginx; then
        local nginx_ver
        nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        log_info "Nginx already installed: ${nginx_ver}"
        return 0
    fi
    
    # Install Nginx with stream module
    install_packages nginx libnginx-mod-stream
    
    register_rollback "apt-get remove -y nginx libnginx-mod-stream"
    
    # Verify stream module
    if nginx -V 2>&1 | grep -q "with-stream"; then
        log_success "Nginx installed with stream module"
    else
        log_warn "Nginx stream module may not be available"
    fi
}

# =============================================================================
# GENERATE DH PARAMETERS
# =============================================================================
generate_dhparam() {
    log_step "Generating DH Parameters"
    
    local dhparam_file="/etc/nginx/dhparam.pem"
    
    if [[ -f "${dhparam_file}" ]]; then
        log_info "DH parameters already exist"
        return 0
    fi
    
    log_warn "Generating DH parameters (this may take several minutes)..."
    
    # Use 2048 bits for faster generation (still secure)
    openssl dhparam -out "${dhparam_file}" 2048 &
    local pid=$!
    
    # Show spinner while generating
    local count=0
    while kill -0 "${pid}" 2>/dev/null; do
        printf "\r  Generating... %ds elapsed" "${count}"
        sleep 5
        ((count+=5))
    done
    printf "\r"
    
    wait "${pid}"
    
    if [[ -f "${dhparam_file}" ]]; then
        chmod 600 "${dhparam_file}"
        log_success "DH parameters generated"
    else
        log_error "Failed to generate DH parameters"
        return 1
    fi
}

# =============================================================================
# CONFIGURE NGINX
# =============================================================================
configure_nginx() {
    log_step "Configuring Nginx"
    
    local nginx_conf="/etc/nginx/nginx.conf"
    local stream_conf="/etc/nginx/stream.conf"
    local sites_dir="/etc/nginx/sites-available"
    local enabled_dir="/etc/nginx/sites-enabled"
    
    # Backup existing configs
    backup_file "${nginx_conf}"
    
    # Remove default site
    rm -f "${enabled_dir}/default" 2>/dev/null || true
    
    # Create directories
    mkdir -p /etc/nginx/stream.d
    mkdir -p /etc/nginx/snippets
    
    # Process main nginx.conf template
    if [[ -f "${TEMPLATES_DIR}/nginx.conf.tpl" ]]; then
        process_template "${TEMPLATES_DIR}/nginx.conf.tpl" "${nginx_conf}"
    else
        # Generate nginx.conf inline
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
    # Basic Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    # MIME types
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # SSL Settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    # Gzip Settings
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript 
               application/rss+xml application/atom+xml image/svg+xml;

    # Rate limiting zones
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=addr:10m;

    # Include additional configs
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

# Stream module for SNI routing
stream {
    log_format stream '$remote_addr [$time_local] $protocol $status $bytes_sent $bytes_received $session_time "$ssl_preread_server_name"';
    access_log /var/log/nginx/stream.log stream;
    
    include /etc/nginx/stream.d/*.conf;
}
EOF
    fi
    
    register_rollback "rm -f ${nginx_conf} && apt-get install --reinstall -y nginx"
    
    log_success "Nginx main configuration created"
}

# =============================================================================
# CONFIGURE SNI ROUTING (STREAM)
# =============================================================================
configure_sni_routing() {
    log_step "Configuring SNI Routing"
    
    local stream_conf="/etc/nginx/stream.d/sni-routing.conf"
    
    # Get configuration values
    local panel_domain="${PANEL_DOMAIN:-}"
    local reality_domain="${REALITY_DEST:-}"
    local xray_port="${XRAY_PORT:-8443}"
    local marzban_port="${MARZBAN_PORT:-8000}"
    
    if [[ -z "${panel_domain}" ]]; then
        log_error "PANEL_DOMAIN is not set"
        return 1
    fi
    
    # Create SNI routing configuration
    cat > "${stream_conf}" << EOF
# =============================================================================
# SNI-based routing configuration
# Generated by Marzban Installer
# =============================================================================

# Upstream definitions
upstream xray_backend {
    server 127.0.0.1:${xray_port};
}

upstream marzban_backend {
    server 127.0.0.1:${marzban_port};
}

upstream fake_site_backend {
    server 127.0.0.1:8080;
}

# SNI map for routing decisions
map \$ssl_preread_server_name \$backend_name {
    # Panel domain -> Marzban (will terminate SSL)
    ${panel_domain}     marzban_backend;
    
    # Reality destination domains -> Xray
EOF

    # Add Reality domains if configured
    if [[ -n "${reality_domain}" ]]; then
        echo "    ${reality_domain}     xray_backend;" >> "${stream_conf}"
    fi
    
    # Continue with default
    cat >> "${stream_conf}" << EOF
    
    # Default -> Fake website
    default             fake_site_backend;
}

# Main listener on port 443
server {
    listen 443;
    listen [::]:443;
    
    ssl_preread on;
    proxy_pass \$backend_name;
    
    # Proxy settings
    proxy_connect_timeout 10s;
    proxy_timeout 300s;
    proxy_buffer_size 16k;
}
EOF

    register_rollback "rm -f ${stream_conf}"
    
    log_success "SNI routing configured"
}

# =============================================================================
# CONFIGURE FAKE SITE SERVER BLOCK
# =============================================================================
configure_fake_site_server() {
    log_step "Configuring Fake Site Server Block"
    
    local site_conf="/etc/nginx/sites-available/fake-site"
    local site_dir="${FAKE_SITE_DIR:-/var/www/html}"
    
    cat > "${site_conf}" << EOF
# Fake site server - listens on 8080 for SNI fallback
server {
    listen 127.0.0.1:8080 default_server;
    listen [::1]:8080 default_server;
    
    server_name _;
    root ${site_dir};
    index index.html index.htm;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Hide sensitive files
    location ~ /\. {
        deny all;
    }
    
    # Error pages
    error_page 404 /index.html;
    error_page 500 502 503 504 /index.html;
}
EOF

    # Enable site
    ln -sf "${site_conf}" "/etc/nginx/sites-enabled/fake-site"
    
    register_rollback "rm -f ${site_conf} /etc/nginx/sites-enabled/fake-site"
    
    log_success "Fake site server block configured"
}

# =============================================================================
# CONFIGURE MARZBAN PANEL PROXY
# =============================================================================
configure_panel_proxy() {
    log_step "Configuring Marzban Panel Proxy"
    
    local panel_domain="${PANEL_DOMAIN:-}"
    local marzban_port="${MARZBAN_PORT:-8000}"
    local panel_conf="/etc/nginx/sites-available/marzban-panel"
    
    if [[ -z "${panel_domain}" ]]; then
        log_error "PANEL_DOMAIN is not set"
        return 1
    fi
    
    # Note: SSL will be added by certbot later
    cat > "${panel_conf}" << EOF
# Marzban Panel reverse proxy
server {
    listen 127.0.0.1:${marzban_port} ssl http2;
    
    server_name ${panel_domain};
    
    # SSL certificates (will be replaced by Certbot)
    ssl_certificate /etc/nginx/ssl/self-signed.crt;
    ssl_certificate_key /etc/nginx/ssl/self-signed.key;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    
    # Rate limiting
    limit_req zone=general burst=20 nodelay;
    limit_conn addr 10;
    
    # Proxy to Marzban dashboard (runs on 8001 internally)
    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        proxy_buffering off;
    }
    
    # WebSocket support for dashboard
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

    # Create self-signed certificate for initial setup
    create_self_signed_cert
    
    # Enable site
    ln -sf "${panel_conf}" "/etc/nginx/sites-enabled/marzban-panel"
    
    register_rollback "rm -f ${panel_conf} /etc/nginx/sites-enabled/marzban-panel"
    
    log_success "Marzban panel proxy configured"
}

# =============================================================================
# CREATE SELF-SIGNED CERTIFICATE
# =============================================================================
create_self_signed_cert() {
    local ssl_dir="/etc/nginx/ssl"
    local cert_file="${ssl_dir}/self-signed.crt"
    local key_file="${ssl_dir}/self-signed.key"
    
    if [[ -f "${cert_file}" ]] && [[ -f "${key_file}" ]]; then
        log_info "Self-signed certificate already exists"
        return 0
    fi
    
    mkdir -p "${ssl_dir}"
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${key_file}" \
        -out "${cert_file}" \
        -subj "/CN=localhost" \
        2>/dev/null
    
    chmod 600 "${key_file}"
    chmod 644 "${cert_file}"
    
    log_success "Self-signed certificate created"
}

# =============================================================================
# TEST NGINX CONFIGURATION
# =============================================================================
test_nginx_config() {
    log_info "Testing Nginx configuration..."
    
    if nginx -t 2>&1; then
        log_success "Nginx configuration is valid"
        return 0
    else
        log_error "Nginx configuration test failed"
        nginx -t
        return 1
    fi
}

# =============================================================================
# START/RESTART NGINX
# =============================================================================
start_nginx() {
    log_step "Starting Nginx"
    
    # Test configuration first
    if ! test_nginx_config; then
        return 1
    fi
    
    # Enable and start Nginx
    systemctl enable nginx
    
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
        log_success "Nginx reloaded"
    else
        systemctl start nginx
        log_success "Nginx started"
    fi
    
    # Verify
    if ! wait_for_service nginx 10; then
        log_error "Nginx failed to start"
        systemctl status nginx
        return 1
    fi
    
    log_success "Nginx is running"
}

# =============================================================================
# MAIN NGINX SETUP
# =============================================================================
setup_nginx() {
    log_step "=== NGINX SETUP ==="
    
    install_nginx
    generate_dhparam
    configure_nginx
    setup_fake_website
    configure_sni_routing
    configure_fake_site_server
    configure_panel_proxy
    test_nginx_config
    start_nginx
    
    log_success "Nginx setup completed"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f setup_fake_website
export -f install_nginx
export -f generate_dhparam
export -f configure_nginx
export -f configure_sni_routing
export -f configure_fake_site_server
export -f configure_panel_proxy
export -f test_nginx_config
export -f start_nginx
export -f setup_nginx
