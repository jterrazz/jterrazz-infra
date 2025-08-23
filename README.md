# JTerrazz Infrastructure CLI

Professional infrastructure management CLI for deploying and managing containerized applications with HTTPS-only reverse proxy, SSL certificates, and security hardening.

## ✨ Features

- **🔧 Modular Architecture** - Clean separation of concerns with individual commands
- **🔐 HTTPS-Only** - Port 443 only, no HTTP exposure
- **🔒 SSL Certificates** - Automatic Let's Encrypt or self-signed certificates
- **🐳 Docker Management** - Container deployment and management
- **🌐 Reverse Proxy** - Nginx with security headers and optimizations
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

# 3. Deploy Portainer container manager
sudo infra portainer --deploy

# 4. Configure Nginx reverse proxy with SSL
sudo infra nginx --configure

# 5. Check overall status
infra status
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
  --remove               # Remove installation
  --status, -s           # Show status (default)
```

### Reverse Proxy & SSL

```bash
# Configure Nginx reverse proxy with SSL
sudo infra nginx [action]
  --configure, -c        # Setup reverse proxy and SSL
  --test, -t             # Test configuration
  --reload, -r           # Reload configuration
  --restart              # Restart service
  --renew-ssl --force-ssl # Force SSL certificate renewal
  --status, -s           # Show status (default)
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
│       └── portainer.conf.template
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

### For Private Networks

```bash
# Configure for private access only
export DOMAIN_NAME="manager.yourdomain.local"
export USE_REAL_SSL=false

# Run setup
sudo infra nginx --configure
```

### For Public Access with Let's Encrypt

```bash
# Configure for public access with real SSL
export DOMAIN_NAME="manager.yourdomain.com"
export USE_REAL_SSL=true

# Ensure DNS points to your server, then run
sudo infra nginx --configure
```

## 🔧 Configuration

### Environment Variables

| Variable            | Default                | Description                      |
| ------------------- | ---------------------- | -------------------------------- |
| `DOMAIN_NAME`       | `manager.jterrazz.com` | Domain name for SSL certificates |
| `USE_REAL_SSL`      | `true`                 | Use Let's Encrypt certificates   |
| `PORTAINER_VERSION` | `latest`               | Portainer version to deploy      |

### SSL Certificate Management

```bash
# Check certificate status
check-ssl-cert

# Manual certificate operations
certbot certificates                    # List certificates
certbot renew --dry-run                # Test renewal
sudo infra nginx --renew-ssl --force-ssl # Force renewal
journalctl -u certbot.timer            # View renewal logs
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

- **HTTPS-Only** - No HTTP port 80 exposure
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
```

## 🐛 Troubleshooting

### Common Issues

**SSL Certificate Issues:**

```bash
# Test domain resolution
nslookup manager.yourdomain.com

# Check certificate status
check-ssl-cert

# Force certificate renewal
sudo infra nginx --renew-ssl --force-ssl
```

**Docker Issues:**

```bash
# Restart Docker service
sudo systemctl restart docker

# Check container status
infra status --docker

# Redeploy Portainer
sudo infra portainer --remove
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
