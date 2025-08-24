# Jterrazz Infrastructure - Simplified Makefile
# Essential commands for daily development and deployment

.DEFAULT_GOAL := help
.PHONY: help start stop clean ansible status deploy deps infra k8s vm reset ssh

# Colors
GREEN := \033[32m
YELLOW := \033[33m  
BLUE := \033[34m
RED := \033[31m
NC := \033[0m

##@ Main Commands

start: ## Complete setup - VM, K3s cluster, and applications ready
	@echo "$(GREEN)🚀 Starting Complete Local Environment Setup$(NC)"
	@echo "$(BLUE)This will create VM, configure security, install K3s, and deploy apps$(NC)"
	@echo
	./scripts/local-dev.sh full
	./scripts/deploy-apps.sh
	@echo
	@echo "$(GREEN)✓ Local environment is ready!$(NC)"
	@echo "$(BLUE)→ Check the service URLs above to access your applications$(NC)"

stop: ## Delete VM and cleanup everything
	@echo "$(RED)Deleting VM...$(NC)"
	./scripts/local-dev.sh delete

ssh: ## SSH into the development VM
	@echo "$(GREEN)Connecting to VM...$(NC)"
	./scripts/local-dev.sh ssh

status: ## Show VM health and service status
	@echo "$(BLUE)Checking VM status...$(NC)"
	./scripts/local-dev.sh status

reset: ## Clean restart - delete everything and start fresh
	@$(MAKE) clean || true
	@$(MAKE) start

##@ Sub-commands

infra: ## Setup K3s cluster ready for applications
	@echo "$(GREEN)Setting up infrastructure (VM + K3s)...$(NC)"
	./scripts/local-dev.sh full

vm: ## Create VM with SSH access
	@echo "$(GREEN)Creating Ubuntu VM...$(NC)"
	./scripts/local-dev.sh create

ansible: ## Configure VM security and system setup
	@echo "$(GREEN)Running Ansible on VM...$(NC)"
	./scripts/local-dev.sh ansible

k8s: ## Deploy applications to cluster via ArgoCD
	@echo "$(GREEN)Deploying applications via ArgoCD...$(NC)"
	./scripts/deploy-apps.sh

##@ Production

deploy: ## Deploy infrastructure and apps to production
	@echo "$(GREEN)Deploying to production...$(NC)"
	./scripts/bootstrap.sh

##@ Utilities

deps: ## Check required tools and dependencies
	@echo "$(BLUE)Checking dependencies...$(NC)"
	@echo "Local development:"
	@command -v multipass >/dev/null 2>&1 && echo "  OK Multipass" || echo "  MISSING Multipass (required - brew install multipass)"
	@command -v ansible >/dev/null 2>&1 && echo "  OK Ansible" || echo "  MISSING Ansible (required - brew install ansible)"
	@echo "Production deployment:"
	@command -v terraform >/dev/null 2>&1 && echo "  OK Terraform" || echo "  MISSING Terraform (for production)"
	@echo "Optional tools:"
	@command -v kubectl >/dev/null 2>&1 && echo "  OK kubectl" || echo "  MISSING kubectl (recommended)"

clean: ## Force delete VM and cleanup all files
	@echo "$(RED)Cleaning development environment...$(NC)"
	./scripts/local-dev.sh delete
	@rm -f local-kubeconfig.yaml ansible/local-kubeconfig.yaml kubeconfig
	@rm -rf local-data/
	@echo "$(GREEN)Environment cleaned successfully$(NC)"

##@ Help

help: ## Display this help message
	@echo "$(GREEN)Jterrazz Infrastructure - Essential Commands$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-15s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(GREEN)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(BLUE)Quick Start:$(NC)"
	@echo "  make start                  # Complete setup - everything ready!"
	@echo "  make ssh                    # SSH into your VM"
	@echo "  make status                 # Check VM status"
	@echo "  make stop                   # Delete VM"
	@echo ""
	@echo "$(BLUE)Advanced:$(NC)"
	@echo "  make infra                  # Infrastructure only (no apps)"
	@echo "  make vm                     # Create VM only"
	@echo "  make k8s                    # Deploy/redeploy applications"
	@echo "  make reset                  # Clean restart"
	@echo "  make deploy                 # Production deployment"
