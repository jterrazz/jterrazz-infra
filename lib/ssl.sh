#!/bin/bash

# JTerrazz Infrastructure - SSL Certificate Management
# Functions for managing Let's Encrypt SSL certificates

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Install certbot for manual DNS challenge
install_certbot_and_dns_plugin() {
    log "Installing certbot for manual DNS challenge..."
    
    if ! apt install -y certbot; then
        error "Failed to install certbot"
        return 1
    fi
    
    log "Certbot installed successfully"
    return 0
}

# No credentials verification needed for manual DNS challenge
verify_dns_credentials() {
    log "Using manual DNS challenge - no API credentials needed"
    log "You'll add DNS TXT records manually in Cloudflare interface"
    return 0
}

# Obtain certificate using manual DNS challenge
obtain_certificate_dns_challenge() {
    local domain="$1"
    
    log "Requesting SSL certificate for $domain using manual DNS challenge..."
    echo
    echo "🔑 MANUAL DNS CHALLENGE PROCESS:"
    echo "1. Certbot will show you a TXT record to create"
    echo "2. Add this TXT record in your Cloudflare DNS settings"  
    echo "3. Press Enter when ready to continue validation"
    echo "4. Certificate will be issued automatically"
    echo
    
    if ! certbot certonly \
        --manual \
        --preferred-challenges dns \
        --manual-public-ip-logging-ok \
        -d "$domain" \
        --agree-tos \
        --email "admin@$domain" \
        --expand; then
        error "Failed to obtain SSL certificate using manual DNS challenge"
        error "Make sure you added the TXT record exactly as shown"
        return 1
    fi
    
    log "SSL certificate obtained successfully via manual DNS challenge"
    return 0
}

# Check if certificates exist for domain
has_certificates() {
    local domain="$1"
    [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]
}

# Generate SSL certificates using Let's Encrypt DNS challenge
generate_ssl_certificates() {
    local domain="$1"
    
    log "Generating SSL certificates for $domain using DNS challenge..."
    
    # Install certbot and DNS plugin
    install_certbot_and_dns_plugin || return 1
    
    # Check if certificates already exist
    if has_certificates "$domain"; then
        warn "SSL certificates already exist for $domain, skipping generation"
        return 0
    fi
    
    # Verify DNS provider credentials are set
    verify_dns_credentials || return 1
    
    # Generate certificate using DNS challenge
    obtain_certificate_dns_challenge "$domain" || return 1
    
    log "SSL certificates generated successfully for $domain"
    return 0
}

# Setup certificate renewal automation
setup_certificate_renewal() {
    local domain="$1"
    
    if ! has_certificates "$domain"; then
        return 0
    fi
    
    log "Certificate renewal information for manual DNS challenge..."
    
    # Show certificate expiry information
    if openssl x509 -in "/etc/letsencrypt/live/$domain/cert.pem" -noout -dates 2>/dev/null; then
        local expiry_date
        expiry_date=$(openssl x509 -in "/etc/letsencrypt/live/$domain/cert.pem" -noout -enddate | cut -d= -f2)
        log "Certificate expires on: $expiry_date"
    fi
    
    warn "Manual DNS challenge certificates require manual renewal"
    warn "Before expiry, run: sudo infra nginx --configure (and add new TXT records)"
    warn "Monitor expiry with: check-ssl-cert"
    
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
    echo "=== Manual Renewal Info ==="
    echo "⚠️  Manual DNS challenge certificates require manual renewal"
    echo "📅 Renew before expiry with: sudo infra nginx --configure"
else
    echo "❌ Let's Encrypt certificate not found"
    echo "Run: sudo infra nginx --configure"
    echo "Follow interactive prompts to add DNS TXT records manually"
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
