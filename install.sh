#!/bin/bash
#===============================================================================
#
#          FILE: install.sh
#
#         USAGE: sudo ./install.sh [OPTIONS]
#
#   DESCRIPTION: Marzban Ultimate VPN Installer
#                Production-grade automated deployment for VLESS/Reality VPN
#
#       OPTIONS:
#         -c, --config FILE    Use custom config file
#         -s, --skip-confirm   Skip confirmation prompts
#         -u, --uninstall      Uninstall Marzban and components
#         -h, --help           Show this help message
#         --no-warp            Skip WARP installation
#         --no-fake-site       Skip fake website setup
#         --staging            Use Let's Encrypt staging (for testing)
#
#        AUTHOR: Marzban Ultimate Installer
#       VERSION: 1.0.0
#       CREATED: 2024
#
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Global Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULES_DIR="${SCRIPT_DIR}/modules"
readonly TEMPLATES_DIR="${SCRIPT_DIR}/templates"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.env"
readonly LOG_FILE="/var/log/marzban-installer.log"

# Installation paths
readonly MARZBAN_DIR="/opt/marzban"
readonly MARZBAN_DATA_DIR="/var/lib/marzban"
readonly NGINX_CONF_DIR="/etc/nginx"
readonly FAKE_SITE_DIR="/var/www/html"

# Default values
SKIP_CONFIRM=false
INSTALL_WARP=true
INSTALL_FAKE_SITE=true
USE_STAGING=false
CUSTOM_CONFIG=""

#-------------------------------------------------------------------------------
# Source Core Module First
#-------------------------------------------------------------------------------
if [[ ! -f "${MODULES_DIR}/core.sh" ]]; then
    echo "ERROR: Core module not found at ${MODULES_DIR}/core.sh"
    exit 1
fi
source "${MODULES_DIR}/core.sh"

#-------------------------------------------------------------------------------
# Show Banner
#-------------------------------------------------------------------------------
show_banner() {
    cat << 'EOF'
    
    ███╗   ███╗ █████╗ ██████╗ ███████╗██████╗  █████╗ ███╗   ██╗
    ████╗ ████║██╔══██╗██╔══██╗╚══███╔╝██╔══██╗██╔══██╗████╗  ██║
    ██╔████╔██║███████║██████╔╝  ███╔╝ ██████╔╝███████║██╔██╗ ██║
    ██║╚██╔╝██║██╔══██║██╔══██╗ ███╔╝  ██╔══██╗██╔══██║██║╚██╗██║
    ██║ ╚═╝ ██║██║  ██║██║  ██║███████╗██████╔╝██║  ██║██║ ╚████║
    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝
    
    ██╗   ██╗██╗  ████████╗██╗███╗   ███╗ █████╗ ████████╗███████╗
    ██║   ██║██║  ╚══██╔══╝██║████╗ ████║██╔══██╗╚══██╔══╝██╔════╝
    ██║   ██║██║     ██║   ██║██╔████╔██║███████║   ██║   █████╗  
    ██║   ██║██║     ██║   ██║██║╚██╔╝██║██╔══██║   ██║   ██╔══╝  
    ╚██████╔╝███████╗██║   ██║██║ ╚═╝ ██║██║  ██║   ██║   ███████╗
     ╚═════╝ ╚══════╝╚═╝   ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝
    
EOF
    echo -e "${CYAN}    VLESS/Reality VPN Installer v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}    Powered by Marzban + Xray-core${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# Show Help
#-------------------------------------------------------------------------------
show_help() {
    cat << EOF
Marzban Ultimate VPN Installer v${SCRIPT_VERSION}

Usage: sudo ./install.sh [OPTIONS]

Options:
  -c, --config FILE    Use custom config file
  -s, --skip-confirm   Skip confirmation prompts
  -u, --uninstall      Uninstall Marzban and components
  -h, --help           Show this help message
  --no-warp            Skip WARP installation
  --no-fake-site       Skip fake website setup
  --staging            Use Let's Encrypt staging (for testing)

Examples:
  sudo ./install.sh                    # Interactive installation
  sudo ./install.sh -c my.env          # Use custom config
  sudo ./install.sh --no-warp          # Install without WARP
  sudo ./install.sh -u                 # Uninstall

For more information, visit: https://github.com/Gozargah/Marzban
EOF
}

#-------------------------------------------------------------------------------
# Parse Command Line Arguments
#-------------------------------------------------------------------------------
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CUSTOM_CONFIG="$2"
                shift 2
                ;;
            -s|--skip-confirm)
                SKIP_CONFIRM=true
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
            --no-warp)
                INSTALL_WARP=false
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
        "firewall.sh"
        "docker.sh"
        "nginx.sh"
        "certbot.sh"
        "xray.sh"
        "marzban.sh"
        "warp.sh"
    )

    for module in "${modules[@]}"; do
        local module_path="${MODULES_DIR}/${module}"
        if [[ -f "${module_path}" ]]; then
            source "${module_path}"
            log_info "Loaded module: ${module}"
        else
            log_error "Module not found: ${module_path}"
            exit 1
        fi
    done
}

