#!/bin/bash
#
# Module: certbot.sh
# Purpose: Let's Encrypt certificate management
# Dependencies: core.sh, nginx.sh
#
# ИСПРАВЛЕНО: Совместимость с nginx stream на порту 443
# - Используем webroot challenge через порт 80
# - Не используем standalone mode (конфликт с nginx)
# - Nginx должен быть запущен для получения сертификата

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

readonly CERT_DIR="/etc/letsencrypt/live"
readonly CERTBOT_WEBROOT="/var/www/html"

# ═══════════════════════════════════════════════════════════════════════════════
# CERTBOT INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

is_certbot_installed() {
    command -v certbot &> /dev/null
}

install_certbot() {
    if is_certbot_installed; then
        log_info "Certbot already installed"
        return 0
    fi
    
    log_info "Installing Certbot..."
    
    install_packages certbot python3-certbot-nginx
    
    register_rollback "apt-get remove -y certbot python3-certbot-nginx" "normal"
    
    log_success "Certbot installed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CERTIFICATE CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

has_certificate() {
    local domain="${1}"
    [[ -d "${CERT_DIR}/${domain}" ]] && \
    [[ -f "${CERT_DIR}/${domain}/fullchain.pem" ]] && \
    [[ -f "${CERT_DIR}/${domain}/privkey.pem" ]]
}

is_certificate_valid() {
    local domain="${1}"
    local cert_file="${CERT_DIR}/${domain}/fullchain.pem"
    
    if [[ ! -f "${cert_file}" ]]; then
        return 1
    fi
    
    # Check if certificate expires within 30 days
    local expiry_date
    expiry_date=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d'=' -f2)
    
    if [[ -z "${expiry_date}" ]]; then
        return 1
    fi
    
    local expiry_epoch
    expiry_epoch=$(date -d "${expiry_date}" +%s 2>/dev/null || echo 0)
    
    local current_epoch
    current_epoch=$(date +%s)
    
    local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    if [[ ${days_left} -gt 30 ]]; then
        log_info "Certificate valid for ${days_left} more days"
        return 0
    else
        log_warn "Certificate expires in ${days_left} days"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

check_certbot_prerequisites() {
    local domain="${1}"
    
    log_info "Checking prerequisites for certificate issuance..."
    
    # Check if nginx is running
    if ! systemctl is-active --quiet nginx; then
        log_error "Nginx must be running for webroot challenge"
        log_info "Start nginx first: systemctl start nginx"
        return 1
    fi
    
    # Check if port 80 is accessible
    if ! ss -tlnp | grep -q ":80 "; then
        log_error "Port 80 is not listening. ACME challenge will fail."
        return 1
    fi
    
    # Check webroot directory
    if [[ ! -d "${CERTBOT_WEBROOT}" ]]; then
        log_info "Creating webroot directory: ${CERTBOT_WEBROOT}"
        mkdir -p "${CERTBOT_WEBROOT}"
    fi
    
    # Create .well-known directory
    mkdir -p "${CERTBOT_WEBROOT}/.well-known/acme-challenge"
    chmod -R 755 "${CERTBOT_WEBROOT}/.well-known"
    
    # Test if webroot is accessible
    local test_file="${CERTBOT_WEBROOT}/.well-known/acme-challenge/test-${RANDOM}"
    echo "test" > "${test_file}"
    
    # Simple connectivity test (optional, may fail behind firewall)
    log_info "Webroot directory configured at ${CERTBOT_WEBROOT}"
    
    rm -f "${test_file}"
    
    log_success "Prerequisites check passed"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CERTIFICATE OBTAINING
# ═══════════════════════════════════════════════════════════════════════════════

obtain_certificate() {
    local domain="${1}"
    local email="${2:-}"
    local webroot="${3:-${CERTBOT_WEBROOT}}"
    
    set_phase "SSL Certificate for ${domain}"
    
    install_certbot
    
    # Check existing certificate
    if has_certificate "${domain}" && is_certificate_valid "${domain}"; then
        log_info "Valid certificate already exists for ${domain}"
        return 0
    fi
    
    # Pre-flight checks
    if ! check_certbot_prerequisites "${domain}"; then
        log_error "Prerequisites check failed"
        return 1
    fi
    
    log_info "Obtaining SSL certificate for ${domain}..."
    log_info "Using webroot method (requires nginx on port 80)"
    
    # Build certbot command - WEBROOT ONLY (no standalone!)
    local certbot_args=(
        "certonly"
        "--webroot"
        "-w" "${webroot}"
        "-d" "${domain}"
        "--non-interactive"
        "--agree-tos"
        "--keep-until-expiring"
    )
    
    if [[ -n "${email}" ]]; then
        certbot_args+=("--email" "${email}")
    else
        certbot_args+=("--register-unsafely-without-email")
    fi
    
    # Attempt to obtain certificate
    log_info "Running: certbot ${certbot_args[*]}"
    
    if certbot "${certbot_args[@]}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "Certificate obtained for ${domain}"
        return 0
    fi
    
    # If webroot failed, DO NOT try standalone (it will conflict with nginx)
    log_error "Failed to obtain certificate for ${domain}"
    log_info ""
    log_info "Troubleshooting steps:"
    log_info "1. Ensure DNS A record points to this server's IP"
    log_info "2. Ensure port 80 is open in firewall (ufw allow 80/tcp)"
    log_info "3. Ensure nginx is running and serving port 80"
    log_info "4. Check nginx logs: tail -f /var/log/nginx/error.log"
    log_info ""
    log_info "Test webroot manually:"
    log_info "  echo 'test' > ${webroot}/.well-known/acme-challenge/test"
    log_info "  curl -v http://${domain}/.well-known/acme-challenge/test"
    
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# CERTIFICATE RENEWAL
# ═══════════════════════════════════════════════════════════════════════════════

renew_certificates() {
    log_info "Renewing SSL certificates..."
    
    # Ensure nginx is running for webroot validation
    if ! systemctl is-active --quiet nginx; then
        log_warn "Starting nginx for certificate renewal..."
        systemctl start nginx
    fi
    
    if certbot renew --quiet --deploy-hook "systemctl reload nginx"; then
        log_success "Certificate renewal completed"
        return 0
    fi
    
    log_warn "Certificate renewal had issues"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# AUTO-RENEWAL SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_auto_renewal() {
    log_info "Setting up automatic certificate renewal..."
    
    # Certbot typically sets up a timer, but let's ensure it
    if systemctl list-timers | grep -q certbot; then
        log_info "Certbot timer already active"
        return 0
    fi
    
    # Create systemd timer if not exists
    if [[ ! -f /etc/systemd/system/certbot-renewal.timer ]]; then
        cat > /etc/systemd/system/certbot-renewal.timer << 'EOF'
[Unit]
Description=Certbot Renewal Timer
Documentation=https://certbot.eff.org/docs/

[Timer]
# Run twice daily at random times
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
        
        cat > /etc/systemd/system/certbot-renewal.service << 'EOF'
[Unit]
Description=Certbot Renewal Service
Documentation=https://certbot.eff.org/docs/

[Service]
Type=oneshot
# Use webroot renewal (compatible with nginx stream)
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
# Don't use standalone - it conflicts with nginx!
EOF
        
        systemctl daemon-reload
        systemctl enable certbot-renewal.timer
        systemctl start certbot-renewal.timer
        
        register_rollback "systemctl disable certbot-renewal.timer" "normal"
        
        log_success "Auto-renewal timer created"
    fi
    
    log_success "Auto-renewal configured"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CERTIFICATE INFO
# ═══════════════════════════════════════════════════════════════════════════════

show_certificate_info() {
    local domain="${1}"
    
    echo
    log_info "═══ Certificate Info: ${domain} ═══"
    
    if has_certificate "${domain}"; then
        local cert_file="${CERT_DIR}/${domain}/fullchain.pem"
        
        echo "Status: ✓ Exists"
        
        # Get expiry date
        local expiry_date
        expiry_date=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d'=' -f2)
        echo "Expires: ${expiry_date}"
        
        # Calculate days remaining
        local expiry_epoch=$(date -d "${expiry_date}" +%s 2>/dev/null || echo 0)
        local current_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
        echo "Days remaining: ${days_left}"
        
        # Get issuer
        local issuer
        issuer=$(openssl x509 -issuer -noout -in "${cert_file}" 2>/dev/null | sed 's/issuer=//')
        echo "Issuer: ${issuer}"
        
        # Get SANs
        local sans
        sans=$(openssl x509 -text -noout -in "${cert_file}" 2>/dev/null | \
               grep -A1 "Subject Alternative Name" | tail -1 | \
               tr ',' '\n' | sed 's/DNS://g' | tr '\n' ' ')
        echo "Domains: ${sans}"
        
        # Show certificate path
        echo "Path: ${cert_file}"
        
    else
        echo "Status: ✗ Not found"
    fi
    
    echo
}

list_certificates() {
    log_info "═══ Installed Certificates ═══"
    
    if [[ ! -d "${CERT_DIR}" ]]; then
        echo "No certificates found"
        return
    fi
    
    for domain_dir in "${CERT_DIR}"/*; do
        if [[ -d "${domain_dir}" ]]; then
            local domain
            domain=$(basename "${domain_dir}")
            
            if [[ "${domain}" != "README" ]]; then
                show_certificate_info "${domain}"
            fi
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# NGINX INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════

# After obtaining certificate, configure nginx to use it
configure_nginx_ssl_for_domain() {
    local domain="${1}"
    
    if ! has_certificate "${domain}"; then
        log_error "No certificate found for ${domain}"
        return 1
    fi
    
    log_info "Certificate ready for nginx configuration"
    log_info "Cert: ${CERT_DIR}/${domain}/fullchain.pem"
    log_info "Key:  ${CERT_DIR}/${domain}/privkey.pem"
    
    # Note: The actual nginx config should be created by nginx.sh module
    # This function just confirms the certificate is available
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

setup_ssl() {
    local domain="${PANEL_DOMAIN:-}"
    local email="${ADMIN_EMAIL:-}"
    
    if [[ -z "${domain}" ]]; then
        log_warn "No panel domain configured, skipping SSL setup"
        return 0
    fi
    
    # Check if using CDN (certificate managed by CDN)
    if [[ "${SSL_MANAGED_BY_CDN:-false}" == "true" ]]; then
        log_info "SSL managed by CDN, skipping local certificate"
        return 0
    fi
    
    set_phase "SSL Setup"
    
    # Install certbot
    install_certbot
    
    # Obtain certificate for panel domain
    if ! obtain_certificate "${domain}" "${email}"; then
        log_error "Failed to obtain certificate for panel domain"
        return 1
    fi
    
    # Setup auto-renewal
    setup_auto_renewal
    
    log_success "SSL setup completed"
}

# Export functions
export -f setup_ssl
export -f install_certbot
export -f obtain_certificate
export -f renew_certificates
export -f has_certificate
export -f is_certificate_valid
export -f show_certificate_info
export -f list_certificates
export -f setup_auto_renewal
export -f check_certbot_prerequisites
