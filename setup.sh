#!/bin/bash

# Portainer Server Setup Script
# This script automates the complete setup of Portainer with HTTPS reverse proxy
# Compatible with Cloudflare Full encryption mode

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables (modify as needed)
DOMAIN_NAME="${DOMAIN_NAME:-manager.example.com}"
PORTAINER_VERSION="${PORTAINER_VERSION:-latest}"
NGINX_CONFIG_PATH="/etc/nginx/sites-available/portainer"

# State tracking
STATE_FILE="/tmp/portainer-setup.state"
STEPS=("check_root" "update_system" "install_dependencies" "install_docker" "create_portainer_volume" "deploy_portainer" "configure_nginx")

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    return 1
}

# State management functions
mark_step_completed() {
    local step="$1"
    echo "$step" >> "$STATE_FILE"
    log "✓ Step '$step' completed"
}

is_step_completed() {
    local step="$1"
    [[ -f "$STATE_FILE" ]] && grep -q "^$step$" "$STATE_FILE"
}

skip_step() {
    local step="$1"
    warn "⏭ Skipping step '$step' (already completed)"
}

run_step() {
    local step="$1"
    local step_function="$2"
    
    if is_step_completed "$step"; then
        skip_step "$step"
        return 0
    fi
    
    log "🚀 Running step: $step"
    if $step_function; then
        mark_step_completed "$step"
        return 0
    else
        error "Step '$step' failed. Fix the issue and run the script again to continue from here."
        return 1
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        return 1
    fi
    return 0
}

# Update system packages
update_system() {
    log "Updating system packages..."
    if ! apt update; then
        error "Failed to update package lists"
        return 1
    fi
    if ! apt upgrade -y; then
        error "Failed to upgrade packages"
        return 1
    fi
    log "System updated successfully"
    return 0
}

# Install required packages
install_dependencies() {
    log "Installing required packages..."
    if ! apt install -y \
        curl \
        wget \
        gnupg \
        lsb-release \
        ca-certificates \
        apt-transport-https \
        software-properties-common \
        nginx \
        ssl-cert; then
        error "Failed to install required packages"
        return 1
    fi
    log "Dependencies installed successfully"
    return 0
}

# Install Docker
install_docker() {
    log "Installing Docker..."
    
    # Check if Docker is already installed
    if command -v docker &> /dev/null; then
        warn "Docker is already installed, skipping installation"
        return 0
    fi
    
    # Add Docker's official GPG key
    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
        error "Failed to add Docker GPG key"
        return 1
    fi
    
    # Add Docker repository
    if ! echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null; then
        error "Failed to add Docker repository"
        return 1
    fi
    
    # Update package index and install Docker
    if ! apt update; then
        error "Failed to update package index for Docker"
        return 1
    fi
    if ! apt install -y docker-ce docker-ce-cli containerd.io; then
        error "Failed to install Docker packages"
        return 1
    fi
    
    # Enable and start Docker service
    if ! systemctl enable docker; then
        error "Failed to enable Docker service"
        return 1
    fi
    if ! systemctl start docker; then
        error "Failed to start Docker service"
        return 1
    fi
    
    log "Docker installed successfully"
    return 0
}

# Create Portainer data volume
create_portainer_volume() {
    log "Creating Portainer data volume..."
    
    # Check if volume already exists
    if docker volume ls | grep -q portainer_data; then
        warn "Portainer data volume already exists, skipping creation"
        return 0
    fi
    
    if ! docker volume create portainer_data; then
        error "Failed to create Portainer data volume"
        return 1
    fi
    log "Portainer data volume created"
    return 0
}

# Deploy Portainer container
deploy_portainer() {
    log "Deploying Portainer container..."
    
    # Stop and remove existing container if it exists
    if docker ps -a --format 'table {{.Names}}' | grep -q '^portainer$'; then
        warn "Existing Portainer container found, removing..."
        docker stop portainer 2>/dev/null || true
        docker rm portainer 2>/dev/null || true
    fi
    
    # Deploy Portainer with HTTPS-only access via localhost
    if ! docker run -d \
        -p 127.0.0.1:9443:9443 \
        --name portainer \
        --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:${PORTAINER_VERSION}; then
        error "Failed to deploy Portainer container"
        return 1
    fi
    
    log "Portainer container deployed successfully"
    return 0
}

