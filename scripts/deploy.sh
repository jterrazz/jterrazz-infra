#!/bin/bash
# Provision the cluster via Pulumi and configure it with Ansible.
#
# There is one cluster: the OrbStack VM on the dev Mac (Pulumi stack
# `jterrazz/local`, Ansible inventory `inventories/laptop.yml`). The Hetzner
# target was removed — see docs/hetzner.md to resurrect it.
#
# Secrets used by Ansible (Cloudflare API token, Tailscale OAuth, etc.) are
# pulled live from Infisical `/jterrazz-infrastructure` env=prod by
# scripts/lib/infisical-vars.py, using the universal-auth credentials in
# `.env`. Nothing sensitive lives on disk beyond the temp extra-vars file —
# 0600, deleted on exit via the trap below.
#
# Usage:
#   ./scripts/deploy.sh              # full: pulumi up + site.yml
#   ./scripts/deploy.sh --skip-up    # ansible only, assume the VM exists
#   ./scripts/deploy.sh --platform   # platform.yml only (no host layer)
#   ./scripts/deploy.sh --destroy    # tear down the stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

STACK="jterrazz/local"
INVENTORY="$PROJECT_DIR/ansible/inventories/laptop.yml"

# .env in repo root carries PULUMI/INFISICAL tokens locally; gitignored.
if [ ! -f "$PROJECT_DIR/.env" ]; then
    error "Missing $PROJECT_DIR/.env"
    error "It must define PULUMI_ACCESS_TOKEN, INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET."
    error "See the '.env' section of CLAUDE.md; the file is gitignored on purpose."
    exit 1
fi
set -a
# shellcheck disable=SC1091
source "$PROJECT_DIR/.env"
set +a

# Populated by fetch_secrets_file(). Script-scope (not `local` inside that
# function) and declared before the trap below so cleanup can see it however
# the script exits — including a failure partway through the fetch. `${var:-}`
# keeps `rm -f` from tripping `set -u` if the path was never populated.
secrets_file=""
trap 'rm -f "${secrets_file:-}"' EXIT

pulumi_up() {
    cd "$PROJECT_DIR/pulumi"
    info "pulumi up --stack $STACK"
    pulumi stack select "$STACK"
    pulumi up --yes --refresh
}

pulumi_destroy() {
    cd "$PROJECT_DIR/pulumi"
    info "pulumi destroy --stack $STACK"
    pulumi stack select "$STACK"
    pulumi destroy --yes --refresh
}

# Sets the script-scope $secrets_file rather than returning the path via
# `echo` + command substitution: command substitution runs this function in a
# subshell, so a global assignment made inside it (e.g. right after `mktemp`,
# before the fetch can fail) would never reach the parent shell, and the EXIT
# trap would leak the tempfile on a partial failure.
fetch_secrets_file() {
    local scope="$1"
    secrets_file=$(mktemp -t jterrazz-infrastructure-vars-XXXXXX.yml)
    "$SCRIPT_DIR/lib/infisical-vars.py" "$scope" "$secrets_file"
}

# A fresh machine (or a laptop after `ansible-galaxy` cache eviction) would
# otherwise silently rely on whatever collections happen to be bundled with the
# local ansible install, which may not satisfy requirements.yml. Cheap and
# idempotent — ansible-galaxy skips collections already at the pinned version.
install_collections() {
    info "Installing Ansible collections (requirements.yml)"
    ansible-galaxy collection install -r "$PROJECT_DIR/ansible/requirements.yml"
}

run_site() {
    fetch_secrets_file site
    # ansible.cfg uses a relative roles_path; run from ansible/ so it
    # resolves correctly. The extra-vars file path is absolute.
    cd "$PROJECT_DIR/ansible"
    install_collections
    info "ansible-playbook site.yml"
    ansible-playbook playbooks/site.yml -i "$INVENTORY" -e "@$secrets_file"
}

run_platform() {
    fetch_secrets_file platform
    cd "$PROJECT_DIR/ansible"
    install_collections
    info "ansible-playbook platform.yml"
    ansible-playbook playbooks/platform.yml -i "$INVENTORY" -e "@$secrets_file"
}

case "${1:-}" in
    --destroy)
        pulumi_destroy
        ;;
    --skip-up)
        run_site
        ;;
    --platform)
        run_platform
        ;;
    "")
        pulumi_up
        run_site
        ;;
    *)
        error "Unknown flag: $1"
        error "Usage: $0 [--skip-up | --platform | --destroy]"
        exit 1
        ;;
esac
