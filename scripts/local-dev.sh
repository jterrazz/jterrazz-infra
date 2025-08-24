#!/bin/bash

# Local Development Environment - Real Ubuntu VM + Ansible + Kubernetes
# Perfect for testing the complete infrastructure workflow locally

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging with better UX hierarchy
info() { echo -e "${BLUE}→ $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; }
section() { echo -e "\n${GREEN}▶ $1${NC}"; }
subsection() { echo -e "\n${BLUE}  $1${NC}"; }

# VM Configuration
VM_NAME="jterrazz-infra"
VM_CPUS="4"
VM_MEMORY="8G"
VM_DISK="20G"

# Create Ubuntu VM
create_vm() {
    section "Setting up Ubuntu VM"
    
    if multipass list | grep -q "$VM_NAME"; then
        local vm_status
        vm_status=$(multipass list | grep "$VM_NAME" | awk '{print $2}')
        
        if [ "$vm_status" = "Running" ]; then
            success "VM '$VM_NAME' is already running"
            subsection "💡 Quick tips:"
            echo "    • Fresh start: make clean && make start"
            echo "    • Deploy apps: make apps"
            return 0
        else
            info "VM exists but is $vm_status, starting..."
            multipass start "$VM_NAME"
            success "VM '$VM_NAME' started"
        return 0
        fi
    fi
    
    info "Creating new VM '$VM_NAME'..."
    
    multipass launch \
        --name "$VM_NAME" \
        --cpus "$VM_CPUS" \
        --memory "$VM_MEMORY" \
        --disk "$VM_DISK" \
        lts
    
    success "VM created successfully"
}

# Configure SSH access for Ansible
setup_ssh() {
    info "Setting up SSH access..."
    
    # Create SSH directory if it doesn't exist
    mkdir -p "$PROJECT_DIR/local-data/ssh"
    
    # Generate SSH key if it doesn't exist
    if [ ! -f "$PROJECT_DIR/local-data/ssh/id_rsa" ]; then
        ssh-keygen -t rsa -b 2048 -f "$PROJECT_DIR/local-data/ssh/id_rsa" -N "" -C "local-dev@jterrazz-infra"
        success "SSH key generated"
    fi
    
    # Get VM IP
    local vm_ip
    vm_ip=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')
    
    # Clean up any existing host keys for this IP
    ssh-keygen -R "$vm_ip" 2>/dev/null || true
    ssh-keygen -R "192.168.64.*" 2>/dev/null || true
    
    # Install public key in VM using multipass mount (more reliable)
    local pub_key
    pub_key=$(cat "$PROJECT_DIR/local-data/ssh/id_rsa.pub")
    
    # Use multipass transfer to safely copy the SSH key
    echo "$pub_key" > "$PROJECT_DIR/local-data/ssh/temp_key.pub"
    multipass transfer "$PROJECT_DIR/local-data/ssh/temp_key.pub" "$VM_NAME:/tmp/ssh_key.pub"
    
    # Install the key using multipass exec (no SSH required)
    multipass exec "$VM_NAME" -- bash -c "
        mkdir -p ~/.ssh &&
        chmod 700 ~/.ssh &&
        # Clear and install the key
        cat /tmp/ssh_key.pub > ~/.ssh/authorized_keys &&
        chmod 600 ~/.ssh/authorized_keys &&
        # Clean up temp file
        rm -f /tmp/ssh_key.pub &&
        # Verify the key was installed
        echo 'SSH key installed with' \$(wc -l < ~/.ssh/authorized_keys) 'entries'
    "
    
    # Clean up local temp file
    rm -f "$PROJECT_DIR/local-data/ssh/temp_key.pub"
    
    # Test SSH connection
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o PasswordAuthentication=no \
           -o ConnectTimeout=5 \
           ubuntu@"$vm_ip" "echo 'SSH test successful'" >/dev/null 2>&1; then
        success "SSH key installed and tested successfully"
    else
        error "SSH key installation failed"
        exit 1
    fi
    
    echo "VM IP: $vm_ip"
}

# Verify dynamic inventory can discover VM
verify_inventory() {
    info "Verifying dynamic inventory can discover VM..."
    
    # Test the dynamic inventory script
    if ansible/inventories/multipass/inventory.py --list | grep -q "jterrazz-multipass"; then
        success "Dynamic inventory successfully discovered VM"
        local vm_ip=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')
        info "VM accessible at: $vm_ip"
    else
        warning "Dynamic inventory couldn't discover VM. VM might not be ready yet."
    fi
}

# Run Ansible playbook against VM
run_ansible() {
    info "Running Ansible playbook against local VM..."
    
    cd "$PROJECT_DIR/ansible"
    
    # Test connectivity first with dynamic inventory
    ansible -i inventories/multipass/inventory.py -m ping all
    
    # Run the full playbook with dynamic inventory
    ansible-playbook -i inventories/multipass/inventory.py site.yml -v
    
    success "Ansible playbook completed"
}

# Get kubeconfig from VM
get_kubeconfig() {
    info "Getting kubeconfig from VM..."
    
    # Check if VM is running
    if ! multipass info "$VM_NAME" &>/dev/null; then
        error "VM '$VM_NAME' not found. Run 'make start' first."
        exit 1
    fi
    
    local vm_ip
    vm_ip=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')
    
    # Check if kubeconfig already exists and works
    if [ -f "$PROJECT_DIR/local-kubeconfig.yaml" ]; then
        info "Found existing kubeconfig, testing connectivity..."
        if KUBECONFIG="$PROJECT_DIR/local-kubeconfig.yaml" kubectl get nodes &>/dev/null; then
            success "Existing kubeconfig is working!"
            info "Use: export KUBECONFIG=$PROJECT_DIR/local-kubeconfig.yaml"
            return 0
        else
            warning "Existing kubeconfig not working, fetching fresh copy..."
        fi
    fi
    
    # Fetch kubeconfig directly via SSH (simple and reliable now that SSH works)
    info "Fetching kubeconfig via SSH..."
    if scp -i "$PROJECT_DIR/local-data/ssh/id_rsa" \
        ubuntu@"$vm_ip":/etc/rancher/k3s/k3s.yaml \
        "$PROJECT_DIR/local-kubeconfig.yaml"; then
        
        # Update server address to point to VM IP
        sed -i.bak "s/127.0.0.1/$vm_ip/g" "$PROJECT_DIR/local-kubeconfig.yaml"
        
        success "Kubeconfig fetched successfully!"
        info "Use: export KUBECONFIG=$PROJECT_DIR/local-kubeconfig.yaml"
    else
        error "Failed to fetch kubeconfig via SSH."
        exit 1
    fi
}

# Delete VM with force
delete_vm() {
    info "Removing development VM '$VM_NAME'..."
    
    # Check if VM exists
    if ! multipass list | grep -q "$VM_NAME"; then
        success "VM '$VM_NAME' already removed"
        return 0
    fi
    
    # Try graceful shutdown first
    if timeout 30 multipass stop "$VM_NAME" 2>/dev/null; then
        info "VM stopped gracefully"
    else
        info "Forcing VM shutdown..."
    fi
    
    # Delete VM with escalating force levels
    if timeout 60 multipass delete "$VM_NAME" 2>/dev/null; then
        info "VM deleted successfully"
    elif timeout 30 multipass delete --purge "$VM_NAME" 2>/dev/null; then
        info "VM force deleted"
    else
        info "Using advanced cleanup (killing multipass processes)..."
        pkill -f multipass 2>/dev/null || true
        sleep 2
        multipass delete --purge "$VM_NAME" 2>/dev/null || true
    fi
    
    # Clean up any remaining instances
    timeout 30 multipass purge 2>/dev/null || true
    
    # Verify deletion
    if multipass list | grep -q "$VM_NAME"; then
        error "VM still exists after deletion attempts!"
        info "You may need to restart multipass: sudo launchctl stop com.canonical.multipassd"
        return 1
    else
        success "VM deleted successfully"
    fi
}

# Show VM status
status() {
    section "🖥️ VM Infrastructure Status"
    
    if ! multipass list | grep -q "$VM_NAME"; then
        error "VM '$VM_NAME' not found"
        subsection "💡 Quick fix:"
        echo "    • Create VM: make start"
        return 1
    fi
    
    # Basic VM info
        multipass info "$VM_NAME"
        
        local vm_ip
        vm_ip=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')
        
    # System Health Check
    section "🔍 System Health Check"
    check_connectivity "$vm_ip"
    check_kubernetes "$vm_ip"
    
    # Security Status
    section "🛡️ Security Status"
    check_security_services "$vm_ip"
    check_firewall_status "$vm_ip"
    check_exposed_ports "$vm_ip"
    
    # Network & Services
    section "🌐 Network & Services"
    check_tailscale_status "$vm_ip"
    check_kubernetes_services "$vm_ip"
    check_argocd_status "$vm_ip"
    
    # System Resources
    section "📊 System Resources"
    check_system_resources "$vm_ip"
}

# Helper functions for status checks
check_connectivity() {
    local vm_ip="$1"
    
    info "Testing SSH connectivity..."
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$vm_ip" "echo 'SSH OK'" 2>/dev/null; then
        success "SSH connection established"
    else
        error "SSH connection failed"
        return 1
    fi
}

check_kubernetes() {
    local vm_ip="$1"
    
    info "Testing Kubernetes cluster..."
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo k3s kubectl get nodes --no-headers 2>/dev/null" | grep -q "Ready"; then
        success "Kubernetes cluster is healthy"
        
        # Show node details
        local node_info
        node_info=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo k3s kubectl get nodes -o wide --no-headers 2>/dev/null" | head -1)
        subsection "📋 Cluster details:"
        echo "    • Node: $node_info"
    else
        error "Kubernetes cluster not responding"
    fi
}

check_security_services() {
    local vm_ip="$1"
    
    info "Checking security services..."
    
    # Check fail2ban
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo systemctl is-active fail2ban 2>/dev/null" | grep -q "active"; then
        success "fail2ban is active"
    else
        warn "fail2ban is not active"
    fi
    
    # Check UFW firewall
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo ufw status 2>/dev/null" | grep -q "Status: active"; then
        success "UFW firewall is active"
    else
        warn "UFW firewall is not active"
    fi
    
    # Check auditd
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo systemctl is-active auditd 2>/dev/null" | grep -q "active"; then
        success "auditd is active"
    else
        warn "auditd is not active"
    fi
    
    # Check unattended-upgrades
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo systemctl is-active unattended-upgrades 2>/dev/null" | grep -q "active"; then
        success "unattended-upgrades is active"
    else
        warn "unattended-upgrades is not active"
    fi
}

check_firewall_status() {
    local vm_ip="$1"
    
    info "Checking firewall rules..."
    local ufw_status
    ufw_status=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo ufw status numbered 2>/dev/null")
    
    if echo "$ufw_status" | grep -q "Status: active"; then
        success "Firewall is configured"
        subsection "🔥 Active firewall rules:"
        
        # Parse and group the rules
        local ipv4_rules=""
        local ipv6_rules=""
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[[[:space:]]*[0-9]+\] ]]; then
                if [[ "$line" =~ \(v6\) ]]; then
                    ipv6_rules+="$line"$'\n'
                else
                    ipv4_rules+="$line"$'\n'
                fi
            fi
        done <<< "$ufw_status"
        
        # Display IPv4 rules with enhanced UX
        if [[ -n "$ipv4_rules" ]]; then
            echo "    📡 IPv4 Rules:"
            echo "$ipv4_rules" | while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    local rule_num=$(echo "$line" | grep -o '^\[[[:space:]]*[0-9]*\]' | tr -d '[]' | xargs)
                    local port=$(echo "$line" | grep -o '[0-9]\+/[a-z]\+' | head -1)
                    local comment=$(echo "$line" | grep -o '# .*' | sed 's/^# //')
                    local source_ip="🌍 Public"
                    
                    # Parse source IP for better security context
                    if echo "$line" | grep -q "100.64.0.0/10"; then
                        source_ip="🔒 Tailscale VPN"
                    elif echo "$line" | grep -q "192.168.0.0/16\|10.0.0.0/8\|172.16.0.0/12"; then
                        source_ip="🏠 Private Network"
                    fi
                    
                    printf "      [%2s] %-12s ← %-18s | %s\n" "$rule_num" "$port" "$source_ip" "$comment"
                fi
            done
        fi
        
        echo
        
        # Display IPv6 rules with enhanced UX
        if [[ -n "$ipv6_rules" ]]; then
            echo "    📡 IPv6 Rules:"
            echo "$ipv6_rules" | while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    local rule_num=$(echo "$line" | grep -o '^\[[[:space:]]*[0-9]*\]' | tr -d '[]' | xargs)
                    local port=$(echo "$line" | grep -o '[0-9]\+/[a-z]\+' | head -1)
                    local comment=$(echo "$line" | grep -o '# .*' | sed 's/^# //' | sed 's/ (v6)//')
                    local source_ip="🌍 Public"
                    
                    # Parse source IP for better security context
                    if echo "$line" | grep -q "100.64.0.0/10"; then
                        source_ip="🔒 Tailscale VPN"
                    elif echo "$line" | grep -q "192.168.0.0/16\|10.0.0.0/8\|172.16.0.0/12"; then
                        source_ip="🏠 Private Network"
                    fi
                    
                    printf "      [%2s] %-12s ← %-18s | %s\n" "$rule_num" "$port" "$source_ip" "$comment"
                fi
            done
        fi
        
        # Add security summary
        echo
        subsection "🛡️ Security Assessment:"
        local k8s_secured=0
        local public_k8s=0
        
        # Count K8s API rules (strip whitespace)
        k8s_secured=$(echo "$ufw_status" | grep "6443.*100\.64\|6443.*192\.168\|6443.*10\.\|6443.*172\.16" 2>/dev/null | wc -l | tr -d ' \t\n\r' || echo "0")
        public_k8s=$(echo "$ufw_status" | grep "6443.*Anywhere" 2>/dev/null | wc -l | tr -d ' \t\n\r' || echo "0")
        
        if [[ $k8s_secured -gt 0 && $public_k8s -eq 0 ]]; then
            echo "      ✅ Kubernetes API secured (VPN + Private networks only)"
        elif [[ $public_k8s -gt 0 ]]; then
            echo "      ⚠️  Kubernetes API exposed to public (HIGH SECURITY RISK)"
        fi
        
        echo "      ✅ Web services (80/443) publicly accessible for Let's Encrypt"
        echo "      ✅ SSH protected by key-based authentication only"
        echo "      ✅ Tailscale VPN uses encrypted mesh networking (no ports needed)"
    else
        warn "Firewall status unclear"
    fi
}

