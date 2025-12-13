#!/bin/bash
#===============================================================================
#
#          FILE: install.sh
#
#         USAGE: sudo ./install.sh [OPTIONS]
#
#   DESCRIPTION: Marzban Ultimate VPN Installer
#                Production-grade automated deployment for VLESS/Reality VPN
#                with XanMod kernel, MariaDB support, AdGuard DNS, and WARP
#
#       OPTIONS:
#         -c, --config FILE    Use custom config file
#         -s, --skip-confirm   Skip confirmation prompts (non-interactive)
#         -u, --uninstall      Uninstall Marzban and components
#         -h, --help           Show this help message
#         --no-kernel          Skip XanMod kernel installation
#         --no-warp            Skip WARP installation
#         --no-fake-site       Skip fake website setup
#         --staging            Use Let's Encrypt staging (for testing)
#         --debug              Enable debug mode
#
#        AUTHOR: Marzban Ultimate Installer
#       VERSION: 2.0.0
#       CREATED: 2024
#
#===============================================================================

# Script version
readonly INSTALLER_VERSION="2.0.0"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Module directory
readonly MODULES_DIR="${SCRIPT_DIR}/modules"
readonly TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# Default config file
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# Installation state file
readonly STATE_FILE="/var/lib/marzban/.install_state"

#-------------------------------------------------------------------------------
# Pre-flight: Minimal error handling before core module is loaded
#-------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

#-------------------------------------------------------------------------------
# Source Core Module
#-------------------------------------------------------------------------------
if [[ ! -f "${MODULES_DIR}/core.sh" ]]; then
    echo "ERROR: Core module not found at ${MODULES_DIR}/core.sh"
    exit 1
fi

# shellcheck source=modules/core.sh
source "${MODULES_DIR}/core.sh"
CORE_LOADED=true

#-------------------------------------------------------------------------------
# Default Values
#-------------------------------------------------------------------------------
SKIP_CONFIRM="${NON_INTERACTIVE:-false}"
INSTALL_XANMOD="${INSTALL_XANMOD:-true}"
INSTALL_WARP="${INSTALL_WARP:-true}"
INSTALL_ADGUARD="${INSTALL_ADGUARD:-false}"
INSTALL_FAKE_SITE="${INSTALL_FAKE_SITE:-true}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-true}"
USE_STAGING="${USE_STAGING:-false}"
DATABASE_TYPE="${DATABASE_TYPE:-sqlite}"

#-------------------------------------------------------------------------------
# Banner
#-------------------------------------------------------------------------------
show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    
  __  __                _                 
 |  \/  | __ _ _ __ ___| |__   __ _ _ __  
 | |\/| |/ _` | '__/_  | '_ \ / _` | '_ \ 
 | |  | | (_| | |  / / | |_) | (_| | | | |
 |_|  |_|\__,_|_| /___/|_.__/ \__,_|_| |_|
                                          
    Ultimate VPN Installer v2.0.0
    VLESS/Reality + XanMod + WARP Edition
    
EOF
    echo -e "${NC}"
    print_separator
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
    cat << EOF
Marzban Ultimate VPN Installer v${INSTALLER_VERSION}

Usage: sudo ./install.sh [OPTIONS]

Options:
  -c, --config FILE    Use custom config file (default: config.env)
  -s, --skip-confirm   Skip confirmation prompts (non-interactive mode)
  -u, --uninstall      Uninstall Marzban and all components
  -h, --help           Show this help message
  --no-kernel          Skip XanMod kernel installation
  --no-warp            Skip WARP installation  
  --no-adguard         Skip AdGuard Home installation
  --no-fake-site       Skip fake website setup
  --staging            Use Let's Encrypt staging (for testing)
  --debug              Enable debug mode (verbose output)

Database Options:
  --sqlite             Use SQLite database (default)
  --mariadb            Use MariaDB database

Examples:
  sudo ./install.sh                    # Interactive installation
  sudo ./install.sh -c my.env          # Use custom config
  sudo ./install.sh --mariadb          # Install with MariaDB
  sudo ./install.sh --no-warp          # Install without WARP
  sudo ./install.sh -u                 # Uninstall

For more information, visit: https://github.com/Gozargah/Marzban
EOF
}

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -s|--skip-confirm)
                SKIP_CONFIRM=true
                NON_INTERACTIVE=true
                export NON_INTERACTIVE
                shift
                ;;
            -u|--uninstall)
                run_uninstall
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --no-kernel)
                INSTALL_XANMOD=false
                shift
                ;;
            --no-warp)
                INSTALL_WARP=false
                shift
                ;;
            --no-adguard)
                INSTALL_ADGUARD=false
                shift
                ;;
            --no-fake-site)
                INSTALL_FAKE_SITE=false
                shift
                ;;
            --staging)
                USE_STAGING=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                export DEBUG_MODE
                shift
                ;;
            --sqlite)
                DATABASE_TYPE="sqlite"
                shift
                ;;
            --mariadb)
                DATABASE_TYPE="mariadb"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Source All Modules
