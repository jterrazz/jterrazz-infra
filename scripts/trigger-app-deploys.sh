#!/bin/bash
# Trigger app CI workflows to deploy all applications.
# Run after a fresh cluster rebuild to deploy all apps.
#
# Usage: ./scripts/trigger-app-deploys.sh
# Prerequisites: gh CLI authenticated (gh auth login)

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

  # Stagger dispatches: this fires 6 rolling deploys (Docker build + helm
  # upgrade) against a single memory-constrained node. Without a gap, all 6
  # CI runs land on the cluster at once and compete for RAM during the
  # build/deploy window. A short sleep spreads them out instead of letting
  # the whole herd hit at once (skip it after the last repo).
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
