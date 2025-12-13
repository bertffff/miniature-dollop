#!/bin/bash
# =============================================================================
# Module: certbot.sh
# Description: SSL certificate generation using Let's Encrypt / Certbot
# =============================================================================

set -euo pipefail

if [[ -z "${CORE_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# INSTALL CERTBOT
# =============================================================================
install_certbot() {
    log_step "Installing Certbot"
    
    if command -v certbot &>/dev/null; then
        local ver=$(certbot --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' || echo "unknown")
        log_info "Certbot already installed: ${ver}"
        return 0
    fi
    
    install_packages certbot python3-certbot-nginx
    register_rollback "Remove Certbot" "apt-get remove -y certbot python3-certbot-nginx" "normal"
    log_success "Certbot installed"
}

# =============================================================================
# VERIFY DNS
# =============================================================================
verify_domain_dns() {
    local domain="$1"
    local server_ip
    server_ip=$(get_public_ip)
    
    log_info "Verifying DNS for: ${domain}"
    
    local dns_ip
    dns_ip=$(dig +short A "${domain}" 2>/dev/null | head -1 || true)
    
    if [[ -z "${dns_ip}" ]]; then
        log_error "Cannot resolve DNS for ${domain}"
        log_info "Ensure A record points to: ${server_ip}"
        return 1
    fi
    
    if [[ "${dns_ip}" != "${server_ip}" ]]; then
        log_error "DNS mismatch: ${domain} -> ${dns_ip}, expected ${server_ip}"
        confirm "Continue anyway?" || return 1
    else
        log_success "DNS verified: ${domain} -> ${server_ip}"
    fi
    
    return 0
}

# =============================================================================
# OBTAIN CERTIFICATE (STANDALONE)
# =============================================================================
obtain_certificate_standalone() {
    local domain="$1"
    local email="${2:-}"
    
    log_step "Obtaining SSL Certificate (Standalone)"
    
    local nginx_was_running=false
    systemctl is-active --quiet nginx && { nginx_was_running=true; systemctl stop nginx; }
    
    local cmd="certbot certonly --standalone -d ${domain} --non-interactive --agree-tos"
    [[ -n "${email}" ]] && cmd+=" --email ${email}" || cmd+=" --register-unsafely-without-email"
    [[ "${USE_STAGING:-false}" == "true" ]] && { cmd+=" --staging"; log_warn "Using staging server"; }
    
    log_info "Running: ${cmd}"
    if eval "${cmd}"; then
        log_success "Certificate obtained"
    else
        log_error "Failed to obtain certificate"
        [[ "${nginx_was_running}" == "true" ]] && systemctl start nginx
        return 1
    fi
    
    [[ "${nginx_was_running}" == "true" ]] && systemctl start nginx
}

# =============================================================================
# OBTAIN CERTIFICATE (NGINX PLUGIN)
# =============================================================================
obtain_certificate_nginx() {
    local domain="$1"
    local email="${2:-}"
    
    log_step "Obtaining SSL Certificate (Nginx Plugin)"
    
    systemctl is-active --quiet nginx || { log_error "Nginx must be running"; return 1; }
    
    local cmd="certbot --nginx -d ${domain} --non-interactive --agree-tos --redirect"
    [[ -n "${email}" ]] && cmd+=" --email ${email}" || cmd+=" --register-unsafely-without-email"
    [[ "${USE_STAGING:-false}" == "true" ]] && cmd+=" --staging"
    
    log_info "Running: ${cmd}"
    eval "${cmd}" && log_success "Certificate obtained" || { log_error "Failed"; return 1; }
}

# =============================================================================
# UPDATE NGINX SSL
# =============================================================================
update_nginx_ssl() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/${domain}"
    local panel_conf="/etc/nginx/sites-available/marzban-panel"
    
    log_info "Updating Nginx SSL configuration..."
    
    [[ ! -d "${cert_path}" ]] && { log_error "Certificate not found: ${cert_path}"; return 1; }
    
    if [[ -f "${panel_conf}" ]]; then
        sed -i "s|ssl_certificate .*|ssl_certificate ${cert_path}/fullchain.pem;|" "${panel_conf}"
        sed -i "s|ssl_certificate_key .*|ssl_certificate_key ${cert_path}/privkey.pem;|" "${panel_conf}"
        
        grep -q "ssl_stapling" "${panel_conf}" || \
            sed -i "/ssl_certificate_key/a\\    ssl_stapling on;\n    ssl_stapling_verify on;\n    ssl_trusted_certificate ${cert_path}/chain.pem;" "${panel_conf}"
        
        log_success "Nginx SSL updated"
    fi
    
    nginx -t 2>&1 && systemctl reload nginx || { log_error "Nginx config invalid"; return 1; }
}

# =============================================================================
# AUTO-RENEWAL
# =============================================================================
setup_auto_renewal() {
    log_step "Setting up Auto-Renewal"
    
    if systemctl list-timers | grep -q certbot; then
        systemctl enable certbot.timer
        systemctl start certbot.timer
        log_success "Auto-renewal via systemd timer"
        return 0
    fi
    
    cat > /etc/cron.d/certbot-renew << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 */12 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF

    chmod 644 /etc/cron.d/certbot-renew
    register_rollback "Remove certbot cron" "rm -f /etc/cron.d/certbot-renew" "cleanup"
    log_success "Auto-renewal cron created"
}

# =============================================================================
# TEST CERTIFICATE
# =============================================================================
test_certificate() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/${domain}"
    
    log_info "Testing certificate for ${domain}..."
    
    [[ ! -f "${cert_path}/fullchain.pem" ]] && { log_error "Certificate not found"; return 1; }
    
    local expiry=$(openssl x509 -enddate -noout -in "${cert_path}/fullchain.pem" | cut -d= -f2)
    log_info "Expires: ${expiry}"
    
    local cert_domain=$(openssl x509 -noout -subject -in "${cert_path}/fullchain.pem" | grep -oP 'CN\s*=\s*\K[^,/]+')
    
    if [[ "${cert_domain}" == "${domain}" ]] || openssl x509 -noout -text -in "${cert_path}/fullchain.pem" | grep -q "DNS:${domain}"; then
        log_success "Certificate valid for ${domain}"
    else
        log_warn "Certificate may not be valid for ${domain}"
    fi
}

# =============================================================================
# MAIN SSL SETUP
# =============================================================================
setup_ssl() {
    log_step "=== SSL CERTIFICATE SETUP ==="
    
    local domain="${PANEL_DOMAIN:-}"
    local email="${ADMIN_EMAIL:-}"
    
    [[ -z "${domain}" ]] && { log_error "PANEL_DOMAIN not set"; return 1; }
    
    install_certbot
    
    if ! verify_domain_dns "${domain}"; then
        log_warn "DNS verification failed. Skipping certificate."
        log_info "Run 'certbot --nginx -d ${domain}' manually later."
        return 0
    fi
    
    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
        log_info "Certificate exists for ${domain}"
        test_certificate "${domain}"
        setup_auto_renewal
        return 0
    fi
    
    local method="${CERTBOT_METHOD:-standalone}"
    
    case "${method}" in
        standalone) obtain_certificate_standalone "${domain}" "${email}" ;;
        nginx) obtain_certificate_nginx "${domain}" "${email}" ;;
        *) log_error "Unknown method: ${method}"; return 1 ;;
    esac
    
    update_nginx_ssl "${domain}"
    test_certificate "${domain}"
    setup_auto_renewal
    
    log_success "SSL setup completed"
}

export -f install_certbot verify_domain_dns obtain_certificate_standalone obtain_certificate_nginx
export -f update_nginx_ssl setup_auto_renewal test_certificate setup_ssl
