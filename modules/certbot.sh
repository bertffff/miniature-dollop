#!/bin/bash
# =============================================================================
# Module: certbot.sh
# Description: SSL certificate generation using Let's Encrypt / Certbot
# =============================================================================

set -euo pipefail

# Source core module if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# INSTALL CERTBOT
# =============================================================================
install_certbot() {
    log_step "Installing Certbot"
    
    if command -v certbot &>/dev/null; then
        local certbot_ver
        certbot_ver=$(certbot --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        log_info "Certbot already installed: ${certbot_ver}"
        return 0
    fi
    
    # Install certbot with nginx plugin
    install_packages certbot python3-certbot-nginx
    
    register_rollback "apt-get remove -y certbot python3-certbot-nginx"
    
    log_success "Certbot installed"
}

# =============================================================================
# VERIFY DOMAIN DNS
# =============================================================================
verify_domain_dns() {
    local domain="$1"
    local server_ip
    local dns_ip
    
    log_info "Verifying DNS for domain: ${domain}"
    
    # Get server's public IP
    server_ip=$(get_public_ip)
    
    # Get domain's DNS record
    dns_ip=$(dig +short A "${domain}" 2>/dev/null | head -1 || true)
    
    if [[ -z "${dns_ip}" ]]; then
        log_error "Could not resolve DNS for ${domain}"
        log_info "Please ensure the domain's A record points to: ${server_ip}"
        return 1
    fi
    
    if [[ "${dns_ip}" != "${server_ip}" ]]; then
        log_error "DNS mismatch!"
        log_info "  Domain ${domain} resolves to: ${dns_ip}"
        log_info "  Server public IP: ${server_ip}"
        log_info "Please update DNS to point to ${server_ip}"
        
        if ! confirm "Continue anyway (certificate may fail)?"; then
            return 1
        fi
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
    
    log_step "Obtaining SSL Certificate (Standalone Mode)"
    
    # Stop Nginx temporarily if running
    local nginx_was_running=false
    if systemctl is-active --quiet nginx; then
        nginx_was_running=true
        log_info "Stopping Nginx temporarily..."
        systemctl stop nginx
    fi
    
    # Build certbot command
    local certbot_cmd="certbot certonly --standalone"
    certbot_cmd+=" -d ${domain}"
    certbot_cmd+=" --non-interactive"
    certbot_cmd+=" --agree-tos"
    
    if [[ -n "${email}" ]]; then
        certbot_cmd+=" --email ${email}"
    else
        certbot_cmd+=" --register-unsafely-without-email"
    fi
    
    # Add staging flag for testing if enabled
    if [[ "${CERTBOT_STAGING:-false}" == "true" ]]; then
        certbot_cmd+=" --staging"
        log_warn "Using Let's Encrypt staging server (for testing)"
    fi
    
    # Execute certbot
    log_info "Running: ${certbot_cmd}"
    if eval "${certbot_cmd}"; then
        log_success "Certificate obtained successfully"
    else
        log_error "Failed to obtain certificate"
        
        # Restart Nginx if it was running
        if [[ "${nginx_was_running}" == "true" ]]; then
            systemctl start nginx
        fi
        return 1
    fi
    
    # Restart Nginx if it was running
    if [[ "${nginx_was_running}" == "true" ]]; then
        log_info "Restarting Nginx..."
        systemctl start nginx
    fi
}

# =============================================================================
# OBTAIN CERTIFICATE (NGINX PLUGIN)
# =============================================================================
obtain_certificate_nginx() {
    local domain="$1"
    local email="${2:-}"
    
    log_step "Obtaining SSL Certificate (Nginx Plugin)"
    
    # Ensure Nginx is running
    if ! systemctl is-active --quiet nginx; then
        log_error "Nginx must be running for --nginx mode"
        return 1
    fi
    
    # Build certbot command
    local certbot_cmd="certbot --nginx"
    certbot_cmd+=" -d ${domain}"
    certbot_cmd+=" --non-interactive"
    certbot_cmd+=" --agree-tos"
    certbot_cmd+=" --redirect"  # Force HTTPS redirect
    
    if [[ -n "${email}" ]]; then
        certbot_cmd+=" --email ${email}"
    else
        certbot_cmd+=" --register-unsafely-without-email"
    fi
    
    # Add staging flag for testing if enabled
    if [[ "${CERTBOT_STAGING:-false}" == "true" ]]; then
        certbot_cmd+=" --staging"
        log_warn "Using Let's Encrypt staging server (for testing)"
    fi
    
    # Execute certbot
    log_info "Running: ${certbot_cmd}"
    if eval "${certbot_cmd}"; then
        log_success "Certificate obtained and Nginx configured"
    else
        log_error "Failed to obtain certificate"
        return 1
    fi
}

# =============================================================================
# OBTAIN CERTIFICATE (WEBROOT)
# =============================================================================
obtain_certificate_webroot() {
    local domain="$1"
    local email="${2:-}"
    local webroot="${3:-/var/www/html}"
    
    log_step "Obtaining SSL Certificate (Webroot Mode)"
    
    # Ensure webroot exists
    mkdir -p "${webroot}/.well-known/acme-challenge"
    chown -R www-data:www-data "${webroot}"
    
    # Build certbot command
    local certbot_cmd="certbot certonly --webroot"
    certbot_cmd+=" -w ${webroot}"
    certbot_cmd+=" -d ${domain}"
    certbot_cmd+=" --non-interactive"
    certbot_cmd+=" --agree-tos"
    
    if [[ -n "${email}" ]]; then
        certbot_cmd+=" --email ${email}"
    else
        certbot_cmd+=" --register-unsafely-without-email"
    fi
    
    # Add staging flag for testing if enabled
    if [[ "${CERTBOT_STAGING:-false}" == "true" ]]; then
        certbot_cmd+=" --staging"
    fi
    
    # Execute certbot
    log_info "Running: ${certbot_cmd}"
    if eval "${certbot_cmd}"; then
        log_success "Certificate obtained successfully"
    else
        log_error "Failed to obtain certificate"
        return 1
    fi
}

# =============================================================================
# UPDATE NGINX WITH REAL CERTIFICATE
# =============================================================================
update_nginx_ssl() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/${domain}"
    local panel_conf="/etc/nginx/sites-available/marzban-panel"
    
    log_info "Updating Nginx configuration with Let's Encrypt certificate..."
    
    if [[ ! -d "${cert_path}" ]]; then
        log_error "Certificate not found at ${cert_path}"
        return 1
    fi
    
    # Update the SSL certificate paths in Nginx config
    if [[ -f "${panel_conf}" ]]; then
        sed -i "s|ssl_certificate .*|ssl_certificate ${cert_path}/fullchain.pem;|" "${panel_conf}"
        sed -i "s|ssl_certificate_key .*|ssl_certificate_key ${cert_path}/privkey.pem;|" "${panel_conf}"
        
        # Add OCSP stapling
        if ! grep -q "ssl_stapling" "${panel_conf}"; then
            sed -i "/ssl_certificate_key/a\\    ssl_stapling on;\n    ssl_stapling_verify on;\n    ssl_trusted_certificate ${cert_path}/chain.pem;" "${panel_conf}"
        fi
        
        log_success "Nginx SSL configuration updated"
    fi
    
    # Test and reload Nginx
    if nginx -t 2>&1; then
        systemctl reload nginx
        log_success "Nginx reloaded with new certificate"
    else
        log_error "Nginx configuration test failed"
        return 1
    fi
}