#-------------------------------------------------------------------------------
source_modules() {
    local modules=(
        "system.sh"
        "docker.sh"
        "firewall.sh"
        "nginx.sh"
        "certbot.sh"
        "xray.sh"
        "warp.sh"
        "marzban.sh"
        "marzban_api.sh"
        "adguard.sh"
    )
    
    for module in "${modules[@]}"; do
        local module_path="${MODULES_DIR}/${module}"
        if [[ -f "${module_path}" ]]; then
            # shellcheck source=/dev/null
            source "${module_path}"
            log_debug "Loaded module: ${module}"
        else
            log_warn "Module not found: ${module_path}"
        fi
    done
}

#-------------------------------------------------------------------------------
# Load Configuration
#-------------------------------------------------------------------------------
load_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        log_info "Loading configuration from: ${CONFIG_FILE}"
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
        return 0
    fi
    return 1
}

#-------------------------------------------------------------------------------
# Interactive Configuration
#-------------------------------------------------------------------------------
collect_configuration() {
    log_step "Interactive Configuration"
    echo ""
    
    # Domain configuration
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                  Domain Configuration                      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ -z "${PANEL_DOMAIN:-}" ]]; then
        while true; do
            read -rp "Enter your domain for Marzban panel (e.g., panel.example.com): " PANEL_DOMAIN
            if validate_domain "$PANEL_DOMAIN"; then
                break
            fi
            echo "Invalid domain format. Please try again."
        done
    fi
    
    if [[ -z "${REALITY_DEST:-}" ]]; then
        read -rp "Enter Reality destination domain [www.google.com]: " REALITY_DEST
        REALITY_DEST="${REALITY_DEST:-www.google.com}"
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                  Admin Configuration                       ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ -z "${ADMIN_EMAIL:-}" ]]; then
        while true; do
            read -rp "Enter admin email (for SSL certificates): " ADMIN_EMAIL
            if validate_email "$ADMIN_EMAIL"; then
                break
            fi
            echo "Invalid email format. Please try again."
        done
    fi
    
    if [[ -z "${ADMIN_USERNAME:-}" ]]; then
        read -rp "Enter Marzban admin username [admin]: " ADMIN_USERNAME
        ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    fi
    
    if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
        read -rsp "Enter Marzban admin password (leave empty to auto-generate): " ADMIN_PASSWORD
        echo ""
        if [[ -z "${ADMIN_PASSWORD}" ]]; then
            ADMIN_PASSWORD=$(generate_password 16)
            log_info "Generated admin password"
        fi
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                  Database Configuration                    ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo "Database options:"
    echo "  1) SQLite (simple, recommended for single server)"
    echo "  2) MariaDB (better for high traffic)"
    
    read -rp "Select database type [1]: " db_choice
    case "${db_choice:-1}" in
        2) DATABASE_TYPE="mariadb" ;;
        *) DATABASE_TYPE="sqlite" ;;
    esac
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                  Optional Features                         ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if confirm_action "Install XanMod kernel for better performance?" "y"; then
        INSTALL_XANMOD=true
    else
        INSTALL_XANMOD=false
    fi
    
    if confirm_action "Install Cloudflare WARP for geo-bypass?" "y"; then
        INSTALL_WARP=true
        read -rp "Enter WARP+ license key (leave empty for free tier): " WARP_LICENSE
    else
        INSTALL_WARP=false
    fi
    
    if confirm_action "Install AdGuard Home DNS filtering?" "n"; then
        INSTALL_ADGUARD=true
    else
        INSTALL_ADGUARD=false
    fi
    
    if confirm_action "Install fake website for camouflage?" "y"; then
        INSTALL_FAKE_SITE=true
    else
        INSTALL_FAKE_SITE=false
    fi
    
    if confirm_action "Install Fail2Ban for SSH protection?" "y"; then
        INSTALL_FAIL2BAN=true
    else
        INSTALL_FAIL2BAN=false
    fi
    
    echo ""
}

