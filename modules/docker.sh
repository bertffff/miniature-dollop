#!/bin/bash
# =============================================================================
# Module: docker.sh
# Description: Docker Engine & Docker Compose installation
# =============================================================================

set -euo pipefail

if [[ -z "${CORE_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/modules/core.sh"
fi

readonly DOCKER_MIN_VERSION="20.10.0"
readonly COMPOSE_MIN_VERSION="2.0.0"

# =============================================================================
# VERSION COMPARISON
# =============================================================================
version_compare() {
    local v1="$1" v2="$2"
    [[ "${v1}" == "${v2}" ]] && return 0
    
    local IFS=.
    local i ver1=($v1) ver2=($v2)
    
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
    
    for ((i=0; i<${#ver1[@]}; i++)); do
        [[ -z ${ver2[i]:-} ]] && ver2[i]=0
        ((10#${ver1[i]} > 10#${ver2[i]})) && return 0
        ((10#${ver1[i]} < 10#${ver2[i]})) && return 1
    done
    return 0
}

get_docker_version() {
    command -v docker &>/dev/null && docker version --format '{{.Server.Version}}' 2>/dev/null | sed 's/[^0-9.]//g' || echo "0.0.0"
}

get_compose_version() {
    docker compose version &>/dev/null && docker compose version --short 2>/dev/null | sed 's/[^0-9.]//g' || echo "0.0.0"
}

check_docker_installed() {
    local docker_ver=$(get_docker_version)
    [[ "${docker_ver}" == "0.0.0" ]] && return 1
    version_compare "${docker_ver}" "${DOCKER_MIN_VERSION}" && { log_success "Docker: ${docker_ver}"; return 0; }
    log_warn "Docker ${docker_ver} < ${DOCKER_MIN_VERSION}"
    return 1
}

check_compose_installed() {
    local compose_ver=$(get_compose_version)
    [[ "${compose_ver}" == "0.0.0" ]] && return 1
    version_compare "${compose_ver}" "${COMPOSE_MIN_VERSION}" && { log_success "Compose: ${compose_ver}"; return 0; }
    return 1
}

# =============================================================================
# INSTALL DOCKER
# =============================================================================
remove_old_docker() {
    log_info "Removing old Docker versions..."
    local old_pkgs=(docker docker-engine docker.io containerd runc docker-compose docker-compose-plugin)
    for pkg in "${old_pkgs[@]}"; do
        is_package_installed "${pkg}" && apt-get remove -y "${pkg}" 2>/dev/null || true
    done
    apt-get autoremove -y 2>/dev/null || true
}

install_docker() {
    log_step "Installing Docker Engine"
    
    if check_docker_installed && check_compose_installed; then
        log_info "Docker meets requirements"
        confirm "Reinstall anyway?" "n" || return 0
    fi
    
    remove_old_docker
    install_packages ca-certificates curl gnupg lsb-release
    
    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    local docker_gpg="/etc/apt/keyrings/docker.gpg"
    rm -f "${docker_gpg}"
    
    curl -fsSL "https://download.docker.com/linux/${OS_NAME}/gpg" | gpg --dearmor -o "${docker_gpg}"
    chmod a+r "${docker_gpg}"
    
    # Add repository
    local arch=$(dpkg --print-architecture)
    local codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-jammy}}")
    
    cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=${arch} signed-by=${docker_gpg}] https://download.docker.com/linux/${OS_NAME} ${codename} stable
EOF

    update_package_cache
    install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    register_rollback "Remove Docker" "apt-get remove -y docker-ce docker-ce-cli containerd.io" "normal"
    
    check_docker_installed || { log_error "Docker installation failed"; return 1; }
    check_compose_installed || { log_error "Docker Compose installation failed"; return 1; }
    
    log_success "Docker Engine installed"
}

# =============================================================================
# CONFIGURE DOCKER
# =============================================================================
configure_docker() {
    log_step "Configuring Docker"
    
    mkdir -p /etc/docker
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
    }
}
EOF

    validate_json "${daemon_config}" || { log_error "Invalid daemon.json"; return 1; }
    register_rollback "Remove Docker config" "rm -f ${daemon_config}" "cleanup"
    log_success "Docker daemon configured"
}

# =============================================================================
# START DOCKER
# =============================================================================
start_docker() {
    log_step "Starting Docker Service"
    
    systemctl enable docker
    systemctl start docker
    
    local max_wait=30 count=0
    while ! docker info &>/dev/null; do
        sleep 1
        ((count++))
        [[ ${count} -ge ${max_wait} ]] && { log_error "Docker failed to start"; return 1; }
    done
    
    systemctl enable containerd 2>/dev/null || true
    register_service "docker"
    
    log_success "Docker is running"
    docker info 2>/dev/null | grep -E "(Server Version|Storage Driver|Operating System)" | head -5
}

# =============================================================================
# DOCKER HEALTH CHECK
# =============================================================================
docker_health_check() {
    log_step "Docker Health Check"
    
    docker info &>/dev/null || { log_error "Docker daemon not running"; return 1; }
    
    log_info "Running Docker test..."
    docker run --rm hello-world &>/dev/null && log_success "Docker working" || log_warn "Docker test failed"
    
    docker compose version &>/dev/null && log_success "Docker Compose available" || { log_error "Compose not available"; return 1; }
    
    return 0
}

# =============================================================================
# DOCKER NETWORK
# =============================================================================
setup_docker_network() {
    local network_name="${1:-marzban-network}"
    
    log_info "Setting up Docker network: ${network_name}"
    
    docker network inspect "${network_name}" &>/dev/null && { log_info "Network exists"; return 0; }
    
    docker network create --driver bridge --subnet=172.20.0.0/16 --gateway=172.20.0.1 "${network_name}"
    
    register_rollback "Remove Docker network" "docker network rm ${network_name} 2>/dev/null || true" "normal"
    log_success "Network '${network_name}' created"
}

# =============================================================================
# UTILITIES
# =============================================================================
docker_cleanup() {
    log_step "Cleaning Docker resources"
    docker container prune -f 2>/dev/null || true
    docker image prune -f 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
    log_success "Docker cleanup completed"
}

restart_docker() {
    log_info "Restarting Docker..."
    systemctl restart docker
    sleep 3
    docker info &>/dev/null && log_success "Docker restarted" || { log_error "Restart failed"; return 1; }
}

pull_docker_image() {
    local image="$1"
    log_info "Pulling: ${image}"
    docker pull "${image}" && log_success "Pulled: ${image}" || { log_error "Failed: ${image}"; return 1; }
}

# =============================================================================
# MAIN
# =============================================================================
setup_docker() {
    log_step "=== DOCKER SETUP ==="
    install_docker
    configure_docker
    start_docker
    docker_health_check
    log_success "Docker setup completed"
}

export -f get_docker_version get_compose_version check_docker_installed check_compose_installed
export -f install_docker configure_docker start_docker docker_health_check
export -f setup_docker_network docker_cleanup restart_docker pull_docker_image setup_docker
