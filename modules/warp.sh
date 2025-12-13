#!/bin/bash
# =============================================================================
# MODULE: warp.sh - Cloudflare WARP Integration for Xray Outbound
# Version: 2.0.0
# =============================================================================
# Features:
# - WGCF-based WARP registration
# - WireGuard configuration generation
# - Xray-compatible outbound format
# - WARP+ license support
# - Connection testing
# =============================================================================

# Source core module if not already loaded
if [[ -z "${CORE_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
fi

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------
readonly WGCF_RELEASES_URL="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
readonly WGCF_INSTALL_PATH="/usr/local/bin/wgcf"
readonly WARP_DIR="/var/lib/marzban/warp"
readonly WARP_CONFIG_FILE="${WARP_DIR}/warp.conf"
readonly WARP_XRAY_OUTBOUND="${WARP_DIR}/warp_outbound.json"
readonly WARP_ACCOUNT_FILE="${WARP_DIR}/wgcf-account.toml"
readonly WARP_PROFILE_FILE="${WARP_DIR}/wgcf-profile.conf"

# Cloudflare WARP endpoints
readonly WARP_ENDPOINTS=(
    "engage.cloudflareclient.com:2408"
    "162.159.193.1:2408"
    "162.159.193.2:2408"
    "162.159.192.1:2408"
    "162.159.192.2:2408"
    "[2606:4700:d0::a29f:c001]:2408"
    "[2606:4700:d0::a29f:c002]:2408"
)

# -----------------------------------------------------------------------------
# WGCF INSTALLATION
# -----------------------------------------------------------------------------

# Get latest WGCF version
get_latest_wgcf_version() {
    curl -sf --max-time 10 "$WGCF_RELEASES_URL" | jq -r '.tag_name // empty'
}

# Check if WGCF is installed
is_wgcf_installed() {
    [[ -x "$WGCF_INSTALL_PATH" ]]
}

# Get WGCF version
get_wgcf_version() {
    if is_wgcf_installed; then
        "$WGCF_INSTALL_PATH" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
    fi
}

# Install WGCF binary
install_wgcf() {
    log_step "Installing WGCF (WARP CLI)"
    
    if is_wgcf_installed; then
        local version
        version=$(get_wgcf_version)
        log_info "WGCF already installed: v${version}"
        return 0
    fi
    
    # Determine architecture
    local arch
    case "$(uname -m)" in
        x86_64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        armv7l)
            arch="armv7"
            ;;
        *)
            log_error "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac
    
    # Get download URL
    local version
    version=$(get_latest_wgcf_version)
    
    if [[ -z "$version" ]]; then
        version="v2.2.22"  # Fallback version
        log_warn "Could not fetch latest version, using ${version}"
    fi
    
    local download_url="https://github.com/ViRb3/wgcf/releases/download/${version}/wgcf_${version#v}_linux_${arch}"
    
    log_info "Downloading WGCF ${version} for ${arch}..."
    
    if ! curl -sfL --max-time 60 -o "$WGCF_INSTALL_PATH" "$download_url"; then
        log_error "Failed to download WGCF"
        return 1
    fi
    
    chmod +x "$WGCF_INSTALL_PATH"
    
    # Verify installation
    if ! is_wgcf_installed; then
        log_error "WGCF installation failed"
        return 1
    fi
    
    register_file "$WGCF_INSTALL_PATH"
    
    log_success "WGCF installed successfully"
}

# -----------------------------------------------------------------------------
# WARP REGISTRATION
# -----------------------------------------------------------------------------

# Register new WARP account
register_warp_account() {
    log_step "Registering WARP Account"
    
    create_dir "$WARP_DIR" "0700"
    
    local old_pwd
    old_pwd=$(pwd)
    cd "$WARP_DIR" || return 1
    
    # Check if account already exists
    if [[ -f "$WARP_ACCOUNT_FILE" ]]; then
        log_info "WARP account already exists"
        
        if ! confirm_action "Re-register WARP account?" "n"; then
            cd "$old_pwd"
            return 0
        fi
        
        # Backup existing account
        backup_file "$WARP_ACCOUNT_FILE"
    fi
    
    # Register new account
    log_info "Registering with Cloudflare WARP..."
    
    if ! "$WGCF_INSTALL_PATH" register --accept-tos; then
        log_error "WARP registration failed"
        cd "$old_pwd"
        return 1
    fi
    
    if [[ ! -f "$WARP_ACCOUNT_FILE" ]]; then
        log_error "WARP account file not created"
        cd "$old_pwd"
        return 1
    fi
    
    register_file "$WARP_ACCOUNT_FILE"
    
    cd "$old_pwd"
    log_success "WARP account registered"
}

