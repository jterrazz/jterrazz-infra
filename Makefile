# jterrazz infrastructure
#
# Dual-mode k3s cluster — `make deploy` (Hetzner production) or
# `make deploy-local` (OrbStack VM on the dev Mac). Whichever stack
# has `manageDns: true` set on it owns the Cloudflare private CNAMEs.
# `scripts/deploy.sh` is the canonical entry point.

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-local destroy-local apps deps lint

GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
NC := \033[0m

##@ Deploy

deploy: ## Deploy production to Hetzner (Pulumi + Ansible)
	./scripts/deploy.sh production

deploy-local: ## Deploy on OrbStack (Pulumi + Ansible)
	./scripts/deploy.sh local

destroy-local: ## Tear down the OrbStack VM (data on the Mac stays)
	./scripts/deploy.sh local --destroy

apps: ## Trigger every app's CI to rebuild+redeploy (bootstrap after cluster rebuild)
	./scripts/trigger-app-deploys.sh

##@ Utilities

deps: ## Check required tools
	@command -v ansible >/dev/null 2>&1 && echo "✓ Ansible"   || echo "✗ Ansible"
	@command -v pulumi  >/dev/null 2>&1 && echo "✓ Pulumi"    || echo "✗ Pulumi"
	@command -v node    >/dev/null 2>&1 && echo "✓ Node.js"   || echo "✗ Node.js"
	@command -v kubectl >/dev/null 2>&1 && echo "✓ kubectl"   || echo "✗ kubectl"
	@command -v orbctl  >/dev/null 2>&1 && echo "✓ orbctl"    || echo "✗ orbctl (only needed for `make deploy-local`)"

##@ Lint

lint: ## Run the same local checks CI runs (shellcheck, ansible-lint, helm lint) — best-effort
	@echo "== shellcheck scripts/ =="
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh scripts/lib/*.sh && echo "✓ shellcheck clean"; \
	else \
		echo "✗ shellcheck not installed (brew install shellcheck) — skipped"; \
	fi
	@echo ""
	@echo "== ansible-lint ansible/ =="
	@if command -v ansible-lint >/dev/null 2>&1; then \
		ansible-lint ansible/ && echo "✓ ansible-lint clean"; \
	else \
		echo "✗ ansible-lint not installed (pip install ansible-core ansible-lint) — skipped"; \
	fi
	@echo ""
	@echo "== helm lint (app, platform) =="
	@if command -v helm >/dev/null 2>&1; then \
		for chart in app platform; do \
			fixture="kubernetes/charts/$$chart/ci/test-values.yaml"; \
			if [ -f "$$fixture" ]; then \
				helm lint "kubernetes/charts/$$chart" -f "$$fixture"; \
			else \
				echo "⚠ $$fixture missing — linting kubernetes/charts/$$chart with chart defaults only (won't catch as much)"; \
				helm lint "kubernetes/charts/$$chart"; \
			fi; \
		done; \
	else \
		echo "✗ helm not installed — skipped"; \
	fi

##@ Help

help:
	@printf "$(GREEN)jterrazz infrastructure$(NC)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-14s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
