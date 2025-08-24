#!/bin/bash
# VM management utilities

# VM Configuration
export VM_CPUS="${VM_CPUS:-4}"
export VM_MEMORY="${VM_MEMORY:-8G}"
export VM_DISK="${VM_DISK:-20G}"

# Check if VM exists
vm_exists() {
    multipass list 2>/dev/null | grep -q "$VM_NAME"
}

# Get VM status
get_vm_status() {
    multipass list 2>/dev/null | grep "$VM_NAME" | awk '{print $2}'
}

# Create or start VM
ensure_vm_running() {
    if ! vm_exists; then
        info "Creating new VM '$VM_NAME'..."
        multipass launch \
            --name "$VM_NAME" \
            --cpus "$VM_CPUS" \
            --memory "$VM_MEMORY" \
            --disk "$VM_DISK" \
            lts
        success "VM created successfully"
    else
        local status=$(get_vm_status)
        if [[ "$status" != "Running" ]]; then
            info "Starting VM '$VM_NAME'..."
            multipass start "$VM_NAME"
            success "VM started"
        else
            success "VM '$VM_NAME' is already running"
        fi
    fi
}

# Setup SSH access
setup_vm_ssh() {
    local ssh_dir="$PROJECT_DIR/local-data/ssh"
    local key_path="$ssh_dir/id_rsa"
    
    # Create SSH directory
    mkdir -p "$ssh_dir"
    
    # Generate SSH key if needed
    if [[ ! -f "$key_path" ]]; then
        ssh-keygen -t rsa -b 2048 -f "$key_path" -N "" -C "local-dev@$VM_NAME"
        success "SSH key generated"
    fi
    
    # Get VM IP
    local vm_ip=$(get_vm_ip)
    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        return 1
    fi
    
    # Clean known hosts
    ssh-keygen -R "$vm_ip" 2>/dev/null || true
    
    # Install public key
    local pub_key=$(cat "$key_path.pub")
    multipass exec "$VM_NAME" -- bash -c "
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        echo '$pub_key' > ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
    "
    
    # Test connection
    if ssh_vm "echo 'SSH test successful'" >/dev/null 2>&1; then
        success "SSH configured successfully"
        echo "VM IP: $vm_ip"
    else
        error "SSH setup failed"
        return 1
    fi
}

# Fetch kubeconfig from VM
fetch_kubeconfig() {
    local vm_ip=$(get_vm_ip)
    
    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        return 1
    fi
    
    # Fetch kubeconfig
    if scp -i "$PROJECT_DIR/local-data/ssh/id_rsa" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        ubuntu@"$vm_ip":/etc/rancher/k3s/k3s.yaml \
        "$KUBECONFIG_PATH"; then
        
        # Update server address
        sed -i.bak "s/127.0.0.1/$vm_ip/g" "$KUBECONFIG_PATH"
        rm -f "$KUBECONFIG_PATH.bak"
        
        success "Kubeconfig fetched successfully"
        info "Use: export KUBECONFIG=$KUBECONFIG_PATH"
        return 0
    else
        error "Failed to fetch kubeconfig"
        return 1
    fi
}

# Delete VM completely
delete_vm() {
    if ! vm_exists; then
        success "VM '$VM_NAME' already removed"
        return 0
    fi
    
    info "Deleting VM '$VM_NAME'..."
    
    # Try graceful shutdown
    multipass stop "$VM_NAME" 2>/dev/null || true
    
    # Delete VM
    if multipass delete "$VM_NAME" 2>/dev/null && multipass purge 2>/dev/null; then
        success "VM deleted successfully"
    else
        warn "VM deletion may have failed - check 'multipass list'"
    fi
}
