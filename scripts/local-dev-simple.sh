#!/bin/bash
# Simplified local development manager

# Load utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/vm-utils.sh"
source "$SCRIPT_DIR/lib/status-checks.sh"

# Commands

cmd_create() {
    section "Creating Development VM"
    ensure_vm_running
    setup_vm_ssh
}

cmd_ansible() {
    section "Running Ansible Configuration"
    
    cd "$PROJECT_DIR/ansible"
    
    # Test connectivity
    info "Testing Ansible connectivity..."
    if ansible -i inventories/multipass/inventory.py -m ping all; then
        success "Ansible can reach VM"
    else
        error "Ansible cannot reach VM"
        exit 1
    fi
    
    # Run playbook
    info "Running Ansible playbook..."
    if ansible-playbook -i inventories/multipass/inventory.py site.yml -v; then
        success "Ansible configuration completed"
    else
        error "Ansible playbook failed"
        exit 1
    fi
}

cmd_kubeconfig() {
    section "Getting Kubeconfig"
    
    if [[ -f "$KUBECONFIG_PATH" ]] && check_kubectl_connection; then
        success "Existing kubeconfig is working"
        info "Use: export KUBECONFIG=$KUBECONFIG_PATH"
    else
        fetch_kubeconfig
    fi
}

cmd_status() {
    show_vm_status
}

cmd_ssh() {
    local vm_ip=$(get_vm_ip)
    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        exit 1
    fi
    
    ssh_vm
}

cmd_delete() {
    section "Deleting Development Environment"
    delete_vm
    rm -f "$KUBECONFIG_PATH"
    rm -rf "$PROJECT_DIR/local-data/"
    success "Environment cleaned"
}

cmd_full() {
    # Complete setup
    cmd_create
    cmd_ansible
    cmd_kubeconfig
    
    # Wait for services
    info "Waiting for Kubernetes services..."
    sleep 10
    
    cmd_status
}

# Help
show_help() {
    cat << EOF
Local Development Manager

Usage: $0 <command>

Commands:
  create      Create VM and setup SSH
  ansible     Run Ansible configuration
  kubeconfig  Get kubeconfig from VM
  status      Show VM and service status
  ssh         SSH into VM
  delete      Delete VM and cleanup
  full        Complete setup (create + ansible + kubeconfig)

Examples:
  $0 full      # Complete setup
  $0 status    # Check status
  $0 ssh       # Access VM
EOF
}

# Main
case "${1:-help}" in
    create)     cmd_create ;;
    ansible)    cmd_ansible ;;
    kubeconfig) cmd_kubeconfig ;;
    status)     cmd_status ;;
    ssh)        cmd_ssh ;;
    delete)     cmd_delete ;;
    full)       cmd_full ;;
    help|--help|-h) show_help ;;
    *)
        error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
