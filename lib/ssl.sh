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
    
    if [[ "$USE_REAL_SSL" != "true" ]]; then
        log "Using self-signed certificates (USE_REAL_SSL=false)"
        return 0
    fi
    
    log "Setting up SSL certificates with Let's Encrypt for $domain..."
    
    # Install certbot if not present
    if ! command -v certbot &> /dev/null; then
        install_certbot || return 1
    fi
    
    # Check if certificates already exist
    if has_certificates "$domain"; then
        warn "SSL certificates already exist for $domain, skipping generation"
        return 0
    fi
    
    # Ensure domain resolves
    log "Testing domain accessibility..."
    if ! test_domain_resolution "$domain"; then
        warn "Domain $domain does not resolve. Please ensure:"
        warn "1. DNS A record points to this server's IP"
        warn "2. Domain resolves correctly"
        warn "Continuing with self-signed certificates for now..."
        warn "You can run this command again after DNS propagation to get real certificates"
        return 0
    fi
    
    # Stop nginx temporarily to allow standalone mode
    if is_service_running nginx; then
        log "Stopping nginx temporarily for certificate generation"
        systemctl stop nginx
        local restart_nginx=true
    fi
    
    # Obtain SSL certificate using standalone mode
    if ! certbot certonly --standalone \
        -d "$domain" \
        --non-interactive \
        --agree-tos \
        --email "admin@$domain" \
        --expand; then
        warn "Failed to obtain Let's Encrypt certificate, falling back to self-signed"
        [[ "${restart_nginx:-}" == "true" ]] && systemctl start nginx
        return 0
    fi
    
    # Restart nginx if it was running
    if [[ "${restart_nginx:-}" == "true" ]]; then
        log "Restarting nginx"
        systemctl start nginx
    fi
    
    log "SSL certificates generated successfully for $domain"
    return 0
}

# Setup certificate renewal automation
setup_certificate_renewal() {
    local domain="$1"
    
    if [[ "$USE_REAL_SSL" != "true" ]] || ! has_certificates "$domain"; then
        return 0
    fi
    
    log "Setting up automatic certificate renewal..."
    
    # Enable certbot timer
    if ! systemctl enable certbot.timer; then
        warn "Failed to enable automatic certificate renewal"
    else
        log "Enabled automatic certificate renewal (certbot.timer)"
    fi
    
    # Create renewal hooks for HTTPS-only setup
    mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post,deploy}
    
    # Pre-renewal hook: stop nginx
    cat > /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh << 'PRE_HOOK_EOF'
#!/bin/bash
systemctl stop nginx 2>/dev/null || true
PRE_HOOK_EOF
    chmod +x /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh
    
    # Post-renewal hook: start nginx
    cat > /etc/letsencrypt/renewal-hooks/post/start-nginx.sh << 'POST_HOOK_EOF'
#!/bin/bash
systemctl start nginx
logger "SSL certificate renewed and nginx restarted for $RENEWED_DOMAINS"
POST_HOOK_EOF
    chmod +x /etc/letsencrypt/renewal-hooks/post/start-nginx.sh
    
    # Test renewal process (dry run)
    log "Testing certificate renewal process..."
    if certbot renew --dry-run; then
        log "Certificate renewal test successful"
    else
        warn "Certificate renewal test failed - manual intervention may be needed"
    fi
    
    log "Configured renewal hooks for HTTPS-only setup"
    
    # Show certificate expiry information
    if openssl x509 -in "/etc/letsencrypt/live/$domain/cert.pem" -noout -dates 2>/dev/null; then
        local expiry_date
        expiry_date=$(openssl x509 -in "/etc/letsencrypt/live/$domain/cert.pem" -noout -enddate | cut -d= -f2)
        log "Certificate expires on: $expiry_date"
    fi
    
    log "SSL certificates configured successfully with automatic renewal"
    return 0
}

# Create certificate monitoring script
create_ssl_monitoring_script() {
    local domain="$1"
    
    cat > /usr/local/bin/check-ssl-cert << MONITOR_EOF
#!/bin/bash
DOMAIN="$domain"
CERT_PATH="/etc/letsencrypt/live/\${DOMAIN}/cert.pem"

if [[ -f "\$CERT_PATH" ]]; then
    echo "=== SSL Certificate Status for \$DOMAIN ==="
    echo "Certificate path: \$CERT_PATH"
    echo
    
    # Show expiry date
    expiry_date=\$(openssl x509 -in "\$CERT_PATH" -noout -enddate | cut -d= -f2)
    echo "Expires: \$expiry_date"
    
    # Calculate days until expiry
    expiry_epoch=\$(date -d "\$expiry_date" +%s)
    current_epoch=\$(date +%s)
    days_until_expiry=\$(( (expiry_epoch - current_epoch) / 86400 ))
    
    echo "Days until expiry: \$days_until_expiry"
    
    if [ \$days_until_expiry -lt 7 ]; then
        echo "🚨 CRITICAL: Certificate expires in less than 7 days!"
    elif [ \$days_until_expiry -lt 30 ]; then
        echo "⚠️  WARNING: Certificate expires in less than 30 days!"
    else
        echo "✅ Certificate is valid"
    fi
    
    echo
    echo "=== Automatic Renewal Status ==="
    systemctl is-active certbot.timer && echo "✅ Renewal timer is active" || echo "❌ Renewal timer is inactive"
    
    echo
    echo "=== Last Renewal Attempts ==="
    journalctl -u certbot.timer --since "7 days ago" --no-pager | tail -10
else
    echo "❌ No Let's Encrypt certificate found for \$DOMAIN"
    echo "Using self-signed certificates"
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
