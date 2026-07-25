#!/bin/bash
# Provision a target via Pulumi and configure it with Ansible.
#
# Dual-mode — pick which stack is "production" by passing it as the
# first arg:
#
#   production  →  Hetzner VPS  (Pulumi stack `jterrazz/production`,
#                                Ansible inventory `production`)
#   local       →  OrbStack VM (Pulumi stack `jterrazz/local`,
#                                Ansible inventory `local`)
#
# Both stacks run the same `site.yml` playbook and end up with an
# identical k3s + platform stack. The active-DNS cluster (the one whose
# Tailscale hostname the private CNAMEs point at) is whichever stack
# has `manageDns: true` set on it. Default: hetzner.
#
# Secrets used by Ansible (Cloudflare API token, Tailscale OAuth, etc.)
# are pulled live from Infisical `/jterrazz-infrastructure` env=prod using the
# universal-auth credentials in `.env`. Nothing sensitive lives on disk
# beyond the temp extra-vars file and (production only) the temp SSH
# private key — both 0600, both deleted on exit via the trap below.
#
# Usage:
#   ./scripts/deploy.sh production         # full: pulumi up + site.yml
#   ./scripts/deploy.sh local
#   ./scripts/deploy.sh local --skip-up    # ansible only, assume VM exists
#   ./scripts/deploy.sh local --destroy    # tear down the stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# .env in repo root carries PULUMI/INFISICAL tokens locally; gitignored.
set -a
# shellcheck disable=SC1091
source "$PROJECT_DIR/.env"
set +a

target="${1:-}"
flag="${2:-}"

case "$target" in
    production|local) ;;
    "") error "Usage: $0 <production|local> [--skip-up | --destroy]"; exit 1 ;;
    *) error "Unknown target: $target"; exit 1 ;;
esac

STACK="jterrazz/$target"
INVENTORY="$PROJECT_DIR/ansible/inventories/$target/hosts.yml"
[ -f "$INVENTORY" ] || { error "Missing inventory: $INVENTORY"; exit 1; }

# Temp files populated by fetch_secrets_file() / extra_args_for_target().
# Script-scope (not `local` inside those functions) and declared before the
# trap below so cleanup can see them however the script exits — including a
# failure partway through either function. `${var:-}` keeps `rm -f` from
# tripping `set -u` if a path was never populated (e.g. `local` target,
# which never touches ssh_key_file).
secrets_file=""
ssh_key_file=""
trap 'rm -f "${secrets_file:-}" "${ssh_key_file:-}"' EXIT

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

