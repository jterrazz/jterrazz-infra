#!/bin/bash
# Bootstrap app deployments by triggering each app's CI workflow
# Run this after a fresh cluster rebuild to deploy all applications
#
# Usage:
#   ./scripts/bootstrap-apps.sh
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - Access to jterrazz and clawrr org repos

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

JTERRAZZ_REPOS=(
  "jterrazz/signews-api"
  "jterrazz/gateway-intelligence"
)

CLAWRR_REPOS=(
  "clawrr/web-landing"
)

section "Triggering App Deployments"

for repo in "${JTERRAZZ_REPOS[@]}"; do
  info "Triggering deploy for $repo..."
  if gh workflow run deploy.yaml --repo "$repo"; then
    success "Triggered $repo"
  else
    warning "Failed to trigger $repo (workflow may not exist yet)"
  fi
done

for repo in "${CLAWRR_REPOS[@]}"; do
  info "Triggering deploy for $repo..."
  if gh workflow run deploy.yaml --repo "$repo"; then
    success "Triggered $repo"
  else
    warning "Failed to trigger $repo (workflow may not exist yet)"
  fi
done

success "All app deployments triggered!"
echo
echo "Monitor progress at:"
for repo in "${JTERRAZZ_REPOS[@]}" "${CLAWRR_REPOS[@]}"; do
  echo "  https://github.com/$repo/actions"
done
