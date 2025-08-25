#!/bin/bash
# Display access information for deployed applications

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper functions with better UX hierarchy
info() { echo -e "${BLUE}→ $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; }
section() { echo -e "\n${GREEN}▶ $1${NC}"; }
subsection() { echo -e "\n${BLUE}  $1${NC}"; }

# Check if we're in local development environment
is_local_dev() {
    command -v multipass &> /dev/null || [[ -f "local-kubeconfig.yaml" ]]
}

# Show access information
show_access_info() {
    section "🎉 Jterrazz Infrastructure Ready!"
    
    if is_local_dev; then
        # Local development with mDNS - automatic .local domain resolution
        subsection "🌐 Access your applications:"
        echo "    • Landing Page:      https://app.local/"
        echo "    • ArgoCD:           https://argocd.local/"
        echo "    • Portainer:        https://portainer.local/"
        echo ""
        info "💡 Zero-sudo DNS resolver enabled - all domains resolve automatically!"
        success "🔒 Docker-like domain resolution with shared SSL certificate"
        echo ""
        info "🚀 Infrastructure fully managed by Ansible!"
    else
        # Production environment
        subsection "🌐 Access your applications:"
        echo "    • Landing Page:      https://yourdomain.com"
        echo "    • ArgoCD:           https://argocd.yourdomain.com"
        echo "    • Portainer:        https://portainer.yourdomain.com"
        echo ""
        info "💡 Configure your domain DNS to point to this server"
        echo ""
        info "🚀 Infrastructure fully managed by Ansible!"
    fi
    
    echo ""
}

# Main execution
main() {
    show_access_info
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
