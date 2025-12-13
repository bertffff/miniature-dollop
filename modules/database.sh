#!/bin/bash
# =============================================================================
# Database Module - SQLite and MariaDB support for Marzban
# =============================================================================
# Handles database selection, configuration, and management
# Supports SQLite (default) and MariaDB (production)
# =============================================================================

# Prevent direct execution
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && echo "This script should be sourced, not executed directly" && exit 1

# =============================================================================
# CONFIGURATION
# =============================================================================

# SQLite settings
SQLITE_DB_PATH="${SQLITE_DB_PATH:-/var/lib/marzban/db.sqlite3}"

# MariaDB settings
MARIADB_VERSION="${MARIADB_VERSION:-10.11}"
MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-}"
MARIADB_DATABASE="${MARIADB_DATABASE:-marzban}"
MARIADB_USER="${MARIADB_USER:-marzban}"
MARIADB_PASSWORD="${MARIADB_PASSWORD:-}"
MARIADB_HOST="${MARIADB_HOST:-127.0.0.1}"
MARIADB_PORT="${MARIADB_PORT:-3306}"

# =============================================================================
# DATABASE TYPE SELECTION
# =============================================================================

# Interactive database selection
select_database_type() {
    log_step "Database Selection"
    
    echo ""
    echo "Choose database backend:"
    echo ""
    echo "  1) SQLite (Recommended for small deployments)"
    echo "     - Zero configuration"
    echo "     - File-based storage"
    echo "     - Good for < 100 users"
    echo ""
    echo "  2) MariaDB (Recommended for production)"
    echo "     - Better performance at scale"
    echo "     - ACID compliant"
    echo "     - Good for 100+ users"
    echo ""
    
    local choice
    read -rp "Select database [1-2, default: 1]: " choice
    choice="${choice:-1}"
    
    case "${choice}" in
        1)
            DATABASE_TYPE="sqlite"
            log_info "Selected: SQLite"
            ;;
        2)
            DATABASE_TYPE="mariadb"
            log_info "Selected: MariaDB"
            ;;
        *)
            log_warn "Invalid choice, defaulting to SQLite"
            DATABASE_TYPE="sqlite"
            ;;
    esac
    
    export DATABASE_TYPE
    return 0
}

# =============================================================================
# SQLITE FUNCTIONS
# =============================================================================

# Setup SQLite database
setup_sqlite() {
    log_step "Setting up SQLite database"
    
    local db_dir
    db_dir=$(dirname "${SQLITE_DB_PATH}")
    
    # Create directory
    mkdir -p "${db_dir}"
    chmod 755 "${db_dir}"
    
    # Generate database URL
    SQLALCHEMY_DATABASE_URL="sqlite:///${SQLITE_DB_PATH}"
    export SQLALCHEMY_DATABASE_URL
    
    log_success "SQLite configured: ${SQLITE_DB_PATH}"
    return 0
}

# Backup SQLite database
backup_sqlite() {
    local backup_path="${1:-}"
    
    if [[ -z "${backup_path}" ]]; then
        backup_path="/var/lib/marzban/backups/db_$(date +%Y%m%d_%H%M%S).sqlite3"
    fi
    
    local backup_dir
    backup_dir=$(dirname "${backup_path}")
    mkdir -p "${backup_dir}"
    
    if [[ -f "${SQLITE_DB_PATH}" ]]; then
        log_step "Backing up SQLite database"
        cp "${SQLITE_DB_PATH}" "${backup_path}"
        chmod 600 "${backup_path}"
        log_success "Database backed up to: ${backup_path}"
        echo "${backup_path}"
        return 0
    else
        log_warn "SQLite database not found at ${SQLITE_DB_PATH}"
        return 1
    fi
}

# Restore SQLite database
restore_sqlite() {
    local backup_path="${1}"
    
    if [[ -z "${backup_path}" ]] || [[ ! -f "${backup_path}" ]]; then
        log_error "Backup file not found: ${backup_path}"
        return 1
    fi
    
    log_step "Restoring SQLite database"
    
    # Backup current database first
    if [[ -f "${SQLITE_DB_PATH}" ]]; then
        backup_sqlite
    fi
    
    cp "${backup_path}" "${SQLITE_DB_PATH}"
    chmod 644 "${SQLITE_DB_PATH}"
    
    log_success "Database restored from: ${backup_path}"
    return 0
}

# =============================================================================
# MARIADB FUNCTIONS
# =============================================================================

# Generate MariaDB Docker Compose service
generate_mariadb_compose_service() {
    local root_password="${1:-${MARIADB_ROOT_PASSWORD}}"
    local database="${2:-${MARIADB_DATABASE}}"
    local user="${3:-${MARIADB_USER}}"
    local password="${4:-${MARIADB_PASSWORD}}"
    
    cat << EOF
  mariadb:
    image: mariadb:${MARIADB_VERSION}
    container_name: marzban-mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${root_password}
      MYSQL_DATABASE: ${database}
      MYSQL_USER: ${user}
      MYSQL_PASSWORD: ${password}
    volumes:
      - /var/lib/marzban/mysql:/var/lib/mysql
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --innodb-buffer-pool-size=256M
      - --innodb-log-file-size=64M
      - --max-connections=100
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
}

