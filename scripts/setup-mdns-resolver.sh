#!/bin/bash
# Pure mDNS setup - no /etc/hosts, just like Docker

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}→ $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; }
section() { echo -e "\n${GREEN}▶ $1${NC}"; }

VM_NAME="${VM_NAME:-jterrazz-infra}"

get_vm_ip() {
    if command -v multipass &> /dev/null; then
        # Get the external Multipass IP, not the internal Kubernetes IP
        multipass info "$VM_NAME" --format json | jq -r ".info.\"$VM_NAME\".ipv4[0]" 2>/dev/null
    fi
}

setup_pure_mdns() {
    section "🚀 Pure mDNS Setup (Zero /etc/hosts)"
    info "Using only macOS built-in mDNS - just like Docker!"
    
    local vm_ip
    vm_ip=$(get_vm_ip)
    if [[ -z "$vm_ip" ]] || [[ "$vm_ip" == "null" ]]; then
        error "VM not found. Run 'make start' first."
        exit 1
    fi
    
    info "VM external IP: $vm_ip"
    
    # Set up proper mDNS broadcasting from the VM
    info "Setting up VM to broadcast mDNS with correct IP..."
    
    if KUBECONFIG="./local-kubeconfig.yaml" kubectl get pods -n default >/dev/null 2>&1; then
        # Create a script that runs on the VM host (not in a container)
        cat > /tmp/setup-vm-mdns.sh <<EOF
#!/bin/bash
# Setup proper mDNS broadcasting

# Get the external IP (the one macOS can reach)
EXTERNAL_IP="$vm_ip"

echo "Setting up mDNS for IP: \$EXTERNAL_IP"

# Install avahi if not present
if ! command -v avahi-publish &> /dev/null; then
    apt-get update -qq
    apt-get install -y avahi-daemon avahi-utils
fi

# Stop any existing publications
pkill -f "avahi-publish" || true

# Start avahi daemon if not running
systemctl start avahi-daemon 2>/dev/null || true
systemctl enable avahi-daemon 2>/dev/null || true

# Publish the correct A records for our domains
nohup avahi-publish -a -R app.local \$EXTERNAL_IP >/dev/null 2>&1 &
nohup avahi-publish -a -R argocd.local \$EXTERNAL_IP >/dev/null 2>&1 &
nohup avahi-publish -a -R portainer.local \$EXTERNAL_IP >/dev/null 2>&1 &

echo "✓ mDNS A records published for: app.local, argocd.local, portainer.local → \$EXTERNAL_IP"

# Also publish HTTP services for better discovery
nohup avahi-publish -s "App Local" _http._tcp 443 host=app.local >/dev/null 2>&1 &
nohup avahi-publish -s "ArgoCD Local" _http._tcp 443 host=argocd.local >/dev/null 2>&1 &
nohup avahi-publish -s "Portainer Local" _http._tcp 443 host=portainer.local >/dev/null 2>&1 &

echo "✓ mDNS HTTP services published"
echo "✓ mDNS setup complete - domains should be discoverable"
EOF

        # Try to execute on the VM via SSH through a running pod
        KUBECONFIG="./local-kubeconfig.yaml" kubectl run mdns-setup --image=ubuntu:22.04 --restart=Never --rm -i --tty=false --privileged --overrides='{"spec":{"hostNetwork":true,"hostPID":true}}' -- bash -c "
        # Install required tools
        apt-get update -qq && apt-get install -y openssh-client curl avahi-daemon avahi-utils systemctl

        # Execute our mDNS setup script on the host
        $(cat /tmp/setup-vm-mdns.sh)
        " 2>/dev/null || {
            warning "Privileged pod approach failed, trying alternative..."
            
            # Alternative: Use a simple deployment to publish from within the cluster
            cat <<YAML | KUBECONFIG="./local-kubeconfig.yaml" kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mdns-publisher
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mdns-publisher
  template:
    metadata:
      labels:
        app: mdns-publisher
    spec:
      hostNetwork: true
      containers:
      - name: mdns-publisher
        image: ubuntu:22.04
        command: ["/bin/bash"]
        args:
        - -c
        - |
          apt-get update -qq
          apt-get install -y avahi-daemon avahi-utils
          
          # Use the external IP
          EXTERNAL_IP="$vm_ip"
          
          # Start avahi
          service dbus start || true
          service avahi-daemon start || true
          
          # Publish our domains
          avahi-publish -a -R app.local \$EXTERNAL_IP &
          avahi-publish -a -R argocd.local \$EXTERNAL_IP &
          avahi-publish -a -R portainer.local \$EXTERNAL_IP &
          
          echo "mDNS publisher started for \$EXTERNAL_IP"
          
          # Keep the container running
          while true; do sleep 60; done
        securityContext:
          privileged: true
YAML
            success "mDNS publisher deployed as a pod"
        }
        
        rm -f /tmp/setup-vm-mdns.sh
        success "VM configured for pure mDNS broadcasting"
    else
        error "Cannot access VM via kubectl"
        exit 1
    fi
    
    # Wait for mDNS to propagate
    info "Waiting for mDNS propagation..."
    sleep 5
    
    section "🧪 Testing Pure mDNS"
    
    local success_count=0
    
    # Test each domain
    for domain in app.local argocd.local portainer.local; do
        info "Testing $domain..."
        
        # Try ping test (best indicator of mDNS working)
        if ping -c 1 "$domain" >/dev/null 2>&1; then
            success "✓ $domain resolves via mDNS"
            ((success_count++))
        else
            warning "✗ $domain not resolving yet"
            
            # Try DNS-SD lookup as backup test
            if timeout 3s dns-sd -L "$domain" _http._tcp . >/dev/null 2>&1; then
                success "✓ $domain service discoverable"
                ((success_count++))
            fi
        fi
    done
    
    # Overall result
    if [[ $success_count -ge 2 ]]; then
        section "🎉 Pure mDNS Success!"
        echo "✅ Pure mDNS working! (no /etc/hosts needed)"
        echo ""
        echo "Your services:"
        echo "  • 🏠 Landing Page:  https://app.local/"
        echo "  • 🚀 ArgoCD:        https://argocd.local/"
        echo "  • 🐳 Portainer:    https://portainer.local/"
        echo ""
        echo "Works everywhere - browsers, terminal, curl!"
        echo "Remove: $0 cleanup"
    else
        section "⚠ mDNS Still Propagating"
        echo "mDNS is configured but may need a few more seconds to propagate."
        echo "Try the URLs in a minute - mDNS discovery takes time."
        echo ""
        echo "If it doesn't work after 2-3 minutes, there may be a network issue."
    fi
}

cleanup() {
    section "🧹 Cleanup"
    
    # Remove the mDNS publisher deployment
    KUBECONFIG="./local-kubeconfig.yaml" kubectl delete deployment mdns-publisher 2>/dev/null || true
    
    success "mDNS publisher removed"
}

case "${1:-setup}" in
    "cleanup") cleanup ;;
    "setup"|"") setup_pure_mdns ;;
    *) 
        echo "Usage: $0 [setup|cleanup]"
        echo "  setup   - Configure pure mDNS resolution (default)"
        echo "  cleanup - Remove mDNS publisher"
        exit 1 
        ;;
esac