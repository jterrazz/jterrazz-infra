#!/bin/bash
# Setup mDNS for local development

# Load common utilities
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

setup_mdns() {
    section "🚀 Setting up mDNS for local development"
    
    if ! is_development; then
        error "This script is only for local development"
        exit 1
    fi
    
    # Check cluster connectivity
    if ! check_kubectl_connection; then
        error "Cannot connect to cluster. Run 'make start' first."
        exit 1
    fi
    
    # Deploy mDNS publisher
    info "Deploying mDNS publisher..."
    if run_kubectl apply -f kubernetes/services/mdns-publisher.yml; then
        success "mDNS publisher deployed"
    else
        error "Failed to deploy mDNS publisher"
        exit 1
    fi
    
    # Wait for deployment
    info "Waiting for mDNS to be ready..."
    if run_kubectl wait --for=condition=available --timeout=60s deployment/mdns-publisher; then
        success "mDNS publisher is ready"
    else
        warn "mDNS publisher may still be starting..."
    fi
    
    # Test mDNS resolution
    section "🧪 Testing mDNS Resolution"
    
    local success_count=0
    for domain in app.local argocd.local portainer.local; do
        if ping -c 1 -t 2 "$domain" >/dev/null 2>&1; then
            success "✓ $domain resolves"
            ((success_count++))
        else
            warn "✗ $domain not resolving yet"
        fi
    done
    
    if [[ $success_count -eq 3 ]]; then
        section "🎉 mDNS Setup Complete!"
        echo "Your services are available at:"
        echo "  • https://app.local/"
        echo "  • https://argocd.local/"
        echo "  • https://portainer.local/"
    else
        warn "Some domains are not resolving yet. They may need a minute to propagate."
    fi
}

cleanup_mdns() {
    section "🧹 Cleaning up mDNS"
    
    if run_kubectl delete -f kubernetes/services/mdns-publisher.yml 2>/dev/null; then
        success "mDNS publisher removed"
    else
        info "mDNS publisher was already removed"
    fi
}

# Main
case "${1:-setup}" in
    setup) setup_mdns ;;
    cleanup) cleanup_mdns ;;
    *)
        echo "Usage: $0 [setup|cleanup]"
        echo "  setup   - Deploy mDNS publisher (default)"
        echo "  cleanup - Remove mDNS publisher"
        exit 1
        ;;
esac
