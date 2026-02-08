#!/bin/bash
# Trigger app CI workflows to deploy all applications.
# Run after a fresh cluster rebuild to deploy all apps.
#
# Usage: ./scripts/trigger-app-deploys.sh
# Prerequisites: gh CLI authenticated (gh auth login)

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPOS=(
  "jterrazz/signews-api"
  "jterrazz/gateway-intelligence"
  "jterrazz/clawssify-web-landing"
  "clawrr/web-landing"
)

section "Triggering App Deployments"

for repo in "${REPOS[@]}"; do
  info "Triggering deploy for $repo..."
  if gh workflow run deploy.yaml --repo "$repo"; then
    success "Triggered $repo"
  else
    warn "Failed to trigger $repo (workflow may not exist yet)"
  fi
done

success "All app deployments triggered!"
echo
echo "Monitor progress at:"
for repo in "${REPOS[@]}"; do
  echo "  https://github.com/$repo/actions"
done
