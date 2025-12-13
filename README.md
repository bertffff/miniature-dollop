# Marzban Ultimate VPN Installer

<p align="center">
  <b>Production-grade automated deployment for VLESS/Reality VPN</b>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#requirements">Requirements</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#configuration">Configuration</a> •
  <a href="#architecture">Architecture</a>
</p>

---

## Overview

Ultimate VPN Installer automates the deployment of a complete VLESS/Reality VPN server powered by [Marzban](https://github.com/Gozargah/Marzban) with advanced features including XanMod kernel, Cloudflare WARP, AdGuard DNS, and API-driven profile configuration.

## Features

### Core Features
- ✅ **VLESS + Reality Protocol** - Modern, undetectable VPN protocol
- ✅ **XanMod Kernel** - Optimized kernel with BBRv3 for better performance
- ✅ **MariaDB Support** - Optional database for enterprise deployments
- ✅ **Automatic SSL** - Let's Encrypt certificates with auto-renewal
- ✅ **Web Panel** - Marzban dashboard for user management

### Advanced Features
- 🚀 **Cloudflare WARP** - Bypass geo-restrictions (Netflix, OpenAI, etc.)
- 🚀 **AdGuard Home** - DNS-level ad blocking for clients
- 🚀 **SNI-based Routing** - Smart traffic routing via Nginx
- 🚀 **Fake Website** - Camouflage with randomized templates
- 🚀 **API-driven Config** - All Xray profiles managed via Marzban API

### Security Features
- 🔒 **Priority-based Rollback** - Safe installation with automatic recovery
- 🔒 **UFW Firewall** - Configured with Cloudflare IP whitelist
- 🔒 **Fail2Ban** - SSH brute-force protection
- 🔒 **No Hardcoded Credentials** - All secrets auto-generated

## Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Ubuntu 20.04 / Debian 11 | Ubuntu 22.04 / Debian 12 |
| Architecture | amd64, arm64 | amd64 |
| RAM | 512 MB | 1 GB+ |
| Disk | 5 GB | 10 GB+ |
| Network | Public IPv4 | Public IPv4 + IPv6 |

## Quick Start

### One-Line Installation

```bash
bash <(curl -sL https://your-repo/install.sh)
```

### Manual Installation

```bash
# Clone repository
git clone https://github.com/your-repo/marzban-installer.git
cd marzban-installer

# Copy and edit configuration
cp config.env.example config.env
nano config.env

# Run installer
sudo ./install.sh
```

### Installation Options

```bash
# Interactive installation
sudo ./install.sh

# Use custom config
sudo ./install.sh -c myconfig.env

# Skip confirmations (CI/CD)
sudo ./install.sh -s

# Install with MariaDB
sudo ./install.sh --mariadb

# Install without WARP
sudo ./install.sh --no-warp

# Testing mode (Let's Encrypt staging)
sudo ./install.sh --staging

# Uninstall
sudo ./install.sh -u
```

## Configuration

### Key Settings in config.env

```bash
# Domain
PANEL_DOMAIN="vpn.example.com"
REALITY_DEST="www.google.com"

# Database
DATABASE_TYPE="sqlite"  # or "mariadb"

# Features
INSTALL_XANMOD="true"
INSTALL_WARP="true"
INSTALL_ADGUARD="false"
INSTALL_FAKE_SITE="true"
INSTALL_FAIL2BAN="true"
```

### VPN Profiles

The installer creates 3 VLESS Reality profiles:

1. **Reality-Whitelist** (Port 8443)
   - SNI: www.google.com
   - Routing: Direct

2. **Reality-Standard** (Port 8444)
   - SNI: www.microsoft.com
   - Routing: Direct

3. **Reality-WARP** (Port 8445)
   - SNI: www.apple.com
   - Routing: Via Cloudflare WARP

## Architecture

### Traffic Flow

```
Internet (Port 443)
       │
       ▼
┌─────────────────────────────┐
│      Nginx (SNI Router)      │
│  ┌─────────┬────────┬──────┐│
│  │ Reality │ Panel  │ Other ││
│  │   SNI   │  SNI   │  SNI  ││
│  └────┬────┴───┬────┴───┬──┘│
└───────┼────────┼────────┼───┘
        │        │        │
        ▼        ▼        ▼
    Xray:8443  Marzban  Fake Site
    Xray:8444  :8000    :8080
    Xray:8445
        │
        ▼
    ┌───────┐
    │ WARP  │ (for geo-bypass)
    └───────┘
```

### Module Structure

```
marzban-installer/
├── install.sh           # Main entry point
├── config.env.example   # Configuration template
├── modules/
│   ├── core.sh          # Utilities, logging, rollback
│   ├── system.sh        # XanMod kernel, sysctl, BBR
│   ├── docker.sh        # Docker installation
│   ├── firewall.sh      # UFW configuration
│   ├── nginx.sh         # Nginx, SNI routing, fake site
│   ├── certbot.sh       # SSL certificates
│   ├── xray.sh          # Reality keys, Xray setup
│   ├── warp.sh          # Cloudflare WARP
│   ├── marzban.sh       # Marzban panel
│   ├── marzban_api.sh   # API-driven configuration
│   └── adguard.sh       # AdGuard Home DNS
└── templates/
    └── docker-compose.yml.tpl
```

## Post-Installation

### Access Dashboard

```
URL: https://your-domain.com/dashboard/
Credentials: See /opt/marzban/admin_credentials.txt
```

### Reality Client Configuration

```
Public Key: See /var/lib/marzban/reality_keys.txt
Short ID: See /var/lib/marzban/reality_keys.txt
Fingerprint: chrome
```

### Useful Commands

```bash
# View Marzban logs
docker logs -f marzban

# Restart Marzban
cd /opt/marzban && docker compose restart

# Update Marzban
cd /opt/marzban && docker compose pull && docker compose up -d

# View Nginx status
systemctl status nginx

# Check SSL certificate
certbot certificates
```

## Troubleshooting

### Common Issues

1. **Port 443 in use**
   ```bash
   ss -tlnp | grep 443
   systemctl stop apache2  # if Apache
   ```

2. **DNS not verified**
   ```bash
   dig +short your-domain.com  # Should show server IP
   ```

3. **Marzban not starting**
   ```bash
   docker logs marzban
   docker compose -f /opt/marzban/docker-compose.yml up
   ```

### Log Files

- Installer: `/var/log/marzban-installer.log`
- Marzban: `docker logs marzban`
- Nginx: `/var/log/nginx/error.log`
- Xray: `/var/lib/marzban/logs/error.log`

## Rollback System

The installer features a priority-based rollback system:

1. **CRITICAL** - Firewall/SSH access (executed first)
2. **NORMAL** - Services and configurations
3. **CLEANUP** - Temporary files (executed last)

If installation fails, rollback executes automatically in reverse order.

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

- [Marzban](https://github.com/Gozargah/Marzban)
- [Xray-core](https://github.com/XTLS/Xray-core)
- [XanMod Kernel](https://xanmod.org/)
- [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome)

---

<p align="center">
  Made with ❤️ for the open internet
</p>
