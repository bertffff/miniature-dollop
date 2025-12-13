#!/bin/bash
# =============================================================================
# CDN Module - GCore and EdgeCenter CDN setup for whitelist bypass
# =============================================================================
# Provides CDN-fronted VLESS configuration for hostile network environments
# Exploits economic impossibility of blocking major CDN infrastructure
# =============================================================================

# Prevent direct execution
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && echo "This script should be sourced, not executed directly" && exit 1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Supported CDN providers
declare -A CDN_PROVIDERS=(
    ["gcore"]="G-Core Labs CDN"
    ["edgecenter"]="EdgeCenter CDN"
    ["cloudflare"]="Cloudflare CDN"
)

# CDN IP ranges for firewall
declare -A CDN_IP_RANGES=(
    ["gcore"]="92.223.65.0/24 92.38.130.0/24 92.38.131.0/24 193.200.78.0/24 87.245.197.0/24"
    ["edgecenter"]="185.112.81.0/24 188.64.13.0/24"
    ["cloudflare"]="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
)

# Default CDN settings
CDN_PROVIDER="${CDN_PROVIDER:-gcore}"
CDN_DOMAIN="${CDN_DOMAIN:-}"
CDN_ORIGIN_DOMAIN="${CDN_ORIGIN_DOMAIN:-}"
SSL_MANAGED_BY_CDN="${SSL_MANAGED_BY_CDN:-false}"

# Clean IP Scanner settings
CLEAN_IP_LIST_FILE="${INSTALLER_DATA_DIR:-/home/claude/marzban-installer/data}/clean_ips.txt"
CLEAN_IP_SCANNER_TIMEOUT="${CLEAN_IP_SCANNER_TIMEOUT:-5}"
CLEAN_IP_SCANNER_WORKERS="${CLEAN_IP_SCANNER_WORKERS:-50}"

# =============================================================================
# CDN SELECTION
# =============================================================================

# Interactive CDN provider selection
select_cdn_provider() {
    log_step "CDN Provider Selection"
    
    echo ""
    echo "Select CDN provider for whitelist bypass:"
    echo ""
    echo "  1) G-Core Labs (Recommended for Russia)"
    echo "     - Unlikely to be blocked due to Russian roots"
    echo "     - Good performance in CIS region"
    echo "     - Free tier available"
    echo ""
    echo "  2) EdgeCenter (Alternative)"
    echo "     - Similar coverage"
    echo "     - Another Russian-friendly option"
    echo ""
    echo "  3) Cloudflare (Most reliable)"
    echo "     - Largest CDN network"
    echo "     - Most likely whitelisted"
    echo "     - Free tier with WebSocket support"
    echo ""
    
    local choice
    read -rp "Select provider [1-3, default: 1]: " choice
    choice="${choice:-1}"
    
    case "${choice}" in
        1)
            CDN_PROVIDER="gcore"
            log_info "Selected: G-Core Labs"
            ;;
        2)
            CDN_PROVIDER="edgecenter"
            log_info "Selected: EdgeCenter"
            ;;
        3)
            CDN_PROVIDER="cloudflare"
            log_info "Selected: Cloudflare"
            ;;
        *)
            log_warn "Invalid choice, defaulting to G-Core"
            CDN_PROVIDER="gcore"
            ;;
    esac
    
    export CDN_PROVIDER
    return 0
}

# =============================================================================
# CDN SETUP INSTRUCTIONS
# =============================================================================

