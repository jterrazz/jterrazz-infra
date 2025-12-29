#!/bin/bash
# Sync ArgoCD applications without running full Ansible
# Usage: ./scripts/sync-apps.sh [local|production]

set -euo pipefail

ENV="${1:-local}"
KUBECONFIG_FILE="${ENV}-kubeconfig.yaml"

if [[ "$ENV" == "production" ]]; then
    KUBECONFIG_FILE="kubeconfig.yaml"
fi

if [[ ! -f "$KUBECONFIG_FILE" ]]; then
    echo "Error: $KUBECONFIG_FILE not found"
    echo "Run 'make start' first to setup the cluster"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

echo "Syncing ArgoCD applications..."

# Apply infrastructure (ArgoCD, Portainer, etc.)
kubectl apply -k "kubernetes/infrastructure/environments/$ENV"

# Apply all application definitions
for app in kubernetes/applications/*.yaml; do
    if [[ -f "$app" ]]; then
        echo "  Applying $(basename "$app")..."
        kubectl apply -f "$app"
    fi
done

echo ""
echo "Done. ArgoCD will now sync your applications."
echo "Check status: kubectl get applications -n platform-gitops"
