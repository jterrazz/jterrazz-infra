# Jterrazz Infrastructure Makefile

.DEFAULT_GOAL := help
.PHONY: help start stop clean ansible status deploy deps vm ssh sync

# Colors
GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
RED := \033[31m
NC := \033[0m

##@ Main Commands

start: ## Complete setup - VM, K3s, and apps
	@echo "$(GREEN)Starting local environment...$(NC)"
	./scripts/local-dev.sh full

stop: ## Delete VM and cleanup
	@echo "$(RED)Deleting VM...$(NC)"
	./scripts/local-dev.sh delete

ssh: ## SSH into the local VM
	./scripts/local-dev.sh ssh

status: ## Show services and URLs
	./scripts/local-dev.sh status

##@ Application Management

sync: ## Sync ArgoCD apps (no Ansible, fast)
	@echo "$(GREEN)Syncing applications...$(NC)"
	./scripts/sync-apps.sh local

sync-prod: ## Sync ArgoCD apps to production
	@echo "$(GREEN)Syncing production applications...$(NC)"
	./scripts/sync-apps.sh production

##@ Infrastructure

vm: ## Create VM only (no config)
	./scripts/local-dev.sh create

ansible: ## Run full Ansible playbook
	./scripts/local-dev.sh ansible

deploy: ## Deploy to production (Terraform + Ansible)
	./scripts/bootstrap.sh

##@ Utilities

deps: ## Check required tools
	@echo "$(BLUE)Checking dependencies...$(NC)"
	@command -v multipass >/dev/null 2>&1 && echo "  ✓ Multipass" || echo "  ✗ Multipass (brew install multipass)"
	@command -v ansible >/dev/null 2>&1 && echo "  ✓ Ansible" || echo "  ✗ Ansible (brew install ansible)"
	@command -v terraform >/dev/null 2>&1 && echo "  ✓ Terraform" || echo "  ✗ Terraform (brew install terraform)"
	@command -v kubectl >/dev/null 2>&1 && echo "  ✓ kubectl" || echo "  ✗ kubectl (brew install kubectl)"

clean: ## Force cleanup everything
	@echo "$(RED)Cleaning environment...$(NC)"
	@multipass delete jterrazz-infra --purge 2>/dev/null || true
	@rm -f local-kubeconfig.yaml kubeconfig.yaml
	@rm -rf local-data/
	@echo "$(GREEN)Done$(NC)"

##@ Help

help: ## Show this help
	@echo "$(GREEN)Jterrazz Infrastructure$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-12s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Workflow:"
	@echo "  1. make start     # First time setup"
	@echo "  2. make sync      # After adding/changing apps"
	@echo "  3. make status    # Check services"