# Apply WARP+ license key
apply_warp_plus_license() {
    local license_key="$1"
    
    log_info "Applying WARP+ license..."
    
    if [[ ! -f "$WARP_ACCOUNT_FILE" ]]; then
        log_error "WARP account not found. Register first."
        return 1
    fi
    
    local old_pwd
    old_pwd=$(pwd)
    cd "$WARP_DIR" || return 1
    
    # Update license in account file
    if "$WGCF_INSTALL_PATH" update --license "$license_key"; then
        log_success "WARP+ license applied"
        cd "$old_pwd"
        return 0
    else
        log_warn "Failed to apply WARP+ license (may still work as free tier)"
        cd "$old_pwd"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# WIREGUARD PROFILE GENERATION
# -----------------------------------------------------------------------------

# Generate WireGuard profile from WARP account
generate_warp_profile() {
    log_step "Generating WARP WireGuard Profile"
    
    if [[ ! -f "$WARP_ACCOUNT_FILE" ]]; then
        log_error "WARP account not found. Run registration first."
        return 1
    fi
    
    local old_pwd
    old_pwd=$(pwd)
    cd "$WARP_DIR" || return 1
    
    # Generate profile
    if ! "$WGCF_INSTALL_PATH" generate; then
        log_error "Failed to generate WARP profile"
        cd "$old_pwd"
        return 1
    fi
    
    if [[ ! -f "$WARP_PROFILE_FILE" ]]; then
        log_error "WARP profile file not created"
        cd "$old_pwd"
        return 1
    fi
    
    register_file "$WARP_PROFILE_FILE"
    
    cd "$old_pwd"
    log_success "WARP WireGuard profile generated"
}

# Parse WireGuard profile to extract configuration
parse_warp_profile() {
    local profile_file="${1:-$WARP_PROFILE_FILE}"
    
    if [[ ! -f "$profile_file" ]]; then
        log_error "WARP profile not found: ${profile_file}"
        return 1
    fi
    
    log_debug "Parsing WARP profile..."
    
    # Extract values
    local private_key
    local address_v4
    local address_v6
    local public_key
    local endpoint
    
    private_key=$(grep -E "^PrivateKey\s*=" "$profile_file" | cut -d'=' -f2 | tr -d ' ')
    public_key=$(grep -E "^PublicKey\s*=" "$profile_file" | cut -d'=' -f2 | tr -d ' ')
    endpoint=$(grep -E "^Endpoint\s*=" "$profile_file" | cut -d'=' -f2 | tr -d ' ')
    
    # Parse addresses (may have multiple)
    local addresses
    addresses=$(grep -E "^Address\s*=" "$profile_file" | cut -d'=' -f2 | tr -d ' ')
    
    # Extract IPv4 and IPv6
    address_v4=$(echo "$addresses" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1)
    address_v6=$(echo "$addresses" | grep -oE '[a-fA-F0-9:]+/[0-9]+' | head -1)
    
    # Remove CIDR notation for Xray
    local address_v4_clean="${address_v4%/*}"
    local address_v6_clean="${address_v6%/*}"
    
    # Export variables
    export WARP_PRIVATE_KEY="$private_key"
    export WARP_PUBLIC_KEY="$public_key"
    export WARP_ADDRESS_V4="$address_v4_clean"
    export WARP_ADDRESS_V6="$address_v6_clean"
    export WARP_ENDPOINT="$endpoint"
    
    log_debug "WARP Private Key: ${private_key:0:10}..."
    log_debug "WARP Public Key: ${public_key}"
    log_debug "WARP IPv4: ${address_v4_clean}"
    log_debug "WARP IPv6: ${address_v6_clean}"
    log_debug "WARP Endpoint: ${endpoint}"
    
    # Return as key=value pairs
    cat << EOF
WARP_PRIVATE_KEY=${private_key}
WARP_PUBLIC_KEY=${public_key}
WARP_ADDRESS_V4=${address_v4_clean}
WARP_ADDRESS_V6=${address_v6_clean}
WARP_ENDPOINT=${endpoint}
EOF
}

# -----------------------------------------------------------------------------
# XRAY OUTBOUND GENERATION
# -----------------------------------------------------------------------------

# Generate Xray WireGuard outbound configuration
generate_xray_warp_outbound() {
    local output_file="${1:-$WARP_XRAY_OUTBOUND}"
    
    log_step "Generating Xray WARP Outbound"
    
    # Parse profile if not already done
    if [[ -z "${WARP_PRIVATE_KEY:-}" ]]; then
        if ! parse_warp_profile; then
            log_error "Failed to parse WARP profile"
            return 1
        fi
    fi
    
    # Validate required values
    if [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_PUBLIC_KEY" ]]; then
        log_error "WARP configuration incomplete"
        return 1
    fi
    
    # Select best endpoint
    local endpoint="${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}"
    
    # Create directory
    create_dir "$(dirname "$output_file")" "0755"
    
    # Generate Xray-compatible WireGuard outbound
    cat > "$output_file" << EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${WARP_PRIVATE_KEY}",
    "address": [
      "${WARP_ADDRESS_V4}/32",
      "${WARP_ADDRESS_V6}/128"
    ],
    "peers": [
      {
        "publicKey": "${WARP_PUBLIC_KEY}",
        "allowedIPs": ["0.0.0.0/0", "::/0"],
        "endpoint": "${endpoint}"
      }
    ],
    "reserved": [0, 0, 0],
    "mtu": 1280,
    "workers": 2
  }
}
EOF
    
    chmod 0644 "$output_file"
    register_file "$output_file"
    
    # Validate JSON
    if ! jq -e '.' "$output_file" &>/dev/null; then
        log_error "Generated WARP outbound is invalid JSON"
        return 1
    fi
    
    log_success "WARP outbound configuration saved to: ${output_file}"
}