check_exposed_ports() {
    local vm_ip="$1"
    
    echo
    info "Checking host-level listening services..."
    local listening_ports
    listening_ports=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo ss -tulpn | grep LISTEN | grep -E ':(22|80|443|6443|8080|9000)'" 2>/dev/null)
    
    subsection "🔌 Host-level exposed ports:"
    if [[ -n "$listening_ports" ]]; then
        echo "$listening_ports" | while read -r line; do
            local port=$(echo "$line" | awk '{print $5}' | cut -d: -f2)
            local service=""
            case "$port" in
                22) service=" (SSH - Direct host service)" ;;
                80) service=" (HTTP - Direct host service)" ;;
                443) service=" (HTTPS - Direct host service)" ;;
                6443) service=" (Kubernetes API - K3s server)" ;;
                8080) service=" (ArgoCD - Direct host service)" ;;
                9000) service=" (Portainer - Direct host service)" ;;
            esac
            echo "    • Port $port$service"
        done
    else
        echo "    • No direct host services on standard ports"
    fi
    
    echo
    subsection "🌐 Kubernetes LoadBalancer routing:"
    info "Checking iptables-routed services..."
    local lb_services
    lb_services=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo iptables -L -t nat | grep 'loadbalancer IP' | grep -E 'tcp dpt:(http|https)'" 2>/dev/null)
    
    if [[ -n "$lb_services" ]]; then
        echo "    • Port 80 (HTTP) → Traefik LoadBalancer (iptables routing)"
        echo "    • Port 443 (HTTPS) → Traefik LoadBalancer (iptables routing)"
        echo "    📝 Note: These ports use kernel-level routing, not host processes"
    else
        echo "    • No LoadBalancer services detected"
    fi
}