# Display G-Core setup instructions
show_gcore_setup() {
    local origin_domain="${1:-your-server.example.com}"
    local cdn_domain="${2:-cdn.example.com}"
    
    cat << EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║                         G-Core Labs CDN Setup Guide                          ║
╚══════════════════════════════════════════════════════════════════════════════╝

STEP 1: Create G-Core Account
─────────────────────────────
1. Go to https://gcore.com/
2. Sign up for a free account
3. Verify your email

STEP 2: Add CDN Resource
────────────────────────
1. Go to CDN → CDN Resources → Create CDN Resource
2. Select "Accelerate and protect only static files"
3. Enter origin settings:
   - Origin: ${origin_domain}
   - Origin Protocol: HTTPS
   - Port: 443

STEP 3: Configure Caching
─────────────────────────
1. Go to Caching settings
2. Set "CDN caching" to: Origin controlled
3. Enable "Ignore query string"
4. Set Browser caching: 0 (disabled)

STEP 4: Configure SSL
─────────────────────
1. Go to SSL/TLS settings
2. Select "Let's Encrypt certificate"
3. Enable "Force HTTPS"
4. Set "Minimum TLS version" to: TLS 1.2

STEP 5: Configure WebSocket Support
───────────────────────────────────
1. Go to HTTP headers
2. Add custom header:
   - Name: Connection
   - Value: upgrade
3. Enable WebSocket support (if available)

STEP 6: Get CDN Domain
──────────────────────
1. Note your CDN domain (e.g., ${cdn_domain}.gcdn.co)
2. Or set up custom CNAME:
   - Your domain: ${cdn_domain}
   - Points to: xxx.gcdn.co

STEP 7: DNS Configuration
─────────────────────────
If using custom domain, add CNAME record:
  ${cdn_domain} CNAME xxx.gcdn.co

STEP 8: Verify Setup
────────────────────
Run: curl -I https://${cdn_domain}/
Should return HTTP 200 with G-Core headers

╔══════════════════════════════════════════════════════════════════════════════╗
║  IMPORTANT: Note the CDN domain - you'll need it for client configuration    ║
╚══════════════════════════════════════════════════════════════════════════════╝

EOF
}

# Display EdgeCenter setup instructions
show_edgecenter_setup() {
    local origin_domain="${1:-your-server.example.com}"
    local cdn_domain="${2:-cdn.example.com}"
    
    cat << EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║                         EdgeCenter CDN Setup Guide                           ║
╚══════════════════════════════════════════════════════════════════════════════╝

STEP 1: Create EdgeCenter Account
─────────────────────────────────
1. Go to https://edgecenter.ru/ or https://edgecenter.com/
2. Register for an account
3. Verify your email

STEP 2: Create CDN Resource
───────────────────────────
1. Navigate to CDN section
2. Click "Create Resource"
3. Configure origin:
   - Protocol: HTTPS
   - Origin: ${origin_domain}
   - Port: 443

STEP 3: SSL Configuration
─────────────────────────
1. Enable SSL/TLS
2. Use Let's Encrypt or upload custom certificate
3. Enable HTTPS redirect

STEP 4: Configure for WebSocket
───────────────────────────────
1. Enable "WebSocket Support"
2. Set timeout for long connections: 3600 seconds
3. Add headers if needed for upgrade

STEP 5: Get CDN Endpoint
────────────────────────
Note your CDN endpoint URL

STEP 6: Configure DNS (if custom domain)
────────────────────────────────────────
Add CNAME record pointing to EdgeCenter CDN

╔══════════════════════════════════════════════════════════════════════════════╗
║  Note the CDN domain for client configuration                                ║
╚══════════════════════════════════════════════════════════════════════════════╝

EOF
}

