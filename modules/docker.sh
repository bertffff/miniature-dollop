#!/bin/bash
# =============================================================================
# Module: docker.sh
# Description: Docker Engine & Docker Compose installation and configuration
# =============================================================================

set -euo pipefail

# Source core module if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

# =============================================================================
# VERSION REQUIREMENTS
# =============================================================================
readonly DOCKER_MIN_VERSION="20.10.0"
readonly COMPOSE_MIN_VERSION="2.0.0"

# =============================================================================
# VERSION COMPARISON
# =============================================================================
version_compare() {
    # Returns 0 if $1 >= $2, 1 otherwise
    local v1="$1"
    local v2="$2"
    
    if [[ "${v1}" == "${v2}" ]]; then
        return 0
    fi
    
    local IFS=.
    local i
    local ver1=($v1)
    local ver2=($v2)
    
    # Fill empty positions with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]:-} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 0
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 1
        fi
    done
    
    return 0
}

# =============================================================================
# DOCKER VERSION CHECK
# =============================================================================
get_docker_version() {
    if command -v docker &>/dev/null; then
        docker version --format '{{.Server.Version}}' 2>/dev/null | sed 's/[^0-9.]//g' || echo "0.0.0"
    else
        echo "0.0.0"
    fi
}

get_compose_version() {
    if docker compose version &>/dev/null; then
        docker compose version --short 2>/dev/null | sed 's/[^0-9.]//g' || echo "0.0.0"
    elif command -v docker-compose &>/dev/null; then
        docker-compose version --short 2>/dev/null | sed 's/[^0-9.]//g' || echo "0.0.0"
    else
        echo "0.0.0"
    fi
}

check_docker_installed() {
    local docker_ver
    docker_ver=$(get_docker_version)
    
    if [[ "${docker_ver}" == "0.0.0" ]]; then
        return 1
    fi
    
    if version_compare "${docker_ver}" "${DOCKER_MIN_VERSION}"; then
        log_success "Docker version: ${docker_ver} (meets minimum ${DOCKER_MIN_VERSION})"
        return 0
    else
        log_warn "Docker version ${docker_ver} is below minimum ${DOCKER_MIN_VERSION}"
        return 1
    fi
}

check_compose_installed() {
    local compose_ver
    compose_ver=$(get_compose_version)
    
    if [[ "${compose_ver}" == "0.0.0" ]]; then
        return 1
    fi
    
    if version_compare "${compose_ver}" "${COMPOSE_MIN_VERSION}"; then
        log_success "Docker Compose version: ${compose_ver} (meets minimum ${COMPOSE_MIN_VERSION})"
        return 0
    else
        log_warn "Docker Compose version ${compose_ver} is below minimum ${COMPOSE_MIN_VERSION}"
        return 1
    fi
}

# =============================================================================
# REMOVE OLD DOCKER VERSIONS
# =============================================================================
remove_old_docker() {
    log_info "Removing old Docker versions..."
    
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
        if is_package_installed "${pkg}"; then
            apt-get remove -y "${pkg}" 2>/dev/null || true
        fi
    done
    
    # Clean up
    apt-get autoremove -y 2>/dev/null || true
    
    log_success "Old Docker packages removed"
}

# =============================================================================
# INSTALL DOCKER
# =============================================================================
install_docker() {
    log_step "Installing Docker Engine"
    
    # Check if already installed and meets requirements
    if check_docker_installed && check_compose_installed; then
        log_info "Docker is already installed and meets requirements"
        
        if ! confirm "Reinstall Docker anyway?" "n"; then
            return 0
        fi
    fi
    
    # Remove old versions
    remove_old_docker
    
    # Install prerequisites
    install_packages ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    
    local docker_gpg="/etc/apt/keyrings/docker.gpg"
    rm -f "${docker_gpg}"
    
    curl -fsSL https://download.docker.com/linux/${OS_NAME}/gpg | gpg --dearmor -o "${docker_gpg}"
    chmod a+r "${docker_gpg}"
    
    # Add Docker repository
    local arch
    arch=$(dpkg --print-architecture)
    local codename
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")
    
    # Fallback for codename
    if [[ -z "${codename}" ]]; then
        codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
    fi
    
    cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=${arch} signed-by=${docker_gpg}] https://download.docker.com/linux/${OS_NAME} ${codename} stable
EOF

    # Update package cache
    update_package_cache
    
    # Install Docker Engine
    install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    register_rollback "apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    
    # Verify installation
    if ! check_docker_installed; then
        log_error "Docker installation failed"
        return 1
    fi
    
    if ! check_compose_installed; then
        log_error "Docker Compose installation failed"
        return 1
    fi
    
    log_success "Docker Engine installed successfully"
}