#-------------------------------------------------------------------------------
# Save Configuration
#-------------------------------------------------------------------------------
save_configuration() {
    log_info "Saving configuration..."
    
    cat > "${CONFIG_FILE}" << EOF
# Marzban Configuration - Generated $(date '+%Y-%m-%d %H:%M:%S')

# Domain
PANEL_DOMAIN="${PANEL_DOMAIN}"
REALITY_DEST="${REALITY_DEST:-www.google.com}"
REALITY_SERVER_NAMES="${REALITY_SERVER_NAMES:-${REALITY_DEST}}"

# Admin
ADMIN_EMAIL="${ADMIN_EMAIL}"
ADMIN_USERNAME="${ADMIN_USERNAME}"
ADMIN_PASSWORD="${ADMIN_PASSWORD}"

# Database
DATABASE_TYPE="${DATABASE_TYPE}"

# Ports
MARZBAN_PORT="${MARZBAN_PORT:-8000}"
DASHBOARD_PATH="${DASHBOARD_PATH:-/dashboard/}"

# Reality Profiles
XRAY_REALITY_PORT_1="${XRAY_REALITY_PORT_1:-8443}"
XRAY_REALITY_SNI_1="${XRAY_REALITY_SNI_1:-www.google.com}"
XRAY_PROFILE_NAME_1="${XRAY_PROFILE_NAME_1:-Reality-Whitelist}"

XRAY_REALITY_PORT_2="${XRAY_REALITY_PORT_2:-8444}"
XRAY_REALITY_SNI_2="${XRAY_REALITY_SNI_2:-www.microsoft.com}"
XRAY_PROFILE_NAME_2="${XRAY_PROFILE_NAME_2:-Reality-Standard}"

XRAY_REALITY_PORT_3="${XRAY_REALITY_PORT_3:-8445}"
XRAY_REALITY_SNI_3="${XRAY_REALITY_SNI_3:-www.apple.com}"
XRAY_PROFILE_NAME_3="${XRAY_PROFILE_NAME_3:-Reality-WARP}"

# Features
INSTALL_XANMOD="${INSTALL_XANMOD}"
INSTALL_WARP="${INSTALL_WARP}"
WARP_LICENSE="${WARP_LICENSE:-}"
INSTALL_ADGUARD="${INSTALL_ADGUARD}"
INSTALL_FAKE_SITE="${INSTALL_FAKE_SITE}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN}"

# SSL
USE_STAGING="${USE_STAGING}"

# Generated
SERVER_IP="${SERVER_IP:-}"
EOF
    
    chmod 0600 "${CONFIG_FILE}"
    log_success "Configuration saved to: ${CONFIG_FILE}"
}

#-------------------------------------------------------------------------------
# Show Configuration Summary
#-------------------------------------------------------------------------------
show_configuration_summary() {
    echo ""
    print_separator
    echo -e "${BOLD}Configuration Summary${NC}"
    print_separator
    echo ""
    echo -e "  Domain:           ${GREEN}${PANEL_DOMAIN}${NC}"
    echo -e "  Reality Dest:     ${GREEN}${REALITY_DEST}${NC}"
    echo -e "  Admin Email:      ${GREEN}${ADMIN_EMAIL}${NC}"
    echo -e "  Admin Username:   ${GREEN}${ADMIN_USERNAME}${NC}"
    echo -e "  Database:         ${GREEN}${DATABASE_TYPE}${NC}"
    echo ""
    echo -e "  Features:"
    echo -e "    XanMod Kernel:  ${INSTALL_XANMOD}"
    echo -e "    WARP:           ${INSTALL_WARP}"
    echo -e "    AdGuard:        ${INSTALL_ADGUARD}"
    echo -e "    Fake Site:      ${INSTALL_FAKE_SITE}"
    echo -e "    Fail2Ban:       ${INSTALL_FAIL2BAN}"
    echo ""
    print_separator
    
    if [[ "${SKIP_CONFIRM}" != "true" ]]; then
        if ! confirm_action "Proceed with installation?"; then
            log_warn "Installation cancelled by user"
            exit 0
        fi
    fi
}

