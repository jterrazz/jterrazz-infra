#!/bin/bash
# Local Development Manager
# Manages Multipass VM for local k3s development

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/vm-utils.sh"
source "$SCRIPT_DIR/lib/status-checks.sh"

cmd_create() {
    section "Creating Development VM"
    ensure_vm_running
    setup_vm_ssh
}

cmd_ansible() {
    section "Running Ansible Configuration"

    local vm_ip=$(get_vm_ip)
    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        exit 1
    fi

    cd "$PROJECT_DIR/ansible"

    info "Running Ansible playbook..."
    if ansible-playbook playbooks/site.yml \
        -i inventories/local/hosts.yml \
        -e "ansible_host=$vm_ip" \
        -v; then
        success "Ansible configuration completed"
    else
        error "Ansible playbook failed"
        exit 1
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
    rm -f "$PROJECT_DIR/local-kubeconfig.yaml"
    rm -rf "$PROJECT_DIR/local-data/"
    success "Environment cleaned"
}

cmd_full() {
    cmd_create
    cmd_ansible

    info "Waiting for services to start..."
    sleep 10

    cmd_status
}

show_help() {
    cat << EOF
Local Development Manager

Usage: $0 <command>

Commands:
  create      Create VM and setup SSH
  ansible     Run Ansible configuration
  status      Show VM and service status
  ssh         SSH into VM
  delete      Delete VM and cleanup
  full        Complete setup (create + ansible)

Examples:
  $0 full      # Complete setup
  $0 status    # Check status
  $0 ssh       # Access VM
EOF
}

case "${1:-help}" in
    create)     cmd_create ;;
    ansible)    cmd_ansible ;;
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