check_tailscale_status() {
    local vm_ip="$1"
    
    info "Checking Tailscale status..."
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "command -v tailscale >/dev/null 2>&1"; then
        local tailscale_status
        tailscale_status=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo tailscale status --json 2>/dev/null" | jq -r '.BackendState' 2>/dev/null || echo "unknown")
        
        if [[ "$tailscale_status" == "Running" ]]; then
            success "Tailscale is connected"
            local tailscale_ip
            tailscale_ip=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo tailscale ip 2>/dev/null" || echo "unknown")
            subsection "🔗 Tailscale details:"
            echo "    • Tailscale IP: $tailscale_ip"
        else
            warn "Tailscale is not connected (status: $tailscale_status)"
        fi
    else
        info "Tailscale not installed (local development)"
    fi
}

check_kubernetes_services() {
    local vm_ip="$1"
    
    info "Checking Kubernetes services..."
    
    # Get all services
    local all_services
    all_services=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo k3s kubectl get svc --all-namespaces -o wide 2>/dev/null" || echo "")
    
    if [[ -n "$all_services" ]]; then
        success "Kubernetes services running"
        
        # Show externally exposed services
        local exposed_services
        exposed_services=$(echo "$all_services" | grep -E '(LoadBalancer|NodePort)' || echo "")
        
        if [[ -n "$exposed_services" ]]; then
            subsection "🌐 Externally exposed services:"
            echo "$exposed_services" | while read -r line; do
                local namespace=$(echo "$line" | awk '{print $1}')
                local name=$(echo "$line" | awk '{print $2}')
                local type=$(echo "$line" | awk '{print $3}')
                local cluster_ip=$(echo "$line" | awk '{print $4}')
                local external_ip=$(echo "$line" | awk '{print $5}')
                local ports=$(echo "$line" | awk '{print $6}')
                echo "    • $namespace/$name ($type)"
                echo "      External: $external_ip | Cluster: $cluster_ip | Ports: $ports"
            done
        else
            echo "    • No externally exposed services"
        fi
        
        # Show internal services (ClusterIP)
        local internal_services
        internal_services=$(echo "$all_services" | grep -E 'ClusterIP' | grep -v '^default.*kubernetes' || echo "")
        
        if [[ -n "$internal_services" ]]; then
            subsection "🔒 Internal cluster services:"
            echo "$internal_services" | while read -r line; do
                local namespace=$(echo "$line" | awk '{print $1}')
                local name=$(echo "$line" | awk '{print $2}')
                local type=$(echo "$line" | awk '{print $3}')
                local cluster_ip=$(echo "$line" | awk '{print $4}')
                local ports=$(echo "$line" | awk '{print $6}')
                
                # Group by namespace for better readability
                case "$namespace" in
                    "argocd")
                        echo "    • ArgoCD: $name ($cluster_ip:$ports)"
                        ;;
                    "portainer")
                        echo "    • Portainer: $name ($cluster_ip:$ports)"
                        ;;
                    "kube-system")
                        echo "    • System: $name ($cluster_ip:$ports)"
                        ;;
                    "default")
                        echo "    • Default: $name ($cluster_ip:$ports)"
                        ;;
                    *)
                        echo "    • $namespace: $name ($cluster_ip:$ports)"
                        ;;
                esac
            done
        else
            echo "    • No internal services found"
        fi
        
        # Show service summary
        local total_services
        total_services=$(echo "$all_services" | grep -v '^NAMESPACE' | wc -l | xargs)
        subsection "📊 Service summary:"
        echo "    • Total services: $total_services"
        
        local exposed_count
        exposed_count=$(echo "$exposed_services" | grep -c . 2>/dev/null || echo "0")
        echo "    • Externally exposed: $exposed_count"
        
        local internal_count
        internal_count=$(echo "$internal_services" | grep -c . 2>/dev/null || echo "0")
        echo "    • Internal services: $internal_count"
        
    else
        warn "No Kubernetes services found"
    fi
}