# Generate WARP routing rules for specific domains
generate_warp_routing_rules() {
    local output_file="${1:-${WARP_DIR}/warp_routing.json}"
    
    log_info "Generating WARP routing rules..."
    
    cat > "$output_file" << 'EOF'
{
  "rules": [
    {
      "type": "field",
      "domain": [
        "geosite:openai",
        "geosite:netflix",
        "geosite:disney",
        "geosite:spotify",
        "geosite:bing"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:openai.com",
        "domain:ai.com",
        "domain:chatgpt.com",
        "domain:chat.openai.com",
        "domain:api.openai.com",
        "domain:platform.openai.com",
        "domain:auth0.openai.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:claude.ai",
        "domain:anthropic.com",
        "domain:api.anthropic.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:bard.google.com",
        "domain:gemini.google.com",
        "domain:generativelanguage.googleapis.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:perplexity.ai",
        "domain:poe.com",
        "domain:character.ai",
        "domain:beta.character.ai"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:netflix.com",
        "domain:netflix.net",
        "domain:nflxvideo.net",
        "domain:nflxso.net",
        "domain:nflximg.net"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:disneyplus.com",
        "domain:disney-plus.net",
        "domain:dssott.com",
        "domain:bamgrid.com",
        "domain:hulu.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:spotify.com",
        "domain:scdn.co",
        "domain:spotifycdn.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:hbomax.com",
        "domain:max.com",
        "domain:hbo.com"
      ],
      "outboundTag": "warp-out"
    }
  ]
}
EOF

    chmod 0644 "$output_file"
    register_file "$output_file"
    
    log_success "WARP routing rules saved"
}

# -----------------------------------------------------------------------------
# CONNECTION TESTING
# -----------------------------------------------------------------------------

# Test WARP endpoint connectivity
test_warp_endpoint() {
    local endpoint="$1"
    local timeout="${2:-5}"
    
    local host="${endpoint%:*}"
    local port="${endpoint#*:}"
    
    log_debug "Testing WARP endpoint: ${endpoint}"
    
    if nc -z -w"$timeout" "$host" "$port" 2>/dev/null; then
        log_debug "Endpoint ${endpoint} is reachable"
        return 0
    else
        log_debug "Endpoint ${endpoint} is not reachable"
        return 1
    fi
}

# Find best WARP endpoint
find_best_warp_endpoint() {
    log_info "Finding best WARP endpoint..."
    
    local best_endpoint=""
    local best_latency=999999
    
    for endpoint in "${WARP_ENDPOINTS[@]}"; do
        local host="${endpoint%:*}"
        local port="${endpoint#*:}"
        
        # Skip IPv6 if not supported
        if [[ "$host" == "["* ]] && ! ip -6 route get 2606:4700:: &>/dev/null; then
            continue
        fi
        
        # Measure latency
        local start_time
        local end_time
        local latency
        
        start_time=$(date +%s%N)
        
        if nc -z -w3 "$host" "$port" 2>/dev/null; then
            end_time=$(date +%s%N)
            latency=$(( (end_time - start_time) / 1000000 ))  # Convert to ms
            
            log_debug "Endpoint ${endpoint}: ${latency}ms"
            
            if [[ $latency -lt $best_latency ]]; then
                best_latency=$latency
                best_endpoint="$endpoint"
            fi
        fi
    done
    
    if [[ -n "$best_endpoint" ]]; then
        log_success "Best endpoint: ${best_endpoint} (${best_latency}ms)"
        echo "$best_endpoint"
        return 0
    else
        log_warn "No reachable WARP endpoints found, using default"
        echo "engage.cloudflareclient.com:2408"
        return 1
    fi
}