#-------------------------------------------------------------------------------
# Pre-flight Checks
#-------------------------------------------------------------------------------
run_preflight_checks() {
    log_step "Running Pre-flight Checks"
    
    # Check system requirements
    check_system_requirements
    
    # Get server IP
    SERVER_IP=$(get_public_ip)
    if [[ -z "$SERVER_IP" ]]; then
        log_error "Could not detect public IP address"
        exit 1
    fi
    log_info "Server IP: ${SERVER_IP}"
    export SERVER_IP
    
    log_success "Pre-flight checks passed"
}

#-------------------------------------------------------------------------------
# Main Installation
#-------------------------------------------------------------------------------
run_installation() {
    local start_time
    start_time=$(date +%s)
    
    log_step "Starting Installation"
    
    # Setup error handling
    setup_error_trap
    
    # Track installation phase for rollback
    export CURRENT_INSTALL_PHASE="init"
    
    # =========================================================================
    # Phase 1: System Preparation
    # =========================================================================
    log_step "[1/10] System Preparation"
    CURRENT_INSTALL_PHASE="system"
    
    install_dependencies
    
    if [[ "${INSTALL_XANMOD}" == "true" ]]; then
        if is_xanmod_installed 2>/dev/null; then
            log_info "XanMod kernel already installed"
        else
            if install_xanmod_kernel; then
                log_warn "XanMod kernel installed. System reboot required!"
                log_warn "After reboot, run this script again to continue."
                save_install_state "xanmod_installed"
                exit 0
            fi
        fi
    fi
    
    configure_sysctl
    configure_limits
    enable_bbr
    
    if [[ "${INSTALL_FAIL2BAN}" == "true" ]]; then
        install_fail2ban || true
    fi
    
    log_success "System preparation complete"
    
    # =========================================================================
    # Phase 2: Firewall Configuration
    # =========================================================================
    log_step "[2/10] Firewall Configuration"
    CURRENT_INSTALL_PHASE="firewall"
    
    configure_firewall
    
    log_success "Firewall configured"
    
    # =========================================================================
    # Phase 3: Docker Installation
    # =========================================================================
    log_step "[3/10] Docker Installation"
    CURRENT_INSTALL_PHASE="docker"
    
    install_docker
    configure_docker
    start_docker
    docker_health_check
    
    log_success "Docker installed"
    
    # =========================================================================
    # Phase 4: Nginx Setup
    # =========================================================================
    log_step "[4/10] Nginx Setup"
    CURRENT_INSTALL_PHASE="nginx"
    
    install_nginx
    configure_nginx
    
    if [[ "${INSTALL_FAKE_SITE}" == "true" ]]; then
        setup_random_fake_site
    fi
    
    configure_sni_routing
    configure_panel_proxy
    create_self_signed_cert
    test_nginx_config
    systemctl restart nginx
    
    log_success "Nginx configured"
    
    # =========================================================================
    # Phase 5: Xray Setup
    # =========================================================================
    log_step "[5/10] Xray Configuration"
    CURRENT_INSTALL_PHASE="xray"
    
    install_xray_core
    update_geo_databases
    
    # Generate Reality keys
    local keys_output
    keys_output=$(setup_reality_keys)
    
    eval "$keys_output"
    
    log_success "Xray configured"
    
    # =========================================================================
    # Phase 6: WARP Setup (Optional)
    # =========================================================================
    if [[ "${INSTALL_WARP}" == "true" ]]; then
        log_step "[6/10] WARP Setup"
        CURRENT_INSTALL_PHASE="warp"
        
        local warp_output
        warp_output=$(setup_warp "${WARP_LICENSE:-}")
        eval "$warp_output"
        
        log_success "WARP configured"
    else
        log_info "[6/10] Skipping WARP setup"
    fi
    
    # =========================================================================
    # Phase 7: AdGuard Setup (Optional)
    # =========================================================================
    if [[ "${INSTALL_ADGUARD}" == "true" ]]; then
        log_step "[7/10] AdGuard Home Setup"
        CURRENT_INSTALL_PHASE="adguard"
        
        configure_systemd_resolved || true
        
        local adguard_output
        adguard_output=$(setup_adguard "${ADGUARD_ADMIN_USER:-admin}" "${ADGUARD_ADMIN_PASS:-}" "${ADGUARD_WEB_PORT:-3000}" 53)
        eval "$adguard_output" 2>/dev/null || true
        
        log_success "AdGuard Home configured"
    else
        log_info "[7/10] Skipping AdGuard Home setup"
    fi
    
    # =========================================================================
    # Phase 8: Marzban Installation
    # =========================================================================
    log_step "[8/10] Marzban Installation"
    CURRENT_INSTALL_PHASE="marzban"
    
    setup_marzban \
        "$DATABASE_TYPE" \
        "$PANEL_DOMAIN" \
        "$ADMIN_USERNAME" \
        "$ADMIN_PASSWORD" \
        "${MARZBAN_PORT:-8000}" \
        "${DASHBOARD_PATH:-/dashboard/}"
    
    log_success "Marzban installed"
    
    # =========================================================================
    # Phase 9: SSL Certificate
    # =========================================================================
    log_step "[9/10] SSL Certificate"
    CURRENT_INSTALL_PHASE="ssl"
    
    local certbot_opts=""
    [[ "${USE_STAGING}" == "true" ]] && certbot_opts="--staging"
    
    if validate_domain_ip "$PANEL_DOMAIN" "$SERVER_IP"; then
        if obtain_certificate_standalone "$PANEL_DOMAIN" "$ADMIN_EMAIL"; then
            update_nginx_ssl "$PANEL_DOMAIN"
            setup_auto_renewal
            systemctl reload nginx
            log_success "SSL certificate obtained"
        else
            log_warn "SSL certificate failed, using self-signed"
        fi
    else
        log_warn "DNS not verified, skipping SSL certificate"
        log_info "Obtain certificate later: certbot --nginx -d ${PANEL_DOMAIN}"
    fi
    
    # =========================================================================
    # Phase 10: API Configuration
    # =========================================================================
    log_step "[10/10] Configuring VPN Profiles via API"
    CURRENT_INSTALL_PHASE="api"
    
    # Wait for Marzban to be fully ready
    sleep 10
    
    # Configure profiles via API
    local warp_outbound_file=""
    [[ "${INSTALL_WARP}" == "true" ]] && warp_outbound_file="${WARP_OUTBOUND_FILE:-}"
    
    configure_profiles_via_api \
        "$SERVER_IP" \
        "http://127.0.0.1:${MARZBAN_PORT:-8000}" \
        "$ADMIN_USERNAME" \
        "$ADMIN_PASSWORD" \
        "${REALITY_PRIVATE_KEY}" \
        "${REALITY_PUBLIC_KEY}" \
        "${REALITY_SHORT_IDS}" \
        "${XRAY_REALITY_PORT_1:-8443}" \
        "${XRAY_REALITY_SNI_1:-www.google.com}" \
        "${XRAY_PROFILE_NAME_1:-Reality-Whitelist}" \
        "${XRAY_REALITY_PORT_2:-8444}" \
        "${XRAY_REALITY_SNI_2:-www.microsoft.com}" \
        "${XRAY_PROFILE_NAME_2:-Reality-Standard}" \
        "${XRAY_REALITY_PORT_3:-8445}" \
        "${XRAY_REALITY_SNI_3:-www.apple.com}" \
        "${XRAY_PROFILE_NAME_3:-Reality-WARP}" \
        "$warp_outbound_file" || true
    
    # =========================================================================
    # Complete
    # =========================================================================
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    CURRENT_INSTALL_PHASE="complete"
    
    log_success "Installation completed in ${minutes}m ${seconds}s"
}

