version: "3.8"

# =============================================================================
# Marzban Docker Compose Configuration
# Template Variables:
#   ${DATABASE_TYPE} - sqlite or mariadb
#   ${MARZBAN_PORT} - Dashboard port (default: 8000)
#   ${MARIADB_PASSWORD} - MariaDB password (required if using mariadb)
#   ${NETWORK_MODE} - host or bridge (default: host)
# =============================================================================

services:
  # ============================================================================
  # Marzban Panel
  # ============================================================================
  marzban:
    image: gozargah/marzban:latest
    container_name: marzban
    restart: unless-stopped
    network_mode: ${NETWORK_MODE:-host}
    env_file:
      - .env
    volumes:
      - /var/lib/marzban:/var/lib/marzban
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:${MARZBAN_PORT:-8000}/api/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    # Uncomment if using MariaDB:
    # depends_on:
    #   marzban-db:
    #     condition: service_healthy

  # ============================================================================
  # MariaDB Database (Optional - uncomment if DATABASE_TYPE=mariadb)
  # ============================================================================
  # marzban-db:
  #   image: mariadb:10.11
  #   container_name: marzban-db
  #   restart: unless-stopped
  #   network_mode: ${NETWORK_MODE:-host}
  #   environment:
  #     MYSQL_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
  #     MYSQL_DATABASE: marzban
  #     MYSQL_USER: marzban
  #     MYSQL_PASSWORD: ${MARIADB_PASSWORD}
  #   volumes:
  #     - mariadb_data:/var/lib/mysql
  #   healthcheck:
  #     test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
  #     interval: 30s
  #     timeout: 10s
  #     retries: 5
  #     start_period: 60s
  #   logging:
  #     driver: json-file
  #     options:
  #       max-size: "10m"
  #       max-file: "3"

  # ============================================================================
  # AdGuard Home DNS (Optional - uncomment if INSTALL_ADGUARD=true)
  # ============================================================================
  # adguardhome:
  #   image: adguard/adguardhome:latest
  #   container_name: adguardhome
  #   restart: unless-stopped
  #   network_mode: ${NETWORK_MODE:-host}
  #   volumes:
  #     - /opt/marzban/adguard/work:/opt/adguardhome/work
  #     - /opt/marzban/adguard/conf:/opt/adguardhome/conf
  #   cap_add:
  #     - NET_ADMIN
  #   environment:
  #     - TZ=${TZ:-UTC}
  #   healthcheck:
  #     test: ["CMD", "wget", "-q", "--spider", "http://localhost:3000"]
  #     interval: 30s
  #     timeout: 10s
  #     retries: 3
  #     start_period: 10s

# =============================================================================
# Volumes
# =============================================================================
# volumes:
#   mariadb_data:
#     driver: local

# =============================================================================
# Networks (only if not using host network mode)
# =============================================================================
# networks:
#   marzban-network:
#     driver: bridge
#     ipam:
#       config:
#         - subnet: 172.20.0.0/16
