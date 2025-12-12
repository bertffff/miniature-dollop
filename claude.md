# Project Context: Marzban "Ultimate" VPN Installer

## 1. Project Mission & Overview
This project aims to synthesize a **production-grade, modular, and idempotent** Bash installer for a VLESS/Reality VPN server powered by [Marzban](https://github.com/Gozargah/Marzban).

**Objective:** Create a single entry-point script (`install.sh`) that automates the deployment of the entire stack (Docker, Xray, Nginx, Firewall, Certificates) on a fresh Debian/Ubuntu server, combining the best logic from three legacy scripts into one cohesive codebase.

### Core Stack
*   **OS:** Ubuntu 22.04+ / Debian 11+ (Target architecture: `amd64`).
*   **Orchestration:** Docker & Docker Compose (v2).
*   **VPN Core:** Marzban (Python-based panel) managing Xray-core.
*   **Edge Router:** Nginx (running on **Host OS**, NOT Docker).
*   **Database:** SQLite (default) or MariaDB (optional).
*   **Security:** UFW (Firewall), Fail2Ban (optional), Cloudflare WARP.

---

## 2. System Architecture & Traffic Flow
*The installer must configure the system to follow this exact traffic flow to ensure "Stealth" and performance.*

### 2.1. Network Path (Port 443)
1.  **Incoming Traffic (Port 443/TCP):** Hits the server.
2.  **Nginx Stream Layer (Host):** Nginx listens on port 443. It uses `ngx_stream_ssl_preread` to inspect the SNI (Server Name Indication) *without* terminating SSL.
    *   **Condition A (Valid Reality SNI):** If SNI matches the Xray Reality domain -> Forward to Xray container (e.g., port `8443`).
    *   **Condition B (Other/Panel SNI):** If SNI matches the Admin Panel domain -> Terminate SSL (using Certbot certs) -> Proxy to Marzban Dashboard (port `8000`).
    *   **Condition C (Fallback/Bad SNI):** Forward to local Nginx Web Server (port `8080` or socket) to serve a **Fake Website** (Camouflage).

### 2.2. Component Interaction
*   **Installer:** Bash script -> Generates `.env`, `docker-compose.yml`, `xray_config.json`, `nginx.conf` -> Triggers `docker compose up`.
*   **Marzban:** Manages Xray configs via API/DB -> Updates Xray Core.
*   **Certbot:** Obtains certs for the Panel domain (not needed for Reality, but needed for Dashboard).

---

## 3. Directory Structure & File Organization
*Strict adherence to this structure is required.*

```text
/root/marzban-installer/
├── install.sh                  # MAIN ENTRY POINT (User Interface & Logic Orchestrator)
├── config.env.example          # Template for user variables (Domain, Emails, Ports)
├── CLAUDE.md                   # THIS FILE (Project Context)
├── modules/                    # LOGIC LIBRARY
│   ├── core.sh                 # Global variables, logging colors, error traps, rollback logic
│   ├── system.sh               # OS preparation, Dependencies, Kernel tuning (BBR), Sysctl
│   ├── firewall.sh             # UFW configuration, SSH port detection, Cloudflare IPs
│   ├── docker.sh               # Docker Engine & Compose installation (with version checks)
│   ├── marzban.sh              # Marzban installation, DB setup, Admin creation
│   ├── nginx.sh                # Host Nginx install, Stream config, Fake site downloading
│   ├── certbot.sh              # SSL generation (LetsEncrypt) for Panel
│   ├── xray.sh                 # Xray JSON generation (templating), Key generation (x25519)
│   └── warp.sh                 # Cloudflare WARP setup (Wireguard config generation)
└── templates/                  # CONFIGURATION TEMPLATES (No hardcoded JSON in Bash!)
    ├── docker-compose.yml.tpl  # Docker compose template
    ├── nginx.conf.tpl          # Nginx main config
    ├── nginx_stream.conf.tpl   # SNI routing logic
    ├── nginx_site.conf.tpl     # Fake site server block
    ├── xray_config.json.tpl    # Base Xray config with variable placeholders
    └── warp.json.tpl           # WARP outbound template
```

---

## 4. Coding Standards (Bash)
*The generated code must be robust, secure, and professional.*

### 4.1. Strict Mode & Safety
*   **Header:** Every script file MUST start with `#!/bin/bash` and `set -euo pipefail`.
*   **Root Check:** The script must strictly forbid running as non-root.
*   **Trap & Rollback:**
    *   Implement a `trap 'error_handler $LINENO' ERR` mechanism.
    *   If a critical step fails (e.g., Docker fails to start), the script should offer to rollback changes (remove installed files).

### 4.2. Variable Naming
*   `UPPER_CASE`: Global variables exported from `config.env` (e.g., `DOMAIN`, `ADMIN_EMAIL`).
*   `lower_case`: Local variables inside functions (e.g., `local config_path="..."`).
*   **Quoting:** ALWAYS quote variables: `"${VARIABLE}"`, not `$VARIABLE`.

### 4.3. Logging & User Output
*   Do not use raw `echo`. Use helper functions defined in `core.sh`:
    *   `log_info "Message"` (Blue/Green)
    *   `log_warn "Message"` (Yellow)
    *   `log_error "Message"` (Red)
    *   `log_input "Prompt"` (for `read` commands)

### 4.4. Configuration Handling
*   **NO `cat <<EOF` for complex JSON.** Do not generate huge JSON files using Bash heredocs. It is error-prone.
*   **Use Templates:** Read a file from `templates/`, replace placeholders using `sed` or `envsubst`, and validate the result with `jq`.
    *   *Example:* `jq . config.json` must return 0 before the script proceeds.

---

## 5. Architectural Decision Records (ADR)
*Why we are building it this way.*

### ADR-001: Nginx on Host vs. Docker
*   **Decision:** Nginx runs on the **Host OS**.
*   **Rationale:**
    1.  **Performance:** Removes Docker bridge overhead for the main traffic ingress.
    2.  **Certbot:** Simpler integration. `certbot --nginx` works natively without sharing volumes between ephemeral containers.
    3.  **Simplicity:** Easier to reload Nginx config dynamically without restarting Docker containers.

### ADR-002: Network Mode Host
*   **Decision:** Marzban container runs with `network_mode: host`.
*   **Rationale:** Critical for Xray performance and correct IP forwarding for `fail2ban` and logs. Avoids NAT complications.

### ADR-003: SQLite vs MariaDB
*   **Decision:** Default to **SQLite**, allow optional switch to MariaDB.
*   **Rationale:** SQLite reduces resource usage for small/medium VPS. MariaDB is overkill for a personal VPN but good for enterprise (keep the code in `marzban.sh` but disabled by default).

### ADR-004: Fake Website (Camouflage)
*   **Decision:** The installer must download a random HTML template (from a predefined list or GitHub repo) to `/var/www/html`.
*   **Rationale:** Active probing protection. If a censor visits the IP/Domain without the correct UUID path, they must see a legitimate-looking website (e.g., a Resume, a Blog, or a Landing page), not a 404 or Xray raw response.

---

## 6. Implementation Guidelines per Module

### `core.sh`
*   Contains `check_root`, `check_os`, `install_packages` (wrapper for apt).
*   Contains the `logo` (Banner).

### `xray.sh`
*   **Keygen:** Must use `docker run --rm ghcr.io/XTLS/Xray-core x25519` to generate keys if `xray` binary is not on host.
*   **ShortID:** Generate random hex strings using `openssl`.

### `nginx.sh`
*   Must clean default Nginx configs (`rm /etc/nginx/sites-enabled/default`).
*   Must generate `dhparam.pem` if it doesn't exist (warning: takes time, show progress).

### `marzban.sh`
*   Must handle the creation of the **First Admin User** via CLI (`marzban cli admin create`).
*   Do NOT rely on Marzban's default API state; force the creation of the admin.

### `warp.sh`
*   Must install `wgcf` or use API to register.
*   Must generate a Wireguard config compatible with Xray's outbound format.
*   **Routing:** Add strict rules in `xray_config.json` to route OpenAI/Netflix/Google traffic through the WARP outbound tag.

---

## 7. Known Pitfalls & Anti-Patterns (Avoid These)
1.  **Port 53 Conflict:** `systemd-resolved` binds port 53. If installing AdGuard, the script **MUST** disable the StubListener in `/etc/systemd/resolved.conf` safely.
2.  **Docker Python Dependency:** Do not install `python3-pip` on the host if possible. Use standard system packages or Docker images for tasks.
3.  **Hardcoded Credentials:** Never hardcode passwords. Generate random strings using `openssl rand -base64 12` if the user doesn't provide one.
4.  **Blind Updates:** Don't run `apt-get upgrade -y` blindly without asking the user (it might update the kernel and require a reboot).
5.  **JSON Syntax Errors:** A single missing comma in `xray_config.json` breaks the VPN. **ALWAYS** validate generated JSON with `jq` before restarting the service.

## 8. Verification Steps (Definition of Done)
*   Script runs to completion without errors.
*   `docker ps` shows Marzban healthy.
*   `systemctl status nginx` shows active.
*   Visiting `https://<domain>/dashboard` prompts for login.
*   Visiting `https://<domain>` (root) shows the Fake Website.
*   Connecting via VLESS Reality works (Internet access confirmed).
*   Connecting via WARP outbound works (IP check shows Cloudflare IP).