#-------------------------------------------------------------------------------
# Show Success Info
#-------------------------------------------------------------------------------
show_success_info() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              🎉 Installation Successful! 🎉                    ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Marzban Dashboard:${NC}"
    echo -e "    URL: ${CYAN}https://${PANEL_DOMAIN}${DASHBOARD_PATH:-/dashboard/}${NC}"
    echo -e "    Username: ${CYAN}${ADMIN_USERNAME}${NC}"
    echo -e "    Password: ${CYAN}${ADMIN_PASSWORD}${NC}"
    echo ""
    echo -e "  ${BOLD}Server Information:${NC}"
    echo -e "    IP Address: ${CYAN}${SERVER_IP}${NC}"
    echo -e "    Domain: ${CYAN}${PANEL_DOMAIN}${NC}"
    echo ""
    echo -e "  ${BOLD}Reality Configuration:${NC}"
    echo -e "    Public Key: ${CYAN}${REALITY_PUBLIC_KEY:-see /var/lib/marzban/reality_keys.txt}${NC}"
    echo -e "    Short ID: ${CYAN}$(echo "${REALITY_SHORT_IDS:-}" | cut -d',' -f1)${NC}"
    echo ""
    echo -e "  ${BOLD}Important Files:${NC}"
    echo -e "    Config: ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "    Credentials: ${CYAN}/opt/marzban/admin_credentials.txt${NC}"
    echo -e "    Reality Keys: ${CYAN}/var/lib/marzban/reality_keys.txt${NC}"
    echo -e "    Logs: ${CYAN}/var/log/marzban-installer.log${NC}"
    echo ""
    echo -e "  ${BOLD}Useful Commands:${NC}"
    echo -e "    View logs: ${CYAN}docker logs -f marzban${NC}"
    echo -e "    Restart: ${CYAN}cd /opt/marzban && docker compose restart${NC}"
    echo -e "    Stop: ${CYAN}cd /opt/marzban && docker compose down${NC}"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# Uninstall
