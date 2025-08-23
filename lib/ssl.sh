#!/bin/bash

# JTerrazz Infrastructure - SSL Certificate Management
# Functions for managing Let's Encrypt SSL certificates

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Install certbot for automated HTTP-01 challenge
install_certbot() {
    log "Installing certbot for automated HTTP-01 challenge..."
    
    # Install certbot and nginx plugin
    if ! apt install -y certbot python3-certbot-nginx; then
        error "Failed to install certbot and nginx plugin"
        return 1
    fi
    
    log "Certbot with nginx plugin installed successfully"
    return 0
}

# Verify prerequisites for HTTP-01 challenge
verify_http_challenge_requirements() {
    log "Verifying HTTP-01 challenge requirements..."
    
    # Check if Nginx is running
    if ! systemctl is-active --quiet nginx; then
        warn "Nginx is not running - will start it for certificate generation"
        systemctl start nginx || return 1
    fi
    
    # Check if port 80 is available for challenges (temporarily)
    log "HTTP-01 challenge requires port 80 for certificate validation"
    return 0
}

# Obtain certificate using automated HTTP-01 challenge
obtain_certificate_http_challenge() {
    local domain="$1"
    
    log "Requesting SSL certificate for $domain using automated HTTP-01 challenge..."
    echo "🔑 AUTOMATED HTTP-01 CHALLENGE:"
    echo "• Let's Encrypt will verify domain ownership via port 80"
    echo "• Fully automated - no manual intervention required"
    echo "• Nginx will serve challenge files automatically"
    echo
    
    # Ensure nginx is running for the challenge
    systemctl start nginx || return 1
    
    # Use nginx plugin for automated certificate installation
    if ! certbot --nginx \
        -d "$domain" \
        --agree-tos \
        --email "admin@$domain" \
        --redirect \
        --non-interactive \
        --expand; then
        error "Failed to obtain SSL certificate using HTTP-01 challenge"
        error "Ensure port 80 is accessible from the internet and domain resolves correctly"
        return 1
    fi
    
    log "✅ SSL certificate obtained and installed successfully via HTTP-01 challenge"
    log "Certificate includes automatic HTTPS redirect"
    return 0
}

# Check if certificates exist for domain
has_certificates() {
    local domain="$1"
    [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]
}

# Generate SSL certificates using automated HTTP-01 challenge
generate_ssl_certificates() {
    local domain="$1"
    
    log "Generating SSL certificates for $domain using automated HTTP-01 challenge..."
    
    # Install certbot and nginx plugin
    install_certbot || return 1
    
    # Check if certificates already exist
    if has_certificates "$domain"; then
        warn "SSL certificates already exist for $domain, skipping generation"
        return 0
    fi
    
    # Verify HTTP challenge requirements
    verify_http_challenge_requirements || return 1
    
    # Generate certificate using automated HTTP-01 challenge
    obtain_certificate_http_challenge "$domain" || return 1
    
    log "SSL certificates generated successfully for $domain"
    return 0
}

# Setup automatic certificate renewal
setup_certificate_renewal() {
    local domain="$1"
    
    if ! has_certificates "$domain"; then
        return 0
    fi
    
    log "Setting up automatic certificate renewal..."
    
    # Enable and start certbot renewal timer
    if ! systemctl is-enabled certbot.timer &>/dev/null; then
        systemctl enable certbot.timer || return 1
        log "Enabled certbot automatic renewal timer"
    fi
    
    if ! systemctl is-active certbot.timer &>/dev/null; then
        systemctl start certbot.timer || return 1
        log "Started certbot automatic renewal timer"
    fi
    
    # Test automatic renewal
    log "Testing automatic renewal process..."
    if certbot renew --dry-run --quiet; then
        log "✅ Automatic renewal test successful"
    else
        warn "Automatic renewal test failed - check configuration"
    fi
    
    # Show certificate expiry information
    if openssl x509 -in "/etc/letsencrypt/live/$domain/cert.pem" -noout -dates 2>/dev/null; then
        local expiry_date
        expiry_date=$(openssl x509 -in "/etc/letsencrypt/live/$domain/cert.pem" -noout -enddate | cut -d= -f2)
        log "Certificate expires on: $expiry_date"
        log "Automatic renewal will occur within 30 days of expiry"
    fi
    
    return 0
}

# Create certificate monitoring script
create_ssl_monitoring_script() {
    local domain="$1"
    
    cat > /usr/local/bin/check-ssl-cert << MONITOR_EOF
#!/bin/bash
DOMAIN="$domain"
CERT_PATH="/etc/letsencrypt/live/\$DOMAIN/cert.pem"

echo "=== SSL Certificate Status for \$DOMAIN ==="

if [[ -f "\$CERT_PATH" ]]; then
    echo "✅ Let's Encrypt certificate (trusted, no browser warnings)"
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
    echo "=== Automatic Renewal Info ==="
    if systemctl is-active --quiet certbot.timer; then
        echo "✅ Automatic renewal is enabled and running"
        echo "🔄 Certificates renew automatically within 30 days of expiry"
    else
        echo "❌ Automatic renewal service not running"
        echo "Fix: sudo systemctl enable --now certbot.timer"
    fi
    echo "📅 Manual renewal (if needed): sudo certbot renew"
else
    echo "❌ Let's Encrypt certificate not found"
    echo "Run: sudo infra nginx --configure"
    echo "HTTP-01 challenge will be used automatically"
fi

echo
echo "=== Tailscale Network Status ==="
if command -v tailscale &> /dev/null && tailscale status --json &>/dev/null; then
    local ts_ip=\$(tailscale ip -4 2>/dev/null)
    echo "✅ Tailscale connected: \$ts_ip"
    echo "🌐 Access URL: https://\$DOMAIN (via Tailscale)"
    echo "🔒 Trusted SSL certificates - no browser warnings"
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
        echo "/etc/letsencrypt/live/$domain/fullchain.pem /etc/letsencrypt/live/$domain/privkey.pem"
    else
        echo "/etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/private/ssl-cert-snakeoil.key"
    fi
}

# Force certificate renewal
force_certificate_renewal() {
    local domain="$1"
    

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


