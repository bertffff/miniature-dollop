#!/bin/bash
# =============================================================================
# MODULE: xray.sh - Xray Core Installation and Reality Key Generation
# Version: 2.0.0
# =============================================================================
# Features:
# - Xray core version management
# - X25519 key pair generation for Reality
# - Short ID generation
# - Configuration validation
# - GeoIP/GeoSite asset management
# =============================================================================

# Source core module if not already loaded
if [[ -z "${CORE_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
fi

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------
readonly XRAY_GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_DOWNLOAD_BASE="https://github.com/XTLS/Xray-core/releases/download"
readonly XRAY_INSTALL_DIR="/var/lib/marzban/xray-core"
readonly XRAY_CONFIG_FILE="/var/lib/marzban/xray_config.json"
readonly XRAY_KEYS_FILE="/var/lib/marzban/reality_keys.txt"

# GeoIP/GeoSite sources
readonly GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
readonly GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

# -----------------------------------------------------------------------------
# XRAY CORE INSTALLATION
# -----------------------------------------------------------------------------

# Get latest Xray version
get_latest_xray_version() {
    local version
    version=$(curl -sf --max-time 10 "$XRAY_GITHUB_API" | jq -r '.tag_name // empty')
    
    if [[ -z "$version" ]]; then
        log_warn "Could not fetch latest Xray version, using fallback"
        echo "v1.8.24"
        return 1
    fi
    
    echo "$version"
}

# Get current installed Xray version
get_installed_xray_version() {
    if [[ -x "${XRAY_INSTALL_DIR}/xray" ]]; then
        "${XRAY_INSTALL_DIR}/xray" version 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+'
    else
        echo ""
    fi
}

# Download and install Xray core
install_xray_core() {
    local version="${1:-}"
    
    log_step "Installing Xray Core"
    
    # Get version if not specified
    if [[ -z "$version" ]]; then
        version=$(get_latest_xray_version)
    fi
    
    log_info "Target version: ${version}"
    
    # Check if already installed
    local current_version
    current_version=$(get_installed_xray_version)
    
    if [[ "$current_version" == "$version" ]]; then
        log_info "Xray ${version} is already installed"
        return 0
    fi
    
    # Determine architecture
    local arch
    case "$(uname -m)" in
        x86_64|amd64)
            arch="64"
            ;;
        aarch64|arm64)
            arch="arm64-v8a"
            ;;
        armv7l)
            arch="arm32-v7a"
            ;;
        *)
            log_error "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac
    
    local download_url="${XRAY_DOWNLOAD_BASE}/${version}/Xray-linux-${arch}.zip"
    local temp_dir="/tmp/xray-install-$$"
    
    log_info "Downloading Xray from: ${download_url}"
    
    # Create directories
    create_dir "$XRAY_INSTALL_DIR" "0755"
    mkdir -p "$temp_dir"
    
    # Download with retry
    if ! retry_command 3 5 curl -sfL --max-time 120 -o "${temp_dir}/xray.zip" "$download_url"; then
        log_error "Failed to download Xray"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Extract
    log_info "Extracting Xray..."
    if ! unzip -q -o "${temp_dir}/xray.zip" -d "$temp_dir"; then
        log_error "Failed to extract Xray"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Install binary
    mv "${temp_dir}/xray" "${XRAY_INSTALL_DIR}/xray"
    chmod +x "${XRAY_INSTALL_DIR}/xray"
    
    # Install geo files if present
    [[ -f "${temp_dir}/geoip.dat" ]] && mv "${temp_dir}/geoip.dat" "${XRAY_INSTALL_DIR}/"
    [[ -f "${temp_dir}/geosite.dat" ]] && mv "${temp_dir}/geosite.dat" "${XRAY_INSTALL_DIR}/"
    
    # Cleanup
    rm -rf "$temp_dir"
    
    # Verify installation
    if ! "${XRAY_INSTALL_DIR}/xray" version &>/dev/null; then
        log_error "Xray installation verification failed"
        return 1
    fi
    
    local installed_version
    installed_version=$(get_installed_xray_version)
    log_success "Xray ${installed_version} installed successfully"
    
    register_file "$XRAY_INSTALL_DIR"
}

