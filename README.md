# JTerrazz Infrastructure CLI

Professional infrastructure management CLI for deploying and managing containerized applications with automated HTTPS reverse proxy, trusted SSL certificates, and Tailscale network security. Designed for private management with public API readiness and **no browser warnings**.

## ✨ Features

- **🔧 Modular Architecture** - Clean separation of concerns with individual commands
- **🔐 Private Management** - Management tools (Portainer) accessible only via Tailscale
- **🚀 API Ready** - Port 443 configured with SSL, ready for public API services  
- **🔒 SSL Certificates** - Fully automated Let's Encrypt certificates via HTTP-01 challenge
- **🐳 Docker Management** - Container deployment and management
- **🌐 Smart Reverse Proxy** - Nginx ready for APIs, management tools stay private
- **🔗 Tailscale VPN** - Secure private network access from anywhere
- **🛡️ Security Hardening** - UFW firewall, fail2ban, automatic updates
- **📊 Status Monitoring** - Comprehensive system and service status reporting
- **🔄 Resumable Operations** - State tracking and recovery from failures
- **💾 Backup/Restore** - Built-in data protection for services

## 🚀 Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/jterrazz/jterrazz-infra.git
cd jterrazz-infra

# Install the CLI globally
sudo ./install.sh

# Verify installation
infra --version
```

### Basic Setup

```bash
# 1. Update system packages
sudo infra upgrade

# 2. Install dependencies and Docker
sudo infra install

# 3. Setup Tailscale VPN for private network access
sudo infra tailscale --install
sudo infra tailscale --connect

# 4. Configure DNS to point your domain to your Tailscale IP
# Get your Tailscale IP: tailscale ip -4  (e.g., 100.64.1.2)
# Point manager.jterrazz.com → 100.64.1.2 in your DNS provider

# 5. Deploy Portainer container manager (private access only)
sudo infra portainer --deploy

# 6. Configure Nginx for future API services (optional - port 443 ready when needed)
sudo infra nginx --configure

# 7. Check overall status  
infra status

# 8. Access management tools
# Portainer: https://manager.jterrazz.com:9443 (Tailscale private network only)
```

## 📋 Commands

### System Management

```bash
# Update system packages and security patches
sudo infra upgrade [options]
  --security-only    # Install security updates only
  --skip-cleanup     # Skip package cleanup

# Install dependencies, Docker, and security tools
sudo infra install [options]
  --skip-docker      # Skip Docker installation
  --skip-firewall    # Skip firewall configuration
  --skip-security    # Skip security hardening
```

### Container Management

```bash
# Manage Portainer container manager
sudo infra portainer [action]
  --deploy, -d           # Deploy Portainer container
  --update, -u           # Update to latest version
  --backup [path]        # Create backup of data
  --restore <file>       # Restore from backup
  --uninstall            # Complete uninstallation
  --status, -s           # Show status (default)
```

### Reverse Proxy & SSL

```bash
# Configure Nginx reverse proxy with SSL
sudo infra nginx [action]
  --configure, -c        # Setup reverse proxy and SSL
  --secure               # Ensure HTTPS-only (disable port 80 services)
  --test, -t             # Test configuration
  --reload, -r           # Reload configuration
  --restart              # Restart service
  --renew-ssl --force-ssl # Force SSL certificate renewal
  --status, -s           # Show status (default)
```

### Tailscale VPN Management

```bash
# Manage Tailscale VPN for secure private network access
sudo infra tailscale [action]
  --install              # Install Tailscale
  --connect              # Connect to network (interactive)
  --connect --auth-key=xyz # Connect with auth key (non-interactive)
  --disconnect           # Disconnect from network
  --subnet-router [cidr] # Configure as subnet router
  --ssh                  # Enable SSH access through Tailscale
  --update               # Update to latest version
  --generate-key         # Generate auth key for other machines
  --status, -s           # Show connection status (default)
```

### Monitoring & Status

```bash
# Comprehensive system status
infra status [section]
  --system      # System information
  --docker      # Docker service status
  --network     # Network and connectivity
  --security    # Security services
  --services    # Infrastructure services
  --tailscale   # Tailscale VPN status
  --progress    # Setup progress
  --resources   # Resource usage
  --all, -a     # All sections (default)
