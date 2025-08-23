#!/bin/bash

# Local Development Environment Manager
# Simple script for Docker + Ansible + k3s local development

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Simple logging
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }

# Setup SSH key for passwordless access
setup_ssh_key() {
    local ssh_key_dir="$PROJECT_DIR/local-data/ssh"
    local private_key="$ssh_key_dir/id_rsa"
    local public_key="$ssh_key_dir/id_rsa.pub"
    
    # Create SSH key directory
    mkdir -p "$ssh_key_dir"
    
    # Generate SSH key pair if it doesn't exist
    if [ ! -f "$private_key" ]; then
        info "Generating SSH key pair for local development..."
        ssh-keygen -t rsa -b 2048 -f "$private_key" -N "" -C "local-dev@jterrazz-infra"
        success "SSH key pair generated"
    fi
    
    # Copy public key to container's authorized_keys
    info "Setting up SSH key authentication..."
    if docker exec jterrazz-infra-server bash -c "
        mkdir -p /home/ubuntu/.ssh &&
        echo '$(cat "$public_key")' > /home/ubuntu/.ssh/authorized_keys &&
        chown -R ubuntu:ubuntu /home/ubuntu &&
        chmod 755 /home/ubuntu &&
        chmod 700 /home/ubuntu/.ssh &&
        chmod 600 /home/ubuntu/.ssh/authorized_keys
    " 2>/dev/null; then
        success "SSH key authentication configured"
    else
        error "Failed to configure SSH key authentication"
        return 1
    fi
}

# SSH command with key authentication
ssh_cmd() {
    local ssh_key="$PROJECT_DIR/local-data/ssh/id_rsa"
    ssh ubuntu@localhost -p 2222 -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"
}

# Start local environment
start() {
    info "Starting local development environment..."
    
    cd "$PROJECT_DIR"
    
    # Start containers
    if docker-compose up -d; then
        success "Containers started"
    else
        error "Failed to start containers"
        return 1
    fi
    
    # Wait for container to be fully ready
    info "Waiting for container to initialize..."
    sleep 10
    
    # Wait for ubuntu user to be created and SSH to be ready
    info "Waiting for SSH service..."
    for i in {1..20}; do
        if docker exec jterrazz-infra-server test -d /home/ubuntu 2>/dev/null; then
            success "Container initialization complete"
            break
        fi
        
        if [ $i -eq 20 ]; then
            error "Container failed to initialize after 40 seconds"
            return 1
        fi
        
        sleep 2
    done
    
    # Setup SSH keys
    setup_ssh_key
    
    # Wait for SSH to be ready with key authentication
    info "Testing SSH connection..."
    for i in {1..10}; do
        if ssh_cmd "echo 'ready'" 2>/dev/null; then
            success "SSH service ready"
            break
        fi
        
        if [ $i -eq 10 ]; then
            error "SSH connection failed after 10 attempts"
            return 1
        fi
        
        sleep 2
    done
    
    success "Local environment ready"
}

# Stop local environment
stop() {
    info "Stopping local development environment..."
    
    cd "$PROJECT_DIR"
    
    if docker-compose down; then
        success "Environment stopped"
    else
        warn "Some containers may still be running"
    fi
}

# Clean local environment
clean() {
    info "Cleaning local development environment..."
    
    cd "$PROJECT_DIR"
    
    # Confirm destructive action
    warn "This will remove all local data!"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Clean cancelled"
        return 0
    fi
    
    # Stop and remove containers
    docker-compose down -v
    
    # Remove local data using Docker (no sudo needed)
    if [ -d "local-data" ]; then
        docker run --rm -v "$PWD/local-data:/data" ubuntu:22.04 rm -rf /data/* || true
        rm -rf local-data/
    fi
    
    # Remove dangling images
    docker image prune -f
    
    success "Environment cleaned"
}

# Run Ansible playbook
ansible() {
    info "Running Ansible playbook..."
    
    cd "$PROJECT_DIR/ansible"
    
    # Build command with any additional arguments
    local cmd="ansible-playbook -i inventories/local/hosts.yml site.yml"
    if [ $# -gt 0 ]; then
        cmd="$cmd $*"
    fi
    
    info "Command: $cmd"
    
    if eval "$cmd"; then
        success "Ansible playbook completed"
    else
        error "Ansible playbook failed"
        return 1
    fi
}

# Get kubeconfig from local k3s
get_kubeconfig() {
    info "Getting kubeconfig from local k3s..."
    
    cd "$PROJECT_DIR"
    
    # Get kubeconfig from container
    if docker exec jterrazz-infra-server test -f /etc/rancher/k3s/k3s.yaml; then
        # Copy and modify kubeconfig
        docker exec jterrazz-infra-server cat /etc/rancher/k3s/k3s.yaml | \
            sed 's/127.0.0.1/localhost/g' | \
            sed 's/6443/6443/g' > local-kubeconfig.yaml
        
        success "Kubeconfig saved to local-kubeconfig.yaml"
        info "Use: export KUBECONFIG=./local-kubeconfig.yaml"
    else
        error "k3s not installed or kubeconfig not found"
        return 1
    fi
}

# Show local environment status
status() {
    info "Local Environment Status:"
    echo
    
    # Container status
    if docker ps --filter "name=jterrazz-infra-server" --format "table {{.Names}}\t{{.Status}}" | grep -q jterrazz-infra-server; then
        echo "🟢 Container: Running"
    else
        echo "🔴 Container: Stopped"
        return 0
    fi
    
    # SSH connectivity
    if ssh_cmd "echo 'ok'" 2>/dev/null; then
        echo "🟢 SSH: Connected"
    else
        echo "🔴 SSH: Not available"
        return 0
    fi
    
    # k3s status
    if docker exec jterrazz-infra-server systemctl is-active k3s 2>/dev/null | grep -q active; then
        echo "🟢 k3s: Running"
        
        # Node count
        local nodes
        nodes=$(docker exec jterrazz-infra-server kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        echo "📊 Nodes: $nodes"
        
        # Pod count
        local pods
        pods=$(docker exec jterrazz-infra-server kubectl get pods -A --no-headers 2>/dev/null | wc -l || echo "0")
        echo "📊 Pods: $pods"
    else
        echo "🔴 k3s: Not running"
    fi
    
    # Kubeconfig availability
    if [ -f "$PROJECT_DIR/local-kubeconfig.yaml" ]; then
        echo "🟢 Kubeconfig: Available"
    else
        echo "🔴 Kubeconfig: Not found (run: make kubeconfig)"
    fi
}

# Show help
show_help() {
    echo "Local Development Environment Manager"
    echo
    echo "Usage: $0 <command>"
    echo
    echo "Commands:"
    echo "  start           Start local Docker environment"
    echo "  stop            Stop local environment"
    echo "  clean           Clean local environment (removes data)"
    echo "  ansible [args]  Run Ansible playbook with optional arguments"
    echo "  get-kubeconfig  Get kubeconfig from local k3s cluster"
    echo "  status          Show local environment status"
    echo "  help            Show this help message"
    echo
    echo "Examples:"
    echo "  $0 ansible --tags=k3s"
    echo "  $0 ansible --check"
}

# Main command dispatcher
main() {
    case "${1:-help}" in
        start)
            start
            ;;
        stop)
            stop
            ;;
        clean)
            clean
            ;;
        ansible)
            shift
            ansible "$@"
            ;;
        get-kubeconfig)
            get_kubeconfig
            ;;
        status)
            status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"