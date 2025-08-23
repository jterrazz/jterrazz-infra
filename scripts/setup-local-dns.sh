#!/bin/bash
# Local DNS automation for jterrazz-infra
# Automatically configures /etc/hosts for local development

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }

# Configuration
VM_NAME="${VM_NAME:-jterrazz-dev}"
HOSTS_MARKER="# jterrazz-infra-local"

# Get VM IP
get_vm_ip() {
    local vm_ip=""
    
    if command -v multipass &> /dev/null; then
        vm_ip=$(multipass info "$VM_NAME" --format json 2>/dev/null | jq -r '.info["'$VM_NAME'"].ipv4[0]' 2>/dev/null || echo "")
    fi
    
    if [[ -z "$vm_ip" || "$vm_ip" == "null" ]]; then
        error "Could not get VM IP for $VM_NAME"
        info "Make sure the VM is running: multipass list"
        exit 1
    fi
    
    echo "$vm_ip"
}

# Clean old entries
clean_hosts() {
    info "Cleaning old /etc/hosts entries..."
    
    # Remove lines with our marker
    sudo sed -i '' "/$HOSTS_MARKER/d" /etc/hosts 2>/dev/null || true
    
    success "Old entries cleaned"
}

# Add new entries
add_hosts_entries() {
    local vm_ip="$1"
    
    info "Adding new /etc/hosts entries for $vm_ip..."
    
    # Define the services we want to access (using .local to avoid conflicts)
    local entries=(
        "$vm_ip app.local $HOSTS_MARKER"
        "$vm_ip argocd.local $HOSTS_MARKER"  
        "$vm_ip portainer.local $HOSTS_MARKER"
        "$vm_ip traefik.local $HOSTS_MARKER"
    )
    
    # Add each entry
    for entry in "${entries[@]}"; do
        echo "$entry" | sudo tee -a /etc/hosts > /dev/null
    done
    
    success "DNS entries added"
}

# Show access URLs
show_urls() {
    local vm_ip="$1"
    
    echo
    success "🌐 Local DNS configured! Access your services:"
        echo "  • Landing Page:      https://app.local"
    echo "  • ArgoCD:           https://argocd.local"
    echo "  • Portainer:        https://portainer.local"
    echo "  • Traefik Dashboard: https://traefik.local (if configured)"
    echo
    info "💡 VM IP: $vm_ip - URLs will auto-update when VM changes"
    echo
    info "💡 All services use HTTPS (production-like setup)"
    info "💡 Accept browser security warnings for self-signed certificates"
}

# Main function
main() {
    echo -e "${GREEN}🔧 Setting up local DNS automation${NC}"
    echo "Configuring /etc/hosts for seamless local development"
    echo
    
    # Get VM IP
    info "Getting VM IP address..."
    local vm_ip
    vm_ip=$(get_vm_ip)
    success "VM IP: $vm_ip"
    
    # Update /etc/hosts
    clean_hosts
    add_hosts_entries "$vm_ip"
    
    # Show results
    show_urls "$vm_ip"
}

# Handle cleanup on script exit
cleanup() {
    if [[ "${1:-}" == "clean" ]]; then
        echo -e "${YELLOW}🧹 Cleaning up local DNS entries${NC}"
        clean_hosts
        success "Local DNS entries removed"
    fi
}

# Check arguments
case "${1:-setup}" in
    setup|"")
        main
        ;;
    clean)
        cleanup clean
        ;;
    status)
        echo "Current jterrazz-infra entries in /etc/hosts:"
        grep "$HOSTS_MARKER" /etc/hosts || echo "No entries found"
        ;;
    *)
        echo "Usage: $0 [setup|clean|status]"
        echo "  setup  - Configure local DNS (default)"
        echo "  clean  - Remove local DNS entries"  
        echo "  status - Show current DNS entries"
        exit 1
        ;;
esac