# Setup MariaDB database
setup_mariadb() {
    log_step "Setting up MariaDB database"
    
    # Generate passwords if not set
    if [[ -z "${MARIADB_ROOT_PASSWORD}" ]]; then
        MARIADB_ROOT_PASSWORD=$(generate_password 24)
        log_info "Generated MariaDB root password"
    fi
    
    if [[ -z "${MARIADB_PASSWORD}" ]]; then
        MARIADB_PASSWORD=$(generate_password 20)
        log_info "Generated MariaDB user password"
    fi
    
    # Create data directory
    mkdir -p /var/lib/marzban/mysql
    chmod 755 /var/lib/marzban/mysql
    
    # Generate database URL
    SQLALCHEMY_DATABASE_URL="mysql+pymysql://${MARIADB_USER}:${MARIADB_PASSWORD}@${MARIADB_HOST}:${MARIADB_PORT}/${MARIADB_DATABASE}"
    export SQLALCHEMY_DATABASE_URL
    
    # Export for compose generation
    export MARIADB_ROOT_PASSWORD
    export MARIADB_DATABASE
    export MARIADB_USER
    export MARIADB_PASSWORD
    
    # Save credentials
    local creds_file="${INSTALLER_DATA_DIR:-/home/claude/marzban-installer/data}/mariadb_credentials.env"
    cat > "${creds_file}" << EOF
# MariaDB Credentials
# Generated: $(date -Iseconds)
# WARNING: Keep this file secure!

MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
MARIADB_DATABASE=${MARIADB_DATABASE}
MARIADB_USER=${MARIADB_USER}
MARIADB_PASSWORD=${MARIADB_PASSWORD}
MARIADB_HOST=${MARIADB_HOST}
MARIADB_PORT=${MARIADB_PORT}

# SQLAlchemy URL
SQLALCHEMY_DATABASE_URL=${SQLALCHEMY_DATABASE_URL}
EOF
    chmod 600 "${creds_file}"
    
    log_success "MariaDB configured"
    log_info "Database: ${MARIADB_DATABASE}"
    log_info "User: ${MARIADB_USER}"
    
    return 0
}

# Wait for MariaDB to be ready
wait_for_mariadb() {
    local max_attempts="${1:-30}"
    local host="${MARIADB_HOST:-127.0.0.1}"
    local port="${MARIADB_PORT:-3306}"
    
    log_step "Waiting for MariaDB to be ready"
    
    local attempt=0
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if docker exec marzban-mariadb healthcheck.sh --connect 2>/dev/null; then
            log_success "MariaDB is ready"
            return 0
        fi
        
        # Alternative: check with mysqladmin
        if docker exec marzban-mariadb mysqladmin ping -h localhost -u root -p"${MARIADB_ROOT_PASSWORD}" 2>/dev/null | grep -q "alive"; then
            log_success "MariaDB is ready"
            return 0
        fi
        
        ((attempt++))
        log_debug "Waiting for MariaDB... (${attempt}/${max_attempts})"
        sleep 2
    done
    
    log_error "MariaDB did not become ready in time"
    return 1
}

# Backup MariaDB database
backup_mariadb() {
    local backup_path="${1:-}"
    
    if [[ -z "${backup_path}" ]]; then
        backup_path="/var/lib/marzban/backups/db_$(date +%Y%m%d_%H%M%S).sql"
    fi
    
    local backup_dir
    backup_dir=$(dirname "${backup_path}")
    mkdir -p "${backup_dir}"
    
    log_step "Backing up MariaDB database"
    
    if docker exec marzban-mariadb mysqldump \
        -u root \
        -p"${MARIADB_ROOT_PASSWORD}" \
        --single-transaction \
        --routines \
        --triggers \
        "${MARIADB_DATABASE}" > "${backup_path}" 2>/dev/null; then
        
        chmod 600 "${backup_path}"
        
        # Compress backup
        if gzip "${backup_path}" 2>/dev/null; then
            backup_path="${backup_path}.gz"
        fi
        
        log_success "Database backed up to: ${backup_path}"
        echo "${backup_path}"
        return 0
    else
        log_error "Failed to backup MariaDB database"
        return 1
    fi
}

# Restore MariaDB database
restore_mariadb() {
    local backup_path="${1}"
    
    if [[ -z "${backup_path}" ]] || [[ ! -f "${backup_path}" ]]; then
        log_error "Backup file not found: ${backup_path}"
        return 1
    fi
    
    log_step "Restoring MariaDB database"
    
    # Backup current database first
    backup_mariadb
    
    # Determine if compressed
    local cat_cmd="cat"
    if [[ "${backup_path}" == *.gz ]]; then
        cat_cmd="zcat"
    fi
    
    if ${cat_cmd} "${backup_path}" | docker exec -i marzban-mariadb mysql \
        -u root \
        -p"${MARIADB_ROOT_PASSWORD}" \
        "${MARIADB_DATABASE}" 2>/dev/null; then
        
        log_success "Database restored from: ${backup_path}"
        return 0
    else
        log_error "Failed to restore MariaDB database"
        return 1
    fi
}