# Configure Nginx reverse proxy
configure_nginx() {
    log "Configuring Nginx reverse proxy..."
    
    # Create Nginx configuration for HTTPS-only access
    cat > ${NGINX_CONFIG_PATH} << NGINX_EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN_NAME};
    
    # Redirect all HTTP to HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN_NAME};
    
    # SSL configuration for Cloudflare Full encryption mode
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    
    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    
    location / {
        proxy_pass https://127.0.0.1:9443;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Increase timeouts for Portainer
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Handle SSL verification for internal connection
        proxy_ssl_verify off;
    }
}
NGINX_EOF

    # Enable the site
    ln -sf ${NGINX_CONFIG_PATH} /etc/nginx/sites-enabled/portainer
    
    # Remove default site if it exists
    rm -f /etc/nginx/sites-enabled/default
    
    # Test Nginx configuration
    if ! nginx -t; then
        error "Nginx configuration test failed"
        return 1
    fi
    
    # Enable and restart Nginx
    if ! systemctl enable nginx; then
        error "Failed to enable Nginx service"
        return 1
    fi
    if ! systemctl restart nginx; then
        error "Failed to restart Nginx service"
        return 1
    fi
    
    log "Nginx reverse proxy configured successfully"
    return 0
}

# Display final information
display_info() {
    echo
    log "🎉 Portainer setup completed successfully!"
    echo
    echo -e "${BLUE}📋 Setup Summary:${NC}"
    echo -e "  • Domain: ${DOMAIN_NAME}"
    echo -e "  • Portainer: Running with auto-restart"
    echo -e "  • Nginx: HTTPS-only reverse proxy configured"
    echo -e "  • SSL: Self-signed certificate for Cloudflare Full mode"
    echo
    echo -e "${BLUE}🌐 Access Information:${NC}"
    echo -e "  • URL: https://${DOMAIN_NAME}"
    echo -e "  • Initial setup timeout: 5 minutes"
    echo
    echo -e "${BLUE}☁️ Cloudflare Configuration Required:${NC}"
    echo -e "  1. Add AAAA record: ${DOMAIN_NAME} → $(curl -6 -s ifconfig.me 2>/dev/null || echo 'YOUR_IPV6_ADDRESS')"
    echo -e "  2. Set SSL/TLS mode to 'Full' (not 'Full (strict)')"
    echo -e "  3. Enable proxy (orange cloud) if desired"
    echo
    echo -e "${YELLOW}⚠️  Important: Complete Portainer setup within 5 minutes!${NC}"
    echo
}

# Main execution
main() {
    log "Starting Portainer setup script..."
    
    # Show resumption status
    if [[ -f "$STATE_FILE" ]]; then
        warn "Resuming setup from previous run..."
        warn "Completed steps: $(cat "$STATE_FILE" | tr '\n' ', ' | sed 's/,$//')"
    fi
    
    local failed_steps=0
    
    # Run each step with state tracking
    run_step "check_root" "check_root" || ((failed_steps++))
    run_step "update_system" "update_system" || ((failed_steps++))
    run_step "install_dependencies" "install_dependencies" || ((failed_steps++))
    run_step "install_docker" "install_docker" || ((failed_steps++))
    run_step "create_portainer_volume" "create_portainer_volume" || ((failed_steps++))
    run_step "deploy_portainer" "deploy_portainer" || ((failed_steps++))
    run_step "configure_nginx" "configure_nginx" || ((failed_steps++))
    
    if [[ $failed_steps -eq 0 ]]; then
        display_info
        log "🎉 Setup script completed successfully!"
        # Clean up state file on successful completion
        rm -f "$STATE_FILE"
    else
        error "Setup failed with $failed_steps error(s). Fix the issues and run the script again."
        error "The script will resume from where it left off."
        return 1
    fi
}

# Run main function
main "$@"