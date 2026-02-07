# Jterrazz Infrastructure Makefile

.DEFAULT_GOAL := help
.PHONY: help deploy deps

# Colors
GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
RED := \033[31m
NC := \033[0m

##@ Production

deploy: ## Deploy to production (Pulumi + Ansible)
	./scripts/deploy.sh

##@ Utilities

deps: ## Check required tools
	@command -v ansible >/dev/null 2>&1 && echo "✓ Ansible" || echo "✗ Ansible"
	@command -v pulumi >/dev/null 2>&1 && echo "✓ Pulumi" || echo "✗ Pulumi"
	@command -v node >/dev/null 2>&1 && echo "✓ Node.js" || echo "✗ Node.js"
	@command -v kubectl >/dev/null 2>&1 && echo "✓ kubectl" || echo "✗ kubectl"

##@ Help

help:
	@echo "$(GREEN)Jterrazz Infrastructure$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-10s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
