#!/bin/bash
# Deploy Kubernetes applications after Ansible setup
# This script applies all the kubernetes/ manifests

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper functions
info() { echo -e "${BLUE}ℹ️ $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠️ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }

# Check if kubectl is available and cluster is reachable
check_cluster() {
    info "Checking cluster connectivity..."
    
    if ! command -v kubectl &> /dev/null; then
        error "kubectl not found. Please install kubectl or use the kubeconfig from the VM."
        exit 1
    fi
    
    # Set kubeconfig if local file exists and KUBECONFIG is not set
    if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "local-kubeconfig.yaml" ]]; then
        info "Using local kubeconfig file..."
        export KUBECONFIG="$(pwd)/local-kubeconfig.yaml"
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        info "Hint: Run 'make kubeconfig' to get the kubeconfig from your VM."
        if [[ -f "local-kubeconfig.yaml" ]]; then
            info "Or set: export KUBECONFIG=$(pwd)/local-kubeconfig.yaml"
        fi
        exit 1
    fi
    
    success "Connected to cluster"
}

# Deploy Traefik middleware configurations
deploy_traefik_configs() {
    info "Deploying Traefik middleware configurations..."
    
    if kubectl apply -f kubernetes/traefik/middleware.yml; then
        success "Traefik middleware deployed"
    else
        warning "Failed to deploy Traefik middleware (may already exist)"
    fi
}

# Deploy ArgoCD applications for GitOps
deploy_argocd_apps() {
    info "Deploying ArgoCD applications for GitOps automation..."
    
    # Deploy the ArgoCD applications that will manage everything else
    for app in kubernetes/argocd/*.yml; do
        if [[ -f "$app" ]]; then
            info "Deploying ArgoCD app: $(basename "$app")"
            if kubectl apply -f "$app"; then
                success "Applied $(basename "$app")"
            else
                warning "Failed to apply $(basename "$app")"
            fi
        fi
    done
    
    info "ArgoCD will now automatically sync and deploy your applications!"
    info "Check status at: kubectl get applications -n argocd"
}

# Wait for ArgoCD to sync applications
wait_for_sync() {
    info "Waiting for ArgoCD to sync applications..."
    
    # Give ArgoCD some time to detect and sync the applications
    sleep 10
    
    info "Checking ArgoCD application status..."
    kubectl get applications -n argocd || true
    
    success "ArgoCD applications are now managing your infrastructure!"
    info "Visit ArgoCD dashboard to monitor deployments."
}

# Configure local development setup
configure_local_setup() {
    info "Configuring local development setup..."
    
    # Create necessary namespaces
    info "Creating necessary namespaces..."
    kubectl create namespace portainer --dry-run=client -o yaml | kubectl apply -f -
    
    # Deploy simple landing page
    info "Deploying landing page service..."
    kubectl apply -f kubernetes/services/landing-page.yml
    
    # Apply HTTPS-only ingresses for local development
    if [[ -f "kubernetes/ingress/local-https-only-ingresses.yml" ]]; then
        info "Deploying HTTPS-only ingresses..."
        if kubectl apply -f kubernetes/ingress/local-https-only-ingresses.yml; then
            success "HTTPS ingresses deployed"
        else
            error "Failed to deploy HTTPS ingresses"
        fi
    fi
    
    # Apply global HTTPS redirect
    if [[ -f "kubernetes/traefik/global-https-redirect.yml" ]]; then
        info "Deploying global HTTPS redirect..."
        if kubectl apply -f kubernetes/traefik/global-https-redirect.yml; then
            success "Global HTTPS redirect deployed"
        else
            error "Failed to deploy global HTTPS redirect"
        fi
    fi
    
    # Configure ArgoCD for insecure mode (required for ingress)
    info "Configuring ArgoCD for ingress compatibility..."
    if kubectl patch configmap argocd-cmd-params-cm -n argocd --patch '{"data":{"server.insecure":"true"}}'; then
        info "Restarting ArgoCD server..."
        kubectl rollout restart deployment argocd-server -n argocd
        success "ArgoCD configured for HTTPS ingress"
    else
        error "Failed to configure ArgoCD insecure mode"
    fi
}

# Setup local DNS automation
setup_local_dns() {
    info "Setting up local DNS automation..."
    
    # Check if we're in local development (multipass available)
    if command -v multipass &> /dev/null; then
        if [[ -f "scripts/setup-local-dns.sh" ]]; then
            info "Configuring /etc/hosts for seamless local access..."
            if ./scripts/setup-local-dns.sh setup; then
                success "Local DNS configured successfully!"
                return 0
            else
                warn "Local DNS setup failed, but deployment continues..."
                return 1
            fi
        else
            warn "setup-local-dns.sh not found, skipping local DNS setup"
            return 1
        fi
    else
        info "Production environment detected - skipping local DNS setup"
        return 1
    fi
}

# Display access information
show_access_info() {
    success "🚀 Deployment Complete!"
    echo
    
    # Try to setup local DNS first
    local dns_configured=false
    if setup_local_dns; then
        dns_configured=true
    fi
    
    if [[ "$dns_configured" == "true" ]]; then
        # Local development with DNS configured - URLs already shown by DNS script
        success "🎉 HTTPS setup complete! All services accessible via secure URLs shown above"
    else
        # Production or local fallback
        info "🌐 Access your applications:"
        echo "  • Landing Page:      https://yourdomain.com"
        echo "  • ArgoCD:           https://argocd.yourdomain.com"
        echo "  • Portainer:        https://portainer.yourdomain.com"
        echo
        info "💡 Configure your domain DNS to point to this server"
    fi
    

}

# Main execution
main() {
    echo -e "${GREEN}🚀 Deploying Kubernetes Applications${NC}"
    echo "This will deploy your applications via ArgoCD GitOps"
    echo
    
    check_cluster
    deploy_traefik_configs
    deploy_argocd_apps
    wait_for_sync
    
    # Only configure local setup if we're in local development
    if command -v multipass &> /dev/null; then
        configure_local_setup
    fi
    
    show_access_info
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
