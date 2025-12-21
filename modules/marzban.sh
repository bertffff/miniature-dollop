#!/bin/bash
#
# Module: marzban.sh
# Purpose: Marzban panel setup, Docker Compose configuration
# Dependencies: core.sh, docker.sh
#

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

if [[ -z "${MARZBAN_REPO:-}" ]]; then
    readonly MARZBAN_REPO="https://github.com/Gozargah/Marzban"
fi

if [[ -z "${MARZBAN_DATA:-}" ]]; then
    readonly MARZBAN_DATA="/var/lib/marzban"
fi

if [[ -z "${MARZBAN_ENV:-}" ]]; then
    readonly MARZBAN_ENV="${MARZBAN_DIR}/.env"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# MARZBAN INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

is_marzban_installed() {
    [[ -d "${MARZBAN_DIR}" ]] && [[ -f "${MARZBAN_DIR}/docker-compose.yml" ]]
}

is_marzban_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^marzban$"
}

download_marzban() {
    set_phase "Marzban Download"
    
    if is_marzban_installed; then
        log_info "Marzban already installed at ${MARZBAN_DIR}"
        
        if ask_yes_no "Update to latest version?" "n"; then
            log_info "Updating Marzban..."
            cd "${MARZBAN_DIR}"
            git pull origin master 2>/dev/null || true
        fi
        return 0
    fi
    
    log_info "Downloading Marzban..."
    
    # Create directories
    mkdir -p "${MARZBAN_DIR}"
    mkdir -p "${MARZBAN_DATA}"
    mkdir -p "${MARZBAN_DATA}/certs"
    
    register_rollback "rm -rf ${MARZBAN_DIR}" "normal"
    register_rollback "rm -rf ${MARZBAN_DATA}" "cleanup"
    
    # Clone repository
    git clone "${MARZBAN_REPO}" "${MARZBAN_DIR}"
    
    log_success "Marzban downloaded to ${MARZBAN_DIR}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER COMPOSE CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_docker_compose() {
    set_phase "Docker Compose Configuration"
    
    log_info "Generating docker-compose.yml..."
    
    local compose_file="${MARZBAN_DIR}/docker-compose.yml"
    
    # Base configuration
    cat > "${compose_file}" << 'EOF'
services:
  marzban:
    image: gozargah/marzban:latest
    container_name: marzban
    restart: unless-stopped
    network_mode: host
    env_file: .env
    volumes:
      - /var/lib/marzban:/var/lib/marzban
EOF
    
    # Add MariaDB dependency if enabled
    if [[ "${DATABASE_TYPE:-sqlite}" == "mariadb" ]]; then
        cat >> "${compose_file}" << 'EOF'
    depends_on:
      mariadb:
        condition: service_healthy
EOF
    fi
    
    # Add healthcheck
    cat >> "${compose_file}" << 'EOF'
    healthcheck:
      test: ["CMD", "curl", "-s", "http://127.0.0.1:8000/api/admin"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF
    
    # Add MariaDB service if enabled
    if [[ "${DATABASE_TYPE:-sqlite}" == "mariadb" ]]; then
        cat >> "${compose_file}" << EOF

  mariadb:
    image: mariadb:10.11
    container_name: marzban-db
    restart: unless-stopped
    environment:
      - MARIADB_ROOT_PASSWORD=\${MARIADB_ROOT_PASSWORD}
      - MARIADB_DATABASE=\${MARIADB_DATABASE:-marzban}
      - MARIADB_USER=\${MARIADB_USER:-marzban}
      - MARIADB_PASSWORD=\${MARIADB_PASSWORD}
    volumes:
      - /var/lib/marzban/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF
    fi
    
    # Add AdGuard service if enabled
    if [[ "${ADGUARD_ENABLED:-false}" == "true" ]]; then
        cat >> "${compose_file}" << 'EOF'

  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/lib/adguard/work:/opt/adguardhome/work
      - /var/lib/adguard/conf:/opt/adguardhome/conf
EOF
    fi
    
    log_success "docker-compose.yml generated"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_marzban_env() {
    set_phase "Marzban Environment Configuration"
    
    log_info "Generating Marzban environment file..."
    
    # Generate admin password if not set
    local admin_password="${ADMIN_PASSWORD:-}"
    if [[ -z "${admin_password}" ]] || [[ "${admin_password}" == "auto" ]]; then
        admin_password=$(generate_password 16)
        export ADMIN_PASSWORD="${admin_password}"
    fi
    
    # Generate secret key
    local secret_key
    secret_key=$(generate_random_string 32)
    
    # Start building env file
    cat > "${MARZBAN_ENV}" << EOF
# Marzban Configuration
# Generated by Marzban Ultimate Installer
# Date: $(date -Iseconds)

# Dashboard
UVICORN_HOST=0.0.0.0
UVICORN_PORT=${MARZBAN_PORT:-8000}

# Admin credentials
SUDO_USERNAME=${ADMIN_USERNAME:-admin}
SUDO_PASSWORD=${admin_password}

# Security
SECRET_KEY=${secret_key}

# Subscription
XRAY_SUBSCRIPTION_URL_PREFIX=https://${PANEL_DOMAIN:-localhost}

# Logging
DEBUG=false
DOCS=false
EOF
    
    # Add database configuration
    if [[ "${DATABASE_TYPE:-sqlite}" == "mariadb" ]]; then
        local db_password="${MARIADB_PASSWORD:-$(generate_password 16)}"
        export MARIADB_PASSWORD="${db_password}"
        
        cat >> "${MARZBAN_ENV}" << EOF

# Database (MariaDB)
SQLALCHEMY_DATABASE_URL=mysql+pymysql://marzban:${db_password}@127.0.0.1/marzban

# MariaDB credentials
MARIADB_ROOT_PASSWORD=${db_password}
MARIADB_DATABASE=marzban
MARIADB_USER=marzban
MARIADB_PASSWORD=${db_password}
EOF
    else
        cat >> "${MARZBAN_ENV}" << 'EOF'

# Database (SQLite)
SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/marzban/db.sqlite3
EOF
    fi
    
    # Add Xray settings
    cat >> "${MARZBAN_ENV}" << EOF

# Xray Configuration
XRAY_JSON=/var/lib/marzban/xray_config.json
XRAY_EXECUTABLE_PATH=/usr/local/bin/xray
XRAY_ASSETS_PATH=/usr/local/share/xray

# Custom config (API-driven, minimal base)
CUSTOM_TEMPLATES_DIRECTORY=/var/lib/marzban/templates/
EOF
    
    # Add DNS settings if AdGuard is enabled
    if [[ "${ADGUARD_ENABLED:-false}" == "true" ]]; then
        cat >> "${MARZBAN_ENV}" << 'EOF'

# DNS (AdGuard)
XRAY_DNS_SERVERS=127.0.0.1
EOF
    fi
    
    # Secure the file
    chmod 600 "${MARZBAN_ENV}"
    
    log_success "Environment file generated"
    
    # Save credentials for display later
    echo "ADMIN_USERNAME=${ADMIN_USERNAME:-admin}" > "${DATA_DIR}/credentials.env"
    echo "ADMIN_PASSWORD=${admin_password}" >> "${DATA_DIR}/credentials.env"
    chmod 600 "${DATA_DIR}/credentials.env"
}

# ═══════════════════════════════════════════════════════════════════════════════
# XRAY BASE CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_xray_base_config() {
    set_phase "Xray Base Configuration"
    
    log_info "Generating minimal Xray base configuration..."
    
    local config_file="${MARZBAN_DATA}/xray_config.json"
    
    cat > "${config_file}" << 'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/lib/marzban/access.log",
    "error": "/var/lib/marzban/error.log"
  },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "LoggerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api-inbound",
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["api-inbound"],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
    
    # Validate JSON
    if ! validate_json "${config_file}"; then
        log_error "Generated Xray config is invalid"
        return 1
    fi
    
    log_success "Xray base configuration generated"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MARZBAN CONTROL
# ═══════════════════════════════════════════════════════════════════════════════

start_marzban() {
    set_phase "Starting Marzban"
    
    # Проверка наличия Docker
    if ! command -v docker &> /dev/null; then
        log_warn "Docker not found. Attempting to reinstall..."
        if [[ -f "${SCRIPT_DIR}/docker.sh" ]]; then
            source "${SCRIPT_DIR}/docker.sh"
            install_docker
            configure_docker_daemon
        else
            log_error "Docker is missing and cannot be restored automatically."
            return 1
        fi
    fi

    log_info "Starting Marzban services..."
    
    cd "${MARZBAN_DIR}"
    
    # Pull latest images
    docker compose pull
    
    # Start services
    docker compose up -d
    
    # Wait for service to be ready
    log_info "Waiting for Marzban to start..."
    
    local max_wait=60
    local waited=0
    
    local api_ready=false
    while [[ ${waited} -lt ${max_wait} ]]; do
        if is_marzban_running; then
            # Check if API is responding (allow 200 OK or 401 Unauthorized)
            local status_code
            status_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${MARZBAN_PORT:-8000}/api/admin" || echo "000")
            
            if [[ "$status_code" == "200" ]] || [[ "$status_code" == "401" ]]; then
                api_ready=true
                break
            fi
        fi
        sleep 2
        ((waited+=2))
        printf "\r  Waiting... %ds / %ds" "${waited}" "${max_wait}"
    done
    
    echo
    
    if [[ "${api_ready}" == "true" ]]; then
        log_success "Marzban started successfully"
    else
        log_error "Marzban failed to start (API check timeout)"
        log_info "Checking logs..."
        docker compose logs --tail=20
        return 1
    fi
}

stop_marzban() {
    log_info "Stopping Marzban services..."
    
    if [[ -d "${MARZBAN_DIR}" ]]; then
        cd "${MARZBAN_DIR}"
        docker compose down
    fi
    
    log_success "Marzban stopped"
}

restart_marzban() {
    log_info "Restarting Marzban services..."
    
    cd "${MARZBAN_DIR}"
    docker compose restart
    
    log_success "Marzban restarted"
}

show_marzban_logs() {
    cd "${MARZBAN_DIR}"
    docker compose logs -f --tail=100
}

# ═══════════════════════════════════════════════════════════════════════════════
# MARZBAN CLI WRAPPER
# ═══════════════════════════════════════════════════════════════════════════════

create_marzban_cli() {
    log_info "Creating marzban CLI command..."
    
    cat > /usr/local/bin/marzban << 'EOF'
#!/bin/bash
# Marzban management CLI
# Generated by Marzban Ultimate Installer

MARZBAN_DIR="/opt/marzban"

cd "${MARZBAN_DIR}" || exit 1

case "${1:-}" in
    start)
        docker compose up -d
        ;;
    stop)
        docker compose down
        ;;
    restart)
        docker compose restart
        ;;
    status)
        docker compose ps
        ;;
    logs)
        docker compose logs -f --tail=${2:-100}
        ;;
    update)
        docker compose pull
        docker compose up -d
        ;;
    shell)
        docker compose exec marzban bash
        ;;
    *)
        echo "Usage: marzban {start|stop|restart|status|logs|update|shell}"
        exit 1
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/marzban
    
    log_success "CLI created: /usr/local/bin/marzban"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

setup_marzban() {
    download_marzban
    generate_docker_compose
    generate_marzban_env
    generate_xray_base_config
    start_marzban
    create_marzban_cli
    
    log_success "Marzban setup completed"
}

# Export functions
export -f setup_marzban
export -f start_marzban
export -f stop_marzban
export -f restart_marzban
export -f is_marzban_running
export -f show_marzban_logs
