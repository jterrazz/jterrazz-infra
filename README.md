# Portainer Server Setup Script

Automated setup script for Portainer with HTTPS reverse proxy, optimized for Cloudflare Full encryption mode.

## Features

- **Resumable execution** - continues from where it left off if interrupted
- **Complete Docker setup** - installs and configures Docker if not present
- **HTTPS-only access** - Nginx reverse proxy with SSL termination
- **Cloudflare compatible** - works with Full encryption mode
- **Production ready** - includes security headers and proper SSL configuration

## Prerequisites

- Ubuntu/Debian server with root access
- Domain name pointed to your server's IP
- Cloudflare account (optional but recommended)

## Quick Start

```bash
# Clone and make executable
chmod +x setup.sh

# Configure domain (optional - defaults to manager.example.com)
export DOMAIN_NAME="your-domain.com"

# Run setup
sudo ./setup.sh
```

## Configuration

Set environment variables before running:

```bash
export DOMAIN_NAME="manager.yourdomain.com"    # Your domain
export PORTAINER_VERSION="latest"              # Portainer version
```

## Resumable Execution

The script automatically tracks progress and can resume from failures:

- **State tracking**: `/tmp/portainer-setup.state` stores completed steps
- **Smart recovery**: Skips completed steps on subsequent runs
- **Clear feedback**: Shows what's been completed vs what's running

```bash
# If script fails, just run it again
sudo ./setup.sh
# → Automatically resumes from failure point
```

## Setup Steps

1. **System update** - updates package lists and installed packages
2. **Dependencies** - installs curl, nginx, ssl-cert, and other requirements
3. **Docker installation** - adds Docker repository and installs Docker CE
4. **Portainer volume** - creates persistent data storage
5. **Portainer deployment** - runs container with restart policy
6. **Nginx configuration** - sets up HTTPS reverse proxy

## Post-Installation

### Cloudflare Configuration

1. **DNS Record**: Add A/AAAA record pointing to your server
2. **SSL Mode**: Set to "Full" (not "Full (strict)")
3. **Proxy**: Enable orange cloud if desired

### Initial Setup

- Access: `https://your-domain.com`
- **Important**: Complete initial Portainer setup within 5 minutes
- Create admin account on first visit

## Troubleshooting

**Script fails at Docker installation?**

```bash
# Check if GPG key download failed
curl -fsSL https://download.docker.com/linux/ubuntu/gpg
```

**Nginx configuration test fails?**

```bash
sudo nginx -t
# Check syntax errors in generated config
```

**Portainer not accessible?**

```bash
# Check container status
sudo docker ps | grep portainer

# Check nginx status
sudo systemctl status nginx
```

**Clean slate restart:**

```bash
# Remove state file to start over
sudo rm -f /tmp/portainer-setup.state
```

## Architecture

```
Internet → Cloudflare → Nginx (443) → Portainer (9443)
```

- **External**: HTTPS traffic via Cloudflare
- **Internal**: Nginx proxies to localhost:9443
- **Security**: Portainer only accessible via reverse proxy

## License

MIT License - use freely for personal and commercial projects.
