#!/bin/bash
#
# Module: certbot.sh
# Purpose: Let's Encrypt certificate management
# Dependencies: core.sh, nginx.sh
#

# Strict mode
set -euo pipefail

# Source core module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/core.sh"

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
# CERTIFICATE MANAGEMENT
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
    
    log_info "Obtaining SSL certificate for ${domain}..."
    
    # Build certbot command
    local certbot_args=(
        "certonly"
        "--webroot"
        "-w" "${webroot}"
        "-d" "${domain}"
        "--non-interactive"
        "--agree-tos"
    )
    
    if [[ -n "${email}" ]]; then
        certbot_args+=("--email" "${email}")
    else
        certbot_args+=("--register-unsafely-without-email")
    fi
    
    # Try to obtain certificate
    if certbot "${certbot_args[@]}"; then
        log_success "Certificate obtained for ${domain}"
        return 0
    fi
    
    log_warn "Webroot method failed, trying standalone..."
    
    # Stop nginx temporarily
    systemctl stop nginx 2>/dev/null || true
    
    certbot_args=(
        "certonly"
        "--standalone"
        "-d" "${domain}"
        "--non-interactive"
        "--agree-tos"
    )
    
    if [[ -n "${email}" ]]; then
        certbot_args+=("--email" "${email}")
    else
        certbot_args+=("--register-unsafely-without-email")
    fi
    
    if certbot "${certbot_args[@]}"; then
        systemctl start nginx
        log_success "Certificate obtained for ${domain}"
        return 0
    fi
    
    systemctl start nginx
    log_error "Failed to obtain certificate for ${domain}"
    return 1
}

obtain_certificate_nginx() {
    local domain="${1}"
    local email="${2:-}"
    
    set_phase "SSL Certificate (Nginx) for ${domain}"
    
    install_certbot
    
    # Check existing certificate
    if has_certificate "${domain}" && is_certificate_valid "${domain}"; then
        log_info "Valid certificate already exists for ${domain}"
        return 0
    fi
    
    log_info "Obtaining SSL certificate via Nginx plugin..."
    
    local certbot_args=(
        "--nginx"
        "-d" "${domain}"
        "--non-interactive"
        "--agree-tos"
        "--redirect"
    )
    
    if [[ -n "${email}" ]]; then
        certbot_args+=("--email" "${email}")
    else
        certbot_args+=("--register-unsafely-without-email")
    fi
    
    if certbot "${certbot_args[@]}"; then
        log_success "Certificate obtained for ${domain}"
        return 0
    fi
    
    log_error "Failed to obtain certificate for ${domain}"
    return 1
}

renew_certificates() {
    log_info "Renewing SSL certificates..."
    
    if certbot renew --quiet; then
        log_success "Certificate renewal completed"
        
        # Reload nginx if running
        systemctl reload nginx 2>/dev/null || true
        
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

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
        
        cat > /etc/systemd/system/certbot-renewal.service << 'EOF'
[Unit]
Description=Certbot Renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
        
        systemctl daemon-reload
        systemctl enable certbot-renewal.timer
        systemctl start certbot-renewal.timer
        
        register_rollback "systemctl disable certbot-renewal.timer" "normal"
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
        
        # Get issuer
        local issuer
        issuer=$(openssl x509 -issuer -noout -in "${cert_file}" 2>/dev/null | sed 's/issuer=//')
        echo "Issuer: ${issuer}"
        
        # Get SANs
        local sans
        sans=$(openssl x509 -text -noout -in "${cert_file}" 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | tr ',' '\n' | sed 's/DNS://g')
        echo "Domains: ${sans}"
        
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
    
    obtain_certificate "${domain}" "${email}"
    setup_auto_renewal
    
    log_success "SSL setup completed"
}

# Export functions
export -f setup_ssl
export -f obtain_certificate
export -f renew_certificates
export -f has_certificate
export -f is_certificate_valid
export -f show_certificate_info
export -f list_certificates
