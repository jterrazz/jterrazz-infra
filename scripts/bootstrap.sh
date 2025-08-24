#!/bin/bash
# Production deployment bootstrap script

# Load common utilities
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Configuration
readonly TERRAFORM_DIR="$PROJECT_DIR/terraform"
readonly ANSIBLE_DIR="$PROJECT_DIR/ansible"

print_header() {
    echo
    echo -e "${GREEN}🚀 $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Check prerequisites
check_prerequisites() {
    section "Checking Prerequisites"
    
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
        subsection "📦 Install missing tools:"
        echo "    • Terraform: https://terraform.io/downloads"
        echo "    • Ansible: pip install ansible"
        echo "    • SSH tools: usually pre-installed"
        exit 1
    fi
    
    success "All prerequisites satisfied"
}

# Initialize Terraform
init_terraform() {
    section "Initializing Terraform"
    
    cd "$TERRAFORM_DIR"
    
    if [[ ! -f terraform.tfvars ]]; then
        error "terraform.tfvars not found!"
        echo
        subsection "📝 Configuration required:"
        echo "    • Create terraform.tfvars with your configuration"
        echo "    • See terraform.tfvars.example for template"
        exit 1
    fi
    
    info "Initializing Terraform backend..."
    terraform init
    
    info "Validating configuration..."
    terraform validate
    
    success "Terraform initialized and validated"
}

# Deploy infrastructure
deploy_infrastructure() {
    section "Deploying Infrastructure"
    
    cd "$TERRAFORM_DIR"
    
    info "Planning infrastructure deployment..."
    terraform plan -out=tfplan
    
    echo
    subsection "🤔 Review the plan above carefully"
    read -p "Deploy infrastructure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Deployment cancelled by user"
        exit 0
    fi
    
    info "Applying Terraform configuration..."
    terraform apply tfplan
    
    success "Infrastructure deployed successfully"
}

# Generate Ansible inventory
generate_inventory() {
    section "Generating Ansible Inventory"
    
    cd "$TERRAFORM_DIR"
    
    info "Extracting server information from Terraform..."
    terraform output -raw ansible_inventory > "$ANSIBLE_DIR/inventory.yml"
    
    success "Ansible inventory generated"
}

# Run Ansible playbook
configure_server() {
    section "Configuring Server with Ansible"
    
    cd "$ANSIBLE_DIR"
    
    # Wait for server SSH to be ready
    info "Waiting for server to be ready..."
    local server_ip=$(cd "$TERRAFORM_DIR" && terraform output -raw server_ip 2>/dev/null || echo "")
    if [[ -n "$server_ip" ]]; then
        local attempts=0
        while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$server_ip" "echo 'SSH ready'" &>/dev/null; do
            ((attempts++))
            if [[ $attempts -gt 12 ]]; then
                warn "Server may not be fully ready yet"
                break
            fi
            sleep 5
        done
    else
        sleep 30
    fi
    
    info "Running Ansible playbook (security, K3s, ArgoCD)..."
    ansible-playbook -i inventory.yml site.yml
    
    success "Server configuration completed"
}

# Display summary
show_summary() {
    section "🎉 Deployment Summary"
    
    cd "$TERRAFORM_DIR"
    
    echo
    subsection "📋 Access Information:"
    terraform output deployment_summary
    
    echo
    subsection "🔑 Kubernetes Access:"
    echo "    • Kubeconfig downloaded to: ./kubeconfig"
    echo "    • Set as default: export KUBECONFIG=./kubeconfig"
    
    echo
    subsection "🚀 Next Steps:"
    echo "    1. Test cluster: kubectl get nodes"
    echo "    2. Get ArgoCD password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo "    3. Deploy applications via ArgoCD UI"
    echo "    4. Configure DNS to point to your server"
    
    echo
    success "Production infrastructure is ready!"
}

# Main deployment function
main() {
    local environment="${1:-production}"
    
    print_header "Jterrazz Infrastructure Deployment"
    
    subsection "🎯 Deployment Configuration:"
    echo "    • Environment: $environment"
    echo "    • Project: $(basename "$PROJECT_ROOT")"
    echo "    • Target: Production Kubernetes cluster"
    
    check_prerequisites
    init_terraform
    deploy_infrastructure
    generate_inventory
    configure_server
    show_summary
    
    print_header "🎉 Deployment Complete!"
}

# Handle script arguments
case "${1:-}" in
    production|staging|development)
        main "$1"
        ;;
    --help|-h)
        print_header "Jterrazz Infrastructure Bootstrap"
        
        subsection "📖 Usage:"
        echo "    $0 [environment]"
        
        echo
        subsection "🌍 Environments:"
        echo "    • production   Deploy production infrastructure (default)"
        echo "    • staging      Deploy staging infrastructure"
        echo "    • development  Deploy development infrastructure"
        
        echo
        subsection "📋 Prerequisites:"
        echo "    • Terraform >= 1.0"
        echo "    • Ansible >= 2.9"
        echo "    • SSH key pair"
        echo "    • Hetzner Cloud API token"
        echo "    • Cloudflare API token (optional)"
        
        echo
        subsection "🚀 What this script does:"
        echo "    1. Validates prerequisites"
        echo "    2. Initializes Terraform"
        echo "    3. Deploys cloud infrastructure"
        echo "    4. Configures servers with Ansible"
        echo "    5. Sets up Kubernetes + ArgoCD"
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