# Update GeoIP and GeoSite databases
update_geo_databases() {
    log_info "Updating GeoIP and GeoSite databases..."
    
    local geo_dir="$XRAY_INSTALL_DIR"
    create_dir "$geo_dir" "0755"
    
    # Download GeoIP
    if curl -sfL --max-time 60 -o "${geo_dir}/geoip.dat.new" "$GEOIP_URL"; then
        mv "${geo_dir}/geoip.dat.new" "${geo_dir}/geoip.dat"
        log_success "GeoIP database updated"
    else
        log_warn "Failed to update GeoIP database"
    fi
    
    # Download GeoSite
    if curl -sfL --max-time 60 -o "${geo_dir}/geosite.dat.new" "$GEOSITE_URL"; then
        mv "${geo_dir}/geosite.dat.new" "${geo_dir}/geosite.dat"
        log_success "GeoSite database updated"
    else
        log_warn "Failed to update GeoSite database"
    fi
}

# -----------------------------------------------------------------------------
# REALITY KEY GENERATION
# -----------------------------------------------------------------------------

# Generate X25519 key pair using Xray
generate_x25519_keypair() {
    log_info "Generating X25519 key pair for Reality..."
    
    local xray_bin="${XRAY_INSTALL_DIR}/xray"
    local output=""
    
    # Method 1: Use installed Xray binary
    if [[ -x "$xray_bin" ]]; then
        output=$("$xray_bin" x25519 2>/dev/null)
    fi
    
    # Method 2: Use Docker if binary not available
    if [[ -z "$output" ]] && command_exists docker; then
        log_debug "Using Docker for key generation..."
        output=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null)
    fi
    
    # Method 3: Use openssl as fallback (less secure, not recommended)
    if [[ -z "$output" ]]; then
        log_warn "Using OpenSSL for key generation (Xray binary preferred)"
        
        local private_key
        local public_key
        
        # Generate using openssl (X25519)
        private_key=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -text -noout 2>/dev/null | grep -A5 'priv:' | tail -4 | tr -d ' \n:')
        
        if [[ -z "$private_key" ]]; then
            log_error "Failed to generate X25519 key pair"
            return 1
        fi
        
        # This is a simplified fallback - production should use Xray
        echo "Private key: ${private_key}"
        echo "Public key: (requires Xray for derivation)"
        return 1
    fi
    
    # Parse output from Xray
    local private_key
    local public_key
    
    private_key=$(echo "$output" | grep -i 'private' | awk '{print $NF}')
    public_key=$(echo "$output" | grep -i 'public' | awk '{print $NF}')
    
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "Failed to parse X25519 key pair"
        return 1
    fi
    
    echo "PRIVATE_KEY=${private_key}"
    echo "PUBLIC_KEY=${public_key}"
}

