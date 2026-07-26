# jterrazz infrastructure
#
# One k3s cluster: an OrbStack VM on the dev Mac. `make deploy` provisions it
# (Pulumi) and configures it (Ansible); `scripts/deploy.sh` is the canonical
# entry point. The Hetzner target was removed — docs/hetzner.md has the
# resurrection recipe.

.DEFAULT_GOAL := help
.PHONY: help deploy deploy-platform destroy redeploy-apps check-tools check lint diff smoke kubeconfig

GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
NC := \033[0m

# The OrbStack VM, and the node's MagicDNS name read out of the CI inventory
# rather than written down a third time (roles/k3s/tasks/kubeconfig.yml and
# inventories/ci.yml are the other two places it appears).
VM_NAME := jterrazz-infrastructure
KUBECONFIG_FILE := kubeconfig.yaml
NODE_FQDN = $(shell awk '/ansible_host:/ {print $$2; exit}' ansible/inventories/ci.yml)

##@ Deploy

deploy: ## Provision + configure the cluster (Pulumi + Ansible site.yml)
	./scripts/deploy.sh

deploy-platform: ## Re-run the platform layer only (Ansible platform.yml)
	./scripts/deploy.sh --platform

destroy: ## Tear down the OrbStack VM (data on the Mac stays)
	./scripts/deploy.sh --destroy

redeploy-apps: ## Trigger every app's CI to rebuild+redeploy (bootstrap after cluster rebuild)
	./scripts/trigger-app-deploys.sh

##@ Utilities

# `make deploy` writes kubeconfig.yaml as a side effect (roles/k3s/tasks/
# kubeconfig.yml); this is the same two steps on their own, for the far more
# common case of "the file is stale/gone and I only want to look at the
# cluster". k3s writes a server address of 127.0.0.1 (0.0.0.0 here, since the
# API server binds every interface), which is useless from the Mac — the
# rewrite to the MagicDNS name is what makes the fetched file usable, and it is
# the step that was easy to forget when this was two lines of prose in
# scripts/platform-diff.sh's error path.
kubeconfig: ## Regenerate ./kubeconfig.yaml from the VM (server = MagicDNS name)
	@test -n "$(NODE_FQDN)" || { echo "✗ no ansible_host in ansible/inventories/ci.yml"; exit 1; }
	@orb -m $(VM_NAME) -u root cat /etc/rancher/k3s/k3s.yaml > $(KUBECONFIG_FILE).tmp \
		|| { rm -f $(KUBECONFIG_FILE).tmp; echo "✗ could not read k3s.yaml from $(VM_NAME) (orb list?)"; exit 1; }
	@sed -E 's#https://(127\.0\.0\.1|0\.0\.0\.0):6443#https://$(NODE_FQDN):6443#' \
		$(KUBECONFIG_FILE).tmp > $(KUBECONFIG_FILE)
	@rm -f $(KUBECONFIG_FILE).tmp
	@chmod 600 $(KUBECONFIG_FILE)
	@grep -q 'server: https://$(NODE_FQDN):6443' $(KUBECONFIG_FILE) \
		|| { echo "✗ server address not rewritten — k3s wrote something other than 127.0.0.1/0.0.0.0"; exit 1; }
	@echo "✓ $(KUBECONFIG_FILE) → https://$(NODE_FQDN):6443 (needs the tailnet)"

# Read-only preview against the LIVE cluster, meant to be run BEFORE
# `make deploy-platform`: that play runs `helm upgrade --install` for every
# release, so a bumped chart version or an edited helm.yaml lands the moment it
# runs. This shows what would change first. Installs the helm-diff plugin on
# first use; needs a working kubeconfig (./kubeconfig.yaml by default,
# override with KUBECONFIG=...). Narrow it to one release: `make diff` then
# `./scripts/platform-diff.sh grafana`.
diff: ## Preview what `make deploy-platform` would change (helm diff, read-only)
	./scripts/platform-diff.sh

# Black-box probe of the deployed surfaces. `--public` needs nothing;
# `--private` and the private half of `--certs` need this machine to be on the
# tailnet, so they are left out of the default target here — CI
# (.github/workflows/smoke.yaml) runs the full set from a runner that joins it.
smoke: ## Probe the public surfaces + their TLS expiry (add --private on the tailnet)
	./scripts/smoke.sh --public --certs

check-tools: ## Check required tools
	@command -v ansible >/dev/null 2>&1 && echo "✓ Ansible"   || echo "✗ Ansible"
	@command -v pulumi  >/dev/null 2>&1 && echo "✓ Pulumi"    || echo "✗ Pulumi"
	@command -v node    >/dev/null 2>&1 && echo "✓ Node.js"   || echo "✗ Node.js"
	@command -v kubectl >/dev/null 2>&1 && echo "✓ kubectl"   || echo "✗ kubectl"
	@command -v orbctl  >/dev/null 2>&1 && echo "✓ orbctl"    || echo "✗ orbctl"

##@ Check

# Deliberately strict: every check below is also a CI job, and a missing tool
# used to be a soft "skipped" line, which meant this target could print all
# green on a machine where it had checked nothing. Install the tools:
#   brew install shellcheck helm actionlint
#   pip install ansible-core ansible-lint
# actionlint is the ONE soft skip — it validates .github/workflows only, which
# CI necessarily re-validates by simply running.
check: ## Run the checks CI runs (shellcheck, python, sync assertions, ansible-lint, helm lint + unittest, actionlint)
	@echo "== shellcheck scripts/ =="
	shellcheck scripts/*.sh scripts/lib/*.sh
	@echo "✓ shellcheck clean"
	@echo ""
	@echo "== python syntax scripts/ =="
	@# ast.parse rather than py_compile: same syntax check, no __pycache__/ left
	@# behind in the working tree.
	@for f in scripts/infisical-vars.py scripts/assert-sync.py; do \
		python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" "$$f" || exit 1; \
	done
	@echo "✓ python clean"
	@echo ""
	@echo "== cross-file sync assertions =="
	@# Facts this repo has to write down twice (Pulumi DNS vs CoreDNS overrides,
	@# the Infisical var map vs the Ansible preflight assert, Traefik's
	@# trustedIPs vs the rate-limit excludedIPs, chart-version pins vs their
	@# consumers, the platform-diff release table vs the Ansible helm
	@# invocations, the three Helm/ansible-core/helm-unittest version pins, the
	@# busybox digest, private hostnames vs the smoke table). Each pair carries
	@# a "keep in sync" comment; this is what actually checks them.
	python3 scripts/assert-sync.py
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
	@echo "== helm unittest (app, service) =="
	@# helm lint + kubeconform only prove the rendered YAML is well-formed and
	@# schema-valid. These assert what the templates COMPUTED: the NODE_OPTIONS
	@# floor, the Mi/Gi parser, the dockerconfigjson escaping, which ipAllowList
	@# an `access:` value selects. The plugin is the ONE soft skip here (like
	@# actionlint) because CI installs and runs it unconditionally.
	@if helm plugin list 2>/dev/null | awk '{print $$1}' | grep -qx unittest; then \
		helm unittest --strict kubernetes/charts/app kubernetes/charts/service || exit 1; \
	else \
		echo "⚠ helm-unittest not installed — skipped. Install with:"; \
		echo "    helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.1.2"; \
		echo "    (add --verify=false on helm 4; the plugin ships no signature)"; \
	fi
	@echo ""
	@echo "== actionlint .github/workflows =="
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint && echo "✓ actionlint clean"; \
	else \
		echo "⚠ actionlint not installed (brew install actionlint) — skipped"; \
	fi

# `check` is the real name — the target runs unit tests and cross-file
# assertions, not just linters. `lint` stays as an alias: it is the name in
# every app repo's universal CI interface (make build / lint / test), and
# muscle memory does not need to be re-trained for a rename.
lint: check

##@ Help

help:
	@printf "$(GREEN)jterrazz infrastructure$(NC)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ { printf "  $(YELLOW)%-16s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
