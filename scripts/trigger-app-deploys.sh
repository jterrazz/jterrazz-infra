#!/bin/bash
# Trigger every app's CI to redeploy — run after a fresh cluster rebuild.
# Needs an authenticated `gh`.

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPOS=(
  "jterrazz/signews-api"
  "jterrazz/signews-web"
  "jterrazz/gateway-intelligence"
  "jterrazz/clawssify-web"
  "jterrazz/spwn-web"
  "clawrr/web-landing"
)

section "Triggering App Deployments"

for i in "${!REPOS[@]}"; do
  repo="${REPOS[$i]}"
  info "Triggering deploy for $repo..."
  if gh workflow run "Build and Deploy" --repo "$repo"; then
    success "Triggered $repo"
  else
    warn "Failed to trigger $repo (workflow may not exist yet)"
  fi

  # Stagger: these are rolling deploys against ONE memory-constrained node,
  # and without a gap every CI run lands at once and competes for RAM.
  if (( i < ${#REPOS[@]} - 1 )); then
    sleep 20
  fi
done

success "All app deployments triggered!"
echo
echo "Monitor progress at:"
for repo in "${REPOS[@]}"; do
  echo "  https://github.com/$repo/actions"
done
