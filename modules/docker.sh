#!/bin/bash
#
# Module: docker.sh
# Purpose: Docker Engine and Docker Compose installation
# Dependencies: core.sh
#

# Strict mode
set -euo pipefail

# Source core module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/core.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

readonly DOCKER_MIN_VERSION="24.0.0"
readonly COMPOSE_MIN_VERSION="2.20.0"

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

is_docker_installed() {
    command -v docker &> /dev/null
}

is_compose_installed() {
    docker compose version &> /dev/null 2>&1
}

get_docker_version() {
    docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d'-' -f1 || echo "0.0.0"
}

get_compose_version() {
    docker compose version --short 2>/dev/null | tr -d 'v' || echo "0.0.0"
}

version_gte() {
    local version1="$1"
    local version2="$2"
    
    # Compare versions using sort -V
    printf '%s\n%s\n' "${version2}" "${version1}" | sort -V -C
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

remove_old_docker() {
    log_info "Removing old Docker versions if present..."
    
    local old_packages=(
        docker
        docker-engine
        docker.io
        containerd
        runc
        docker-compose
        docker-compose-plugin
    )
    
    for pkg in "${old_packages[@]}"; do
        apt-get remove -y "${pkg}" 2>/dev/null || true
    done
}

install_docker() {
    set_phase "Docker Installation"
    
    # Check if Docker is already installed and meets version requirements
    if is_docker_installed; then
        local current_version
        current_version=$(get_docker_version)
        
        if version_gte "${current_version}" "${DOCKER_MIN_VERSION}"; then
            log_info "Docker ${current_version} already installed ✓"
            
            # Still check compose
            if is_compose_installed; then
                local compose_version
                compose_version=$(get_compose_version)
                log_info "Docker Compose ${compose_version} available ✓"
                return 0
            fi
        else
            log_warn "Docker ${current_version} is outdated, upgrading..."
        fi
    fi
    
    # Remove old versions
    remove_old_docker
    
    # Install prerequisites
    log_info "Installing Docker prerequisites..."
    install_packages \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    log_info "Adding Docker GPG key..."
    mkdir -p /etc/apt/keyrings
    
    local docker_gpg_url="https://download.docker.com/linux/${OS_ID}/gpg"
    curl -fsSL "${docker_gpg_url}" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    register_rollback "rm -f /etc/apt/keyrings/docker.gpg" "normal"
    
    # Add Docker repository
    log_info "Adding Docker repository..."
    local arch
    arch=$(dpkg --print-architecture)
    
    echo \
        "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
        $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    
    register_rollback "rm -f /etc/apt/sources.list.d/docker.list" "normal"
    
    # Update package list
    apt-get update
    
    # Install Docker Engine
    log_info "Installing Docker Engine..."
    install_packages \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    register_rollback "apt-get remove -y docker-ce docker-ce-cli containerd.io" "normal"
    
    # Verify installation
    local installed_version
    installed_version=$(get_docker_version)
    log_info "Docker ${installed_version} installed"
    
    local compose_version
    compose_version=$(get_compose_version)
    log_info "Docker Compose ${compose_version} installed"
    
    log_success "Docker installation completed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

configure_docker_daemon() {
    set_phase "Docker Configuration"
    
    local daemon_config="/etc/docker/daemon.json"
    
    log_info "Configuring Docker daemon..."
    
    # Backup existing config
    backup_file "${daemon_config}"
    
    # Create daemon configuration
    mkdir -p /etc/docker
    
    cat > "${daemon_config}" << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true,
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 65535,
            "Soft": 65535
        }
    },
    "dns": ["1.1.1.1", "8.8.8.8"]
}
EOF
    
    register_rollback "rm -f ${daemon_config}" "normal"
    
    # Restart Docker to apply configuration
    log_info "Restarting Docker daemon..."
    systemctl daemon-reload
    systemctl restart docker
    
    # Enable Docker to start on boot
    systemctl enable docker
    
    log_success "Docker configured"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER HEALTH CHECK
# ═══════════════════════════════════════════════════════════════════════════════

verify_docker() {
    log_info "Verifying Docker installation..."
    
    # Check Docker daemon is running
    if ! systemctl is-active --quiet docker; then
        log_error "Docker daemon is not running"
        return 1
    fi
    
    # Test Docker functionality
    if ! docker run --rm hello-world &> /dev/null; then
        log_error "Docker test container failed to run"
        return 1
    fi
    
    # Clean up test container
    docker rmi hello-world &> /dev/null || true
    
    # Display versions
    log_info "Docker version: $(get_docker_version)"
    log_info "Docker Compose version: $(get_compose_version)"
    
    log_success "Docker is working correctly"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

docker_cleanup() {
    log_info "Cleaning up Docker resources..."
    
    # Remove unused containers
    docker container prune -f 2>/dev/null || true
    
    # Remove unused images
    docker image prune -f 2>/dev/null || true
    
    # Remove unused volumes
    docker volume prune -f 2>/dev/null || true
    
    # Remove unused networks
    docker network prune -f 2>/dev/null || true
    
    log_info "Docker cleanup completed"
}

show_docker_status() {
    echo
    log_info "═══ Docker Status ═══"
    docker version --format 'Docker Engine: {{.Server.Version}}'
    docker compose version
    
    echo
    log_info "Running containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

setup_docker() {
    install_docker
    configure_docker_daemon
    verify_docker
}

# Export functions
export -f setup_docker
export -f install_docker
export -f configure_docker_daemon
export -f verify_docker
export -f docker_cleanup
export -f show_docker_status
export -f is_docker_installed
export -f is_compose_installed
