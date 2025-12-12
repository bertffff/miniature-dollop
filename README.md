# Marzban Ultimate VPN Installer

<p align="center">
  <img src="https://raw.githubusercontent.com/Gozargah/Marzban/master/docs/assets/marzban-logo.png" alt="Marzban Logo" width="150">
</p>

<p align="center">
  <b>Production-grade automated deployment for VLESS/Reality VPN</b>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#requirements">Requirements</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#configuration">Configuration</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#troubleshooting">Troubleshooting</a>
</p>

---

## Overview

This installer automates the deployment of a complete VLESS/Reality VPN server powered by [Marzban](https://github.com/Gozargah/Marzban). It configures all components for optimal performance, security, and stealth.

### Stack Components

| Component | Role | Version |
|-----------|------|---------|
| Marzban | VPN Panel & Management | Latest |
| Xray-core | VPN Core Engine | Latest |
| Nginx | Edge Router & SNI Routing | 1.18+ |
| Docker | Container Runtime | 20.10+ |
| UFW | Firewall | System |
| Certbot | SSL Certificates | Latest |
| WARP | Cloudflare Tunnel (Optional) | Latest |

## Features

### Core Features
- ✅ **VLESS + Reality Protocol** - Modern, undetectable VPN protocol
- ✅ **SNI-based Routing** - Traffic routing via TLS SNI inspection
- ✅ **Automatic SSL** - Let's Encrypt certificates with auto-renewal
- ✅ **Web Panel** - Beautiful Marzban dashboard for user management
- ✅ **Multi-user Support** - Create and manage multiple VPN users

### Security Features
- 🔒 **BBR Congestion Control** - Optimized network performance
- 🔒 **Firewall Configuration** - UFW with Cloudflare IP whitelist
- 🔒 **Fail2Ban Integration** - SSH brute-force protection (optional)
- 🔒 **Fake Website Camouflage** - Serves legitimate site on invalid SNI
- 🔒 **No Hardcoded Credentials** - All secrets auto-generated

### Advanced Features
- 🚀 **Cloudflare WARP** - Bypass geo-restrictions (Netflix, OpenAI, etc.)
- 🚀 **Template-based Config** - No heredocs, proper JSON validation
- 🚀 **Rollback Support** - Automatic cleanup on failure
- 🚀 **Idempotent Installation** - Safe to run multiple times

## Requirements

### System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Ubuntu 22.04 / Debian 11 | Ubuntu 24.04 |
| Architecture | amd64 | amd64 |
| RAM | 512 MB | 1 GB+ |
| Disk | 5 GB | 10 GB+ |
| Network | Public IPv4 | Public IPv4 + IPv6 |

### Pre-requisites

1. **Clean server** - Fresh VPS installation recommended
2. **Root access** - Script must run as root
3. **Domain name** - Pointed to your server's IP (A record)
4. **Open ports** - 80, 443 (22 for SSH)

## Quick Start

### One-Line Installation

```bash
bash <(curl -sL https://raw.githubusercontent.com/your-repo/marzban-installer/main/install.sh)
```

### Manual Installation

```bash
# Clone repository
git clone https://github.com/your-repo/marzban-installer.git
cd marzban-installer

# Make executable
chmod +x install.sh

# Run installer
sudo ./install.sh
```

### Installation Options

```bash
# Use custom config file
sudo ./install.sh -c myconfig.env

# Skip confirmation prompts
sudo ./install.sh -s

# Install without WARP
sudo ./install.sh --no-warp

# Use Let's Encrypt staging (for testing)
sudo ./install.sh --staging

# Uninstall
sudo ./install.sh -u
```

## Configuration

### Configuration File

Copy the example configuration and edit as needed:

```bash
cp config.env.example config.env
nano config.env
```

### Key Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `DOMAIN` | Your panel domain | Required |
| `ADMIN_EMAIL` | Email for SSL certs | Required |
| `ADMIN_USERNAME` | Panel admin username | `admin` |
| `ADMIN_PASSWORD` | Panel admin password | Auto-generated |
| `REALITY_DEST` | Reality camouflage site | `www.google.com` |
| `XRAY_PORT` | Internal Xray port | `8443` |
| `INSTALL_WARP` | Enable WARP | `true` |

### Post-Installation

After installation, you'll find:

- **Dashboard**: `https://your-domain.com/dashboard`
- **Config**: `/opt/marzban/config.env`
- **Credentials**: `/opt/marzban/admin_credentials.txt`
- **Reality Keys**: `/var/lib/marzban/reality_keys.txt`
- **Logs**: `/var/log/marzban-installer.log`

## Architecture

### Traffic Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         Internet                                 │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼ Port 443
┌─────────────────────────────────────────────────────────────────┐
│                      Nginx (Host OS)                             │
│                    SNI Inspection Layer                          │
│                                                                  │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────────┐   │
│  │ Reality SNI │   │ Panel SNI   │   │ Invalid/Other SNI   │   │
│  │  (google)   │   │  (domain)   │   │    (fallback)       │   │
│  └──────┬──────┘   └──────┬──────┘   └──────────┬──────────┘   │
│         │                 │                      │               │
└─────────┼─────────────────┼──────────────────────┼───────────────┘
          │                 │                      │
          ▼                 ▼                      ▼
    ┌───────────┐    ┌───────────┐          ┌───────────┐
    │   Xray    │    │  Marzban  │          │   Fake    │
    │  :8443    │    │  :8001    │          │  Website  │
    │ (Reality) │    │ (Panel)   │          │  :8080    │
    └─────┬─────┘    └───────────┘          └───────────┘
          │
          ▼
    ┌───────────┐
    │   WARP    │ (Optional - for geo-restricted services)
    │ Outbound  │
    └───────────┘
```

### Directory Structure

```
/opt/marzban/                 # Marzban installation
├── docker-compose.yml        # Docker configuration
├── .env                      # Environment variables
└── admin_credentials.txt     # Admin login info

/var/lib/marzban/             # Marzban data
├── xray_config.json          # Xray configuration
├── reality_keys.txt          # Reality key pairs
├── warp/                     # WARP configuration
└── db.sqlite3                # User database

/etc/nginx/                   # Nginx configuration
├── nginx.conf                # Main config
├── conf.d/marzban.conf       # Site config
└── stream.d/sni.conf         # SNI routing

/var/www/html/                # Fake website files
```

## Management

### Docker Commands

```bash
# View container status
docker ps

# View Marzban logs
docker logs -f marzban

# Restart Marzban
cd /opt/marzban && docker compose restart

# Stop Marzban
cd /opt/marzban && docker compose down

# Update Marzban
cd /opt/marzban && docker compose pull && docker compose up -d
```

### Nginx Commands

```bash
# Test configuration
nginx -t

# Reload configuration
systemctl reload nginx

# View logs
tail -f /var/log/nginx/error.log
```

### SSL Certificate

```bash
# Check certificate status
certbot certificates

# Renew certificate manually
certbot renew

# Obtain new certificate
certbot --nginx -d your-domain.com
```

## Troubleshooting

### Common Issues

#### 1. "Port 443 already in use"

```bash
# Check what's using the port
ss -tlnp | grep 443

# Stop conflicting service
systemctl stop apache2  # if Apache is running
```

#### 2. "DNS verification failed"

Ensure your domain's A record points to the server IP:

```bash
# Check DNS resolution
dig +short your-domain.com

# Check server IP
curl -s ifconfig.me
```

#### 3. "Marzban container unhealthy"

```bash
# Check container logs
docker logs marzban

# Check Xray config validity
docker exec marzban xray run -test -config /var/lib/marzban/xray_config.json

# Restart container
cd /opt/marzban && docker compose restart
```

#### 4. "Reality connection failed"

```bash
# Verify Reality keys are generated
cat /var/lib/marzban/reality_keys.txt

# Check Xray is listening
ss -tlnp | grep 8443

# Verify SNI routing
curl -I --resolve google.com:443:YOUR_SERVER_IP https://google.com
```

### Debug Mode

```bash
# Enable verbose logging
export DEBUG=1
./install.sh
```

### Log Files

| Log | Location |
|-----|----------|
| Installer | `/var/log/marzban-installer.log` |
| Marzban | `docker logs marzban` |
| Nginx | `/var/log/nginx/error.log` |
| Xray | `/var/lib/marzban/error.log` |
| System | `journalctl -xe` |

## Security Recommendations

1. **Change SSH Port** - Use a non-standard SSH port
2. **Enable Fail2Ban** - Run installer with `INSTALL_FAIL2BAN=true`
3. **Regular Updates** - Keep system and Marzban updated
4. **Backup Regularly** - Backup `/var/lib/marzban` directory
5. **Monitor Logs** - Check for unusual activity

## Backup & Restore

### Backup

```bash
# Backup script
tar -czvf marzban-backup-$(date +%Y%m%d).tar.gz \
    /opt/marzban \
    /var/lib/marzban \
    /etc/nginx/conf.d/marzban.conf
```

### Restore

```bash
# Stop services
cd /opt/marzban && docker compose down

# Restore files
tar -xzvf marzban-backup-*.tar.gz -C /

# Restart services
cd /opt/marzban && docker compose up -d
systemctl restart nginx
```

## Uninstallation

```bash
# Interactive uninstall
sudo ./install.sh -u

# Manual uninstall
cd /opt/marzban && docker compose down -v
rm -rf /opt/marzban /var/lib/marzban
rm -f /etc/nginx/conf.d/marzban.conf /etc/nginx/stream.d/sni.conf
systemctl restart nginx
```

## Contributing

Contributions are welcome! Please read the contribution guidelines before submitting a pull request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Marzban](https://github.com/Gozargah/Marzban) - The VPN management panel
- [Xray-core](https://github.com/XTLS/Xray-core) - The VPN engine
- [XTLS/Reality](https://github.com/XTLS/REALITY) - The Reality protocol

---

<p align="center">
  Made with ❤️ for the open internet
</p>
