#!/bin/bash
# Provision the cluster machine via Pulumi and configure it with Ansible.
#
# Single stack: jterrazz/local — the OrbStack VM hosting the k3s cluster
# on the dev Mac. Previously there was a `production` Hetzner stack too;
# it was retired (see git log around commit b29f250) and Pulumi state
# fully torn down.
#
# Secrets used by Ansible (Cloudflare API token, Tailscale OAuth, etc.)
# are pulled live from Infisical /jterrazz-infra env=prod using the
# universal-auth credentials in .env. Nothing sensitive lives on disk
# beyond the temp extra-vars file (0600, deleted on exit).
#
# Usage:
#   ./scripts/deploy.sh             # full: pulumi up + site.yml
#   ./scripts/deploy.sh --skip-up   # ansible only, assume VM exists
#   ./scripts/deploy.sh --destroy   # tear down the stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# .env in repo root carries PULUMI/INFISICAL tokens locally; gitignored.
# shellcheck disable=SC1091
set -a; source "$PROJECT_DIR/.env"; set +a

flag="${1:-}"

STACK="jterrazz/local"
INVENTORY="$PROJECT_DIR/ansible/inventories/local/hosts.yml"
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

# Fetch all Ansible-bound secrets from Infisical /jterrazz-infra env=prod.
# Returns the path to a temp YAML file. Mapping below decides which
# Infisical keys become which Ansible vars; if a role needs a new value,
# add it here and to the role's defaults.
fetch_secrets_file() {
    local jwt
    jwt=$(curl -s -X POST https://eu.infisical.com/api/v1/auth/universal-auth/login \
        -H "Content-Type: application/json" \
        -d "{\"clientId\":\"$INFISICAL_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_CLIENT_SECRET\"}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['accessToken'])")

    local secrets_json
    secrets_json=$(curl -s -G \
        --data-urlencode "workspaceSlug=jterrazz" \
        --data-urlencode "environment=prod" \
        --data-urlencode "secretPath=/jterrazz-infra" \
        -H "Authorization: Bearer $jwt" \
        "https://eu.infisical.com/api/v3/secrets/raw")

    local out
    out=$(mktemp -t jterrazz-infra-vars-XXXXXX.yml)
    chmod 600 "$out"

    python3 - "$secrets_json" "$out" <<'PY'
import json, os, sys

data = json.loads(sys.argv[1])
# Infisical secret key → Ansible variable name. Extend as roles demand.
mapping = {
    "CLOUDFLARE_API_TOKEN":          "cloudflare_api_token",
    "CLOUDFLARE_TUNNEL_TOKEN":       "cloudflare_tunnel_token",
    "TAILSCALE_OAUTH_CLIENT_ID":     "tailscale_oauth_client_id",
    "TAILSCALE_OAUTH_CLIENT_SECRET": "tailscale_oauth_client_secret",
    "DOCKER_REGISTRY_PASSWORD":      "registry_password",
    "PORTAINER_ADMIN_PASSWORD":      "portainer_password",
    "GRAFANA_PASSWORD":              "grafana_password",
    "N8N_ENCRYPTION_KEY":            "n8n_encryption_key",
}
out = {}
for s in data.get("secrets", []):
    if s["secretKey"] in mapping:
        out[mapping[s["secretKey"]]] = s["secretValue"]
# Infisical-operator credentials are local-only and live in .env, not in
# Infisical itself (chicken-and-egg).
out["infisical_client_id"]     = os.environ["INFISICAL_CLIENT_ID"]
out["infisical_client_secret"] = os.environ["INFISICAL_CLIENT_SECRET"]

with open(sys.argv[2], "w") as f:
    for k, v in out.items():
        # Quote everything: tokens may start with `[` or contain `:`, both
        # of which mean things to the YAML parser.
        v = v.replace("\\", "\\\\").replace('"', '\\"')
        f.write(f'{k}: "{v}"\n')
PY
    echo "$out"
}

run_ansible() {
    # Not `local` because the EXIT trap fires after the function frame
    # is gone; with `set -u` a local would read as unbound and abort
    # cleanup. Script-scope means the trap can still see the path.
    secrets_file=$(fetch_secrets_file)
    trap 'rm -f "${secrets_file:-}"' EXIT

    # ansible.cfg uses a relative roles_path; run from ansible/ so it
    # resolves correctly. The extra-vars file path is absolute.
    cd "$PROJECT_DIR/ansible"
    echo "==> ansible-playbook site.yml"
    ansible-playbook playbooks/site.yml \
        -i "$INVENTORY" \
        -e "@$secrets_file"
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
        echo "Usage: $0 [--skip-up | --destroy]" >&2
        exit 1
        ;;
esac