check_argocd_status() {
    local vm_ip="$1"
    
    echo
    info "Checking ArgoCD status..."
    if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo k3s kubectl get pods -n argocd 2>/dev/null | grep -q 'argocd-server.*Running'"; then
        success "ArgoCD is running"
        
        # Check ArgoCD applications
        local apps_status
        apps_status=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo k3s kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l" || echo "0")
        subsection "🚀 ArgoCD details:"
        echo "    • Applications managed: $apps_status"
        
        # Show app sync status
        local apps_info
        apps_info=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo k3s kubectl get applications -n argocd --no-headers 2>/dev/null" || echo "")
        if [[ -n "$apps_info" ]]; then
            echo "$apps_info" | while read -r line; do
                local app_name=$(echo "$line" | awk '{print $1}')
                local sync_status=$(echo "$line" | awk '{print $2}')
                local health_status=$(echo "$line" | awk '{print $3}')
                echo "    • $app_name: $sync_status/$health_status"
            done
        fi
    else
        warn "ArgoCD is not running"
    fi
}

check_system_resources() {
    local vm_ip="$1"
    
    info "Checking system resources..."
    local resource_info
    resource_info=$(ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "free -h | grep '^Mem:'; df -h / | tail -1; uptime" 2>/dev/null)
    
    if [[ -n "$resource_info" ]]; then
        success "System resources available"
        subsection "💾 Resource usage:"
        echo "$resource_info" | while IFS= read -r line; do
            if [[ "$line" =~ ^Mem: ]]; then
                local used=$(echo "$line" | awk '{print $3}')
                local total=$(echo "$line" | awk '{print $2}')
                echo "    • Memory: $used / $total used"
            elif [[ "$line" =~ ^/ ]]; then
                local used=$(echo "$line" | awk '{print $5}')
                local size=$(echo "$line" | awk '{print $2}')
                echo "    • Disk: $used of $size used"
            elif [[ "$line" =~ load ]]; then
                local load=$(echo "$line" | awk -F'load average: ' '{print $2}')
                echo "    • Load average: $load"
            fi
        done
    else
        warn "Could not retrieve resource information"
    fi
}

