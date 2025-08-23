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
    
    # Force regeneration
    log "Regenerating Nginx configuration..."
    configure_nginx_portainer || return 1
    validate_nginx_config || return 1
    manage_nginx_service restart || return 1
    
    log "✅ Nginx configuration repaired successfully"
    return 0
}

# Configure Nginx for Portainer with SSL
configure_nginx_portainer() {
    log "Configuring Nginx reverse proxy for Portainer..."
    
    # Generate SSL certificates first
    generate_ssl_certificates "$DOMAIN_NAME" || return 1
    
    # Determine which SSL certificates to use
    local ssl_cert ssl_key
    read -r ssl_cert ssl_key < <(get_ssl_cert_paths "$DOMAIN_NAME")
    
    if has_certificates "$DOMAIN_NAME"; then
        log "Using Let's Encrypt certificates for $DOMAIN_NAME"
    else
        log "Using self-signed certificates for $DOMAIN_NAME"
    fi
    
    # Generate Nginx configuration from template
    local template_path="${CLI_DIR}/config/nginx/portainer.conf.template"
    
    if [[ ! -f "$template_path" ]]; then
        error "Nginx configuration template not found: $template_path"
        return 1
    fi
    
    # Replace template variables
    sed \
        -e "s|__DOMAIN_NAME__|$DOMAIN_NAME|g" \
        -e "s|__SSL_CERT__|$ssl_cert|g" \
        -e "s|__SSL_KEY__|$ssl_key|g" \
        "$template_path" > "$NGINX_CONFIG_PATH"
    
    if [[ $? -ne 0 ]]; then
        error "Failed to generate Nginx configuration"
        return 1
    fi
    
    # Enable the site
    ln -sf "$NGINX_CONFIG_PATH" "$NGINX_ENABLED_PATH"
    
    # Remove default site if it exists
    rm -f /etc/nginx/sites-enabled/default
    
    # Ensure no HTTP (port 80) services are running - HTTPS-only setup
    disable_http_services
    
    log "Nginx configuration generated successfully"
    return 0
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

# Remove Nginx configuration
remove_nginx_config() {
    log "Removing Nginx configuration for Portainer..."
    
    # Disable site
    if [[ -L "$NGINX_ENABLED_PATH" ]]; then
        rm "$NGINX_ENABLED_PATH"
        log "Site disabled"
    fi
    
    # Remove configuration file
    if [[ -f "$NGINX_CONFIG_PATH" ]]; then
        rm "$NGINX_CONFIG_PATH"
        log "Configuration file removed"
    fi
    
    # Reload nginx if running
    if is_service_running nginx; then
        systemctl reload nginx
        log "Nginx configuration reloaded"
    fi
    
    log "Nginx configuration removed successfully"
    return 0
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
            --remove)
                action="remove"
                shift
                ;;
            --renew-ssl)
                action="renew-ssl"
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
                error "Nginx is not installed. Run: infra install"
                exit 1
            fi
            
            if ! is_container_running portainer; then
                warn "Portainer container is not running"
                warn "Make sure to deploy Portainer first: infra portainer --deploy"
            fi
            
            # Configure nginx and SSL
            run_step "ssl_certificates" "setup_ssl_certificates" || exit 1
            run_step "nginx_configuration" "configure_nginx_portainer" || exit 1
            run_step "nginx_validation" "validate_nginx_config" || exit 1
            run_step "nginx_service" "manage_nginx_service restart" || exit 1
            
            print_section "Configuration Summary"
            log "Nginx reverse proxy configured successfully"
            echo
            show_final_info
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
        remove)
            check_root || exit 1
            print_header "Nginx Configuration Removal"
            remove_nginx_config || exit 1
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
        secure|https-only)
            check_root || exit 1
            print_header "HTTPS-Only Security Check"
            disable_http_services
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
    echo "  --remove             Remove Nginx configuration for Portainer"
    echo "  --renew-ssl          Force SSL certificate renewal (requires --force-ssl)"
    echo "  --repair, --fix      Repair broken Nginx configuration (reset and regenerate)"
    echo "  --secure             Ensure HTTPS-only setup (disable port 80 services)"
    echo "  --https-only         Alias for --secure"
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
    echo "  infra nginx --secure                 # Ensure HTTPS-only (disable port 80)"
    echo "  infra nginx --test                   # Test configuration"
    echo "  infra nginx --renew-ssl --force-ssl  # Force certificate renewal"
}
