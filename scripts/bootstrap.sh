#!/bin/bash
# Production deployment script

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

readonly TERRAFORM_DIR="$PROJECT_DIR/terraform"
readonly ANSIBLE_DIR="$PROJECT_DIR/ansible"

check_prerequisites() {
    section "Checking Prerequisites"

    local missing=()
    for tool in terraform ansible-playbook; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing: ${missing[*]}"
        exit 1
    fi

    success "Prerequisites OK"
}

deploy_terraform() {
    section "Deploying Infrastructure"

    cd "$TERRAFORM_DIR"

    terraform init
    terraform plan -out=tfplan

    read -p "Apply changes? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0

    terraform apply tfplan
    success "Infrastructure deployed"
}

run_ansible() {
    section "Configuring Server"

    cd "$TERRAFORM_DIR"
    local server_ip=$(terraform output -raw server_ip)

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

    cd "$TERRAFORM_DIR"
    echo
    echo "Server IP: $(terraform output -raw server_ip)"
    echo "Kubeconfig: ./kubeconfig.yaml"
    echo
    echo "Next steps:"
    echo "  1. export KUBECONFIG=./kubeconfig.yaml"
    echo "  2. kubectl get nodes"
    echo "  3. Access ArgoCD at https://argocd.yourdomain.com"
}

main() {
    section "Production Deployment"

    check_prerequisites
    deploy_terraform
    run_ansible
    show_summary
}

case "${1:-}" in
    --help|-h)
        echo "Usage: $0"
        echo "Deploys production infrastructure via Terraform + Ansible"
        ;;
    *)
        main
        ;;
esac
