#!/bin/bash
# Deploy the same set of app releases that run on Hetzner onto the local
# OrbStack k3s cluster. Mirrors what jterrazz-actions' docker-deploy
# composite action does, but driven from the Mac instead of GitHub
# Actions — useful when bringing the OrbStack target into prod-parity
# without flipping every app's CI to point at it.
#
# Each release is helm-installed from the same OCI chart (app v1.11.0)
# the production stack uses. Image tags are read live from each
# corresponding Hetzner release so OrbStack lands on the same versions.
#
# Usage: ./scripts/deploy-apps-local.sh
# Requires: orb CLI, ssh access to Hetzner, .env in repo root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
set -a; source "$PROJECT_DIR/.env"; set +a

VM=jterrazz-infra
SSH_KEY=/tmp/jterrazz_ssh_key
HETZNER_IP=46.224.186.190
ORB_TAILSCALE_HOSTNAME="${VM}.tail77a797.ts.net"

# Repo each app is published from, in `owner/repo` form. The app's image
# tag and the registry namespace match the repo name (e.g.
# `jterrazz/spwn-web` → image `registry.jterrazz.com/spwn-web:<tag>`).
APP_REPOS=(
    "jterrazz/signews-api"
    "jterrazz/signews-web"
    "jterrazz/gateway-intelligence"
    "jterrazz/clawssify-web-landing"
    "jterrazz/spwn-web"
    "clawrr/web-landing"
)

# Fetch the platform-shared values from Infisical /infrastructure prod.
# Returns: REGISTRY_PASSWORD, CLOUDFLARE_TUNNEL_HOSTNAME, exported.
fetch_platform_values() {
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

    export REGISTRY_PASSWORD
    export CLOUDFLARE_TUNNEL_TOKEN
    REGISTRY_PASSWORD=$(echo "$secrets_json" | python3 -c "
import json, sys
for s in json.load(sys.stdin).get('secrets', []):
    if s['secretKey'] == 'DOCKER_REGISTRY_PASSWORD':
        print(s['secretValue'])")
    CLOUDFLARE_TUNNEL_TOKEN=$(echo "$secrets_json" | python3 -c "
import json, sys
for s in json.load(sys.stdin).get('secrets', []):
    if s['secretKey'] == 'CLOUDFLARE_TUNNEL_TOKEN':
        print(s['secretValue'])")
    # Tunnel token is base64 JSON {a:<account>, t:<tunnel>, s:<secret>}.
    export CLOUDFLARE_TUNNEL_HOSTNAME
    CLOUDFLARE_TUNNEL_HOSTNAME="$(python3 -c "
import json, base64, os
d = json.loads(base64.b64decode(os.environ['CLOUDFLARE_TUNNEL_TOKEN']))
print(d['t'])").cfargotunnel.com"
}

# Resolve the helm release config currently running on Hetzner for a
# given app namespace. Returns one line per existing release in:
#   <release>|<image>:<tag>|<environment>
hetzner_releases_for() {
    local image_name=$1
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@$HETZNER_IP" "
        for ns in \$(kubectl get ns -o name | grep -E '/(prod|next|staging)-${image_name}\$' | cut -d/ -f2); do
            release=\$(helm list -n \"\$ns\" -q | head -1)
            [ -z \"\$release\" ] && continue
            vals=\$(helm get values \"\$release\" -n \"\$ns\" 2>/dev/null)
            image=\$(echo \"\$vals\" | grep -E '^  image:' | head -1 | awk '{print \$2}')
            env=\$(echo \"\$vals\" | grep -E '^environment:' | head -1 | awk '{print \$2}')
            echo \"\$release|\$image|\$env\"
        done
    "
}

# Fetch an app's .infrastructure/application.yaml from GitHub. Streamed
# through gh (which is already authenticated locally) so we don't need
# to clone the repo.
fetch_app_manifest() {
    local repo=$1 dest=$2
    gh api "repos/$repo/contents/.infrastructure/application.yaml" --jq .content \
        | base64 -d > "$dest"
}

deploy_app() {
    local repo=$1 image_name="${repo##*/}"
    # Each app's image-name in the registry usually matches the repo name,
    # except for the special `clawrr/web-landing` repo whose image is
    # `clawrr-web-landing` (the namespace it lives in on Hetzner).
    [ "$repo" = "clawrr/web-landing" ] && image_name="clawrr-web-landing"

    echo "==> $repo (image: $image_name)"

    local manifest_local
    manifest_local=$(mktemp -t "app-manifest-${image_name}-XXXXX.yaml")
    # RETURN traps are NOT function-scoped by default in bash (would need
    # `set -o functrace`/`-T`). So this trap also fires when main()
    # returns — at which point manifest_local is out of scope and `set -u`
    # complains. The `:-` default makes the eval a no-op outside the
    # function's scope; the actual cleanup still works when the trap
    # fires immediately at deploy_app's return.
    trap 'rm -f "${manifest_local:-}"' RETURN
    fetch_app_manifest "$repo" "$manifest_local"

    # Copy the manifest into the VM. /tmp inside the VM is fine for
    # one-shot deploys; it doesn't need to persist.
    local vm_manifest="/tmp/app-manifest-${image_name}.yaml"
    orbctl push -m "$VM" -u root "$manifest_local" "$vm_manifest" 2>/dev/null \
        || cat "$manifest_local" | orb -m "$VM" -u root tee "$vm_manifest" >/dev/null

    while IFS='|' read -r release image env; do
        [ -z "$release" ] && continue
        echo "  --> $release ($image, env=$env)"
        # `</dev/null` on orb stops the remote shell from consuming the
        # outer `while read` loop's stdin (read had returned line 1; if we
        # don't redirect, orb's underlying ssh pulls lines 2+ off the pipe
        # and the loop only iterates once).
        # No --wait: helm waits per-release are serially blocking and
        # ImagePullBackOff-style failures eat 5min each.
        orb -m "$VM" -u root sh -c "
            KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
            helm upgrade --install '$release' \
                oci://registry.jterrazz.com/charts/app \
                --version 1.12.0 \
                -f '$vm_manifest' \
                --set environment='$env' \
                --set spec.image='$image' \
                --set registry.username=deploy \
                --set registry.password='$REGISTRY_PASSWORD' \
                --set infrastructure.publicTarget='$CLOUDFLARE_TUNNEL_HOSTNAME' \
                --set infrastructure.tailscaleHostname='$ORB_TAILSCALE_HOSTNAME' \
                -n '$release' \
                --create-namespace 2>&1 | tail -3
        " </dev/null
    done < <(hetzner_releases_for "$image_name")
}

main() {
    echo "==> Resolving platform values from Infisical"
    fetch_platform_values
    echo "    Cloudflare tunnel:    $CLOUDFLARE_TUNNEL_HOSTNAME"
    echo "    OrbStack Tailscale:   $ORB_TAILSCALE_HOSTNAME"
    echo

    echo "==> Logging in to the OCI registry inside the VM"
    orb -m "$VM" -u root sh -c "
        echo '$REGISTRY_PASSWORD' | helm registry login registry.jterrazz.com \
            --username deploy --password-stdin
    "

    for repo in "${APP_REPOS[@]}"; do
        deploy_app "$repo"
    done

    echo
    echo "==> Done. Releases on OrbStack:"
    orb -m "$VM" -u root sh -c 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm list -A | grep -E "prod-|next-|staging-"'
}

main "$@"
