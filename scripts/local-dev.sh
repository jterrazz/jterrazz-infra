#!/bin/bash

# Local Development Environment Manager
# Test Ansible + Kubernetes locally before VPS deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        missing_deps+=("docker-compose")
    fi
    
    if ! command -v ansible &> /dev/null; then
        missing_deps+=("ansible")
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing_deps+=("kubectl")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        echo
        echo "Install missing dependencies:"
        for dep in "${missing_deps[@]}"; do
            case $dep in
                docker)
                    echo "  🐳 Docker: https://docs.docker.com/get-docker/"
                    ;;
                docker-compose)
                    echo "  🐙 Docker Compose: https://docs.docker.com/compose/install/"
                    ;;
                ansible)
                    echo "  📦 Ansible: pip install ansible"
                    ;;
                kubectl)
                    echo "  ⚙️ kubectl: https://kubernetes.io/docs/tasks/tools/"
                    ;;
            esac
        done
        exit 1
    fi
    
    log_success "All dependencies found"
}

# Start local environment
start_environment() {
    log_info "Starting local development environment..."
    
    cd "$PROJECT_DIR"
    
    # Create local data directories
    mkdir -p local-data/{server,k3s,ssh}
    
    # Start containers
    docker-compose up -d
    
    log_info "Waiting for containers to be ready..."
    sleep 10
    
    # Wait for SSH to be ready
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost "echo 'SSH Ready'" &>/dev/null; then
            log_success "SSH connection established"
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_error "SSH connection failed after $max_attempts attempts"
            exit 1
        fi
        
        log_info "Waiting for SSH... (attempt $attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done
}

# Stop local environment
stop_environment() {
    log_info "Stopping local development environment..."
    
    cd "$PROJECT_DIR"
    docker-compose down
    
    log_success "Environment stopped"
}

# Clean local environment
clean_environment() {
    log_warning "This will remove all local data and containers!"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$PROJECT_DIR"
        
        # Stop and remove containers
        docker-compose down -v
        
        # Remove local data
        sudo rm -rf local-data/
        
        # Remove dangling images
        docker image prune -f
        
        log_success "Environment cleaned"
    else
        log_info "Clean cancelled"
    fi
}

# Run Ansible playbook against local environment
run_ansible() {
    log_info "Running Ansible playbook against local environment..."
    
    cd "$PROJECT_DIR/ansible"
    
    # Install Ansible collections
    ansible-galaxy install -r requirements.yml
    
    # Run unified playbook with local inventory
    ansible-playbook \
        -i inventories/local/hosts.yml \
        site.yml \
        --diff \
        --check \
        "$@"
    
    log_success "Ansible dry-run completed"
    
    read -p "Apply changes? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ansible-playbook \
            -i inventories/local/hosts.yml \
            site.yml \
            --diff \
            "$@"
        
        log_success "Ansible playbook applied"
    else
        log_info "Ansible apply cancelled"
    fi
}

# Get kubeconfig from local k3s
get_kubeconfig() {
    log_info "Getting kubeconfig from local k3s..."
    
    # Copy kubeconfig from container
    docker exec jterrazz-infra-server bash -c "
        if [ -f /etc/rancher/k3s/k3s.yaml ]; then
            cat /etc/rancher/k3s/k3s.yaml
        else
            echo 'k3s not installed yet. Run ansible first.'
            exit 1
        fi
    " > local-kubeconfig.yaml
    
    # Update server address for local access
    sed -i 's/127.0.0.1:6443/localhost:6443/g' local-kubeconfig.yaml
    
    export KUBECONFIG="$PROJECT_DIR/local-kubeconfig.yaml"
    
    log_success "Kubeconfig saved to local-kubeconfig.yaml"
    log_info "Export KUBECONFIG=$PROJECT_DIR/local-kubeconfig.yaml"
}

# Test Kubernetes connectivity
test_kubernetes() {
    log_info "Testing Kubernetes connectivity..."
    
    if [ ! -f "$PROJECT_DIR/local-kubeconfig.yaml" ]; then
        log_error "kubeconfig not found. Run 'get-kubeconfig' first."
        exit 1
    fi
    
    export KUBECONFIG="$PROJECT_DIR/local-kubeconfig.yaml"
    
    # Test basic connectivity
    if kubectl cluster-info &>/dev/null; then
        log_success "Kubernetes cluster is accessible"
        
        echo
        kubectl get nodes -o wide
        echo
        kubectl get pods -A
        
    else
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
}

# Show environment status
show_status() {
    log_info "Local Environment Status"
    echo
    
    # Docker containers
    echo "🐳 Docker Containers:"
    docker-compose ps
    echo
    
    # SSH connectivity
    echo "🔐 SSH Connectivity:"
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost "echo 'SSH: ✅ Connected'" 2>/dev/null; then
        echo "SSH: ✅ Connected"
    else
        echo "SSH: ❌ Not accessible"
    fi
    echo
    
    # Kubernetes status
    echo "☸️ Kubernetes Status:"
    if [ -f "$PROJECT_DIR/local-kubeconfig.yaml" ]; then
        export KUBECONFIG="$PROJECT_DIR/local-kubeconfig.yaml"
        if kubectl cluster-info &>/dev/null; then
            echo "Cluster: ✅ Running"
            kubectl get nodes --no-headers | awk '{print "Nodes: " $2 " (" $1 ")"}'
        else
            echo "Cluster: ❌ Not accessible"
        fi
    else
        echo "Cluster: ❓ kubeconfig not found"
    fi
    echo
    
    # Services
    echo "🌐 Local Services:"
    echo "  SSH:       localhost:2222"
    echo "  HTTP:      localhost:80"  
    echo "  HTTPS:     localhost:443"
    echo "  k3s API:   localhost:6443"
    echo "  Portainer: localhost:9000 (via k3s)"
}

# Show help
show_help() {
    cat << EOF
🏠 Local Development Environment Manager

Test your Ansible playbooks and Kubernetes configurations locally before VPS deployment.

USAGE:
    $0 <command> [options]

COMMANDS:
    start           Start local Docker environment
    stop            Stop local Docker environment  
    clean           Clean all local data and containers
    ansible         Run Ansible playbook against local environment
    get-kubeconfig  Extract kubeconfig from local k3s
    test-k8s        Test Kubernetes connectivity
    status          Show environment status
    help            Show this help message

EXAMPLES:
    # Start local environment and run full setup
    $0 start
    $0 ansible
    $0 get-kubeconfig
    $0 test-k8s
    
    # Run specific Ansible roles
    $0 ansible --tags k3s,nginx-ingress
    
    # Clean restart
    $0 clean
    $0 start

WORKFLOW:
    1. Test locally:    $0 start && $0 ansible 
    2. Verify k8s:      $0 get-kubeconfig && $0 test-k8s
    3. Deploy to VPS:   GitHub Actions or manual Terraform

EOF
}

# Main function
main() {
    case "${1:-help}" in
        start)
            check_dependencies
            start_environment
            ;;
        stop)
            stop_environment
            ;;
        clean)
            clean_environment
            ;;
        ansible)
            shift
            run_ansible "$@"
            ;;
        get-kubeconfig)
            get_kubeconfig
            ;;
        test-k8s)
            test_kubernetes
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

main "$@"