# Test WARP connection through Xray
test_warp_connection() {
    log_info "Testing WARP connection..."
    
    # This would require Xray to be running with WARP configured
    # For now, just verify the configuration
    
    if [[ ! -f "$WARP_XRAY_OUTBOUND" ]]; then
        log_error "WARP outbound configuration not found"
        return 1
    fi
    
    # Validate JSON
    if ! jq -e '.' "$WARP_XRAY_OUTBOUND" &>/dev/null; then
        log_error "WARP outbound configuration is invalid"
        return 1
    fi
    
    # Check required fields
    local protocol
    protocol=$(jq -r '.protocol // empty' "$WARP_XRAY_OUTBOUND")
    
    if [[ "$protocol" != "wireguard" ]]; then
        log_error "Invalid protocol in WARP outbound: ${protocol}"
        return 1
    fi
    
    local secret_key
    secret_key=$(jq -r '.settings.secretKey // empty' "$WARP_XRAY_OUTBOUND")
    
    if [[ -z "$secret_key" ]]; then
        log_error "Missing secretKey in WARP outbound"
        return 1
    fi
    
    log_success "WARP configuration validated"
    return 0
}

# -----------------------------------------------------------------------------
# STATUS AND INFORMATION
# -----------------------------------------------------------------------------

# Show WARP status
show_warp_status() {
    log_step "WARP Status"
    
    echo ""
    echo "Configuration Directory: ${WARP_DIR}"
    echo ""
    
    # Check WGCF
    if is_wgcf_installed; then
        echo "WGCF Binary: Installed (v$(get_wgcf_version))"
    else
        echo "WGCF Binary: Not installed"
    fi
    
    # Check account
    if [[ -f "$WARP_ACCOUNT_FILE" ]]; then
        echo "WARP Account: Registered"
        
        # Check for WARP+ status
        if grep -q "license_key" "$WARP_ACCOUNT_FILE" 2>/dev/null; then
            echo "Account Type: WARP+"
        else
            echo "Account Type: Free"
        fi
    else
        echo "WARP Account: Not registered"
    fi
    
    # Check profile
    if [[ -f "$WARP_PROFILE_FILE" ]]; then
        echo "WireGuard Profile: Generated"
    else
        echo "WireGuard Profile: Not generated"
    fi
    
    # Check Xray outbound
    if [[ -f "$WARP_XRAY_OUTBOUND" ]]; then
        echo "Xray Outbound: Configured"
        
        if jq -e '.' "$WARP_XRAY_OUTBOUND" &>/dev/null; then
            local endpoint
            endpoint=$(jq -r '.settings.peers[0].endpoint // "unknown"' "$WARP_XRAY_OUTBOUND")
            echo "WARP Endpoint: ${endpoint}"
        fi
    else
        echo "Xray Outbound: Not configured"
    fi
    
    echo ""
}

# Get WARP outbound file path
get_warp_outbound_path() {
    if [[ -f "$WARP_XRAY_OUTBOUND" ]]; then
        echo "$WARP_XRAY_OUTBOUND"
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# MAIN SETUP FUNCTION
# -----------------------------------------------------------------------------

# Complete WARP setup
setup_warp() {
    local license_key="${1:-}"
    
    log_step "Setting up Cloudflare WARP"
    
    # Install WGCF
    if ! install_wgcf; then
        log_error "Failed to install WGCF"
        return 1
    fi
    
    # Register account
    if ! register_warp_account; then
        log_error "Failed to register WARP account"
        return 1
    fi
    
    # Apply WARP+ license if provided
    if [[ -n "$license_key" ]]; then
        apply_warp_plus_license "$license_key" || true
    fi
    
    # Generate profile
    if ! generate_warp_profile; then
        log_error "Failed to generate WARP profile"
        return 1
    fi
    
    # Parse profile
    if ! parse_warp_profile; then
        log_error "Failed to parse WARP profile"
        return 1
    fi
    
    # Find best endpoint
    local best_endpoint
    best_endpoint=$(find_best_warp_endpoint)
    export WARP_ENDPOINT="$best_endpoint"
    
    # Generate Xray outbound
    if ! generate_xray_warp_outbound; then
        log_error "Failed to generate Xray WARP outbound"
        return 1
    fi
    
    # Generate routing rules
    generate_warp_routing_rules
    
    # Test configuration
    test_warp_connection
    
    # Show status
    show_warp_status
    
    log_success "WARP setup completed"
    
    # Return outbound path for integration
    echo "WARP_OUTBOUND_FILE=${WARP_XRAY_OUTBOUND}"
}

# Export function marker
WARP_MODULE_LOADED=true
