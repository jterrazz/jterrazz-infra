# Jterrazz Infrastructure Makefile

.DEFAULT_GOAL := help
.PHONY: help start stop clean ansible status deploy deps vm ssh

# Colors
GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
RED := \033[31m
NC := \033[0m

##@ Local Development

start: ## Full setup - VM, K3s, apps
	./scripts/local-dev.sh full

stop: ## Delete VM
	./scripts/local-dev.sh delete

ssh: ## SSH into VM
	./scripts/local-dev.sh ssh

status: ## Show services
	./scripts/local-dev.sh status

vm: ## Create VM only
	./scripts/local-dev.sh create

ansible: ## Run Ansible (idempotent - safe to re-run)
	./scripts/local-dev.sh ansible

##@ Production

deploy: ## Deploy to production (Pulumi + Ansible)
	./scripts/bootstrap.sh

##@ Utilities

deps: ## Check tools
	@command -v multipass >/dev/null 2>&1 && echo "✓ Multipass" || echo "✗ Multipass"
	@command -v ansible >/dev/null 2>&1 && echo "✓ Ansible" || echo "✗ Ansible"
	@command -v pulumi >/dev/null 2>&1 && echo "✓ Pulumi" || echo "✗ Pulumi"
	@command -v node >/dev/null 2>&1 && echo "✓ Node.js" || echo "✗ Node.js"
	@command -v kubectl >/dev/null 2>&1 && echo "✓ kubectl" || echo "✗ kubectl"

clean: ## Cleanup everything
	@multipass delete jterrazz-infra --purge 2>/dev/null || true
	@rm -f local-kubeconfig.yaml kubeconfig.yaml
	@rm -rf data/

##@ Help

help:
	@echo "$(GREEN)Jterrazz Infrastructure$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-10s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Ansible is idempotent - run 'make ansible' anytime, it only applies changes."
