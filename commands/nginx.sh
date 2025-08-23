#!/bin/bash

# JTerrazz Infrastructure - Nginx Command
# Configure Nginx reverse proxy with SSL

# Source required libraries (paths set by main infra script)
# If running standalone, set up paths
if [[ -z "${LIB_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
    source "$LIB_DIR/common.sh"
fi
source "$LIB_DIR/ssl.sh"

readonly NGINX_CONFIG_PATH="/etc/nginx/sites-available/portainer"
readonly NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/portainer"

# Disable HTTP services for HTTPS-only setup
disable_http_services() {
    log "Ensuring HTTPS-only setup (no port 80 services)..."
    
    # Check what's listening on port 80
    local port_80_service
    port_80_service=$(netstat -tlnp 2>/dev/null | grep ':80 ' | head -1)
    
    if [[ -n "$port_80_service" ]]; then
        warn "Service detected on port 80: $port_80_service"
        
        # Common services that might be on port 80
        local services_to_stop=("apache2" "httpd" "lighttpd")
        
        for service in "${services_to_stop[@]}"; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                log "Stopping and disabling $service (HTTPS-only setup)"
                systemctl stop "$service" || warn "Failed to stop $service"
                systemctl disable "$service" || warn "Failed to disable $service"
            fi
        done
        
        # Check and remove default Nginx configurations that listen on port 80
        if [[ -f /etc/nginx/sites-enabled/default ]]; then
            rm -f /etc/nginx/sites-enabled/default
            log "Removed default Nginx site"
        fi
        
        # Check for any remaining sites listening on port 80
        if [[ -d /etc/nginx/sites-enabled ]]; then
            for site in /etc/nginx/sites-enabled/*; do
                if [[ -f "$site" ]] && grep -q "listen.*80" "$site" 2>/dev/null; then
                    local site_name=$(basename "$site")
                    warn "Found site listening on port 80: $site_name"
                    # Comment out port 80 listen directives
                    sed -i 's/^\s*listen.*80/# &/' "$site"
                    log "Disabled port 80 listening in $site_name"
                fi
            done
        fi
        
        # Check main nginx.conf for port 80 configurations
        if [[ -f /etc/nginx/nginx.conf ]] && grep -q "listen.*80" /etc/nginx/nginx.conf 2>/dev/null; then
            warn "Found port 80 configuration in main nginx.conf"
        fi
        
        # Reload Nginx to apply changes
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx || warn "Failed to reload Nginx"
            log "Reloaded Nginx to apply HTTPS-only configuration"
        fi
        
        # Ensure UFW blocks port 80 if firewall is active
        if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
            ufw delete allow 80/tcp 2>/dev/null || true
            ufw delete allow http 2>/dev/null || true
            log "Removed port 80 from UFW firewall rules"
        fi
        
        # Double-check after cleanup
        sleep 2
        port_80_service=$(netstat -tlnp 2>/dev/null | grep ':80 ' | head -1)
        if [[ -n "$port_80_service" ]]; then
            warn "Port 80 still in use after cleanup: $port_80_service"
            
            # Last resort: create a minimal nginx configuration
            if [[ "$port_80_service" == *nginx* ]]; then
                warn "Attempting to create minimal HTTPS-only Nginx configuration"
                create_minimal_nginx_config
                systemctl reload nginx || warn "Failed to reload Nginx with minimal config"
                sleep 1
                port_80_service=$(netstat -tlnp 2>/dev/null | grep ':80 ' | head -1)
                if [[ -z "$port_80_service" ]]; then
                    log "✅ Port 80 closed with minimal configuration"
                else
                    warn "Manual investigation required - check: nginx -T | grep 'listen.*80'"
                fi
            else
                warn "Manual investigation may be required"
            fi
        else
            log "✅ Port 80 successfully closed - HTTPS-only setup confirmed"
        fi
    else
        log "✅ No services on port 80 - HTTPS-only setup confirmed"
    fi
}

# Create minimal HTTPS-only nginx configuration
create_minimal_nginx_config() {
    local backup_dir="/etc/nginx/backup-$(date +%Y%m%d-%H%M%S)"
    
    # Backup current configuration
    mkdir -p "$backup_dir"
    cp -r /etc/nginx/sites-enabled "$backup_dir/" 2>/dev/null || true
    cp /etc/nginx/nginx.conf "$backup_dir/" 2>/dev/null || true
    log "Nginx configuration backed up to $backup_dir"
    
    # Disable all sites temporarily
    if [[ -d /etc/nginx/sites-enabled ]]; then
        rm -f /etc/nginx/sites-enabled/*
    fi
    
    # Create a minimal main configuration if needed
    cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    gzip on;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    log "Created minimal HTTPS-only Nginx configuration"
}

# Repair broken nginx configuration
repair_nginx_config() {
    log "Repairing Nginx configuration..."
    
    # Reset state to force regeneration
    if [[ -f /var/lib/jterrazz-infra/state ]]; then
        log "Resetting nginx configuration state..."
        sed -i '/nginx_configuration/d' /var/lib/jterrazz-infra/state
        sed -i '/ssl_certificates/d' /var/lib/jterrazz-infra/state
        sed -i '/nginx_validation/d' /var/lib/jterrazz-infra/state
        log "State reset - configuration will be regenerated"
    fi
    
    # Remove broken configuration files
    if [[ -f /etc/nginx/sites-enabled/portainer ]]; then
        rm -f /etc/nginx/sites-enabled/portainer
        log "Removed broken site configuration"
    fi
    
    if [[ -f /etc/nginx/sites-available/portainer ]]; then
        rm -f /etc/nginx/sites-available/portainer  
        log "Removed broken available site configuration"
    fi
    
    # Force regeneration with current architecture (API-ready)
    log "Regenerating Nginx configuration..."
    configure_nginx_basic || return 1
    validate_nginx_config || return 1
    manage_nginx_service restart || return 1
    
    log "✅ Nginx configuration repaired successfully"
    return 0
}

# Configure basic Nginx setup (ready for APIs, no management tools)
configure_nginx_basic() {
    log "Configuring basic Nginx setup for future API services..."
    
    # Generate SSL certificates first  
    generate_ssl_certificates "$DOMAIN_NAME" || return 1
    
    # Ensure HTTPS-only setup (no port 80 services)
    disable_http_services
    
    # Create basic nginx configuration (no sites enabled initially)
    create_basic_nginx_site
    
    log "Basic Nginx configuration created successfully"
    return 0
}

# Create basic nginx site configuration (placeholder for APIs)
create_basic_nginx_site() {
    log "Creating basic site configuration..."
    
    # Determine SSL certificate paths
    local ssl_cert ssl_key
    read -r ssl_cert ssl_key < <(get_ssl_cert_paths "$DOMAIN_NAME")
    
    # Create a basic "coming soon" site for port 443
    cat > "$NGINX_CONFIG_PATH" << EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;
    
    # SSL configuration
    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    
    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Hide nginx version
    server_tokens off;
    
    # Placeholder for API services
    location / {
        return 200 '{"status":"ready","message":"Nginx configured - ready for API services"}';
        add_header Content-Type application/json;
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

    # Enable the site
    ln -sf "$NGINX_CONFIG_PATH" "$NGINX_ENABLED_PATH"
    
    # Remove default site if it exists
    rm -f /etc/nginx/sites-enabled/default
    
    log "Basic site configuration created"
}

# Show basic setup information
show_nginx_basic_info() {
    echo "🎉 Nginx setup completed successfully!"
    echo
    echo -e "${BLUE}📋 Configuration Summary:${NC}"
    echo "  • Domain: $DOMAIN_NAME"
    echo "  • SSL: Let's Encrypt certificate (trusted, no browser warnings)"
    echo "  • Port 443: Ready for API services"
    echo "  • Management tools: Private Tailscale access only"
    echo
    echo -e "${BLUE}🌐 Access Information:${NC}"
    echo "  • APIs (future): https://$DOMAIN_NAME"
    echo "  • Portainer (management): https://$DOMAIN_NAME:9443 (Tailscale only)"
    echo
    echo -e "${BLUE}🏠 DNS Configuration:${NC}"
    echo "  • DNS A record: $DOMAIN_NAME → YOUR_TAILSCALE_IP (100.x.x.x)"
    echo "  • Management tools accessible via Tailscale network only"
    echo "  • Port 443 ready for public API services"
    echo
    if is_tailscale_connected; then
        local ts_ip
        ts_ip=$(get_tailscale_ip)
        if [[ -n "$ts_ip" ]]; then
            echo -e "${GREEN}✅ Tailscale IP detected: $ts_ip${NC}"
            echo "Management access: https://$DOMAIN_NAME:9443"
        fi
    else
        echo -e "${YELLOW}⚠️  Tailscale not connected. Run: infra tailscale --connect${NC}"
    fi
    echo
    echo -e "${BLUE}🚀 Next Steps:${NC}"
    echo "  • Management tools: Access Portainer via Tailscale network"
    echo "  • API services: Configure reverse proxy rules as needed"
    echo "  • Port 443 is ready for your public services"
}



# Validate Nginx configuration
validate_nginx_config() {
    log "Validating Nginx configuration..."
    
    if ! nginx -t; then
        error "Nginx configuration validation failed"
        return 1
    fi
    
    log "Nginx configuration is valid"
    return 0
}

# Setup SSL certificates and renewal
setup_ssl_certificates() {
    generate_ssl_certificates "$DOMAIN_NAME" || return 1
    setup_certificate_renewal "$DOMAIN_NAME" || return 1
    create_ssl_monitoring_script "$DOMAIN_NAME" || return 1
    return 0
}

# Start/restart Nginx service
manage_nginx_service() {
    local action="$1"
    
    case "$action" in
        start)
            log "Starting Nginx service..."
            systemctl enable nginx
            systemctl start nginx
            ;;
        restart)
            log "Restarting Nginx service..."
            systemctl restart nginx
            ;;
        reload)
            log "Reloading Nginx configuration..."
            systemctl reload nginx
            ;;
        stop)
            log "Stopping Nginx service..."
            systemctl stop nginx
            ;;
        *)
            error "Unknown nginx action: $action"
            return 1
            ;;
    esac
    
    if [[ $? -eq 0 ]]; then
        log "Nginx $action completed successfully"
    else
        error "Failed to $action Nginx"
        return 1
    fi
    
    return 0
}

# Show Nginx status and configuration
show_nginx_status() {
    print_section "Nginx Status"
    
    # Service status
    if is_service_running nginx; then
        echo "✅ Nginx service is running"
        if is_service_enabled nginx; then
            echo "✅ Nginx service is enabled (auto-start)"
        else
            echo "⚠️  Nginx service is not enabled"
        fi
    else
        echo "❌ Nginx service is not running"
        if is_service_enabled nginx; then
            echo "⚠️  Nginx service is enabled but not running"
        else
            echo "❌ Nginx service is not enabled"
        fi
    fi
    
    # Configuration status
    echo
    echo "Configuration:"
    if [[ -f "$NGINX_CONFIG_PATH" ]]; then
        echo "  ✅ Portainer configuration exists"
        
        if [[ -L "$NGINX_ENABLED_PATH" ]]; then
            echo "  ✅ Site is enabled"
        else
            echo "  ❌ Site is not enabled"
        fi
        
        # Validate configuration
        if nginx -t &>/dev/null; then
            echo "  ✅ Configuration is valid"
        else
            echo "  ❌ Configuration has errors"
        fi
    else
        echo "  ❌ Portainer configuration not found"
    fi
    
    # SSL status
    echo
    echo "SSL Certificates:"
    if has_certificates "$DOMAIN_NAME"; then
        echo "  ✅ Let's Encrypt certificates for $DOMAIN_NAME"
        local days_remaining
        days_remaining=$(get_cert_expiry_days "$DOMAIN_NAME")
        echo "  📅 Days until expiry: $days_remaining"
        
        if [[ "$days_remaining" -lt 30 ]]; then
            echo "  ⚠️  Certificate expires soon!"
        fi
    else
        echo "  ⚠️  Using self-signed certificates"
        echo "     Domain: $DOMAIN_NAME"
    fi
    
    # Port status
    echo
    echo "Network:"
    if is_port_open 443; then
        echo "  ✅ Port 443 (HTTPS) is listening"
    else
        echo "  ❌ Port 443 (HTTPS) is not listening"
    fi
    
    if is_port_open 80; then
        echo "  ⚠️  Port 80 (HTTP) is listening (should be blocked)"
    else
        echo "  ✅ Port 80 (HTTP) is not listening"
    fi
    
    # Domain accessibility
    echo
    echo "Domain Access:"
    if test_domain_resolution "$DOMAIN_NAME"; then
        echo "  ✅ Domain $DOMAIN_NAME resolves"
        
        # Test HTTPS accessibility
        if curl -k -s --connect-timeout 5 "https://$DOMAIN_NAME" &>/dev/null; then
            echo "  ✅ HTTPS access to $DOMAIN_NAME is working"
        else
            echo "  ❌ HTTPS access to $DOMAIN_NAME failed"
        fi
    else
        echo "  ❌ Domain $DOMAIN_NAME does not resolve"
        echo "     Configure DNS: $DOMAIN_NAME → $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
    fi
}

# Test Nginx configuration
test_nginx() {
    print_section "Nginx Configuration Test"
    
    log "Testing Nginx configuration..."
    
    if nginx -t; then
        log "✅ Nginx configuration test passed"
        
        # Show configuration details
        echo
        echo "Active Configuration:"
        if [[ -f "$NGINX_CONFIG_PATH" ]]; then
            echo "  • Configuration file: $NGINX_CONFIG_PATH"
            echo "  • Domain: $DOMAIN_NAME"
            
            # Extract SSL certificate paths
            local cert_path key_path
            cert_path=$(grep "ssl_certificate " "$NGINX_CONFIG_PATH" | head -1 | awk '{print $2}' | tr -d ';')
            key_path=$(grep "ssl_certificate_key " "$NGINX_CONFIG_PATH" | head -1 | awk '{print $2}' | tr -d ';')
            
            echo "  • SSL certificate: $cert_path"
            echo "  • SSL key: $key_path"
            
            # Check certificate validity
            if [[ -f "$cert_path" ]]; then
                echo "  ✅ SSL certificate file exists"
            else
                echo "  ❌ SSL certificate file missing"
            fi
            
            if [[ -f "$key_path" ]]; then
                echo "  ✅ SSL key file exists"
            else
                echo "  ❌ SSL key file missing"
            fi
        fi
        
        return 0
    else
        error "❌ Nginx configuration test failed"
        echo
        echo "To see detailed errors, run: nginx -t"
        return 1
    fi
}



# Main nginx command
cmd_nginx() {
    local action="status"
    local force_ssl_renewal=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --configure|-c)
                action="configure"
                shift
                ;;
            --test|-t)
                action="test"
                shift
                ;;
            --reload|-r)
                action="reload"
                shift
                ;;
            --restart)
                action="restart"
                shift
                ;;
            --uninstall)
                action="uninstall"
                shift
                ;;
            --renew-ssl)
                action="renew-ssl"
                shift
                ;;
            --repair|--fix)
                action="repair"
                shift
                ;;

            --force-ssl)
                force_ssl_renewal=true
                shift
                ;;
            --status|-s)
                action="status"
                shift
                ;;
            --help|-h)
                show_nginx_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_nginx_help
                exit 1
                ;;
        esac
    done
    
    # Validate system for non-status operations
    if [[ "$action" != "status" && "$action" != "test" ]]; then
        check_root || exit 1
    fi
    
    # Execute action
    case "$action" in
        configure)
            print_header "Nginx Configuration"
            
            # Check prerequisites
            if ! command -v nginx &> /dev/null; then
                error "Nginx is not installed or missing"
                error "This may happen if the installation was incomplete"
                error "Fix: sudo infra install  (will detect and reinstall missing components)"
                exit 1
            fi
            
            log "Setting up Nginx for future API services (management tools remain private)"
            
            # Configure nginx basic setup (no Portainer reverse proxy)
            run_step "ssl_certificates" "setup_ssl_certificates" || exit 1
            run_step "nginx_basic_setup" "configure_nginx_basic" || exit 1
            run_step "nginx_validation" "validate_nginx_config" || exit 1
            run_step "nginx_service" "manage_nginx_service restart" || exit 1
            
            print_section "Configuration Summary"
            log "Nginx configured successfully - ready for API services"
            echo
            show_nginx_basic_info
            ;;
        test)
            test_nginx || exit 1
            ;;
        reload)
            check_root || exit 1
            manage_nginx_service reload || exit 1
            ;;
        restart)
            check_root || exit 1
            manage_nginx_service restart || exit 1
            ;;
        uninstall)
            check_root || exit 1
            print_header "Nginx Complete Uninstallation"
            echo
            echo "This will completely remove Nginx and all its data:"
            echo "  • Stop and disable Nginx service"
            echo "  • Remove Nginx package and dependencies"
            echo "  • Delete all configuration files"
            echo "  • Remove SSL certificates"
            echo "  • Remove firewall rules"
            echo "  • Clean up all related data"
            echo
            read -p "Are you sure you want to completely uninstall Nginx? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                uninstall_nginx_complete || exit 1
            else
                log "Uninstallation cancelled"
            fi
            ;;
        renew-ssl)
            check_root || exit 1
            print_header "SSL Certificate Renewal"
            if [[ "$force_ssl_renewal" == "true" ]]; then
                force_certificate_renewal "$DOMAIN_NAME" || exit 1
            else
                error "Use --force-ssl to force certificate renewal"
                exit 1
            fi
            ;;
        repair|fix)
            check_root || exit 1
            print_header "Nginx Configuration Repair"
            repair_nginx_config
            ;;

        status)
            show_nginx_status
            ;;
    esac
}

# Show final configuration information
show_final_info() {
    local ssl_status
    
    if has_certificates "$DOMAIN_NAME"; then
        ssl_status="Let's Encrypt SSL certificate (trusted, no browser warnings)"
    else
        ssl_status="Let's Encrypt SSL certificate (pending generation)"
    fi
    
    echo "🎉 Setup completed successfully!"
    echo
    echo -e "${BLUE}📋 Configuration Summary:${NC}"
    echo "  • Domain: $DOMAIN_NAME"
    echo "  • Nginx: HTTPS-only on port 443 (no HTTP port 80)"
    echo "  • SSL: $ssl_status"
    echo "  • Proxy: Portainer on https://127.0.0.1:9443"
    echo
    echo -e "${BLUE}🌐 Access Information:${NC}"
    echo "  • URL: https://$DOMAIN_NAME"
    echo "  • Initial Portainer setup timeout: 5 minutes"
    echo
    echo -e "${BLUE}🏠 DNS Configuration for Private Access:${NC}"
    echo "  • Add DNS A record: $DOMAIN_NAME → YOUR_TAILSCALE_IP (100.x.x.x)"
    echo "  • Let's Encrypt certificates via DNS challenge (no browser warnings)"
    echo "  • Access only via Tailscale private network"
    echo "  • Port 443 only (no port 80 needed)"
    echo "  • Get Tailscale IP with: tailscale ip -4"
    echo
    if is_tailscale_connected; then
        local ts_ip
        ts_ip=$(get_tailscale_ip)
        if [[ -n "$ts_ip" ]]; then
            echo -e "${GREEN}✅ Tailscale IP detected: $ts_ip${NC}"
            echo "Point your DNS A record: $DOMAIN_NAME → $ts_ip"
        fi
    else
        echo -e "${YELLOW}⚠️  Tailscale not connected. Run: infra tailscale --connect${NC}"
    fi
    echo
    
    echo -e "${BLUE}📊 Certificate Management:${NC}"
    echo "  • Check status: check-ssl-cert"
    echo "  • Let's Encrypt certificates via manual DNS challenge"
    echo "  • No browser warnings - trusted certificates"
    echo "  • Manual renewal required before expiry"
    if has_certificates "$DOMAIN_NAME"; then
        echo "  • Certificates expire every 90 days"
        echo "  • Renew with: sudo infra nginx --configure"
    fi
    echo
    
    echo -e "${YELLOW}⚠️  Important: Complete Portainer setup within 5 minutes!${NC}"
}

# Complete uninstallation of Nginx
uninstall_nginx_complete() {
    log "Starting complete Nginx uninstallation..."
    
    # Stop and disable Nginx service
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log "Stopping Nginx service..."
        systemctl stop nginx || warn "Failed to stop Nginx service"
    fi
    
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        log "Disabling Nginx service..."
        systemctl disable nginx || warn "Failed to disable Nginx service"
    fi
    
    # Remove Nginx package and dependencies
    log "Removing Nginx package and dependencies..."
    if command -v apt &> /dev/null; then
        apt remove --purge -y nginx nginx-common nginx-core nginx-full 2>/dev/null || warn "Failed to remove Nginx packages"
        apt autoremove -y 2>/dev/null || true
    fi
    
    # Remove all Nginx configuration files
    log "Removing Nginx configuration files..."
    rm -rf /etc/nginx 2>/dev/null || warn "Failed to remove /etc/nginx"
    rm -rf /var/log/nginx 2>/dev/null || warn "Failed to remove /var/log/nginx"
    rm -rf /var/lib/nginx 2>/dev/null || warn "Failed to remove /var/lib/nginx"
    rm -rf /usr/share/nginx 2>/dev/null || warn "Failed to remove /usr/share/nginx"
    
    # Remove SSL certificates (Let's Encrypt)
    log "Removing SSL certificates..."
    if [[ -d /etc/letsencrypt ]]; then
        echo
        echo "Found Let's Encrypt SSL certificates"
        read -p "Do you want to remove SSL certificates as well? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Stop certbot renewal timer
            systemctl stop certbot.timer 2>/dev/null || true
            systemctl disable certbot.timer 2>/dev/null || true
            
            # Remove certbot and certificates
            apt remove --purge -y certbot python3-certbot-dns-cloudflare 2>/dev/null || true
            rm -rf /etc/letsencrypt 2>/dev/null || warn "Failed to remove /etc/letsencrypt"
            rm -rf /var/lib/letsencrypt 2>/dev/null || warn "Failed to remove /var/lib/letsencrypt"
            rm -rf /var/log/letsencrypt 2>/dev/null || warn "Failed to remove /var/log/letsencrypt"
            rm -f /usr/local/bin/check-ssl-cert 2>/dev/null || true
            
            log "SSL certificates and certbot removed"
        else
            log "Keeping SSL certificates (can be reused)"
        fi
    fi
    
    # Remove firewall rules
    log "Cleaning up firewall rules..."
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow 80/tcp 2>/dev/null || true
        ufw delete allow 443/tcp 2>/dev/null || true
        ufw delete allow 'Nginx Full' 2>/dev/null || true
        ufw delete allow 'Nginx HTTP' 2>/dev/null || true
        ufw delete allow 'Nginx HTTPS' 2>/dev/null || true
        log "Removed Nginx UFW firewall rules"
    fi
    
    # Remove systemd service files
    log "Cleaning up systemd configurations..."
    rm -f /etc/systemd/system/nginx.service 2>/dev/null || true
    rm -f /lib/systemd/system/nginx.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    
    # Remove our Nginx configuration template
    rm -f /opt/jterrazz-infra/config/nginx/portainer.conf.template 2>/dev/null || true
    
    # Remove any backup configurations we created
    find /etc/nginx/backup-* -maxdepth 0 -type d -exec rm -rf {} \; 2>/dev/null || true
    
    # Remove Nginx state from our tracking
    if [[ -f /var/lib/jterrazz-infra/state ]]; then
        sed -i '/nginx_/d' /var/lib/jterrazz-infra/state 2>/dev/null || true
        sed -i '/ssl_certificates/d' /var/lib/jterrazz-infra/state 2>/dev/null || true
    fi
    
    # Clean up package cache
    apt update 2>/dev/null || true
    
    log "✅ Nginx completely uninstalled"
    log "All Nginx components, configurations, and optionally SSL certificates have been removed"
    log "You can reinstall with: infra install && infra nginx --configure"
    
    return 0
}

# Show nginx command help
show_nginx_help() {
    echo "Usage: infra nginx [action] [options]"
    echo
    echo "Configure and manage Nginx reverse proxy with SSL"
    echo
    echo "Actions:"
    echo "  --configure, -c      Configure Nginx reverse proxy and SSL certificates"
    echo "  --test, -t           Test Nginx configuration"
    echo "  --reload, -r         Reload Nginx configuration"
    echo "  --restart            Restart Nginx service"
    echo "  --uninstall          Complete uninstallation (removes package, configs, and optionally SSL)"
    echo "  --renew-ssl          Force SSL certificate renewal (requires --force-ssl)"
    echo "  --repair, --fix      Repair broken Nginx configuration (reset and regenerate)"

    echo "  --status, -s         Show Nginx status and configuration (default)"
    echo "  --help, -h           Show this help message"
    echo
    echo "Options:"
    echo "  --force-ssl          Force SSL certificate renewal (use with --renew-ssl)"
    echo
    echo "Examples:"
    echo "  infra nginx                          # Show status"
    echo "  infra nginx --configure              # Setup reverse proxy with SSL"
    echo "  infra nginx --repair                 # Fix broken configuration"

    echo "  infra nginx --test                   # Test configuration"
    echo "  infra nginx --renew-ssl --force-ssl  # Force certificate renewal"
}
