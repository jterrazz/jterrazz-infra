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
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="${VM_NAME:-jterrazz-infra}"
HOSTS_MARKER="# jterrazz-infra-local"

# Default services (can be overridden)
DEFAULT_SERVICES=(
    "app.local"
    "argocd.local"
    "portainer.local"
    "traefik.local"
)

# Get VM IP (supports both bridged and regular networking)
get_vm_ip() {
    local vm_ip=""
    
    if command -v multipass &> /dev/null; then
        # Get all IPv4 addresses - prefer bridged network (typically first non-10.x.x.x)
        local all_ips
        all_ips=$(multipass info "$VM_NAME" --format json 2>/dev/null | jq -r '.info["'$VM_NAME'"].ipv4[]' 2>/dev/null || echo "")
        
        # If we have multiple IPs, prefer the bridged network IP (usually not 10.x.x.x or 192.168.64.x)
        if [[ -n "$all_ips" ]]; then
            local fallback_ip=""
            while read -r ip; do
                if [[ -n "$ip" && "$ip" != "null" ]]; then
                    # Skip Kubernetes cluster IPs (10.42.x.x)
                    if [[ "$ip" =~ ^10\.42\. ]]; then
                        continue
                    fi
                    # Prefer bridged network IPs (not 10.x or 192.168.64.x)
                    if [[ ! "$ip" =~ ^192\.168\.64\. && ! "$ip" =~ ^10\. ]]; then
                        vm_ip="$ip"
                        break
                    elif [[ "$ip" =~ ^192\.168\.64\. ]]; then
                        # Use multipass internal IP as fallback
                        fallback_ip="$ip"
                    fi
                fi
            done <<< "$all_ips"
            
            # If no bridged IP found, use the multipass internal IP
            if [[ -z "$vm_ip" && -n "$fallback_ip" ]]; then
                vm_ip="$fallback_ip"
            fi
        fi
    fi
    
    if [[ -z "$vm_ip" || "$vm_ip" == "null" ]]; then
        error "Could not get VM IP for $VM_NAME"
        info "Make sure the VM is running: multipass list"
        exit 1
    fi
    
    echo "$vm_ip"
}

# Get current IP from hosts file
get_current_hosts_ip() {
    grep "$HOSTS_MARKER" /etc/hosts 2>/dev/null | head -1 | awk '{print $1}' || echo ""
}

# Auto-detect services from Kubernetes ingresses
get_kubernetes_services() {
    local services=()
    
    # Try to get services from Kubernetes if kubectl is available
    if command -v kubectl &> /dev/null; then
        local kubeconfig_arg=""
        if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "$PROJECT_DIR/local-kubeconfig.yaml" ]]; then
            kubeconfig_arg="--kubeconfig=$PROJECT_DIR/local-kubeconfig.yaml"
        fi
        
        # Get hostnames from ingresses
        local ingress_hosts
        ingress_hosts=$(kubectl get ingress --all-namespaces $kubeconfig_arg -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null || echo "")
        
        if [[ -n "$ingress_hosts" ]]; then
            while read -r host; do
                if [[ -n "$host" && "$host" != "null" ]]; then
                    services+=("$host")
                fi
            done <<< "$ingress_hosts"
        fi
    fi
    
    # If no services found from Kubernetes, use defaults
    if [[ ${#services[@]} -eq 0 ]]; then
        services=("${DEFAULT_SERVICES[@]}")
    fi
    
    printf '%s\n' "${services[@]}"
}

# Check if hosts file needs updating
needs_hosts_update() {
    local new_ip="$1"
    local current_ip
    current_ip=$(get_current_hosts_ip)
    
    # Check if IP changed
    if [[ "$current_ip" != "$new_ip" ]]; then
        return 0  # IP changed - needs update
    fi
    
    # Check if services changed
    local current_services
    mapfile -t current_services < <(grep "$HOSTS_MARKER" /etc/hosts 2>/dev/null | awk '{print $2}' | sort)
    
    local expected_services
    mapfile -t expected_services < <(get_kubernetes_services | sort)
    
    # Compare service lists
    if [[ "${current_services[*]}" != "${expected_services[*]}" ]]; then
        return 0  # Services changed - needs update
    fi
    
    return 1  # No changes needed
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
    
    # Get services (auto-detected or defaults)
    local services
    mapfile -t services < <(get_kubernetes_services)
    
    info "Configuring ${#services[@]} services: ${services[*]}"
    
    # Add each service entry
    for service in "${services[@]}"; do
        echo "$vm_ip $service $HOSTS_MARKER" | sudo tee -a /etc/hosts > /dev/null
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
    
    # Update /etc/hosts only if needed
    if needs_hosts_update "$vm_ip"; then
        local current_ip
        current_ip=$(get_current_hosts_ip)
        if [[ -n "$current_ip" ]]; then
            info "IP changed from $current_ip to $vm_ip - updating DNS..."
        else
            info "No existing DNS entries found - setting up..."
        fi
        clean_hosts
        add_hosts_entries "$vm_ip"
    else
        success "DNS already configured for $vm_ip - no update needed"
    fi
    
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
    cleanup)
        # Clean up any corrupted entries (like debug messages)
        info "Cleaning up corrupted hosts file entries..."
        sudo sed -i '' '/→ Using bridged network IP:/d' /etc/hosts 2>/dev/null || true
        sudo sed -i '' '/→ Getting VM IP address/d' /etc/hosts 2>/dev/null || true
        sudo sed -i '' '/✓ VM IP:/d' /etc/hosts 2>/dev/null || true
        success "Corrupted entries cleaned up"
        ;;
    status)
        current_ip=$(get_current_hosts_ip)
        if [[ -n "$current_ip" ]]; then
            success "Local DNS configured for IP: $current_ip"
            echo "Current jterrazz-infra entries in /etc/hosts:"
            grep "$HOSTS_MARKER" /etc/hosts || echo "No entries found"
        else
            info "No local DNS entries found"
        fi
        ;;
    *)
        echo "Usage: $0 [setup|clean|cleanup|status]"
        echo "  setup   - Configure local DNS (default)"
        echo "  clean   - Remove local DNS entries"  
        echo "  cleanup - Clean corrupted hosts file entries"
        echo "  status  - Show current DNS entries"
        exit 1
        ;;
esac