#-------------------------------------------------------------------------------
# Interactive Configuration
#-------------------------------------------------------------------------------
collect_configuration() {
    log_info "Starting interactive configuration..."
    echo ""
    
    # Domain configuration
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Domain Configuration                        ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Main domain (for Marzban panel)
    if [[ -z "${DOMAIN:-}" ]]; then
        while true; do
            log_input "Enter your domain for Marzban panel (e.g., panel.example.com): "
            read -r DOMAIN
            if validate_domain "${DOMAIN}"; then
                break
            fi
            log_error "Invalid domain format. Please try again."
        done
    fi
    
    # Reality destination (SNI camouflage)
    if [[ -z "${REALITY_DEST:-}" ]]; then
        log_input "Enter Reality destination domain (default: www.google.com): "
        read -r REALITY_DEST
        REALITY_DEST="${REALITY_DEST:-www.google.com}"
    fi
    
    # Reality server names
    if [[ -z "${REALITY_SERVER_NAMES:-}" ]]; then
        log_input "Enter Reality server names (default: www.google.com,google.com): "
        read -r REALITY_SERVER_NAMES
        REALITY_SERVER_NAMES="${REALITY_SERVER_NAMES:-www.google.com,google.com}"
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Admin Configuration                         ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Admin email
    if [[ -z "${ADMIN_EMAIL:-}" ]]; then
        while true; do
            log_input "Enter admin email (for SSL certificates): "
            read -r ADMIN_EMAIL
            if validate_email "${ADMIN_EMAIL}"; then
                break
            fi
            log_error "Invalid email format. Please try again."
        done
    fi
    
    # Admin username
    if [[ -z "${ADMIN_USERNAME:-}" ]]; then
        log_input "Enter Marzban admin username (default: admin): "
        read -r ADMIN_USERNAME
        ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    fi
    
    # Admin password
    if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
        log_input "Enter Marzban admin password (leave empty for auto-generate): "
        read -rs ADMIN_PASSWORD
        echo ""
        if [[ -z "${ADMIN_PASSWORD}" ]]; then
            ADMIN_PASSWORD=$(generate_password 16)
            log_info "Generated admin password: ${ADMIN_PASSWORD}"
        fi
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Port Configuration                          ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Xray Reality port (internal)
    if [[ -z "${XRAY_PORT:-}" ]]; then
        log_input "Enter Xray Reality port (default: 8443): "
        read -r XRAY_PORT
        XRAY_PORT="${XRAY_PORT:-8443}"
    fi
    
    # Marzban dashboard port (internal)
    if [[ -z "${MARZBAN_PORT:-}" ]]; then
        log_input "Enter Marzban dashboard port (default: 8001): "
        read -r MARZBAN_PORT
        MARZBAN_PORT="${MARZBAN_PORT:-8001}"
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Optional Features                           ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # WARP installation
    if [[ "${INSTALL_WARP}" == "true" ]]; then
        if ! confirm_action "Install Cloudflare WARP for bypassing restrictions?"; then
            INSTALL_WARP=false
        fi
    fi
    
    # Fake website
    if [[ "${INSTALL_FAKE_SITE}" == "true" ]]; then
        if ! confirm_action "Install fake website for camouflage?"; then
            INSTALL_FAKE_SITE=false
        fi
    fi
    
    # Fail2Ban
    if [[ -z "${INSTALL_FAIL2BAN:-}" ]]; then
        if confirm_action "Install Fail2Ban for SSH protection?"; then
            INSTALL_FAIL2BAN=true
        else
            INSTALL_FAIL2BAN=false
        fi
    fi
    
    echo ""
}