# =============================================================================
# SETUP AUTO-RENEWAL
# =============================================================================
setup_auto_renewal() {
    log_step "Setting up Certificate Auto-Renewal"
    
    # Certbot creates a systemd timer by default on newer systems
    if systemctl list-timers | grep -q certbot; then
        log_info "Certbot timer already configured"
        systemctl enable certbot.timer
        systemctl start certbot.timer
        log_success "Auto-renewal enabled via systemd timer"
        return 0
    fi
    
    # Fallback to cron job
    local cron_file="/etc/cron.d/certbot-renew"
    
    cat > "${cron_file}" << 'EOF'
# Certbot auto-renewal
# Runs twice daily at random times
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 */12 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF

    chmod 644 "${cron_file}"
    
    register_rollback "rm -f ${cron_file}"
    
    log_success "Auto-renewal cron job created"
}

# =============================================================================
# TEST CERTIFICATE
# =============================================================================
test_certificate() {
    local domain="$1"
    
    log_info "Testing SSL certificate for ${domain}..."
    
    # Check certificate files exist
    local cert_path="/etc/letsencrypt/live/${domain}"
    
    if [[ ! -f "${cert_path}/fullchain.pem" ]]; then
        log_error "Certificate file not found"
        return 1
    fi
    
    # Check certificate validity
    local expiry
    expiry=$(openssl x509 -enddate -noout -in "${cert_path}/fullchain.pem" | cut -d= -f2)
    log_info "Certificate expires: ${expiry}"
    
    # Check if certificate is valid for domain
    local cert_domain
    cert_domain=$(openssl x509 -noout -subject -in "${cert_path}/fullchain.pem" | grep -oP 'CN\s*=\s*\K[^,/]+')
    
    if [[ "${cert_domain}" == "${domain}" ]] || openssl x509 -noout -text -in "${cert_path}/fullchain.pem" | grep -q "DNS:${domain}"; then
        log_success "Certificate is valid for ${domain}"
    else
        log_warn "Certificate may not be valid for ${domain}"
    fi
    
    # Test SSL connection
    if command -v curl &>/dev/null; then
        if curl -sI "https://${domain}" --max-time 10 &>/dev/null; then
            log_success "HTTPS connection test passed"
        else
            log_warn "HTTPS connection test failed (this may be normal if service not yet started)"
        fi
    fi
}