```

## 🏗️ Architecture

### Directory Structure

```
jterrazz-infra/
├── infra                    # Main CLI dispatcher
├── install.sh              # Installation script
├── lib/                    # Shared utilities
│   ├── common.sh           # Logging, state, validation
│   └── ssl.sh              # SSL certificate management
├── commands/               # Individual command modules
│   ├── upgrade.sh          # System upgrades
│   ├── install.sh          # Dependencies & Docker
│   ├── portainer.sh        # Container management
│   ├── nginx.sh            # Reverse proxy config
│   └── status.sh           # System monitoring
├── config/                 # Configuration templates
│   └── nginx/
└── README.md
```

### Design Principles

- **Single Responsibility** - Each module handles one concern
- **Clean Boundaries** - Clear interfaces between components
- **State Management** - Resumable operations with progress tracking
- **Error Handling** - Graceful failure recovery and detailed logging
- **Security First** - HTTPS-only, minimal attack surface
- **Maintainability** - Clean code, comprehensive documentation

## 🌐 Network Configuration

### Private Network Access via Tailscale (Default Setup)

This infrastructure uses a **hybrid approach**: **private management tools** + **API-ready public services**. Your domain resolves to your server's Tailscale private IP, providing secure access from anywhere.

> 🎯 **Smart Architecture**: Private Management + Public API Ready  
> Management tools (Portainer) accessible only via Tailscale network on port 9443. Port 443 configured with trusted SSL certificates, ready for your public API services when needed. Perfect separation of concerns!

```bash
# Setup private access via Tailscale VPN with trusted SSL certificates
export DOMAIN_NAME="manager.jterrazz.com"     # Your private domain

# Full setup process (in correct order)
sudo infra upgrade
sudo infra install
sudo infra tailscale --install
sudo infra tailscale --connect               # Follow authentication URL

# IMPORTANT: Configure DNS before deploying services
# 1. Get your server's public IP: curl ifconfig.me (e.g., 203.0.113.1)  
# 2. Point manager.jterrazz.com → 203.0.113.1 in your DNS provider (for Let's Encrypt validation)
# 3. SSL certificates will be generated automatically (HTTP-01 challenge)
# 4. Services will be restricted to Tailscale IPs for security

sudo infra portainer --deploy
sudo infra nginx --configure  # Optional - for future APIs

# Access from any device on your Tailscale network:
# Management: https://manager.jterrazz.com:9443 (Portainer - private only)
# APIs: https://manager.jterrazz.com (port 443 - ready when needed)
```

### Advanced Configuration Options

```bash
# Configure as subnet router (route entire server network through Tailscale)
sudo infra tailscale --subnet-router 192.168.1.0/24

# Enable SSH access through Tailscale
sudo infra tailscale --ssh

# SSL certificates (Let's Encrypt via DNS challenge)
sudo infra nginx --configure
```

## 🔧 Configuration

### Environment Variables

| Variable            | Default                | Description                            |
| ------------------- | ---------------------- | -------------------------------------- |
| `DOMAIN_NAME`       | `manager.jterrazz.com` | Domain name for private network access |
| `PORTAINER_VERSION` | `latest`               | Portainer version to deploy            |

### SSL Certificate Management

This infrastructure uses **fully automated SSL certificates** via Let's Encrypt HTTP-01 challenge with **Tailscale network restrictions** for security. This provides the perfect balance: **automated certificates** with **private network access**.

#### **How Automated HTTP-01 Challenge Works**

- ✅ **Fully automated** - No manual intervention required for certificate generation or renewal
- ✅ **Public validation, private access** - Let's Encrypt validates via HTTP, services restricted to Tailscale
- ✅ **Port 80 for challenges only** - HTTP port used exclusively for Let's Encrypt verification  
- ✅ **Trusted certificates** - No browser warnings, full green lock
- ✅ **Automatic renewal** - Certificates renew every 60-90 days automatically
- ✅ **Tailscale IP restrictions** - HTTPS services only accessible from Tailscale network (100.64.0.0/10)

#### **Certificate Generation Process**

1. **Ensure DNS points to public IP:**
   ```bash
   # Your domain must resolve to your server's public IP (not Tailscale IP)
   # This is required for Let's Encrypt HTTP-01 validation
   dig +short manager.jterrazz.com  # Should show your server's public IP
   ```

2. **Run the automated SSL setup:**
   ```bash
   sudo infra nginx --configure
   ```

3. **Automatic process:**
   - ✅ Certbot automatically requests certificates via HTTP-01 challenge
   - ✅ Let's Encrypt validates domain ownership via port 80  
   - ✅ Nginx configuration automatically updated with SSL
   - ✅ Tailscale IP restrictions automatically applied to HTTPS
   - ✅ Automatic renewal timer enabled

4. **Result:**
   - Port 80: Let's Encrypt challenges only  
   - Port 443: HTTPS services (restricted to Tailscale IPs)
   - Certificates auto-renew every 60-90 days

#### **Certificate Status**

```bash
# Check certificate status
check-ssl-cert

# Example output:
# ✅ Let's Encrypt certificate (trusted, no browser warnings)
# Expires: Mar 15 14:30:00 2024 GMT
# Days until expiry: 75
# ✅ Certificate is valid
```

### State Management

The CLI uses persistent state tracking in `/var/lib/jterrazz-infra/`:

```bash
# View completed steps
infra status --progress