# SSH into VM
ssh_vm() {
    local vm_ip
    vm_ip=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')
    
    ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip"
}

# Main command dispatcher
case "${1:-help}" in
    create)
        create_vm
        setup_ssh
        verify_inventory
        ;;
    ansible)
        run_ansible
        ;;
    kubeconfig)
        get_kubeconfig
        ;;
    delete)
        delete_vm
        ;;
    status)
        status
        ;;
    ssh)
        ssh_vm
        ;;
    full)
        if create_vm; then
            # Check if SSH is working, if not set it up
            vm_ip=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')
            if [ -n "$vm_ip" ] && ! ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$vm_ip" "echo 'SSH test'" &>/dev/null; then
                info "SSH not configured or not working, setting up..."
        setup_ssh
            else
                info "SSH already configured and working"
            fi
        verify_inventory
        run_ansible
        status
        fi
        ;;
    help|--help|-h)
        echo "Local Development Manager - Real Ubuntu VM + Ansible + Kubernetes"
        echo
        echo "Usage: $0 <command>"
        echo
        echo "Commands:"
        echo "  create      Create Ubuntu VM and setup SSH"
        echo "  ansible     Run Ansible playbook against VM"
        echo "  kubeconfig  Get kubeconfig from VM"
        echo "  delete      Delete VM"
        echo "  status      Show VM status"
        echo "  ssh         SSH into VM"
        echo "  full        Complete setup (create + ansible)"
        echo "  help        Show this help"
        echo
        echo "Examples:"
        echo "  $0 full      # Complete local development setup (kubeconfig included)"
        echo "  $0 ssh       # Access the VM"
        echo "  $0 status    # Check everything"
        ;;
    *)
        error "Unknown command: $1"
        exit 1
        ;;
esac