# Generate multiple short IDs for Reality
generate_short_ids() {
    local count="${1:-4}"
    local short_ids=()
    
    log_debug "Generating ${count} short IDs..."
    
    for ((i=0; i<count; i++)); do
        local sid
        sid=$(openssl rand -hex 8 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
        short_ids+=("$sid")
    done
    
    # Return comma-separated list
    local IFS=','
    echo "${short_ids[*]}"
}

# Generate single short ID
generate_short_id() {
    openssl rand -hex 8 2>/dev/null || head -c 16 /dev/urandom | xxd -p | head -c 16
}

# Save Reality keys to secure file
save_reality_keys() {
    local private_key="$1"
    local public_key="$2"
    local short_ids="$3"
    local output_file="${4:-$XRAY_KEYS_FILE}"
    
    log_info "Saving Reality keys to ${output_file}..."
    
    # Create directory if needed
    create_dir "$(dirname "$output_file")" "0755"
    
    cat > "$output_file" << EOF
# Reality Keys - Generated $(date '+%Y-%m-%d %H:%M:%S')
# ============================================
# KEEP THIS FILE SECURE!
# These keys are required for client configuration.
# ============================================

REALITY_PRIVATE_KEY=${private_key}
REALITY_PUBLIC_KEY=${public_key}
REALITY_SHORT_IDS=${short_ids}

# Client Configuration:
# - Public Key: ${public_key}
# - Short ID: $(echo "$short_ids" | cut -d',' -f1)
# - Fingerprint: chrome (recommended)
# - Server Name: (your configured SNI)
EOF
    
    chmod 0600 "$output_file"
    register_file "$output_file"
    
    log_success "Reality keys saved"
}

# Load Reality keys from file
load_reality_keys() {
    local keys_file="${1:-$XRAY_KEYS_FILE}"
    
    if [[ ! -f "$keys_file" ]]; then
        log_debug "Reality keys file not found: ${keys_file}"
        return 1
    fi
    
    # Source the file to load variables
    # shellcheck source=/dev/null
    source "$keys_file"
    
    if [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]]; then
        export REALITY_PRIVATE_KEY
        export REALITY_PUBLIC_KEY
        export REALITY_SHORT_IDS
        log_debug "Reality keys loaded from ${keys_file}"
        return 0
    fi
    
    return 1
}

# Generate all Reality keys
setup_reality_keys() {
    log_step "Setting up Reality Keys"
    
    # Check if keys already exist
    if load_reality_keys; then
        log_info "Existing Reality keys found"
        
        if ! confirm_action "Regenerate Reality keys?" "n"; then
            echo "PRIVATE_KEY=${REALITY_PRIVATE_KEY}"
            echo "PUBLIC_KEY=${REALITY_PUBLIC_KEY}"
            echo "SHORT_IDS=${REALITY_SHORT_IDS}"
            return 0
        fi
    fi
    
    # Generate new keys
    local keypair_output
    keypair_output=$(generate_x25519_keypair)
    
    if [[ -z "$keypair_output" ]]; then
        log_error "Failed to generate Reality keys"
        return 1
    fi
    
    # Parse keys
    local private_key
    local public_key
    
    private_key=$(echo "$keypair_output" | grep 'PRIVATE_KEY=' | cut -d'=' -f2)
    public_key=$(echo "$keypair_output" | grep 'PUBLIC_KEY=' | cut -d'=' -f2)
    
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "Failed to parse generated keys"
        return 1
    fi
    
    # Generate short IDs
    local short_ids
    short_ids=$(generate_short_ids 4)
    
    # Save keys
    save_reality_keys "$private_key" "$public_key" "$short_ids"
    
    # Export for use
    export REALITY_PRIVATE_KEY="$private_key"
    export REALITY_PUBLIC_KEY="$public_key"
    export REALITY_SHORT_IDS="$short_ids"
    
    # Print summary
    echo ""
    print_separator
    echo -e "${GREEN}Reality Keys Generated${NC}"
    print_separator
    echo ""
    echo "Private Key: ${private_key}"
    echo "Public Key:  ${public_key}"
    echo "Short IDs:   ${short_ids}"
    echo ""
    echo -e "${YELLOW}Important: Save the Public Key for client configuration!${NC}"
    print_separator
    
    echo "PRIVATE_KEY=${private_key}"
    echo "PUBLIC_KEY=${public_key}"
    echo "SHORT_IDS=${short_ids}"
}

# -----------------------------------------------------------------------------
# XRAY CONFIGURATION VALIDATION
# -----------------------------------------------------------------------------

