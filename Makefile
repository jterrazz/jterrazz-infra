# JTerrazz Infrastructure - Simplified Makefile
# Essential commands for daily development and deployment

.DEFAULT_GOAL := help
.PHONY: help start stop clean nuke ansible kubeconfig dns dns-clean dns-status shell logs status deploy deps

# Colors
GREEN := \033[32m
YELLOW := \033[33m  
BLUE := \033[34m
RED := \033[31m
NC := \033[0m

##@ Local Development (Real K3s + Ansible)

start: ## 🚀 Complete local setup (VM + Ansible + K3s)
	@echo "$(GREEN)Setting up real K3s with Ansible on Ubuntu VM...$(NC)"
	./scripts/local-dev.sh full

create: ## 🏗️  Create Ubuntu VM and setup SSH
	@echo "$(GREEN)Creating Ubuntu VM...$(NC)"
	./scripts/local-dev.sh create

ansible: ## ⚙️  Run Ansible playbook on VM
	@echo "$(GREEN)Running Ansible on VM...$(NC)"
	./scripts/local-dev.sh ansible

kubeconfig: ## 📋 Get kubeconfig from VM
	@echo "$(BLUE)Getting kubeconfig from VM...$(NC)"
	./scripts/local-dev.sh kubeconfig

dns: ## 🌐 Setup local DNS (/etc/hosts) for seamless access
	@./scripts/setup-local-dns.sh setup

dns-clean: ## 🧹 Remove local DNS entries from /etc/hosts
	@./scripts/setup-local-dns.sh clean

dns-status: ## ℹ️ Show current local DNS entries
	@./scripts/setup-local-dns.sh status

apps: ## 🚀 Deploy applications (Traefik configs + ArgoCD apps)
	@echo "$(GREEN)Deploying applications via ArgoCD...$(NC)"
	./scripts/deploy-apps.sh

status: ## 📊 Show VM and K3s status
	@echo "$(BLUE)Checking VM status...$(NC)"
	./scripts/local-dev.sh status

ssh: ## 🐚 SSH into Ubuntu VM
	@echo "$(GREEN)Connecting to VM...$(NC)"
	./scripts/local-dev.sh ssh

stop: ## 🗑️  Delete Ubuntu VM
	@echo "$(RED)Deleting VM...$(NC)"
	./scripts/local-dev.sh delete

##@ Production Deployment

deploy: ## 🚀 Deploy to production
	@echo "$(GREEN)Deploying to production...$(NC)"
	./scripts/bootstrap.sh

##@ Development Shortcuts

dev: ## 🔄 Full development cycle (same as start)
	@$(MAKE) start

reset: ## 🔄 Reset environment (stop → start)
	@$(MAKE) stop || true
	@$(MAKE) start

##@ Utilities

deps: ## 🔍 Check dependencies
	@echo "$(BLUE)Checking dependencies...$(NC)"
	@echo "Local development:"
	@command -v multipass >/dev/null 2>&1 && echo "  ✅ Multipass" || echo "  ❌ Multipass (required - brew install multipass)"
	@command -v ansible >/dev/null 2>&1 && echo "  ✅ Ansible" || echo "  ❌ Ansible (required - brew install ansible)"
	@echo "Production deployment:"
	@command -v terraform >/dev/null 2>&1 && echo "  ✅ Terraform" || echo "  ❌ Terraform (for production)"
	@echo "Optional tools:"
	@command -v kubectl >/dev/null 2>&1 && echo "  ✅ kubectl" || echo "  ⚠️  kubectl (recommended)"

clean: ## 🧹 Clean everything (delete VM and kubeconfig)
	@echo "$(RED)Cleaning everything...$(NC)"
	@$(MAKE) stop || true
	@rm -f local-kubeconfig.yaml ansible/local-kubeconfig.yaml kubeconfig
	@rm -rf local-data/
	@echo "$(GREEN)Cleanup complete$(NC)"

nuke: ## 💥 Nuclear clean (force kill multipass and clean everything)
	@echo "$(RED)Nuclear cleanup - forcing multipass shutdown...$(NC)"
	@sudo pkill -f multipass 2>/dev/null || true
	@sleep 3
	@sudo launchctl stop com.canonical.multipassd 2>/dev/null || true
	@sleep 2
	@sudo launchctl start com.canonical.multipassd 2>/dev/null || true
	@sleep 3
	@multipass delete --all --purge 2>/dev/null || true
	@rm -f local-kubeconfig.yaml ansible/local-kubeconfig.yaml kubeconfig
	@rm -rf local-data/
	@echo "$(GREEN)Nuclear cleanup complete - multipass restarted$(NC)"

##@ Help

help: ## 💡 Display this help message
	@echo "$(GREEN)JTerrazz Infrastructure - Essential Commands$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  $(YELLOW)%-15s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(GREEN)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(BLUE)Quick Examples:$(NC)"
	@echo "  make start                  # Complete local setup (VM + K3s + Ansible)"
	@echo "  make apps                   # Deploy applications (after start)"
	@echo "  make ssh                    # SSH into Ubuntu VM"
	@echo "  make status                 # Check VM and K3s status"
	@echo "  make clean                  # Clean everything (delete VM)"
	@echo "  make nuke                   # Nuclear clean (if clean gets stuck)"
	@echo "  make deploy                 # Deploy to production"
