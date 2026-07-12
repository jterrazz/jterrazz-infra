#!/bin/bash
# Provision a target via Pulumi and configure it with Ansible.
#
# Dual-mode — pick which stack is "production" by passing it as the
# first arg:
#
#   production  →  Hetzner VPS  (Pulumi stack `jterrazz/production`,
#                                Ansible inventory `production`)
#   local       →  OrbStack VM  (Pulumi stack `jterrazz/local`,
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
# beyond the temp extra-vars file (0600, deleted on exit).
#
# Usage:
#   ./scripts/deploy.sh production         # full: pulumi up + site.yml
#   ./scripts/deploy.sh local
#   ./scripts/deploy.sh local --skip-up    # ansible only, assume VM exists
#   ./scripts/deploy.sh local --destroy    # tear down the stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# .env in repo root carries PULUMI/INFISICAL tokens locally; gitignored.
# shellcheck disable=SC1091
set -a; source "$PROJECT_DIR/.env"; set +a

target="${1:-}"
flag="${2:-}"

case "$target" in
    production|local) ;;
    "") echo "Usage: $0 <production|local> [--skip-up | --destroy]" >&2; exit 1 ;;
    *) echo "Unknown target: $target" >&2; exit 1 ;;
esac

STACK="jterrazz/$target"
INVENTORY="$PROJECT_DIR/ansible/inventories/$target/hosts.yml"
[ -f "$INVENTORY" ] || { echo "Missing inventory: $INVENTORY" >&2; exit 1; }

pulumi_up() {
    cd "$PROJECT_DIR/pulumi"
    echo "==> pulumi up --stack $STACK"
    pulumi stack select "$STACK"
    pulumi up --yes --refresh
}

pulumi_destroy() {
    cd "$PROJECT_DIR/pulumi"
    echo "==> pulumi destroy --stack $STACK"
    pulumi stack select "$STACK"
    pulumi destroy --yes --refresh
}

# Fetch all Ansible-bound secrets from Infisical env=prod into a temp YAML file.
# Shared/core secrets live at /jterrazz-infrastructure; per-service secrets in subfolders
# (grafana, n8n, portainer). Each path is fetched EXPLICITLY (not recursively)
# so short keys can repeat across services (grafana + portainer both use
# ADMIN_PASSWORD) without colliding. If a role needs a new value, add it below
# and to the role's defaults.
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

    local out
    out=$(mktemp -t jterrazz-infrastructure-vars-XXXXXX.yml)
    chmod 600 "$out"

    python3 - "$root" "$grafana" "$n8n" "$portainer" "$out" <<'PY'
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
# Drop absent values so Ansible role defaults apply rather than a literal "None".
out = {k: v for k, v in out.items() if v is not None}

# Infisical-operator credentials are local-only and live in .env, not in
# Infisical itself (chicken-and-egg).
out["infisical_client_id"]     = os.environ["INFISICAL_CLIENT_ID"]
out["infisical_client_secret"] = os.environ["INFISICAL_CLIENT_SECRET"]

with open(outpath, "w") as f:
    for k, v in out.items():
        # Quote everything: tokens may start with `[` or contain `:`, both
        # of which mean things to the YAML parser.
        v = v.replace("\\", "\\\\").replace('"', '\\"')
        f.write(f'{k}: "{v}"\n')
PY
    echo "$out"
}

# Pull the SSH private key out of Pulumi state and pass it to Ansible so
# the production inventory (which doesn't hardcode a key path) can
# connect to a freshly provisioned VPS. OrbStack uses its own SSH proxy,
# so this only applies when target=production.
extra_args_for_target() {
    if [ "$target" = "production" ]; then
        local key_file ip
        key_file=$(mktemp -t jterrazz-infrastructure-ssh-XXXXXX.key)
        chmod 600 "$key_file"
        (cd "$PROJECT_DIR/pulumi" && pulumi stack output sshPrivateKey --show-secrets --stack "$STACK") > "$key_file"
        ip=$(cd "$PROJECT_DIR/pulumi" && pulumi stack output sshHost --stack "$STACK")
        echo "-e ansible_host=$ip -e ansible_ssh_private_key_file=$key_file"
    fi
}

run_ansible() {
    # Not `local` because the EXIT trap fires after the function frame
    # is gone; with `set -u` a local would read as unbound and abort
    # cleanup. Script-scope means the trap can still see the path.
    secrets_file=$(fetch_secrets_file)
    local extra_args
    extra_args=$(extra_args_for_target)
    trap 'rm -f "${secrets_file:-}"' EXIT

    # ansible.cfg uses a relative roles_path; run from ansible/ so it
    # resolves correctly. The extra-vars file path is absolute.
    cd "$PROJECT_DIR/ansible"
    echo "==> ansible-playbook site.yml (target=$target, inventory=$target)"
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
        echo "Unknown flag: $flag" >&2
        echo "Usage: $0 <production|local> [--skip-up | --destroy]" >&2
        exit 1
        ;;
esac