# =============================================================================
# LIST CERTIFICATES
# =============================================================================
list_certificates() {
    log_step "Listing Certificates"
    
    certbot certificates
}

# =============================================================================
# RENEW CERTIFICATES
# =============================================================================
renew_certificates() {
    log_step "Renewing Certificates"
    
    certbot renew --dry-run
    
    if confirm "Proceed with actual renewal?"; then
        certbot renew
        systemctl reload nginx
        log_success "Certificates renewed"
    fi
}

# =============================================================================
# REVOKE CERTIFICATE
# =============================================================================
revoke_certificate() {
    local domain="$1"
    
    log_warn "This will revoke the certificate for ${domain}"
    
    if ! confirm "Are you sure?"; then
        return 0
    fi
    
    certbot revoke --cert-name "${domain}"
    certbot delete --cert-name "${domain}"
    
    log_success "Certificate revoked and deleted"
}

# =============================================================================
# MAIN SSL SETUP
# =============================================================================
setup_ssl() {
    log_step "=== SSL CERTIFICATE SETUP ==="
    
    local domain="${PANEL_DOMAIN:-}"
    local email="${ADMIN_EMAIL:-}"
    
    if [[ -z "${domain}" ]]; then
        log_error "PANEL_DOMAIN is not set"
        return 1
    fi
    
    # Install certbot
    install_certbot
    
    # Verify DNS
    if ! verify_domain_dns "${domain}"; then
        log_warn "DNS verification failed. Skipping certificate generation."
        log_info "You can run 'certbot --nginx -d ${domain}' manually later."
        return 0
    fi
    
    # Check if certificate already exists
    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
        log_info "Certificate already exists for ${domain}"
        test_certificate "${domain}"
        setup_auto_renewal
        return 0
    fi
    
    # Choose method based on configuration
    local method="${CERTBOT_METHOD:-standalone}"
    
    case "${method}" in
        standalone)
            obtain_certificate_standalone "${domain}" "${email}"
            ;;
        nginx)
            obtain_certificate_nginx "${domain}" "${email}"
            ;;
        webroot)
            obtain_certificate_webroot "${domain}" "${email}"
            ;;
        *)
            log_error "Unknown certbot method: ${method}"
            return 1
            ;;
    esac
    
    # Update Nginx with new certificate
    update_nginx_ssl "${domain}"
    
    # Test certificate
    test_certificate "${domain}"
    
    # Setup auto-renewal
    setup_auto_renewal
    
    log_success "SSL setup completed"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f install_certbot
export -f verify_domain_dns
export -f obtain_certificate_standalone
export -f obtain_certificate_nginx
export -f obtain_certificate_webroot
export -f update_nginx_ssl
export -f setup_auto_renewal
export -f test_certificate
export -f list_certificates
export -f renew_certificates
export -f revoke_certificate
export -f setup_ssl