# =============================================================================
# CONFIGURE DOCKER
# =============================================================================
configure_docker() {
    log_step "Configuring Docker"
    
    # Create docker config directory
    mkdir -p /etc/docker
    
    # Docker daemon configuration
    local daemon_config="/etc/docker/daemon.json"
    backup_file "${daemon_config}"
    
    cat > "${daemon_config}" << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true,
    "userland-proxy": false,
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 1048576,
            "Soft": 1048576
        }
    },
    "default-address-pools": [
        {
            "base": "172.17.0.0/12",
            "size": 24
        }
    ]
}
EOF

    # Validate JSON
    if ! validate_json "${daemon_config}"; then
        log_error "Invalid Docker daemon configuration"
        return 1
    fi
    
    register_rollback "rm -f ${daemon_config}"
    
    log_success "Docker daemon configured"
}

# =============================================================================
# START DOCKER SERVICE
# =============================================================================
start_docker() {
    log_step "Starting Docker Service"
    
    # Enable and start Docker
    systemctl enable docker
    systemctl start docker
    
    # Wait for Docker to be ready
    local max_wait=30
    local count=0
    
    while ! docker info &>/dev/null; do
        sleep 1
        ((count++))
        if [[ ${count} -ge ${max_wait} ]]; then
            log_error "Docker failed to start within ${max_wait} seconds"
            systemctl status docker
            return 1
        fi
    done
    
    # Enable containerd
    systemctl enable containerd 2>/dev/null || true
    
    log_success "Docker is running"
    
    # Show Docker info
    log_info "Docker Info:"
    docker info 2>/dev/null | grep -E "(Server Version|Storage Driver|Logging Driver|Operating System|Total Memory)" | head -10
}

# =============================================================================
# DOCKER HEALTH CHECK
# =============================================================================
docker_health_check() {
    log_step "Docker Health Check"
    
    # Check Docker daemon
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running"
        return 1
    fi
    
    # Test Docker with hello-world
    log_info "Running Docker test..."
    if docker run --rm hello-world &>/dev/null; then
        log_success "Docker is working correctly"
    else
        log_warn "Docker test failed, but daemon is running"
    fi
    
    # Check Docker Compose
    if docker compose version &>/dev/null; then
        log_success "Docker Compose (plugin) is available"
    elif command -v docker-compose &>/dev/null; then
        log_success "Docker Compose (standalone) is available"
    else
        log_error "Docker Compose is not available"
        return 1
    fi
    
    return 0
}

# =============================================================================
# DOCKER NETWORK SETUP
# =============================================================================
setup_docker_network() {
    local network_name="${1:-marzban-network}"
    
    log_info "Setting up Docker network: ${network_name}"
    
    # Check if network exists
    if docker network inspect "${network_name}" &>/dev/null; then
        log_info "Docker network '${network_name}' already exists"
        return 0
    fi
    
    # Create network
    docker network create \
        --driver bridge \
        --subnet=172.20.0.0/16 \
        --gateway=172.20.0.1 \
        "${network_name}"
    
    register_rollback "docker network rm ${network_name} 2>/dev/null || true"
    
    log_success "Docker network '${network_name}' created"
}

# =============================================================================
# DOCKER CLEANUP
# =============================================================================
docker_cleanup() {
    log_step "Cleaning up Docker resources"
    
    # Remove unused containers
    docker container prune -f 2>/dev/null || true
    
    # Remove unused images
    docker image prune -f 2>/dev/null || true
    
    # Remove unused volumes
    docker volume prune -f 2>/dev/null || true
    
    # Remove unused networks
    docker network prune -f 2>/dev/null || true
    
    log_success "Docker cleanup completed"
}

# =============================================================================
# DOCKER RESTART
# =============================================================================
restart_docker() {
    log_info "Restarting Docker..."
    
    systemctl restart docker
    
    # Wait for Docker to be ready
    sleep 3
    
    if docker info &>/dev/null; then
        log_success "Docker restarted successfully"
    else
        log_error "Docker failed to restart"
        return 1
    fi
}

# =============================================================================
# PULL DOCKER IMAGE
# =============================================================================
pull_docker_image() {
    local image="$1"
    
    log_info "Pulling Docker image: ${image}"
    
    if docker pull "${image}"; then
        log_success "Image pulled: ${image}"
    else
        log_error "Failed to pull image: ${image}"
        return 1
    fi
}

# =============================================================================
# MAIN DOCKER SETUP
# =============================================================================
setup_docker() {
    log_step "=== DOCKER SETUP ==="
    
    install_docker
    configure_docker
    start_docker
    docker_health_check
    
    log_success "Docker setup completed"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f get_docker_version
export -f get_compose_version
export -f check_docker_installed
export -f check_compose_installed
export -f install_docker
export -f configure_docker
export -f start_docker
export -f docker_health_check
export -f setup_docker_network
export -f docker_cleanup
export -f restart_docker
export -f pull_docker_image
export -f setup_docker
