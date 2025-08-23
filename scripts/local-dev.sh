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
VM_NAME="jterrazz-dev"
VM_CPUS="2"
VM_MEMORY="4G"
VM_DISK="20G"

# Create Ubuntu VM
create_vm() {
    info "Creating Ubuntu VM '$VM_NAME'..."
    
    if multipass list | grep -q "$VM_NAME"; then
        warn "VM '$VM_NAME' already exists"
        return 0
    fi
    
    multipass launch \
        --name "$VM_NAME" \
        --cpus "$VM_CPUS" \
        --memory "$VM_MEMORY" \
        --disk "$VM_DISK" \
        22.04
    
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
    
    # Install public key in VM (replace existing to avoid duplicates)
    local pub_key
    pub_key=$(cat "$PROJECT_DIR/local-data/ssh/id_rsa.pub")
    
    multipass exec "$VM_NAME" -- bash -c "
        mkdir -p ~/.ssh &&
        # Remove any existing entries for this key
        grep -v 'local-dev@jterrazz-infra' ~/.ssh/authorized_keys 2>/dev/null > ~/.ssh/authorized_keys.tmp || touch ~/.ssh/authorized_keys.tmp &&
        # Add the new key
        echo '$pub_key' >> ~/.ssh/authorized_keys.tmp &&
        mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys &&
        chmod 700 ~/.ssh &&
        chmod 600 ~/.ssh/authorized_keys
    "
    
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

# Update Ansible inventory for local VM
update_inventory() {
    info "Updating Ansible inventory..."
    
    local vm_ip
    vm_ip=$(multipass info "$VM_NAME" | grep IPv4 | awk '{print $2}')
    
    # Create local development inventory
    cat > "$PROJECT_DIR/ansible/inventories/local/hosts.yml" << EOF
---
all:
  children:
    jterrazz:
      hosts:
        jterrazz-local:
          ansible_host: $vm_ip
          ansible_user: ubuntu
          ansible_ssh_private_key_file: ${PROJECT_DIR}/local-data/ssh/id_rsa
          ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
          
          # Environment configuration
          environment_type: "local"
          domain_name: "local.dev"
          
          # Skip components that don't work well in local dev
          skip_security: false  # Enable full security testing
          skip_tailscale: true  # Skip VPN for local testing
          skip_argocd: false    # Enable ArgoCD
          
      vars:
        ansible_python_interpreter: /usr/bin/python3
EOF

    # Ensure directory exists
    mkdir -p "$PROJECT_DIR/ansible/inventories/local"
    
    success "Ansible inventory updated"
    info "VM accessible at: $vm_ip"
}

# Run Ansible playbook against VM
run_ansible() {
    info "Running Ansible playbook against local VM..."
    
    cd "$PROJECT_DIR/ansible"
    
    # Test connectivity first
    ansible -i inventories/local/hosts.yml -m ping all
    
    # Run the full playbook
    ansible-playbook -i inventories/local/hosts.yml site.yml -v
    
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
    
    # Clean up any conflicting SSH host keys for this IP
    ssh-keygen -R "$vm_ip" 2>/dev/null || true
    ssh-keygen -R "192.168.64.*" 2>/dev/null || true
    
    # Copy kubeconfig from VM using robust SSH options
    scp -i "$PROJECT_DIR/local-data/ssh/id_rsa" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PasswordAuthentication=no \
        -o IdentitiesOnly=yes \
        -o ConnectTimeout=10 \
        ubuntu@"$vm_ip":/etc/rancher/k3s/k3s.yaml \
        "$PROJECT_DIR/local-kubeconfig.yaml" || {
        error "Failed to copy kubeconfig. SSH authentication failed."
        info "This usually happens after VM recreation. Try: make clean && make start"
        exit 1
    }
    
    # Update server address
    sed -i.bak "s/127.0.0.1/$vm_ip/g" "$PROJECT_DIR/local-kubeconfig.yaml"
    
    success "Kubeconfig saved to local-kubeconfig.yaml"
    info "Use: export KUBECONFIG=$PROJECT_DIR/local-kubeconfig.yaml"
}

# Delete VM
delete_vm() {
    info "Deleting VM '$VM_NAME'..."
    
    if multipass list | grep -q "$VM_NAME"; then
        multipass delete "$VM_NAME"
        multipass purge
        success "VM deleted"
    else
        warn "VM '$VM_NAME' not found"
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
        if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 \
               ubuntu@"$vm_ip" "echo 'SSH OK'" 2>/dev/null; then
            echo "🟢 SSH: Connected"
        else
            echo "🔴 SSH: Failed"
        fi
        
        info "Testing Kubernetes..."
        if ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               ubuntu@"$vm_ip" "sudo k3s kubectl get nodes" 2>/dev/null; then
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
    
    ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        ubuntu@"$vm_ip"
}

# Main command dispatcher
case "${1:-help}" in
    create)
        create_vm
        setup_ssh
        update_inventory
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
        create_vm
        setup_ssh
        update_inventory
        run_ansible
        status
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