# Fetch all Ansible-bound secrets from Infisical env=prod into a temp YAML file.
# Shared/core secrets live at /jterrazz-infrastructure; per-service secrets in subfolders
# (grafana, n8n, portainer). Each path is fetched EXPLICITLY (not recursively)
# so short keys can repeat across services (grafana + portainer both use
# ADMIN_PASSWORD) without colliding. If a role needs a new value, add it below
# and to the role's defaults.
#
# Sets the script-scope $secrets_file rather than returning the path via
# `echo` + command substitution: command substitution runs this function in
# a subshell, so a global assignment made inside it (e.g. right after
# `mktemp`, before the python step can fail) would never reach the parent
# shell, and the EXIT trap would leak the tempfile on a partial failure.
fetch_secrets_file() {
    local jwt
    jwt=$(curl -s -X POST https://eu.infisical.com/api/v1/auth/universal-auth/login \
        -H "Content-Type: application/json" \
        -d "{\"clientId\":\"$INFISICAL_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_CLIENT_SECRET\"}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['accessToken'])")

    _fetch_path() {
        curl -s -G \
            --data-urlencode "workspaceSlug=jterrazz" \
            --data-urlencode "environment=prod" \
            --data-urlencode "secretPath=$1" \
            -H "Authorization: Bearer $jwt" \
            "https://eu.infisical.com/api/v3/secrets/raw"
    }

    local root grafana n8n portainer
    root=$(_fetch_path "/jterrazz-infrastructure")
    grafana=$(_fetch_path "/jterrazz-infrastructure/grafana")
    n8n=$(_fetch_path "/jterrazz-infrastructure/n8n")
    portainer=$(_fetch_path "/jterrazz-infrastructure/portainer")

    secrets_file=$(mktemp -t jterrazz-infrastructure-vars-XXXXXX.yml)
    chmod 600 "$secrets_file"

    python3 - "$root" "$grafana" "$n8n" "$portainer" "$secrets_file" <<'PY'
import json, os, sys

root_json, grafana_json, n8n_json, portainer_json, outpath = sys.argv[1:6]

def kv(raw):
    return {s["secretKey"]: s["secretValue"] for s in json.loads(raw).get("secrets", [])}

root, grafana, n8n, portainer = kv(root_json), kv(grafana_json), kv(n8n_json), kv(portainer_json)

# (Infisical path → key) → Ansible variable. Shared/core at /jterrazz-infrastructure;
# per-service in subfolders with short (de-prefixed) keys.
out = {
    "cloudflare_api_token":          root.get("CLOUDFLARE_API_TOKEN"),
    "cloudflare_tunnel_token":       root.get("CLOUDFLARE_TUNNEL_TOKEN"),
    "tailscale_oauth_client_id":     root.get("TAILSCALE_OAUTH_CLIENT_ID"),
    "tailscale_oauth_client_secret": root.get("TAILSCALE_OAUTH_CLIENT_SECRET"),
    "registry_password":             root.get("DOCKER_REGISTRY_PASSWORD"),
    "grafana_password":              grafana.get("ADMIN_PASSWORD"),
    "n8n_encryption_key":            n8n.get("ENCRYPTION_KEY"),
    "portainer_password":            portainer.get("ADMIN_PASSWORD"),
}
# Hard-fail on any missing secret rather than silently dropping it and
# letting an Ansible role default paper over a real Infisical
# misconfiguration. Mirrors the equivalent check in
# .github/workflows/deploy-platform.yaml (`Build extra-vars file` step) —
# the two are kept in sync by hand; if you change one, change the other.
missing = [k for k, v in out.items() if v is None]
if missing:
    print(f"ERROR: Missing Infisical secrets: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

# Infisical-operator credentials are local-only and live in .env, not in
# Infisical itself (chicken-and-egg).
out["infisical_client_id"]     = os.environ["INFISICAL_CLIENT_ID"]
out["infisical_client_secret"] = os.environ["INFISICAL_CLIENT_SECRET"]

with open(outpath, "w") as f:
    for k, v in out.items():
        # Quote everything: tokens may start with `[` or contain `:`, both
        # of which mean things to the YAML parser. Escape embedded newlines
        # too, so a multi-line secret can't break the YAML file — mirrors
        # deploy-platform.yaml's copy of this same transform.
        v = v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        f.write(f'{k}: "{v}"\n')
PY
}

# Pull the SSH private key out of Pulumi state and pass it to Ansible so
# the production inventory (which doesn't hardcode a key path) can
# connect to a freshly provisioned VPS. OrbStack uses its own SSH proxy,
# so this only applies when target=production.
#
# Sets the script-scope $ssh_key_file (see fetch_secrets_file() above for
# why this isn't `local`) so the top-of-file EXIT trap can remove it.
extra_args_for_target() {
    if [ "$target" = "production" ]; then
        local ip
        ssh_key_file=$(mktemp -t jterrazz-infrastructure-ssh-XXXXXX.key)
        chmod 600 "$ssh_key_file"
        (cd "$PROJECT_DIR/pulumi" && pulumi stack output sshPrivateKey --show-secrets --stack "$STACK") > "$ssh_key_file"
        ip=$(cd "$PROJECT_DIR/pulumi" && pulumi stack output sshHost --stack "$STACK")
        echo "-e ansible_host=$ip -e ansible_ssh_private_key_file=$ssh_key_file"
    fi
}

run_ansible() {
    fetch_secrets_file
    local extra_args
    extra_args=$(extra_args_for_target)

    # ansible.cfg uses a relative roles_path; run from ansible/ so it
    # resolves correctly. The extra-vars file path is absolute.
    cd "$PROJECT_DIR/ansible"

    # A fresh machine (or a laptop after `ansible-galaxy` cache eviction)
    # would otherwise silently rely on whatever collections happen to be
    # bundled with the local ansible install, which may not satisfy
    # requirements.yml. Cheap and idempotent — ansible-galaxy skips
    # collections already satisfying the version constraint.
    info "Installing Ansible collections (requirements.yml)"
    ansible-galaxy collection install -r "$PROJECT_DIR/ansible/requirements.yml"

    info "ansible-playbook site.yml (target=$target, inventory=$target)"
    # shellcheck disable=SC2086
    ansible-playbook playbooks/site.yml \
        -i "$INVENTORY" \
        -e "@$secrets_file" \
        $extra_args
}

case "$flag" in
    --destroy)
        pulumi_destroy
        ;;
    --skip-up)
        run_ansible
        ;;
    "")
        pulumi_up
        run_ansible
        ;;
    *)
        error "Unknown flag: $flag"
        error "Usage: $0 <production|local> [--skip-up | --destroy]"
        exit 1
        ;;
esac
