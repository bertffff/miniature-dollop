# Marzban Ultimate VPN Installer v2.0

Production-grade, modular, idempotent installer for multi-profile VLESS/Reality VPN server powered by Marzban. Engineered for hostile network environments including Russian ТСПУ/DPI filtering systems.

## Features

### VPN Profiles
- **Standard (VLESS + Reality)**: Direct connection with TLS camouflage
- **WARP (Cloudflare)**: Geo-restricted services bypass (OpenAI, Netflix, Spotify)
- **Whitelist Bypass (CDN-fronted)**: For environments with IP whitelist filtering

### Security & Performance
- XanMod kernel with BBRv3 congestion control (optional)
- uTLS fingerprinting (Chrome/Firefox/Safari)
- Reality protocol with legitimate TLS camouflage
- Fail2Ban brute-force protection
- AdGuard Home DNS-level ad blocking

### Deployment Options
- Exit node (direct to internet)
- Relay node (forwards to another server)
- Combined exit + relay

## Requirements

- Ubuntu 22.04+ or Debian 11+
- x86_64 architecture
- 2+ CPU cores
- 2GB+ RAM
- Root access
- Domain name (with DNS configured)

## Quick Start

```bash
# Clone/download the installer
git clone https://github.com/your-repo/marzban-installer.git
cd marzban-installer

# Run the installer
sudo ./install.sh
```

## Installation Options

```bash
# Interactive installation (recommended)
./install.sh

# Resume interrupted installation
./install.sh --resume

# Check status
./install.sh --status

# Update Marzban
./install.sh --update

# Uninstall
./install.sh --uninstall
```

## Directory Structure

```
marzban-installer/
├── install.sh              # Main installer script
├── modules/                # Core functionality
│   ├── core.sh            # Logging, error handling, utilities
│   ├── system.sh          # System preparation, kernel
│   ├── firewall.sh        # UFW, Fail2Ban
│   ├── docker.sh          # Docker installation
│   ├── nginx.sh           # Nginx with SNI routing
│   ├── certbot.sh         # SSL certificates
│   ├── xray.sh            # Xray key generation
│   ├── warp.sh            # Cloudflare WARP setup
│   ├── marzban.sh         # Marzban installation
│   ├── marzban_api.sh     # API-driven configuration
│   ├── adguard.sh         # AdGuard Home
│   ├── cdn.sh             # CDN setup for whitelist bypass
│   └── database.sh        # Database configuration
├── templates/              # Configuration templates
│   ├── nginx/             # Nginx configs
│   ├── xray/              # Xray configs
│   ├── docker/            # Docker Compose
│   └── adguard/           # AdGuard Home
├── tools/                  # Utilities
│   ├── clean-ip-scanner.sh    # CDN clean IP finder
│   ├── health-check.sh        # System health check
│   ├── backup.sh              # Backup/restore
│   └── subscription-generator.sh  # Client configs
├── fake-sites/            # Camouflage website templates
└── data/                  # Runtime data
    ├── config.env         # Installation configuration
    ├── credentials.env    # Admin credentials
    ├── keys/              # Encryption keys
    └── backups/           # Automatic backups
```

## Post-Installation

### Access Panel
After installation, access the Marzban panel at:
```
https://your-domain.com
```

Credentials are displayed after installation and saved to:
```
data/credentials.env
```

### Useful Commands
```bash
# View logs
marzban logs

# Restart services
marzban restart

# Check status
marzban status

# Run health check
./tools/health-check.sh

# Create backup
./tools/backup.sh

# Generate client subscription
./tools/subscription-generator.sh -u username
```

### CDN Setup (Whitelist Bypass Profile)

If you enabled the whitelist bypass profile, you need to configure your CDN:

1. **Create CDN Resource**
   - Log into your CDN provider (GCore/EdgeCenter/Cloudflare)
   - Create a new CDN resource
   - Set origin to your server IP

2. **Configure Origin**
   - Origin type: IP address
   - Origin IP: Your server's public IP
   - Origin port: 443
   - Enable WebSocket support

3. **SSL Configuration**
   - Enable HTTPS
   - Either use CDN's SSL or your own certificate

4. **Find Clean IPs**
   ```bash
   ./tools/clean-ip-scanner.sh -d cdn.your-domain.com -p gcore
   ```

## VPN Profile Details

### Standard Profile (VLESS + Reality)
- Protocol: VLESS over TCP
- Security: Reality (TLS 1.3 camouflage)
- Fingerprint: Chrome browser
- SNI: Configurable (default: microsoft.com)

### WARP Profile
- Same connection as Standard
- Traffic routed through Cloudflare WARP
- Unlocks: OpenAI, Netflix, Spotify, etc.

### Whitelist Bypass Profile
- Protocol: VLESS over WebSocket
- Security: TLS via CDN
- Bypasses IP-based whitelist filtering
- Requires CDN configuration

## Troubleshooting

### Check System Health
```bash
./tools/health-check.sh
```

### Common Issues

**Port 53 in use:**
```bash
# The installer handles this automatically
# If issues persist:
systemctl stop systemd-resolved
systemctl disable systemd-resolved
```

**SSL Certificate Issues:**
```bash
# Renew certificates
certbot renew --force-renewal
systemctl reload nginx
```

**Docker Issues:**
```bash
# Check container status
docker ps -a
docker logs marzban
```

**Firewall Issues:**
```bash
# Check UFW status
ufw status verbose

# Reset and reconfigure
ufw reset
./install.sh --resume
```

## Security Recommendations

1. **Change Default Ports**: Modify standard ports if possible
2. **Regular Updates**: Keep system and Marzban updated
3. **Strong Passwords**: Use generated passwords
4. **Monitor Logs**: Check for unusual activity
5. **Regular Backups**: Use the backup tool weekly
6. **Fail2Ban**: Keep enabled for brute-force protection

## Technical Details

### Architecture Decisions
- **Nginx on host** (not containerized): Better performance, native certbot
- **Network mode: host**: Zero NAT overhead, IP transparency
- **API-driven config**: All inbounds visible in Marzban GUI
- **Dynamic templates**: No hardcoded configurations

### Threat Model Coverage
| Threat | Countermeasure |
|--------|----------------|
| L3/L4 IP filtering | CDN fronting |
| Protocol fingerprinting | uTLS (browser fingerprints) |
| SNI inspection | Domain fronting, legitimate SNI |
| TLS fingerprint analysis | Randomized ALPN, cipher suites |
| Traffic pattern analysis | Fake website, padding |
| Active probing | Valid certificate responses |

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test thoroughly
4. Submit a pull request

## License

MIT License - see LICENSE file

## Acknowledgments

- [Marzban](https://github.com/Gozargah/Marzban) - Unified GUI for Xray
- [Xray-core](https://github.com/XTLS/Xray-core) - Network proxy platform
- [XanMod Kernel](https://xanmod.org/) - High-performance Linux kernel
- [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) - DNS-level ad blocking