#-------------------------------------------------------------------------------
# Load Configuration File
#-------------------------------------------------------------------------------
load_config_file() {
    local config_path="${CUSTOM_CONFIG:-${CONFIG_FILE}}"
    
    if [[ -f "${config_path}" ]]; then
        log_info "Loading configuration from: ${config_path}"
        # shellcheck source=/dev/null
        source "${config_path}"
        return 0
    fi
    
    return 1
}

#-------------------------------------------------------------------------------
# Save Configuration
#-------------------------------------------------------------------------------
save_configuration() {
    log_info "Saving configuration to ${CONFIG_FILE}..."
    
    cat > "${CONFIG_FILE}" << EOF
#===============================================================================
# Marzban Ultimate VPN Installer - Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
#===============================================================================

# Domain Configuration
DOMAIN="${DOMAIN}"
REALITY_DEST="${REALITY_DEST}"
REALITY_SERVER_NAMES="${REALITY_SERVER_NAMES}"

# Admin Configuration
ADMIN_EMAIL="${ADMIN_EMAIL}"
ADMIN_USERNAME="${ADMIN_USERNAME}"
ADMIN_PASSWORD="${ADMIN_PASSWORD}"

# Port Configuration
XRAY_PORT="${XRAY_PORT}"
MARZBAN_PORT="${MARZBAN_PORT}"

# Feature Flags
INSTALL_WARP="${INSTALL_WARP}"
INSTALL_FAKE_SITE="${INSTALL_FAKE_SITE}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-false}"

# SSL Configuration
USE_STAGING="${USE_STAGING}"

# Generated Values (DO NOT EDIT)
SERVER_IP="${SERVER_IP:-$(get_public_ip)}"
EOF
    
    chmod 600 "${CONFIG_FILE}"
    log_success "Configuration saved"
}

#-------------------------------------------------------------------------------
# Display Configuration Summary
#-------------------------------------------------------------------------------
show_configuration_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                  Configuration Summary                         ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${WHITE}Domain:${NC}              ${GREEN}${DOMAIN}${NC}"
    echo -e "  ${WHITE}Reality Dest:${NC}        ${GREEN}${REALITY_DEST}${NC}"
    echo -e "  ${WHITE}Admin Email:${NC}         ${GREEN}${ADMIN_EMAIL}${NC}"
    echo -e "  ${WHITE}Admin Username:${NC}      ${GREEN}${ADMIN_USERNAME}${NC}"
    echo -e "  ${WHITE}Xray Port:${NC}           ${GREEN}${XRAY_PORT}${NC}"
    echo -e "  ${WHITE}Marzban Port:${NC}        ${GREEN}${MARZBAN_PORT}${NC}"
    echo -e "  ${WHITE}Install WARP:${NC}        ${GREEN}${INSTALL_WARP}${NC}"
    echo -e "  ${WHITE}Install Fake Site:${NC}   ${GREEN}${INSTALL_FAKE_SITE}${NC}"
    echo -e "  ${WHITE}Install Fail2Ban:${NC}    ${GREEN}${INSTALL_FAIL2BAN:-false}${NC}"
    echo -e "  ${WHITE}SSL Staging:${NC}         ${GREEN}${USE_STAGING}${NC}"
    echo ""
    
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
    log_info "Running pre-flight checks..."
    
    # Check root
    check_root
    
    # Check OS
    check_os
    
    # Check architecture
    check_architecture
    
    # Check virtualization
    check_virtualization
    
    # Check memory
    check_memory 512
    
    # Check disk space
    check_disk_space 5
    
    # Get server IP
    SERVER_IP=$(get_public_ip)
    if [[ -z "${SERVER_IP}" ]]; then
        log_error "Could not detect public IP address"
        exit 1
    fi
    log_info "Detected server IP: ${SERVER_IP}"
    
    log_success "All pre-flight checks passed"
}