#-------------------------------------------------------------------------------
run_uninstall() {
    show_banner
    
    log_warn "This will remove Marzban and all related components!"
    echo ""
    
    if ! confirm_action "Are you sure you want to uninstall?"; then
        log_info "Uninstall cancelled"
        exit 0
    fi
    
    log_step "Uninstalling Marzban"
    
    # Stop containers
    if [[ -d "/opt/marzban" ]]; then
        log_info "Stopping Marzban containers..."
        (cd /opt/marzban && docker compose down --volumes 2>/dev/null) || true
    fi
    
    if [[ -d "/opt/marzban/adguard" ]]; then
        log_info "Stopping AdGuard containers..."
        (cd /opt/marzban/adguard && docker compose down --volumes 2>/dev/null) || true
    fi
    
    # Remove directories
    if confirm_action "Remove Marzban data (/var/lib/marzban)?"; then
        rm -rf /var/lib/marzban
    fi
    
    rm -rf /opt/marzban
    
    # Remove Nginx configs
    rm -f /etc/nginx/sites-enabled/marzban*
    rm -f /etc/nginx/sites-available/marzban*
    rm -f /etc/nginx/stream.d/*
    systemctl reload nginx 2>/dev/null || true
    
    # Remove certificates
    if confirm_action "Remove SSL certificates?"; then
        certbot delete --cert-name "${PANEL_DOMAIN:-marzban}" 2>/dev/null || true
    fi
    
    # Remove config
    rm -f "${CONFIG_FILE}"
    
    log_success "Uninstallation complete"
}

#-------------------------------------------------------------------------------
# Save/Load Install State (for reboot handling)
#-------------------------------------------------------------------------------
save_install_state() {
    local state="$1"
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$state" > "$STATE_FILE"
}

load_install_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    fi
}

clear_install_state() {
    rm -f "$STATE_FILE"
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    # Parse arguments
    parse_arguments "$@"
    
    # Show banner
    show_banner
    
    # Source all modules
    source_modules
    
    # Check for resume after reboot
    local install_state
    install_state=$(load_install_state)
    
    if [[ "$install_state" == "xanmod_installed" ]]; then
        log_info "Resuming installation after kernel update..."
        clear_install_state
        
        # Verify new kernel is active
        if uname -r | grep -q "xanmod"; then
            log_success "XanMod kernel is now active"
        else
            log_warn "XanMod kernel may not be active. Check: uname -r"
        fi
    fi
    
    # Run pre-flight checks
    run_preflight_checks
    
    # Load or collect configuration
    if ! load_config; then
        collect_configuration
        save_configuration
    else
        log_info "Using existing configuration"
    fi
    
    # Show summary and confirm
    show_configuration_summary
    
    # Run installation
    run_installation
    
    # Show success info
    show_success_info
}

# Run main
main "$@"
