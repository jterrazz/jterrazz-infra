# jterrazz infrastructure
#
# One k3s cluster: an OrbStack VM on the dev Mac. `make deploy` provisions it
# (Pulumi) and configures it (Ansible); `scripts/deploy.sh` is the canonical
# entry point. The Hetzner target was removed — docs/hetzner.md has the
# resurrection recipe.

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-platform destroy redeploy-apps apps check-tools lint

GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
NC := \033[0m

##@ Deploy

deploy: ## Provision + configure the cluster (Pulumi + Ansible site.yml)
	./scripts/deploy.sh

deploy-platform: ## Re-run the platform layer only (Ansible platform.yml)
	./scripts/deploy.sh --platform

destroy: ## Tear down the OrbStack VM (data on the Mac stays)
	./scripts/deploy.sh --destroy

redeploy-apps: ## Trigger every app's CI to rebuild+redeploy (bootstrap after cluster rebuild)
	./scripts/trigger-app-deploys.sh

# Kept as an alias for muscle memory; `redeploy-apps` is the real name.
apps: redeploy-apps

##@ Utilities

check-tools: ## Check required tools
	@command -v ansible >/dev/null 2>&1 && echo "✓ Ansible"   || echo "✗ Ansible"
	@command -v pulumi  >/dev/null 2>&1 && echo "✓ Pulumi"    || echo "✗ Pulumi"
	@command -v node    >/dev/null 2>&1 && echo "✓ Node.js"   || echo "✗ Node.js"
	@command -v kubectl >/dev/null 2>&1 && echo "✓ kubectl"   || echo "✗ kubectl"
	@command -v orbctl  >/dev/null 2>&1 && echo "✓ orbctl"    || echo "✗ orbctl"

##@ Lint

# Deliberately strict: every check below is also a CI job, and a missing tool
# used to be a soft "skipped" line, which meant `make lint` could print all
# green on a machine where it had checked nothing. Install the tools:
#   brew install shellcheck helm actionlint
#   pip install ansible-core ansible-lint
# actionlint is the ONE soft skip — it validates .github/workflows only, which
# CI necessarily re-validates by simply running.
lint: ## Run the same checks CI runs (shellcheck, python, ansible-lint, helm lint, actionlint)
	@echo "== shellcheck scripts/ =="
	shellcheck scripts/*.sh scripts/lib/*.sh
	@echo "✓ shellcheck clean"
	@echo ""
	@echo "== python syntax scripts/lib/ =="
	@# ast.parse rather than py_compile: same syntax check, no __pycache__/ left
	@# behind in the working tree.
	python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" scripts/lib/infisical-vars.py
	@echo "✓ python clean"
	@echo ""
	@echo "== ansible-lint ansible/ =="
	ansible-lint -c ansible/.ansible-lint ansible/
	@echo "✓ ansible-lint clean"
	@echo ""
	@echo "== helm lint (app, service) =="
	@for chart in app service; do \
		fixture="kubernetes/charts/$$chart/ci/test-values.yaml"; \
		if [ ! -f "$$fixture" ]; then \
			echo "✗ $$fixture missing — the fixture IS the validation contract for this chart"; \
			exit 1; \
		fi; \
		helm lint "kubernetes/charts/$$chart" -f "$$fixture" || exit 1; \
	done
	@echo "✓ helm lint clean"
	@echo ""
	@echo "== actionlint .github/workflows =="
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint && echo "✓ actionlint clean"; \
	else \
		echo "⚠ actionlint not installed (brew install actionlint) — skipped"; \
	fi

##@ Help

help:
	@printf "$(GREEN)jterrazz infrastructure$(NC)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-16s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
