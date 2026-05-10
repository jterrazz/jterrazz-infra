# jterrazz infrastructure
#
# `make deploy` provisions and configures the Hetzner cluster.
# `make deploy-local` does the same against an OrbStack VM on the Mac.
# Both call scripts/deploy.sh, which is the canonical entry point.

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-local destroy-local apps-local deps

GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
NC := \033[0m

##@ Deploy

deploy: ## Deploy production to Hetzner (Pulumi + Ansible)
	./scripts/deploy.sh production

deploy-local: ## Deploy locally on OrbStack (Pulumi + Ansible)
	./scripts/deploy.sh local

destroy-local: ## Tear down the OrbStack VM
	./scripts/deploy.sh local --destroy

apps-local: ## Mirror Hetzner's app helm releases onto OrbStack
	./scripts/deploy-apps-local.sh

##@ Utilities

deps: ## Check required tools
	@command -v ansible >/dev/null 2>&1 && echo "✓ Ansible"   || echo "✗ Ansible"
	@command -v pulumi  >/dev/null 2>&1 && echo "✓ Pulumi"    || echo "✗ Pulumi"
	@command -v node    >/dev/null 2>&1 && echo "✓ Node.js"   || echo "✗ Node.js"
	@command -v kubectl >/dev/null 2>&1 && echo "✓ kubectl"   || echo "✗ kubectl"
	@command -v orbctl  >/dev/null 2>&1 && echo "✓ orbctl"    || echo "✗ orbctl (only needed for `make deploy-local`)"

##@ Help

help:
	@printf "$(GREEN)jterrazz infrastructure$(NC)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-14s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