#-------------------------------------------------------------------------------
# Installation Steps
#-------------------------------------------------------------------------------
run_installation() {
    local start_time
    start_time=$(date +%s)
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                  Starting Installation                         ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Step 1: System Preparation
    log_info "[1/9] Preparing system..."
    add_rollback_action "echo 'System preparation rollback - manual cleanup may be required'"
    configure_timezone
    install_essential_packages
    configure_sysctl_optimizations
    configure_system_limits
    configure_dns
    if [[ "${INSTALL_FAIL2BAN:-false}" == "true" ]]; then
        install_fail2ban
    fi
    log_success "System preparation complete"
    
    # Step 2: Firewall Configuration
    log_info "[2/9] Configuring firewall..."
    add_rollback_action "ufw --force reset 2>/dev/null || true"
    detect_ssh_port
    configure_ufw
    log_success "Firewall configured"
    
    # Step 3: Docker Installation
    log_info "[3/9] Installing Docker..."
    add_rollback_action "systemctl stop docker 2>/dev/null || true; apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true"
    install_docker
    configure_docker_daemon
    verify_docker_installation
    log_success "Docker installed"
    
    # Step 4: Nginx Installation
    log_info "[4/9] Installing Nginx..."
    add_rollback_action "systemctl stop nginx 2>/dev/null || true; apt-get remove -y nginx 2>/dev/null || true"
    install_nginx
    generate_dhparams
    configure_nginx_main
    if [[ "${INSTALL_FAKE_SITE}" == "true" ]]; then
        setup_fake_website
    fi
    configure_nginx_stream "${DOMAIN}" "${XRAY_PORT}" "${MARZBAN_PORT}"
    configure_nginx_site "${DOMAIN}"
    create_self_signed_cert "${DOMAIN}"
    validate_nginx_config
    systemctl reload nginx
    log_success "Nginx installed and configured"
    
    # Step 5: Generate Xray Configuration
    log_info "[5/9] Generating Xray configuration..."
    generate_xray_keys
    generate_xray_config \
        "${XRAY_PORT}" \
        "${REALITY_DEST}" \
        "${REALITY_SERVER_NAMES}" \
        "${XRAY_PRIVATE_KEY}" \
        "${XRAY_SHORT_ID}"
    log_success "Xray configuration generated"
    
    # Step 6: WARP Installation (Optional)
    if [[ "${INSTALL_WARP}" == "true" ]]; then
        log_info "[6/9] Installing Cloudflare WARP..."
        if install_wgcf; then
            if register_warp; then
                if generate_warp_config; then
                    configure_xray_warp_outbound
                    log_success "WARP installed and configured"
                else
                    log_warn "WARP config generation failed, skipping..."
                fi
            else
                log_warn "WARP registration failed, skipping..."
            fi
        else
            log_warn "WGCF installation failed, skipping WARP..."
        fi
    else
        log_info "[6/9] Skipping WARP installation (disabled)"
    fi
    
    # Step 7: Marzban Installation
    log_info "[7/9] Installing Marzban..."
    add_rollback_action "cd ${MARZBAN_DIR} && docker compose down 2>/dev/null || true; rm -rf ${MARZBAN_DIR} ${MARZBAN_DATA_DIR} 2>/dev/null || true"
    create_marzban_directories
    generate_marzban_env "${DOMAIN}" "${MARZBAN_PORT}"
    generate_docker_compose
    pull_marzban_image
    start_marzban
    create_admin_user "${ADMIN_USERNAME}" "${ADMIN_PASSWORD}"
    log_success "Marzban installed"
    
    # Step 8: SSL Certificate
    log_info "[8/9] Obtaining SSL certificate..."
    local certbot_opts=""
    if [[ "${USE_STAGING}" == "true" ]]; then
        certbot_opts="--staging"
    fi
    if verify_domain_dns "${DOMAIN}" "${SERVER_IP}"; then
        obtain_certificate "${DOMAIN}" "${ADMIN_EMAIL}" "${certbot_opts}"
        update_nginx_ssl_paths "${DOMAIN}"
        configure_ssl_renewal
        systemctl reload nginx
        log_success "SSL certificate obtained"
    else
        log_warn "DNS verification failed. Using self-signed certificate."
        log_warn "You can obtain a real certificate later with: certbot --nginx -d ${DOMAIN}"
    fi
    
    # Step 9: Final Verification
    log_info "[9/9] Running final verification..."
    verify_installation
    
    # Calculate installation time
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    echo ""
    log_success "Installation completed in ${minutes}m ${seconds}s"
}

