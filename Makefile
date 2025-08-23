# JTerrazz Infrastructure - Simplified Makefile
# Essential commands for daily development and deployment

.DEFAULT_GOAL := help
.PHONY: help start stop clean ansible kubeconfig shell logs status deploy deps setup

# Colors
GREEN := \033[32m
YELLOW := \033[33m  
BLUE := \033[34m
RED := \033[31m
NC := \033[0m

##@ Local Development

start: ## 🚀 Start local development environment
	@echo "$(GREEN)Starting local environment...$(NC)"
	./scripts/local-dev.sh start

stop: ## ⏹️  Stop local environment
	@echo "$(YELLOW)Stopping local environment...$(NC)"
	./scripts/local-dev.sh stop

clean: ## 🧹 Clean local environment (removes all data!)
	@echo "$(RED)Cleaning local environment...$(NC)"
	./scripts/local-dev.sh clean

ansible: ## ⚙️  Run Ansible playbook locally
	@echo "$(GREEN)Running Ansible playbook...$(NC)"
	./scripts/local-dev.sh ansible $(ARGS)

kubeconfig: ## 📋 Get kubeconfig from local k3s
	@echo "$(BLUE)Getting kubeconfig...$(NC)"
	./scripts/local-dev.sh get-kubeconfig

shell: ## 🐚 SSH into local container
	@echo "$(GREEN)Connecting to container...$(NC)"
	@if [ -f local-data/ssh/id_rsa ]; then \
		ssh ubuntu@localhost -p 2222 -i local-data/ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR; \
	else \
		echo "$(YELLOW)SSH key not found. Run 'make start' first.$(NC)"; \
	fi

logs: ## 📋 Show container logs
	@docker logs jterrazz-infra-server

status: ## 📊 Show local environment status
	@./scripts/local-dev.sh status

##@ Production Deployment

deploy: ## 🚀 Deploy to production
	@echo "$(GREEN)Deploying to production...$(NC)"
	./scripts/bootstrap.sh

##@ Development Shortcuts

dev: ## 🔄 Full development cycle (clean → start → ansible → kubeconfig)
	@echo "$(GREEN)Running full development cycle...$(NC)"
	@$(MAKE) clean
	@$(MAKE) start
	@sleep 10
	@$(MAKE) ansible
	@$(MAKE) kubeconfig
	@echo "$(GREEN)✅ Development environment ready!$(NC)"

reset: ## 🔄 Reset environment (stop → clean → start)
	@$(MAKE) stop || true
	@$(MAKE) clean
	@$(MAKE) start

##@ Utilities

deps: ## 🔍 Check dependencies
	@echo "$(BLUE)Checking dependencies...$(NC)"
	@echo "Local development:"
	@command -v docker >/dev/null 2>&1 && echo "  ✅ Docker" || echo "  ❌ Docker (required)"
	@command -v docker-compose >/dev/null 2>&1 && echo "  ✅ Docker Compose" || echo "  ❌ Docker Compose (required)"
	@command -v ansible >/dev/null 2>&1 && echo "  ✅ Ansible" || echo "  ❌ Ansible (required)"
	@echo "Production deployment:"
	@command -v terraform >/dev/null 2>&1 && echo "  ✅ Terraform" || echo "  ❌ Terraform (for production)"
	@echo "Optional tools:"
	@command -v kubectl >/dev/null 2>&1 && echo "  ✅ kubectl" || echo "  ⚠️  kubectl (recommended)"

setup: ## 📦 Install dependencies
	@echo "$(GREEN)Installing dependencies...$(NC)"
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)Please install Docker first$(NC)"; exit 1; }
	@command -v docker-compose >/dev/null 2>&1 || { echo "$(RED)Please install Docker Compose first$(NC)"; exit 1; }
	@pip install ansible
	@echo "$(GREEN)Dependencies installed!$(NC)"

clean-all: ## 🧹 Clean everything
	@echo "$(RED)Cleaning everything...$(NC)"
	@$(MAKE) clean || true
	@rm -f local-kubeconfig.yaml kubeconfig
	@rm -rf local-data/
	@docker system prune -f
	@echo "$(GREEN)Cleanup complete$(NC)"

##@ Help

help: ## 💡 Display this help message
	@echo "$(GREEN)JTerrazz Infrastructure - Essential Commands$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  $(YELLOW)%-15s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(GREEN)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(BLUE)Quick Examples:$(NC)"
	@echo "  make dev                    # Complete development setup"
	@echo "  make ansible ARGS='--tags=k3s'  # Run specific Ansible tags"
	@echo "  make shell                  # SSH into container"
	@echo "  make deploy                 # Deploy to production"
