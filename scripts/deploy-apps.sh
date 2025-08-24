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
        sleep 2
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

# Deploy ArgoCD applications for GitOps
deploy_argocd_apps() {
    section "Setting up GitOps with ArgoCD"
    info "Deploying application manifests..."
    
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
    sleep 10
    
    info "Checking ArgoCD application status..."
    echo
    kubectl get applications -n argocd || true
    echo
    
    success "ArgoCD applications are now managing your infrastructure!"
    info "Visit ArgoCD dashboard to monitor deployments."
}

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
        sleep 3
    done
    
    warning "ArgoCD not ready after $max_attempts attempts"
    return 1
}

# Create TLS certificates for local .local domains
create_local_tls_certificates() {
    # Check if certificates already exist
    if kubectl get secret local-tls-secret -n default &> /dev/null; then
        success "TLS certificates already exist"
        return 0
    fi
    
    # Create temporary certificate files
    local temp_key="/tmp/local-tls.key"
    local temp_crt="/tmp/local-tls.crt"
    local temp_cnf="/tmp/openssl.cnf"
    
    # Create proper OpenSSL config for browser compatibility
    cat > "$temp_cnf" << 'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = *.local

[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = app.local
DNS.2 = argocd.local
DNS.3 = portainer.local
DNS.4 = *.local
EOF
    
    # Generate certificate with proper key usage for browser compatibility
    if openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$temp_key" -out "$temp_crt" \
        -config "$temp_cnf" -extensions v3_req &> /dev/null; then
        
        # Create TLS secrets in all required namespaces
        kubectl create secret tls local-tls-secret --cert="$temp_crt" --key="$temp_key" -n default &> /dev/null || true
        kubectl create secret tls local-tls-secret --cert="$temp_crt" --key="$temp_key" -n argocd &> /dev/null || true
        kubectl create secret tls local-tls-secret --cert="$temp_crt" --key="$temp_key" -n portainer &> /dev/null || true
        
        # Clean up temporary files
        rm -f "$temp_key" "$temp_crt" "$temp_cnf"
        success "TLS certificates created with browser-compatible key usage"
    else
        warning "Failed to create TLS certificates"
        rm -f "$temp_key" "$temp_crt" "$temp_cnf"
    fi
}

# Create HTTPS redirect middleware required by ingresses
create_https_redirect_middleware() {
    # Check if middleware already exists
    if kubectl get middleware https-redirect-global -n default &> /dev/null; then
        success "HTTPS redirect middleware already exists"
        return 0
    fi
    
    # Create the middleware
    if cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: https-redirect-global
  namespace: default
spec:
  redirectScheme:
    scheme: https
    permanent: true
EOF
    then
        success "HTTPS redirect middleware created"
    else
        warning "Failed to create HTTPS redirect middleware"
    fi
}

# Configure local development setup
configure_local_setup() {
    section "Configuring Local Development"
    
    # Create necessary namespaces
    info "Setting up namespaces..."
    kubectl create namespace portainer --dry-run=client -o yaml | kubectl apply -f -
    
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
    
    # Create TLS certificates for .local domains
    info "Creating TLS certificates for .local domains..."
    create_local_tls_certificates
    
    # Create required middleware for ingresses
    info "Creating required middleware..."
    create_https_redirect_middleware
    
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
    
    # Set up ultra-simple DNS resolver
    info "Configuring ultra-simple DNS resolver..."
    if [[ -f "$PROJECT_DIR/scripts/setup-mdns-resolver.sh" ]]; then
        "$PROJECT_DIR/scripts/setup-mdns-resolver.sh" > /dev/null 2>&1 || true
        success "Ultra-simple DNS resolver configured (just like Docker!)"
    fi
}

# Zero-sudo DNS resolver provides Docker-like domain resolution

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
