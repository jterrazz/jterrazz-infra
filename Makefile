# jterrazz infrastructure
#
# `make deploy` provisions and configures the OrbStack-hosted k3s cluster.
# `scripts/deploy.sh` is the canonical entry point.

.DEFAULT_GOAL := help
.PHONY: help deploy destroy apps deps

GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
NC := \033[0m

##@ Deploy

deploy: ## Provision the OrbStack VM and run site.yml (Pulumi + Ansible)
	./scripts/deploy.sh

destroy: ## Tear down the OrbStack VM (data on the Mac stays)
	./scripts/deploy.sh --destroy

apps: ## Trigger every app's CI to rebuild+redeploy (bootstrap after cluster rebuild)
	./scripts/trigger-app-deploys.sh

##@ Utilities

deps: ## Check required tools
	@command -v ansible >/dev/null 2>&1 && echo "✓ Ansible"   || echo "✗ Ansible"
	@command -v pulumi  >/dev/null 2>&1 && echo "✓ Pulumi"    || echo "✗ Pulumi"
	@command -v node    >/dev/null 2>&1 && echo "✓ Node.js"   || echo "✗ Node.js"
	@command -v kubectl >/dev/null 2>&1 && echo "✓ kubectl"   || echo "✗ kubectl"
	@command -v orbctl  >/dev/null 2>&1 && echo "✓ orbctl"    || echo "✗ orbctl"

##@ Help

help:
	@printf "$(GREEN)jterrazz infrastructure$(NC)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-10s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