# Reset specific step (if needed)
sudo rm /var/lib/jterrazz-infra/state
```

## 🛡️ Security Features

### Network Security

- **Private Network Only** - No public internet exposure
- **HTTPS-Only** - No HTTP port 80 exposure
- **Tailscale VPN** - Encrypted mesh network with device authentication
- **UFW Firewall** - Default deny with SSH/HTTPS exceptions
- **Fail2ban** - SSH brute-force protection

### SSL/TLS Security

- **Modern TLS** - TLS 1.2/1.3 only
- **Security Headers** - HSTS, XSS protection, content type options
- **Certificate Management** - Automatic renewal and monitoring

### System Security

- **Automatic Updates** - Security patches applied automatically
- **Log Management** - Rotation and size limits
- **Service Isolation** - Containers run with minimal privileges

## 🔄 Backup & Recovery

### Portainer Data Backup

```bash
# Create backup
sudo infra portainer --backup /path/to/backup

# Restore from backup
sudo infra portainer --restore /path/to/backup.tar.gz
```

### Full System Backup

```bash
# Backup important configurations
tar -czf infrastructure-backup.tar.gz \
  /etc/nginx/sites-available/portainer \
  /var/lib/jterrazz-infra/ \
  /etc/letsencrypt/

# Backup Docker volumes
docker run --rm -v portainer_data:/data \
  -v $(pwd):/backup alpine:latest \
  tar -czf /backup/portainer-data.tar.gz -C /data .
```

## 📊 Monitoring & Maintenance

### Health Checks

```bash
# Quick system overview
infra status

# Detailed service check
infra status --services

# Check for security updates
sudo infra upgrade --security-only
```

### Log Management

```bash
# View service logs
journalctl -u nginx -f          # Nginx logs
journalctl -u docker -f         # Docker logs
docker logs portainer -f        # Portainer logs
journalctl -u certbot.timer     # Certificate renewal logs
journalctl -u tailscaled -f     # Tailscale daemon logs
```

### Tailscale Network Management

```bash
# Check Tailscale connection
infra status --tailscale

# View network peers
tailscale status

# Access services via Tailscale
# Once connected, access your services from any Tailscale device:
# https://manager.yourdomain.com (resolves to your server's Tailscale IP)

# IMPORTANT: Configure your DNS provider to point your domain to your Tailscale IP:
# 1. Get Tailscale IP: tailscale ip -4  (returns something like 100.x.x.x)
# 2. Create DNS A record: manager.yourdomain.com → 100.x.x.x
# 3. Access from any device on your Tailscale network

# Subnet routing (to access entire server network)
sudo infra tailscale --subnet-router 192.168.1.0/24

# SSH through Tailscale
sudo infra tailscale --ssh
ssh username@machine-name  # No IP needed, use Tailscale machine name
```

## 🐛 Troubleshooting

### Common Issues

**SSL Certificate Issues:**

```bash
# Check certificate status
check-ssl-cert

# View certificate details
certbot certificates

# Test certificate renewal (dry run)
certbot renew --dry-run

# Force certificate renewal (interactive - you'll add new TXT records)
sudo infra nginx --configure

# Check DNS configuration
nslookup manager.jterrazz.com
dig +short TXT _acme-challenge.manager.jterrazz.com

# Check certificate expiry
openssl x509 -in /etc/letsencrypt/live/manager.jterrazz.com/cert.pem -noout -dates
```

**Docker Issues:**

```bash
# Restart Docker service
sudo systemctl restart docker

# Check container status
infra status --docker

# Redeploy Portainer
sudo infra portainer --uninstall
sudo infra portainer --deploy
```

**Nginx Issues:**

```bash
# Test configuration
sudo infra nginx --test

# Check error logs
sudo tail -f /var/log/nginx/error.log

# Reload configuration
sudo infra nginx --reload
```

**Tailscale Issues:**

```bash
# Check connection status
infra status --tailscale

# Restart Tailscale daemon
sudo systemctl restart tailscaled

# Reconnect to network
sudo infra tailscale --disconnect
sudo infra tailscale --connect

# View detailed logs
journalctl -u tailscaled -f

# Access admin console
# Visit: https://login.tailscale.com/admin/machines
```

## 🔧 Development

### Adding New Commands

1. Create command script in `commands/`
2. Follow the naming convention: `cmd_commandname()`
3. Add help function: `show_commandname_help()`
4. Update main CLI dispatcher
5. Test thoroughly with state management

### Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature/amazing-feature`
3. Follow coding standards and add tests
4. Commit changes: `git commit -m 'Add amazing feature'`
5. Push branch: `git push origin feature/amazing-feature`
6. Open pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Support

- **Issues**: [GitHub Issues](https://github.com/jterrazz/jterrazz-infra/issues)
- **Documentation**: This README and inline help (`infra command --help`)
- **Status Monitoring**: `infra status` for comprehensive health checks

---

**Built with ❤️ for modern infrastructure management**
