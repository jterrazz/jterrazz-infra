#!/bin/bash

# JTerrazz Infrastructure - SSL Certificate Management
# Functions for managing Let's Encrypt SSL certificates

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Install certbot and dependencies
install_certbot() {
    log "Installing certbot and nginx plugin..."
    
    if ! apt install -y certbot python3-certbot-nginx; then
        error "Failed to install certbot"
        return 1
    fi
    
    log "Certbot installed successfully"
    return 0
}

# Check if certificates exist for domain
has_certificates() {
    local domain="$1"
    [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]
}

# Generate SSL certificates using Let's Encrypt
generate_ssl_certificates() {
    local domain="$1"
    
    if [[ "$USE_REAL_SSL" == "true" ]]; then
        warn "Let's Encrypt certificates requested but not recommended for private Tailscale networks"
        warn "Domain likely points to Tailscale private IP which Let's Encrypt cannot validate"
        warn "Continuing with self-signed certificates for secure private access"
        warn "Set USE_REAL_SSL=false to suppress this warning"
    fi
    
    log "Using self-signed certificates for private network access"
    log "Certificates will be generated automatically by system SSL packages"
    return 0
}

# Setup certificate renewal automation
setup_certificate_renewal() {
    local domain="$1"
    
    log "Self-signed certificates do not require renewal"
    log "Certificates are valid for extended periods and regenerated as needed"
    return 0
}

# Create certificate monitoring script
create_ssl_monitoring_script() {
    local domain="$1"
    
    cat > /usr/local/bin/check-ssl-cert << MONITOR_EOF
#!/bin/bash
DOMAIN="$domain"
CERT_PATH="/etc/ssl/certs/ssl-cert-snakeoil.pem"

echo "=== SSL Certificate Status for \$DOMAIN ==="
echo "Certificate type: Self-signed (private network)"
echo "Certificate path: \$CERT_PATH"
echo

if [[ -f "\$CERT_PATH" ]]; then
    echo "✅ Self-signed certificate is available"
    echo "🔒 Provides encryption for private Tailscale network"
    echo "⚠️  Browser will show security warning (expected for self-signed)"
    echo
    echo "Certificate details:"
    openssl x509 -in "\$CERT_PATH" -noout -subject -issuer -dates 2>/dev/null || echo "Unable to read certificate details"
else
    echo "❌ Self-signed certificate not found"
    echo "Run: sudo infra nginx --configure"
fi

echo
echo "=== Tailscale Network Status ==="
if command -v tailscale &> /dev/null && tailscale status --json &>/dev/null; then
    local ts_ip=\$(tailscale ip -4 2>/dev/null)
    echo "✅ Tailscale connected: \$ts_ip"
    echo "🌐 Access URL: https://\$DOMAIN (via Tailscale)"
else
    echo "❌ Tailscale not connected"
    echo "Run: sudo infra tailscale --connect"
fi
MONITOR_EOF
    
    chmod +x /usr/local/bin/check-ssl-cert
    log "Created certificate monitoring script: /usr/local/bin/check-ssl-cert"
}

# Get SSL certificate paths for nginx configuration
get_ssl_cert_paths() {
    local domain="$1"
    
    if has_certificates "$domain"; then
        echo "/etc/letsencrypt/live/$domain/fullchain.pem"
        echo "/etc/letsencrypt/live/$domain/privkey.pem"
    else
        echo "/etc/ssl/certs/ssl-cert-snakeoil.pem"
        echo "/etc/ssl/private/ssl-cert-snakeoil.key"
    fi
}

# Force certificate renewal
force_certificate_renewal() {
    local domain="$1"
    
    if [[ "$USE_REAL_SSL" != "true" ]]; then
        error "Real SSL is disabled (USE_REAL_SSL=false)"
        return 1
    fi
    
    if ! has_certificates "$domain"; then
        error "No certificates found for $domain. Run certificate generation first."
        return 1
    fi
    
    log "Forcing certificate renewal for $domain..."
    
    # Stop nginx temporarily
    if is_service_running nginx; then
        systemctl stop nginx
        local restart_nginx=true
    fi
    
    # Force renewal
    if certbot renew --force-renewal --cert-name "$domain"; then
        log "Certificate renewal completed successfully"
    else
        error "Certificate renewal failed"
        [[ "${restart_nginx:-}" == "true" ]] && systemctl start nginx
        return 1
    fi
    
    # Restart nginx
    if [[ "${restart_nginx:-}" == "true" ]]; then
        systemctl start nginx
    fi
    
    return 0
}

# Remove certificates for domain
remove_certificates() {
    local domain="$1"
    
    if ! has_certificates "$domain"; then
        warn "No certificates found for $domain"
        return 0
    fi
    
    log "Removing certificates for $domain..."
    
    if certbot delete --cert-name "$domain" --non-interactive; then
        log "Certificates removed successfully"
    else
        error "Failed to remove certificates"
        return 1
    fi
    
    return 0
}