# Validate Xray JSON configuration
validate_xray_config() {
    local config_file="${1:-$XRAY_CONFIG_FILE}"
    
    log_info "Validating Xray configuration: ${config_file}"
    
    # Check file exists
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: ${config_file}"
        return 1
    fi
    
    # Validate JSON syntax
    if ! jq -e '.' "$config_file" &>/dev/null; then
        log_error "Invalid JSON syntax in configuration"
        return 1
    fi
    
    # Validate with Xray binary
    local xray_bin="${XRAY_INSTALL_DIR}/xray"
    
    if [[ -x "$xray_bin" ]]; then
        if "$xray_bin" run -test -config "$config_file" &>/dev/null; then
            log_success "Xray configuration is valid"
            return 0
        else
            log_error "Xray configuration validation failed"
            "$xray_bin" run -test -config "$config_file" 2>&1 | tail -10
            return 1
        fi
    fi
    
    # Validate using Docker if binary not available
    if command_exists docker; then
        if docker run --rm -v "${config_file}:/config.json:ro" \
            ghcr.io/xtls/xray-core:latest run -test -config /config.json &>/dev/null; then
            log_success "Xray configuration is valid (via Docker)"
            return 0
        else
            log_error "Xray configuration validation failed"
            return 1
        fi
    fi
    
    log_warn "Could not fully validate configuration (Xray binary not available)"
    return 0
}

# Check required sections in Xray config
check_xray_config_sections() {
    local config_file="${1:-$XRAY_CONFIG_FILE}"
    
    local required_sections=("log" "inbounds" "outbounds" "routing")
    local missing=()
    
    for section in "${required_sections[@]}"; do
        if ! jq -e ".${section}" "$config_file" &>/dev/null; then
            missing+=("$section")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing config sections: ${missing[*]}"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# REALITY PROFILE GENERATION
# -----------------------------------------------------------------------------

# Generate Reality server names list from SNI
generate_server_names() {
    local sni="$1"
    
    # Return JSON array of server names
    # Include both with and without www for common domains
    if [[ "$sni" == www.* ]]; then
        local base="${sni#www.}"
        echo "[\"${sni}\", \"${base}\"]"
    else
        echo "[\"${sni}\"]"
    fi
}

# Get recommended Reality destination sites
get_recommended_reality_sites() {
    cat << 'EOF'
# Recommended Reality destination sites
# These sites support TLS 1.3 and have good global accessibility

# Google services (very stable, high compatibility)
www.google.com
www.googletagmanager.com
www.googleapis.com

# Microsoft services
www.microsoft.com
www.azure.com
www.office.com

# Apple services
www.apple.com
www.icloud.com

# CDN/Cloud providers
www.cloudflare.com
www.akamai.com
www.fastly.com

# Popular sites
www.amazon.com
www.ebay.com
www.paypal.com

# Gaming (good for low latency)
www.steampowered.com
www.epicgames.com
www.playstation.com
www.xbox.com

# Social media (check regional availability)
www.facebook.com
www.twitter.com
www.instagram.com
EOF
}

# Test Reality SNI connectivity
test_reality_sni() {
    local sni="$1"
    local timeout="${2:-5}"
    
    log_debug "Testing Reality SNI: ${sni}"
    
    # Test TLS 1.3 support
    local result
    result=$(echo | openssl s_client -connect "${sni}:443" \
        -tls1_3 -servername "$sni" 2>/dev/null | \
        grep -E "Protocol|Cipher" | head -2)
    
    if echo "$result" | grep -q "TLSv1.3"; then
        log_debug "SNI ${sni} supports TLS 1.3"
        return 0
    else
        log_debug "SNI ${sni} may not support TLS 1.3"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# MAIN SETUP FUNCTION
# -----------------------------------------------------------------------------

# Complete Xray setup
setup_xray() {
    log_step "Setting up Xray Core"
    
    # Install Xray binary
    install_xray_core
    
    # Update geo databases
    update_geo_databases
    
    # Setup Reality keys
    setup_reality_keys
    
    log_success "Xray setup completed"
}

# Export function marker
XRAY_MODULE_LOADED=true