#-------------------------------------------------------------------------------
# Verify Installation
#-------------------------------------------------------------------------------
verify_installation() {
    local errors=0
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                  Installation Verification                     ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Check Docker
    if docker ps &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Docker is running"
    else
        echo -e "  ${RED}✗${NC} Docker is not running"
        ((errors++))
    fi
    
    # Check Marzban container
    if docker ps --format '{{.Names}}' | grep -q "marzban"; then
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' marzban 2>/dev/null || echo "unknown")
        if [[ "${health}" == "healthy" ]]; then
            echo -e "  ${GREEN}✓${NC} Marzban container is healthy"
        else
            echo -e "  ${YELLOW}!${NC} Marzban container status: ${health}"
        fi
    else
        echo -e "  ${RED}✗${NC} Marzban container is not running"
        ((errors++))
    fi
    
    # Check Nginx
    if systemctl is-active --quiet nginx; then
        echo -e "  ${GREEN}✓${NC} Nginx is running"
    else
        echo -e "  ${RED}✗${NC} Nginx is not running"
        ((errors++))
    fi
    
    # Check ports
    if check_port_listening 443; then
        echo -e "  ${GREEN}✓${NC} Port 443 is listening"
    else
        echo -e "  ${RED}✗${NC} Port 443 is not listening"
        ((errors++))
    fi
    
    if check_port_listening "${XRAY_PORT}"; then
        echo -e "  ${GREEN}✓${NC} Xray port ${XRAY_PORT} is listening"
    else
        echo -e "  ${YELLOW}!${NC} Xray port ${XRAY_PORT} - check Marzban logs"
    fi
    
    # Check UFW
    if ufw status | grep -q "Status: active"; then
        echo -e "  ${GREEN}✓${NC} UFW firewall is active"
    else
        echo -e "  ${YELLOW}!${NC} UFW firewall is not active"
    fi
    
    echo ""
    
    if [[ ${errors} -gt 0 ]]; then
        log_warn "Installation completed with ${errors} issue(s). Please check the logs."
        return 1
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# Display Success Information
#-------------------------------------------------------------------------------
show_success_info() {
    local credentials_file="${MARZBAN_DIR}/admin_credentials.txt"
    local keys_file="${MARZBAN_DATA_DIR}/reality_keys.txt"
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              🎉 Installation Successful! 🎉                    ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${WHITE}Marzban Dashboard:${NC}"
    echo -e "    URL: ${CYAN}https://${DOMAIN}/dashboard${NC}"
    echo -e "    Username: ${CYAN}${ADMIN_USERNAME}${NC}"
    echo -e "    Password: ${CYAN}${ADMIN_PASSWORD}${NC}"
    echo ""
    echo -e "  ${WHITE}Server Information:${NC}"
    echo -e "    IP Address: ${CYAN}${SERVER_IP}${NC}"
    echo -e "    Domain: ${CYAN}${DOMAIN}${NC}"
    echo ""
    
    if [[ -f "${keys_file}" ]]; then
        echo -e "  ${WHITE}Reality Keys:${NC}"
        echo -e "    Location: ${CYAN}${keys_file}${NC}"
    fi
    
    echo ""
    echo -e "  ${WHITE}Important Files:${NC}"
    echo -e "    Config: ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "    Credentials: ${CYAN}${credentials_file}${NC}"
    echo -e "    Marzban Dir: ${CYAN}${MARZBAN_DIR}${NC}"
    echo -e "    Logs: ${CYAN}${LOG_FILE}${NC}"
    echo ""
    echo -e "  ${WHITE}Useful Commands:${NC}"
    echo -e "    View logs: ${CYAN}docker logs -f marzban${NC}"
    echo -e "    Restart: ${CYAN}cd ${MARZBAN_DIR} && docker compose restart${NC}"
    echo -e "    Stop: ${CYAN}cd ${MARZBAN_DIR} && docker compose down${NC}"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Save summary to file
    {
        echo "Marzban Installation Summary"
        echo "============================"
        echo "Date: $(date)"
        echo ""
        echo "Dashboard: https://${DOMAIN}/dashboard"
        echo "Username: ${ADMIN_USERNAME}"
        echo "Password: ${ADMIN_PASSWORD}"
        echo ""
        echo "Server IP: ${SERVER_IP}"
    } > "${MARZBAN_DIR}/installation_summary.txt"
    chmod 600 "${MARZBAN_DIR}/installation_summary.txt"
}

#-------------------------------------------------------------------------------
# Uninstall Function
#-------------------------------------------------------------------------------
run_uninstall() {
    show_banner
    
    log_warn "This will remove Marzban and all related components!"
    echo ""
    
    if ! confirm_action "Are you sure you want to uninstall?"; then
        log_info "Uninstall cancelled"
        exit 0
    fi
    
    log_info "Starting uninstallation..."
    
    # Stop and remove Marzban
    if [[ -d "${MARZBAN_DIR}" ]]; then
        log_info "Stopping Marzban..."
        cd "${MARZBAN_DIR}" && docker compose down --volumes 2>/dev/null || true
    fi
    
    # Remove Marzban directories
    log_info "Removing Marzban directories..."
    rm -rf "${MARZBAN_DIR}"
    
    if confirm_action "Remove Marzban data directory (${MARZBAN_DATA_DIR})?"; then
        rm -rf "${MARZBAN_DATA_DIR}"
    fi
    
    # Remove Nginx configs
    log_info "Removing Nginx configurations..."
    rm -f /etc/nginx/conf.d/marzban.conf
    rm -f /etc/nginx/conf.d/stream.conf
    systemctl reload nginx 2>/dev/null || true
    
    # Remove certificates
    if confirm_action "Remove SSL certificates?"; then
        certbot delete --cert-name "${DOMAIN:-marzban}" 2>/dev/null || true
    fi
    
    # Optionally remove Docker
    if confirm_action "Remove Docker? (This will affect other containers)"; then
        apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
        rm -rf /var/lib/docker
    fi
    
    # Remove config file
    rm -f "${CONFIG_FILE}"
    
    log_success "Uninstallation complete"
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    # Parse arguments
    parse_arguments "$@"
    
    # Show banner
    show_banner
    
    # Initialize logging
    init_logging "${LOG_FILE}"
    
    # Run pre-flight checks
    run_preflight_checks
    
    # Source all modules
    source_modules
    
    # Load or collect configuration
    if ! load_config_file; then
        collect_configuration
        save_configuration
    else
        log_info "Using existing configuration"
    fi
    
    # Show summary and confirm
    show_configuration_summary
    
    # Run installation
    run_installation
    
    # Show success information
    show_success_info
}

# Run main function
main "$@"
