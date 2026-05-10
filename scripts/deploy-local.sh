#!/bin/bash
# Provision the OrbStack VM via Pulumi and configure it with Ansible.
#
# Mirrors scripts/deploy.sh but targets the `local` Pulumi stack (OrbStack
# instead of Hetzner). Secrets needed by Ansible are pulled live from
# Infisical /infrastructure (the platform path) using INFISICAL_CLIENT_ID
# and INFISICAL_CLIENT_SECRET from .env.
#
# Usage:
#   ./scripts/deploy-local.sh             # full: pulumi up + site.yml
#   ./scripts/deploy-local.sh --skip-up   # ansible only, assume VM exists
#   ./scripts/deploy-local.sh --destroy   # tear down the VM (pulumi destroy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# .env in repo root carries Pulumi + Infisical tokens locally; never committed.
# shellcheck disable=SC1091
set -a; source "$PROJECT_DIR/.env"; set +a

cmd="${1:-}"

ensure_pulumi() {
    cd "$PROJECT_DIR/pulumi"
    pulumi stack select jterrazz/local
}

pulumi_up() {
    ensure_pulumi
    echo "==> pulumi up --stack local"
    pulumi up --yes --refresh
}

pulumi_destroy() {
    ensure_pulumi
    echo "==> pulumi destroy --stack local"
    pulumi destroy --yes --refresh
}

# Fetch the secrets Ansible needs from Infisical /infrastructure env=prod.
# Returns a path to a temp YAML file the caller is responsible for cleaning
# up. The file is created with 0600 perms because it contains plaintext
# tokens.
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
        --data-urlencode "secretPath=/infrastructure" \
        -H "Authorization: Bearer $jwt" \
        "https://eu.infisical.com/api/v3/secrets/raw")

    local out
    out=$(mktemp -t jterrazz-infra-vars-XXXXXX.yml)
    chmod 600 "$out"
    # Map Infisical secret names → Ansible variable names. Adding here means
    # platform.yml can read it; the var name must match what the role expects.
    python3 - "$secrets_json" "$out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
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
infisical_id = "INFISICAL_CLIENT_ID"
infisical_secret = "INFISICAL_CLIENT_SECRET"
out = {}
for s in data.get("secrets", []):
    if s["secretKey"] in mapping:
        out[mapping[s["secretKey"]]] = s["secretValue"]
# Infisical client creds come from the local .env, not Infisical itself.
import os
out["infisical_client_id"]     = os.environ["INFISICAL_CLIENT_ID"]
out["infisical_client_secret"] = os.environ["INFISICAL_CLIENT_SECRET"]

with open(sys.argv[2], "w") as f:
    for k, v in out.items():
        # Ansible parses YAML; quote everything to dodge tokens that start
        # with `[` or contain colons.
        v = v.replace("\\", "\\\\").replace('"', '\\"')
        f.write(f'{k}: "{v}"\n')
PY
    echo "$out"
}

run_ansible() {
    local secrets_file
    secrets_file=$(fetch_secrets_file)
    trap 'rm -f "$secrets_file"' EXIT

    # ansible.cfg uses a relative roles_path ("roles"), so cd into ansible/
    # before invoking the playbook. The secrets file path is absolute so it
    # still resolves after the directory change.
    cd "$PROJECT_DIR/ansible"
    echo "==> ansible-playbook site.yml (inventory: local, target: orbstack)"
    ansible-playbook playbooks/site.yml \
        -i inventories/local/hosts.yml \
        -e "@$secrets_file"
}

case "$cmd" in
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
        echo "Usage: $0 [--skip-up | --destroy]" >&2
        exit 1
        ;;
esac
