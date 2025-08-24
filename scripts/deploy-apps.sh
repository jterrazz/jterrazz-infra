#!/bin/bash
# Deploy Kubernetes applications after Ansible setup
# This script applies all the kubernetes/ manifests

set -euo pipefail

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper functions with better UX hierarchy
info() { echo -e "${BLUE}→ $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; }
section() { echo -e "\n${GREEN}▶ $1${NC}"; }
subsection() { echo -e "\n${BLUE}  $1${NC}"; }

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
        if [[ -f "local-kubeconfig.yaml" ]]; then
            info "Local kubeconfig found. Set: export KUBECONFIG=$(pwd)/local-kubeconfig.yaml"
        else
            info "Hint: Run 'make start' to set up the complete environment first."
            info "Or run './scripts/local-dev.sh kubeconfig' to get kubeconfig from existing VM."
        fi
        exit 1
    fi
    
    success "Connected to cluster"
}

# Wait for Traefik CRDs to be available
wait_for_traefik_crds() {
    info "Waiting for Traefik CRDs to be available..."
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if kubectl get crd middlewares.traefik.containo.us &>/dev/null && \
           kubectl get crd ingressroutes.traefik.containo.us &>/dev/null; then
            success "Traefik CRDs are available"
            return 0
        fi
        
        ((attempt++))
        if [[ $attempt -eq 1 ]]; then
            info "Waiting for Traefik to install CRDs... (attempt $attempt/$max_attempts)"
        elif [[ $((attempt % 5)) -eq 0 ]]; then
            info "Still waiting for Traefik CRDs... (attempt $attempt/$max_attempts)"
        fi
        sleep 1
    done
    
    warning "Traefik CRDs not available after $max_attempts attempts"
    info "This may cause some Traefik-specific resources to fail"
    return 1
}

# Deploy Traefik middleware configurations
deploy_traefik_configs() {
    section "Configuring Traefik"
    
    # Wait for Traefik CRDs first
    wait_for_traefik_crds
    
    info "Deploying middleware configurations..."
    if kubectl apply -f kubernetes/traefik/middleware.yml; then
        success "Traefik middleware configured"
    else
        warning "Failed to deploy Traefik middleware (CRDs may not be ready yet)"
    fi
}

# ArgoCD is ready for your application deployments
# Create ArgoCD applications for your actual apps (separate repositories)
setup_argocd_for_apps() {
    section "🎯 ArgoCD Ready for Applications"
    info "ArgoCD is installed and ready!"
    info "Create applications for your separate app repositories:"
    echo "  • kubectl apply -f your-app-argocd.yml"
    echo "  • kubectl apply -f your-website-argocd.yml"
    info "Check status: kubectl get applications -n argocd"
}

# Note: wait_for_sync removed - no longer deploying infrastructure via ArgoCD

# Wait for ArgoCD to be ready
wait_for_argocd() {
    info "Waiting for ArgoCD to be ready..."
    
    local max_attempts=60
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if kubectl get configmap argocd-cmd-params-cm -n argocd &>/dev/null; then
            success "ArgoCD is ready"
            return 0
        fi
        
        ((attempt++))
        if [[ $attempt -eq 1 ]]; then
            info "Waiting for ArgoCD to be fully deployed... (attempt $attempt/$max_attempts)"
        elif [[ $((attempt % 10)) -eq 0 ]]; then
            info "Still waiting for ArgoCD... (attempt $attempt/$max_attempts)"
        fi
        sleep 1
    done
    
    warning "ArgoCD not ready after $max_attempts attempts"
    return 1
}



# Configure local development setup
configure_local_setup() {
    section "Configuring Local Development"
    


    # Deploy simple landing page
    info "Deploying landing page..."
    kubectl apply -f kubernetes/services/landing-page.yml
    
    # Ensure Traefik CRDs are ready before applying ingresses
    info "Ensuring Traefik is ready for ingress configuration..."
    wait_for_traefik_crds
    
    # Apply mDNS-based ingresses for local development
    if [[ -f "kubernetes/ingress/local-mdns-ingresses.yml" ]]; then
        info "Deploying mDNS-based ingresses (app.local, argocd.local, portainer.local)..."
        if kubectl apply -f kubernetes/ingress/local-mdns-ingresses.yml; then
            success "mDNS ingresses deployed"
        else
            warning "Failed to deploy mDNS ingresses (Traefik CRDs may not be ready)"
        fi
    fi
    
    # Apply global HTTPS redirect
    if [[ -f "kubernetes/traefik/global-https-redirect.yml" ]]; then
        info "Deploying global HTTPS redirect..."
        if kubectl apply -f kubernetes/traefik/global-https-redirect.yml; then
            success "Global HTTPS redirect deployed"
        else
            warning "Failed to deploy global HTTPS redirect (Traefik CRDs may not be ready)"
        fi
    fi
    
    # Create TLS certificates using Kubernetes Job
    info "Creating TLS certificates for .local domains..."
    if kubectl apply -f kubernetes/jobs/create-tls-certificates.yml; then
        # Wait for job to complete
        if kubectl wait --for=condition=complete --timeout=120s job/create-tls-certificates; then
            success "TLS certificates created"
        else
            warning "TLS certificate job is taking longer than expected - checking status..."
            kubectl get job create-tls-certificates -o wide || true
            kubectl describe job create-tls-certificates || true
        fi
    else
        warning "Failed to create TLS certificate job"
    fi
    
    # Middleware is already deployed as part of Traefik configuration
    success "Middleware configuration already applied"
    
    # Wait for ArgoCD and configure for insecure mode (required for ingress)
    info "Configuring ArgoCD for ingress compatibility..."
    if wait_for_argocd; then
        if kubectl patch configmap argocd-cmd-params-cm -n argocd --patch '{"data":{"server.insecure":"true"}}'; then
            info "Restarting ArgoCD server..."
            kubectl rollout restart deployment argocd-server -n argocd
            success "ArgoCD configured for HTTPS ingress"
        else
            warning "Failed to configure ArgoCD insecure mode"
        fi
    else
        warning "ArgoCD not ready - skipping insecure mode configuration"
    fi
}

# Display access information
show_access_info() {
    section "🎉 Deployment Complete!"
    
    if command -v multipass &> /dev/null; then
        # Local development with mDNS - automatic .local domain resolution
        subsection "🌐 Access your applications:"
        echo "    • Landing Page:      https://app.local/"
        echo "    • ArgoCD:           https://argocd.local/"
        echo "    • Portainer:        https://portainer.local/"
        echo ""
        info "Zero-sudo DNS resolver enabled - all domains resolve automatically"
        success "Docker-like domain resolution with shared SSL certificate"
    else
        # Production environment
        subsection "🌐 Access your applications:"
        echo "    • Landing Page:      https://yourdomain.com"
        echo "    • ArgoCD:           https://argocd.yourdomain.com"
        echo "    • Portainer:        https://portainer.yourdomain.com"
        info "Configure your domain DNS to point to this server"
    fi
}

# Main execution
main() {
    echo -e "\n${GREEN}🚀 Kubernetes Application Deployment${NC}"
    echo -e "${BLUE}Setting up your applications via ArgoCD GitOps${NC}"
    
    check_cluster
    deploy_traefik_configs
    setup_argocd_for_apps
    
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
