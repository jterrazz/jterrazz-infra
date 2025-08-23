#!/bin/bash

# JTerrazz Infrastructure - Bootstrap Script
# One-click deployment of entire infrastructure

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly TERRAFORM_DIR="$PROJECT_ROOT/terraform"
readonly ANSIBLE_DIR="$PROJECT_ROOT/ansible"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

print_header() {
    echo
    echo -e "${BLUE}═══ $1 ═══${NC}"
    echo
}

print_section() {
    echo
    echo -e "${BLUE}▸ $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_section "Checking Prerequisites"
    
    local missing=()
    
    # Check required tools
    for tool in terraform ansible-playbook ssh-keygen; do
        if ! command -v "$tool" &> /dev/null; then
            missing+=("$tool")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        echo
        echo "Install missing tools:"
        echo "• Terraform: https://terraform.io/downloads"
        echo "• Ansible: pip install ansible"
        echo "• SSH tools: usually pre-installed"
        exit 1
    fi
    
    log "All prerequisites satisfied ✅"
}

# Initialize Terraform
init_terraform() {
    print_section "Initializing Terraform"
    
    cd "$TERRAFORM_DIR"
    
    if [[ ! -f terraform.tfvars ]]; then
        error "terraform.tfvars not found!"
        echo
        echo "Create terraform.tfvars with your configuration:"
        echo "See terraform.tfvars.example for template"
        exit 1
    fi
    
    log "Initializing Terraform..."
    terraform init
    
    log "Validating Terraform configuration..."
    terraform validate
    
    log "Terraform initialized ✅"
}

# Deploy infrastructure
deploy_infrastructure() {
    print_section "Deploying Infrastructure"
    
    cd "$TERRAFORM_DIR"
    
    log "Planning infrastructure deployment..."
    terraform plan -out=tfplan
    
    echo
    read -p "Deploy infrastructure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Deployment cancelled"
        exit 0
    fi
    
    log "Applying Terraform configuration..."
    terraform apply tfplan
    
    log "Infrastructure deployed ✅"
}

# Generate Ansible inventory
generate_inventory() {
    print_section "Generating Ansible Inventory"
    
    cd "$TERRAFORM_DIR"
    
    log "Generating Ansible inventory from Terraform output..."
    terraform output -raw ansible_inventory > "$ANSIBLE_DIR/inventory.yml"
    
    log "Ansible inventory generated ✅"
}

# Run Ansible playbook
configure_server() {
    print_section "Configuring Server with Ansible"
    
    cd "$ANSIBLE_DIR"
    
    # Wait for server to be ready
    log "Waiting for server to be ready..."
    sleep 30
    
    log "Running Ansible playbook..."
    ansible-playbook -i inventory.yml site.yml
    
    log "Server configuration completed ✅"
}

# Display summary
show_summary() {
    print_section "Deployment Summary"
    
    cd "$TERRAFORM_DIR"
    
    echo
    echo "🎉 Infrastructure deployment completed successfully!"
    echo
    echo "📋 Access Information:"
    terraform output deployment_summary
    echo
    echo "🔑 Kubeconfig downloaded to: ./kubeconfig"
    echo "   Set it as default: export KUBECONFIG=./kubeconfig"
    echo
    echo "🚀 Next Steps:"
    echo "1. Test Kubernetes: kubectl get nodes"
    echo "2. Access ArgoCD: kubectl -n argocd get secret argocd-initial-admin-secret"
    echo "3. Deploy your applications via ArgoCD"
    echo
}

# Main deployment function
main() {
    local environment="${1:-production}"
    
    print_header "JTerrazz Infrastructure Deployment"
    
    info "Environment: $environment"
    info "Project: $(basename "$PROJECT_ROOT")"
    echo
    
    check_prerequisites
    init_terraform
    deploy_infrastructure
    generate_inventory
    configure_server
    show_summary
    
    print_header "Deployment Complete! 🎉"
}

# Handle script arguments
case "${1:-}" in
    production|staging|development)
        main "$1"
        ;;
    --help|-h)
        echo "Usage: $0 [environment]"
        echo
        echo "Environments:"
        echo "  production   Deploy production infrastructure (default)"
        echo "  staging      Deploy staging infrastructure"
        echo "  development  Deploy development infrastructure"
        echo
        echo "Prerequisites:"
        echo "  • Terraform >= 1.0"
        echo "  • Ansible >= 2.9"
        echo "  • SSH key pair"
        echo "  • Hetzner Cloud API token"
        echo "  • Cloudflare API token (optional)"
        echo
        exit 0
        ;;
    "")
        main "production"
        ;;
    *)
        error "Unknown environment: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