# Get MariaDB status
get_mariadb_status() {
    echo "=== MariaDB Status ==="
    
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "marzban-mariadb"; then
        echo "Container: Running"
        docker ps --filter "name=marzban-mariadb" --format "table {{.Status}}\t{{.Ports}}"
        
        echo ""
        echo "Database Info:"
        docker exec marzban-mariadb mysql \
            -u root \
            -p"${MARIADB_ROOT_PASSWORD}" \
            -e "SELECT VERSION();" 2>/dev/null | tail -1
        
        echo ""
        echo "Database Size:"
        docker exec marzban-mariadb mysql \
            -u root \
            -p"${MARIADB_ROOT_PASSWORD}" \
            -e "SELECT table_schema AS 'Database', 
                ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)' 
                FROM information_schema.tables 
                WHERE table_schema = '${MARIADB_DATABASE}' 
                GROUP BY table_schema;" 2>/dev/null
    else
        echo "Container: Not running"
    fi
}

# =============================================================================
# UNIFIED FUNCTIONS
# =============================================================================

# Setup database based on type
setup_database() {
    local db_type="${1:-${DATABASE_TYPE:-sqlite}}"
    
    case "${db_type}" in
        sqlite)
            setup_sqlite
            ;;
        mariadb|mysql)
            setup_mariadb
            ;;
        *)
            log_error "Unknown database type: ${db_type}"
            return 1
            ;;
    esac
}

# Backup database based on type
backup_database() {
    local db_type="${1:-${DATABASE_TYPE:-sqlite}}"
    local backup_path="${2:-}"
    
    case "${db_type}" in
        sqlite)
            backup_sqlite "${backup_path}"
            ;;
        mariadb|mysql)
            backup_mariadb "${backup_path}"
            ;;
        *)
            log_error "Unknown database type: ${db_type}"
            return 1
            ;;
    esac
}

# Restore database based on type
restore_database() {
    local db_type="${1:-${DATABASE_TYPE:-sqlite}}"
    local backup_path="${2}"
    
    case "${db_type}" in
        sqlite)
            restore_sqlite "${backup_path}"
            ;;
        mariadb|mysql)
            restore_mariadb "${backup_path}"
            ;;
        *)
            log_error "Unknown database type: ${db_type}"
            return 1
            ;;
    esac
}

# Get database status
get_database_status() {
    local db_type="${1:-${DATABASE_TYPE:-sqlite}}"
    
    case "${db_type}" in
        sqlite)
            echo "=== SQLite Database Status ==="
            if [[ -f "${SQLITE_DB_PATH}" ]]; then
                echo "Database: ${SQLITE_DB_PATH}"
                echo "Size: $(du -h "${SQLITE_DB_PATH}" 2>/dev/null | cut -f1)"
                echo "Modified: $(stat -c %y "${SQLITE_DB_PATH}" 2>/dev/null)"
            else
                echo "Database: Not found"
            fi
            ;;
        mariadb|mysql)
            get_mariadb_status
            ;;
        *)
            echo "Unknown database type: ${db_type}"
            ;;
    esac
}

# Generate database URL
get_database_url() {
    local db_type="${1:-${DATABASE_TYPE:-sqlite}}"
    
    case "${db_type}" in
        sqlite)
            echo "sqlite:///${SQLITE_DB_PATH}"
            ;;
        mariadb|mysql)
            echo "mysql+pymysql://${MARIADB_USER}:${MARIADB_PASSWORD}@${MARIADB_HOST}:${MARIADB_PORT}/${MARIADB_DATABASE}"
            ;;
        *)
            return 1
            ;;
    esac
}

# List available backups
list_database_backups() {
    local backup_dir="/var/lib/marzban/backups"
    
    echo "=== Available Database Backups ==="
    
    if [[ -d "${backup_dir}" ]]; then
        ls -lhtr "${backup_dir}"/*.{sqlite3,sql,gz} 2>/dev/null || echo "No backups found"
    else
        echo "Backup directory not found: ${backup_dir}"
    fi
}

# Optimize database
optimize_database() {
    local db_type="${1:-${DATABASE_TYPE:-sqlite}}"
    
    log_step "Optimizing database"
    
    case "${db_type}" in
        sqlite)
            if [[ -f "${SQLITE_DB_PATH}" ]]; then
                sqlite3 "${SQLITE_DB_PATH}" "VACUUM; ANALYZE;" 2>/dev/null
                log_success "SQLite database optimized"
            fi
            ;;
        mariadb|mysql)
            docker exec marzban-mariadb mysqlcheck \
                -u root \
                -p"${MARIADB_ROOT_PASSWORD}" \
                --optimize \
                "${MARIADB_DATABASE}" 2>/dev/null
            log_success "MariaDB database optimized"
            ;;
    esac
}
