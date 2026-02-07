#!/bin/bash
# Production deployment script
# Deploys infrastructure via Pulumi + configures server via Ansible

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PULUMI_DIR="$PROJECT_DIR/pulumi"
ANSIBLE_DIR="$PROJECT_DIR/ansible"

check_prerequisites() {
    section "Checking Prerequisites"

    local missing=()
    for tool in pulumi node ansible-playbook; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing: ${missing[*]}"
        exit 1
    fi

    success "Prerequisites OK"
}

deploy_pulumi() {
    section "Deploying Infrastructure"

    cd "$PULUMI_DIR"

    npm install
    pulumi up --stack production

    success "Infrastructure deployed"
}

run_ansible() {
    section "Configuring Server"

    cd "$PULUMI_DIR"
    local server_ip=$(pulumi stack output serverIp --stack production)

    info "Waiting for SSH..."
    for i in {1..24}; do
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$server_ip" "echo ready" &>/dev/null && break
        sleep 5
    done

    cd "$ANSIBLE_DIR"
    ansible-playbook playbooks/site.yml \
        -i inventories/production/hosts.yml \
        -e "ansible_host=$server_ip"

    success "Server configured"
}

show_summary() {
    section "Deployment Complete"

    cd "$PULUMI_DIR"
    echo
    echo "Server IP: $(pulumi stack output serverIp --stack production)"
    echo "Kubeconfig: ./kubeconfig.yaml"
    echo
    echo "Next steps:"
    echo "  1. export KUBECONFIG=./kubeconfig.yaml"
    echo "  2. kubectl get nodes"
    echo "  3. Access Portainer: https://portainer.jterrazz.com"
}

main() {
    section "Production Deployment"

    check_prerequisites
    deploy_pulumi
    run_ansible
    show_summary
}

case "${1:-}" in
    --help|-h)
        echo "Usage: $0"
        echo "Deploys production infrastructure via Pulumi + Ansible"
        ;;
    *)
        main
        ;;
esac
