#!/bin/bash
# Common utilities for all scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

# Colors
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Logging functions
info() { echo -e "${BLUE}→ $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}" >&2; }
section() { echo -e "\n${GREEN}▶ $1${NC}"; }
subsection() { echo -e "\n${BLUE}  $1${NC}"; }

# Script setup - will be overridden by caller if needed
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
fi
if [[ -z "${PROJECT_DIR:-}" ]]; then
    export PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Common configuration
export VM_NAME="${VM_NAME:-jterrazz-infra}"
export KUBECONFIG_PATH="$PROJECT_DIR/local-kubeconfig.yaml"

# Check if we're in development (multipass available)
is_development() {
    command -v multipass &> /dev/null
}

# Setup kubeconfig for kubectl commands
setup_kubeconfig() {
    if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "$KUBECONFIG_PATH" ]]; then
        export KUBECONFIG="$KUBECONFIG_PATH"
        return 0
    fi
    return 1
}

# Get VM IP reliably
get_vm_ip() {
    if is_development && multipass info "$VM_NAME" &>/dev/null; then
        multipass info "$VM_NAME" --format json 2>/dev/null | \
            jq -r ".info.\"$VM_NAME\".ipv4[0] // empty" | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || echo ""
    fi
}

# Check if kubectl can connect to cluster
check_kubectl_connection() {
    if ! command -v kubectl &> /dev/null; then
        return 1
    fi
    
    setup_kubeconfig
    kubectl cluster-info &> /dev/null
}

# Run command with automatic kubeconfig setup
run_kubectl() {
    setup_kubeconfig
    kubectl "$@"
}

# SSH helper for VM
ssh_vm() {
    local vm_ip
    vm_ip=$(get_vm_ip)
    
    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        return 1
    fi
    
    # Create SSH directory if it doesn't exist
    mkdir -p "$PROJECT_DIR/local-data/ssh"
    
    # Use SSH with suppressed warnings but functional authentication
    ssh -i "$PROJECT_DIR/local-data/ssh/id_rsa" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$PROJECT_DIR/local-data/ssh/known_hosts" \
        -o PasswordAuthentication=no \
        -o ConnectTimeout=5 \
        -o LogLevel=QUIET \
        ubuntu@"$vm_ip" "$@" 2>/dev/null
}
