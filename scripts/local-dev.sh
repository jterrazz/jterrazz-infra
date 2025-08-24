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

# Logging
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }

# VM Configuration
VM_NAME="jterrazz-infra"
VM_CPUS="4"
VM_MEMORY="8G"
VM_DISK="20G"

# Create Ubuntu VM
create_vm() {
    info "Creating Ubuntu VM '$VM_NAME'..."
    
    if multipass list | grep -q "$VM_NAME"; then
        local vm_status
        vm_status=$(multipass list | grep "$VM_NAME" | awk '{print $2}')
        
        if [ "$vm_status" = "Running" ]; then
            success "VM '$VM_NAME' is already running!"
            info "💡 If you want to start fresh, run: make clean && make start"
            info "💡 To deploy apps on existing VM, run: make apps"
            return 0
        else
            info "VM '$VM_NAME' exists but is $vm_status. Starting it..."
            multipass start "$VM_NAME"
            success "VM '$VM_NAME' started"
            return 0
        fi
    fi
    
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
    info "Local Development VM Status:"
    echo
    
    if multipass list | grep -q "$VM_NAME"; then
        multipass info "$VM_NAME"
        
        local vm_ip
        vm_ip=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')
        
        echo
        info "Testing SSH connectivity..."
        if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "echo 'SSH OK'" 2>/dev/null; then
            echo "🟢 SSH: Connected"
        else
            echo "🔴 SSH: Failed"
        fi
        
        info "Testing Kubernetes..."
        if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" -o StrictHostKeyChecking=no ubuntu@"$vm_ip" "sudo k3s kubectl get nodes" 2>/dev/null; then
            echo "🟢 Kubernetes: Running"
        else
            echo "🔴 Kubernetes: Not running"
        fi
    else
        echo "🔴 VM: Not found"
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
