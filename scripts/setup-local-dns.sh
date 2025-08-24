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

info() { echo -e "${BLUE}→ $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; }
section() { echo -e "\n${GREEN}▶ $1${NC}"; }
subsection() { echo -e "\n${BLUE}  $1${NC}"; }

# Configuration
VM_NAME="${VM_NAME:-jterrazz-infra}"
HOSTS_MARKER="# jterrazz-infra-local"

# Get VM IP (supports both bridged and regular networking)
get_vm_ip() {
    local vm_ip=""
    
    if command -v multipass &> /dev/null; then
        # Get all IPv4 addresses - prefer bridged network (typically first non-10.x.x.x)
        local all_ips
        all_ips=$(multipass info "$VM_NAME" --format json 2>/dev/null | jq -r '.info["'$VM_NAME'"].ipv4[]' 2>/dev/null || echo "")
        
        # If we have multiple IPs, prefer the bridged network IP (usually not 10.x.x.x or 192.168.64.x)
        if [[ -n "$all_ips" ]]; then
            while read -r ip; do
                if [[ -n "$ip" && "$ip" != "null" ]]; then
                    # Skip typical Multipass internal IPs and prefer bridged IPs
                    if [[ ! "$ip" =~ ^192\.168\.64\. && ! "$ip" =~ ^10\. ]]; then
                        vm_ip="$ip"
                        break
                    else
                        # Fallback to internal IP if no bridged IP found
                        vm_ip="$ip"
                    fi
                fi
            done <<< "$all_ips"
        fi
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

# Check if IP looks stable (bridged network)
is_stable_ip() {
    local vm_ip="$1"
    
    # Bridged IPs typically are on your local network range (192.168.1.x, 192.168.0.x, etc)
    # and are more stable than Multipass internal ranges
    if [[ "$vm_ip" =~ ^192\.168\.[0-9]+\.[0-9]+$ && ! "$vm_ip" =~ ^192\.168\.64\. ]]; then
        return 0  # Likely stable bridged IP
    fi
    return 1  # Probably dynamic IP
}

# Show access URLs
show_urls() {
    local vm_ip="$1"
    
    section "🌐 Local Services Ready"
    
    subsection "Access your applications:"
    echo "    • Landing Page:      https://app.local"
    echo "    • ArgoCD:           https://argocd.local"
    echo "    • Portainer:        https://portainer.local"
    echo "    • Traefik Dashboard: https://traefik.local (if configured)"
    
    subsection "💡 Development notes:"
    echo "    • VM IP: $vm_ip"
    if is_stable_ip "$vm_ip"; then
        echo "    • Network: Bridged (stable IP - less likely to change)"
    else
        echo "    • Network: Dynamic (IP may change when VM recreated)"
    fi
    echo "    • All services use HTTPS (production-like setup)"
    echo "    • Accept browser security warnings for self-signed certificates"
}

# Main function
main() {
    section "🔧 Local DNS Configuration"
    subsection "Configuring /etc/hosts for seamless local development"
    
    info "Getting VM IP address..."
    local vm_ip
    vm_ip=$(get_vm_ip)
    
    # Show network type info
    if is_stable_ip "$vm_ip"; then
        success "VM IP: $vm_ip (bridged network)"
    else
        success "VM IP: $vm_ip (multipass internal)"
    fi
    
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
