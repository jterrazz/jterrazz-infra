#!/bin/bash
# Local VM management utilities (Multipass)
# Provides: VM lifecycle, SSH access, IP resolution

# VM Configuration
export VM_NAME="${VM_NAME:-jterrazz-infra}"
export VM_CPUS="${VM_CPUS:-4}"
export VM_MEMORY="${VM_MEMORY:-8G}"
export VM_DISK="${VM_DISK:-20G}"
export KUBECONFIG_PATH="$PROJECT_DIR/local-kubeconfig.yaml"

# Check if we're in local environment (multipass available)
is_local() {
    command -v multipass &> /dev/null
}

# Get VM IP reliably
get_vm_ip() {
    if is_local && multipass info "$VM_NAME" &>/dev/null; then
        multipass info "$VM_NAME" --format json 2>/dev/null | \
            jq -r ".info.\"$VM_NAME\".ipv4[0] // empty" | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || echo ""
    fi
}

# SSH helper for VM
ssh_vm() {
    local vm_ip
    vm_ip=$(get_vm_ip)

    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        return 1
    fi

    mkdir -p "$PROJECT_DIR/data/ssh"

    ssh -i "$PROJECT_DIR/data/ssh/id_rsa" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$PROJECT_DIR/data/ssh/known_hosts" \
        -o PasswordAuthentication=no \
        -o ConnectTimeout=5 \
        -o LogLevel=QUIET \
        ubuntu@"$vm_ip" "$@" 2>/dev/null
}

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

        info "Waiting for VM network..."
        local retries=30
        while [[ $retries -gt 0 ]]; do
            local vm_ip=$(get_vm_ip)
            if [[ -n "$vm_ip" ]] && ping -c 1 -W 1 "$vm_ip" &>/dev/null; then
                success "VM network ready (IP: $vm_ip)"
                break
            fi
            sleep 2
            retries=$((retries - 1))
        done

        if [[ $retries -eq 0 ]]; then
            error "VM network not ready after 60 seconds"
            return 1
        fi
    else
        local status=$(get_vm_status)
        if [[ "$status" != "Running" ]]; then
            info "Starting VM '$VM_NAME'..."
            multipass start "$VM_NAME"
            sleep 5
            success "VM started"
        else
            success "VM '$VM_NAME' is already running"
        fi
    fi
}

# Setup SSH access
setup_vm_ssh() {
    local ssh_dir="$PROJECT_DIR/data/ssh"
    local key_path="$ssh_dir/id_rsa"

    mkdir -p "$ssh_dir"

    if [[ ! -f "$key_path" ]]; then
        ssh-keygen -t rsa -b 2048 -f "$key_path" -N "" -C "local-dev@$VM_NAME"
        success "SSH key generated"
    fi

    local vm_ip=$(get_vm_ip)
    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        return 1
    fi

    ssh-keygen -R "$vm_ip" 2>/dev/null || true
    rm -f "$ssh_dir/known_hosts" 2>/dev/null || true

    # Inject SSH key into VM
    # Note: use "bash -c" wrapper — bare "multipass exec -- echo" hangs in non-interactive shells
    info "Injecting SSH key into VM..."
    local pub_key
    pub_key=$(cat "$key_path.pub")
    multipass exec "$VM_NAME" -- bash -c "
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        echo '$pub_key' >> ~/.ssh/authorized_keys
        sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
    "

    info "Testing SSH connection..."
    local ssh_retries=15
    while [[ $ssh_retries -gt 0 ]]; do
        if ssh_vm "echo 'SSH test successful'" >/dev/null 2>&1; then
            success "SSH configured successfully"
            echo "VM IP: $vm_ip"
            return 0
        fi
        sleep 2
        ssh_retries=$((ssh_retries - 1))
    done

    error "SSH setup failed after retries"
    return 1
}

# Delete VM completely
delete_vm() {
    if ! vm_exists; then
        success "VM '$VM_NAME' already removed"
        return 0
    fi

    info "Deleting VM '$VM_NAME'..."
    multipass stop "$VM_NAME" 2>/dev/null || true

    if multipass delete "$VM_NAME" 2>/dev/null && multipass purge 2>/dev/null; then
        success "VM deleted successfully"
    else
        warn "VM deletion may have failed - check 'multipass list'"
    fi
}