# Display Cloudflare setup instructions
show_cloudflare_setup() {
    local origin_domain="${1:-your-server.example.com}"
    local cdn_domain="${2:-cdn.example.com}"
    
    cat << EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║                         Cloudflare CDN Setup Guide                           ║
╚══════════════════════════════════════════════════════════════════════════════╝

STEP 1: Create Cloudflare Account
─────────────────────────────────
1. Go to https://cloudflare.com/
2. Sign up for a free account
3. Add your domain to Cloudflare

STEP 2: DNS Configuration
─────────────────────────
1. Go to DNS settings
2. Add A record:
   - Name: ${cdn_domain%%.*}
   - IPv4: Your server IP
   - Proxy status: Proxied (orange cloud)

STEP 3: SSL/TLS Settings
────────────────────────
1. Go to SSL/TLS → Overview
2. Set encryption mode to: Full (strict)
3. Go to Edge Certificates
4. Enable "Always Use HTTPS"
5. Set Minimum TLS Version: 1.2

STEP 4: Enable WebSocket
────────────────────────
1. Go to Network
2. Enable "WebSockets"

STEP 5: Configure Rules (Optional)
──────────────────────────────────
1. Go to Rules → Page Rules
2. Add rule for VPN path:
   - URL: ${cdn_domain}/*
   - Cache Level: Bypass
   - Disable Security: On (if needed)

STEP 6: Firewall Settings
─────────────────────────
1. Go to Security → WAF
2. Create rule to allow VPN traffic:
   - If URI Path contains "/ws" or your WebSocket path
   - Then: Allow

STEP 7: Verify Setup
────────────────────
1. Check DNS propagation: dig ${cdn_domain}
2. Should return Cloudflare IP
3. Test: curl -I https://${cdn_domain}/

╔══════════════════════════════════════════════════════════════════════════════╗
║  IMPORTANT: Cloudflare free tier supports WebSocket!                         ║
║  Make sure the orange cloud (proxy) is enabled for your DNS record           ║
╚══════════════════════════════════════════════════════════════════════════════╝

EOF
}

# Show setup instructions for selected provider
show_cdn_setup_instructions() {
    local provider="${1:-${CDN_PROVIDER}}"
    local origin="${2:-${CDN_ORIGIN_DOMAIN:-$(get_public_ip)}}"
    local cdn="${3:-${CDN_DOMAIN:-cdn.example.com}}"
    
    case "${provider}" in
        gcore)
            show_gcore_setup "${origin}" "${cdn}"
            ;;
        edgecenter)
            show_edgecenter_setup "${origin}" "${cdn}"
            ;;
        cloudflare)
            show_cloudflare_setup "${origin}" "${cdn}"
            ;;
        *)
            log_error "Unknown CDN provider: ${provider}"
            return 1
            ;;
    esac
}

# =============================================================================
# CDN CONFIGURATION
# =============================================================================

# Configure CDN settings interactively
configure_cdn() {
    log_step "CDN Configuration"
    
    # Select provider if not set
    if [[ -z "${CDN_PROVIDER}" ]]; then
        select_cdn_provider
    fi
    
    echo ""
    
    # Get CDN domain
    while [[ -z "${CDN_DOMAIN}" ]]; do
        read -rp "Enter your CDN domain (e.g., vpn.example.com): " CDN_DOMAIN
        if [[ -z "${CDN_DOMAIN}" ]]; then
            log_warn "CDN domain is required for whitelist bypass profile"
        fi
    done
    
    # Get origin domain
    local default_origin
    default_origin=$(get_public_ip 2>/dev/null || echo "")
    
    read -rp "Enter origin server address [${default_origin}]: " CDN_ORIGIN_DOMAIN
    CDN_ORIGIN_DOMAIN="${CDN_ORIGIN_DOMAIN:-${default_origin}}"
    
    # SSL management
    echo ""
    echo "Who manages SSL certificates?"
    echo "  1) CDN provider (SSL termination at CDN)"
    echo "  2) This server (end-to-end encryption)"
    echo ""
    read -rp "Select [1-2, default: 1]: " ssl_choice
    
    case "${ssl_choice:-1}" in
        1)
            SSL_MANAGED_BY_CDN=true
            log_info "SSL managed by CDN"
            ;;
        2)
            SSL_MANAGED_BY_CDN=false
            log_info "SSL managed by server"
            ;;
    esac
    
    # Export settings
    export CDN_PROVIDER
    export CDN_DOMAIN
    export CDN_ORIGIN_DOMAIN
    export SSL_MANAGED_BY_CDN
    
    # Show setup instructions
    echo ""
    if ask_yes_no "Show CDN setup instructions?" "y"; then
        show_cdn_setup_instructions
    fi
    
    return 0
}

# Save CDN configuration
save_cdn_config() {
    local config_file="${INSTALLER_DATA_DIR:-/home/claude/marzban-installer/data}/cdn_config.env"
    
    cat > "${config_file}" << EOF
# CDN Configuration
# Generated: $(date -Iseconds)

CDN_PROVIDER=${CDN_PROVIDER}
CDN_DOMAIN=${CDN_DOMAIN}
CDN_ORIGIN_DOMAIN=${CDN_ORIGIN_DOMAIN}
SSL_MANAGED_BY_CDN=${SSL_MANAGED_BY_CDN}

# Provider-specific settings
CDN_PROVIDER_NAME=${CDN_PROVIDERS[${CDN_PROVIDER}]:-Unknown}
EOF
    
    chmod 600 "${config_file}"
    log_success "CDN configuration saved"
}

# Load CDN configuration
load_cdn_config() {
    local config_file="${INSTALLER_DATA_DIR:-/home/claude/marzban-installer/data}/cdn_config.env"
    
    if [[ -f "${config_file}" ]]; then
        source "${config_file}"
        export CDN_PROVIDER CDN_DOMAIN CDN_ORIGIN_DOMAIN SSL_MANAGED_BY_CDN
        return 0
    fi
    return 1
}

# =============================================================================
# CDN IP MANAGEMENT
# =============================================================================

# Get CDN IP ranges for firewall
get_cdn_ip_ranges() {
    local provider="${1:-${CDN_PROVIDER}}"
    
    case "${provider}" in
        cloudflare)
            # Fetch latest Cloudflare IPs
            local cf_ips
            cf_ips=$(curl -sSL "https://www.cloudflare.com/ips-v4" 2>/dev/null)
            if [[ -n "${cf_ips}" ]]; then
                echo "${cf_ips}"
            else
                echo "${CDN_IP_RANGES[cloudflare]}"
            fi
            ;;
        gcore)
            echo "${CDN_IP_RANGES[gcore]}"
            ;;
        edgecenter)
            echo "${CDN_IP_RANGES[edgecenter]}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Update firewall with CDN IP ranges
update_firewall_for_cdn() {
    local provider="${1:-${CDN_PROVIDER}}"
    local port="${2:-443}"
    
    log_step "Updating firewall for ${provider} CDN"
    
    local ip_ranges
    ip_ranges=$(get_cdn_ip_ranges "${provider}")
    
    if [[ -z "${ip_ranges}" ]]; then
        log_warn "No IP ranges available for ${provider}"
        return 1
    fi
    
    for ip_range in ${ip_ranges}; do
        ufw allow from "${ip_range}" to any port "${port}" proto tcp comment "${provider} CDN" 2>/dev/null || true
    done
    
    log_success "Firewall updated for ${provider} CDN"
}

# =============================================================================
# CLEAN IP SCANNER INTEGRATION
# =============================================================================

# Find clean CDN IPs (not blocked)
scan_clean_ips() {
    local provider="${1:-${CDN_PROVIDER}}"
    local output_file="${2:-${CLEAN_IP_LIST_FILE}}"
    
    log_step "Scanning for clean ${provider} IPs"
    
    local scanner_script="${INSTALLER_DIR:-/home/claude/marzban-installer}/tools/clean-ip-scanner.sh"
    
    if [[ ! -f "${scanner_script}" ]]; then
        log_error "Clean IP scanner not found: ${scanner_script}"
        return 1
    fi
    
    source "${scanner_script}"
    
    local ip_ranges
    ip_ranges=$(get_cdn_ip_ranges "${provider}")
    
    if [[ -z "${ip_ranges}" ]]; then
        log_error "No IP ranges for ${provider}"
        return 1
    fi
    
    # Run scanner
    local clean_ips
    clean_ips=$(scan_ip_ranges "${ip_ranges}" "${CLEAN_IP_SCANNER_TIMEOUT}" "${CLEAN_IP_SCANNER_WORKERS}")
    
    if [[ -n "${clean_ips}" ]]; then
        echo "${clean_ips}" > "${output_file}"
        local count
        count=$(echo "${clean_ips}" | wc -l)
        log_success "Found ${count} clean IPs, saved to ${output_file}"
        return 0
    else
        log_warn "No clean IPs found"
        return 1
    fi
}

# Get best clean IP
get_best_clean_ip() {
    local ip_file="${1:-${CLEAN_IP_LIST_FILE}}"
    
    if [[ -f "${ip_file}" ]]; then
        head -1 "${ip_file}"
    else
        log_warn "Clean IP list not found"
        return 1
    fi
}

# =============================================================================
# CDN VERIFICATION
# =============================================================================

# Verify CDN configuration
verify_cdn_setup() {
    local cdn_domain="${1:-${CDN_DOMAIN}}"
    
    log_step "Verifying CDN setup for ${cdn_domain}"
    
    local errors=0
    
    # Check DNS resolution
    log_info "Checking DNS..."
    local resolved_ip
    resolved_ip=$(dig +short "${cdn_domain}" 2>/dev/null | head -1)
    if [[ -z "${resolved_ip}" ]]; then
        log_error "DNS resolution failed for ${cdn_domain}"
        ((errors++))
    else
        log_success "DNS resolves to: ${resolved_ip}"
    fi
    
    # Check HTTPS connectivity
    log_info "Checking HTTPS..."
    local http_code
    http_code=$(curl -sSL -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://${cdn_domain}/" 2>/dev/null)
    if [[ "${http_code}" =~ ^(200|301|302|403|404)$ ]]; then
        log_success "HTTPS connection OK (HTTP ${http_code})"
    else
        log_error "HTTPS connection failed (HTTP ${http_code})"
        ((errors++))
    fi
    
    # Check WebSocket upgrade (if path configured)
    if [[ -n "${WS_PATH:-}" ]]; then
        log_info "Checking WebSocket..."
        local ws_response
        ws_response=$(curl -sSL -o /dev/null -w "%{http_code}" \
            -H "Upgrade: websocket" \
            -H "Connection: Upgrade" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
            -H "Sec-WebSocket-Version: 13" \
            --connect-timeout 10 \
            "https://${cdn_domain}${WS_PATH}" 2>/dev/null)
        
        if [[ "${ws_response}" =~ ^(101|400|426)$ ]]; then
            log_success "WebSocket endpoint accessible"
        else
            log_warn "WebSocket check returned: HTTP ${ws_response}"
        fi
    fi
    
    # Check SSL certificate
    log_info "Checking SSL certificate..."
    local cert_info
    cert_info=$(echo | openssl s_client -connect "${cdn_domain}:443" -servername "${cdn_domain}" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
    if [[ -n "${cert_info}" ]]; then
        log_success "SSL certificate valid"
        echo "${cert_info}" | grep -E "(notBefore|notAfter)"
    else
        log_warn "Could not verify SSL certificate"
    fi
    
    if [[ ${errors} -eq 0 ]]; then
        log_success "CDN setup verified successfully"
        return 0
    else
        log_error "CDN verification found ${errors} issue(s)"
        return 1
    fi
}

# =============================================================================
# NGINX CDN CONFIGURATION
# =============================================================================

# Generate Nginx config for CDN-fronted traffic
generate_cdn_nginx_config() {
    local cdn_domain="${1:-${CDN_DOMAIN}}"
    local ws_port="${2:-8444}"
    local ws_path="${3:-/ws}"
    
    cat << EOF
# CDN-fronted WebSocket configuration
# Domain: ${cdn_domain}

server {
    listen 127.0.0.1:${ws_port} ssl http2;
    server_name ${cdn_domain};
    
    # SSL certificates (if not managed by CDN)
    ssl_certificate /etc/letsencrypt/live/${cdn_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${cdn_domain}/privkey.pem;
    
    # WebSocket location
    location ${ws_path} {
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Timeouts for long-lived connections
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 3600s;
    }
    
    # Health check endpoint
    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
    
    # Default - serve fake site
    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF
}

# =============================================================================
# CLIENT CONFIGURATION HELPERS
# =============================================================================

# Generate client config snippet for CDN profile
generate_cdn_client_config() {
    local cdn_domain="${1:-${CDN_DOMAIN}}"
    local ws_path="${2:-/ws}"
    local clean_ip="${3:-}"
    
    # Get clean IP if not provided
    if [[ -z "${clean_ip}" ]]; then
        clean_ip=$(get_best_clean_ip 2>/dev/null || echo "${cdn_domain}")
    fi
    
    cat << EOF
{
  "remarks": "CDN-fronted (Whitelist Bypass)",
  "address": "${clean_ip}",
  "port": 443,
  "sni": "${cdn_domain}",
  "host": "${cdn_domain}",
  "path": "${ws_path}",
  "tls": true,
  "network": "ws",
  "note": "Use this profile if other profiles are blocked"
}
EOF
}

# Display CDN client configuration instructions
show_cdn_client_instructions() {
    local cdn_domain="${1:-${CDN_DOMAIN}}"
    
    cat << EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║                    CDN Profile Client Configuration                          ║
╚══════════════════════════════════════════════════════════════════════════════╝

For blocked networks (mobile, restrictive ISPs), use these settings:

Address:    Use a "clean" CDN IP from the scanner
            Or use the CDN domain directly: ${cdn_domain}

Port:       443

Network:    WebSocket (ws)

TLS:        Enabled

SNI:        ${cdn_domain}

Host:       ${cdn_domain}

Path:       ${WS_PATH:-/ws}

═══════════════════════════════════════════════════════════════════════════════

FINDING CLEAN IPs:
─────────────────
If direct connection to ${cdn_domain} is blocked:

1. Run the Clean IP Scanner on an unblocked network
2. Import the clean IP list to your client
3. Use a clean IP instead of the domain

The scanner tests CDN IPs and finds ones that aren't blocked.
Run: ./tools/clean-ip-scanner.sh ${CDN_PROVIDER}

╚══════════════════════════════════════════════════════════════════════════════╝

EOF
}
