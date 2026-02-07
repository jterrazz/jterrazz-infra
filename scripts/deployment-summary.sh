#!/bin/bash
# Deployment Summary Script
# Collects comprehensive deployment information for GitHub Actions summary
# Uses kubectl JSON output + jq for reliable parsing

set -euo pipefail

# Arguments
SERVER_IP="${1:-}"
SSH_KEY="${2:-~/.ssh/id_ed25519}"
COMMIT_SHA="${3:-unknown}"
DEPLOY_STATUS="${4:-unknown}"
DEPLOY_DURATION="${5:-unknown}"
GITHUB_ACTOR="${6:-unknown}"

if [[ -z "$SERVER_IP" ]]; then
    echo "Usage: $0 <server_ip> [ssh_key] [commit_sha] [status] [duration] [actor]"
    exit 1
fi

SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY root@$SERVER_IP"

# Helper function to run remote command
remote() {
    $SSH_CMD "$1" 2>/dev/null || echo ""
}

# Helper to run kubectl with JSON output
kubectl_json() {
    remote "kubectl $1 -o json 2>/dev/null" || echo "{}"
}

echo "Collecting deployment information..." >&2

# Infrastructure info
TAILSCALE_IP=$(remote "tailscale ip -4 2>/dev/null")
K3S_VERSION=$(remote "k3s --version 2>/dev/null | head -1 | awk '{print \$3}'")
OS_INFO=$(remote "grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"'")

# Security info
UFW_STATUS=$(remote "ufw status | head -1 | awk '{print \$2}'")
FAIL2BAN_BANNED=$(remote "fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | awk '{print \$NF}'" || echo "0")
TAILSCALE_CONNECTED="no"
[[ -n "$TAILSCALE_IP" ]] && TAILSCALE_CONNECTED="yes"

# Resources
CPU_USAGE=$(remote "top -bn1 | grep 'Cpu(s)' | awk '{print 100 - \$8}' | cut -d. -f1")
CPU_CORES=$(remote "nproc")
MEM_INFO=$(remote "free -m | awk 'NR==2{printf \"%.1f|%.1f\", \$3/1024, \$2/1024}'")
DISK_INFO=$(remote "df -h / | awk 'NR==2{print \$3\"|\"\$2}'")

MEM_USED=$(echo "$MEM_INFO" | cut -d'|' -f1)
MEM_TOTAL=$(echo "$MEM_INFO" | cut -d'|' -f2)
DISK_USED=$(echo "$DISK_INFO" | cut -d'|' -f1)
DISK_TOTAL=$(echo "$DISK_INFO" | cut -d'|' -f2)

# Get all pods for total count
ALL_PODS_JSON=$(kubectl_json "get pods -A")
TOTAL_PODS=$(echo "$ALL_PODS_JSON" | jq '.items | length')
RUNNING_PODS=$(echo "$ALL_PODS_JSON" | jq '[.items[] | select(.status.phase == "Running")] | length')

# Platform services - using JSON for reliable parsing
# Each service: namespace, optional name filter
get_service_status() {
    local namespace="$1"
    local filter="${2:-}"

    local pods_json=$(kubectl_json "get pods -n $namespace")

    # Check if namespace exists (empty items means no namespace or no pods)
    local total_items=$(echo "$pods_json" | jq '.items | length')
    if [[ "$total_items" == "0" || "$total_items" == "null" ]]; then
        echo "notdeployed|0|0"
        return
    fi

    # Apply filter if provided
    local running total
    if [[ -n "$filter" ]]; then
        running=$(echo "$pods_json" | jq --arg f "$filter" '[.items[] | select(.metadata.name | contains($f)) | select(.status.phase == "Running")] | length')
        total=$(echo "$pods_json" | jq --arg f "$filter" '[.items[] | select(.metadata.name | contains($f)) | select(.status.phase != "Succeeded" and .status.phase != "Completed")] | length')
    else
        running=$(echo "$pods_json" | jq '[.items[] | select(.status.phase == "Running")] | length')
        total=$(echo "$pods_json" | jq '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Completed")] | length')
    fi

    # Determine status
    local status="down"
    if [[ "$running" -gt 0 && "$running" -ge "$total" ]]; then
        status="healthy"
    elif [[ "$running" -gt 0 ]]; then
        status="degraded"
    fi

    echo "$status|$running|$total"
}

# Get service statuses
PORTAINER_STATUS=$(get_service_status "platform-management" "portainer")
TRAEFIK_STATUS=$(get_service_status "kube-system" "traefik")
CERTMGR_STATUS=$(get_service_status "platform-networking" "cert-manager")
EXTDNS_STATUS=$(get_service_status "platform-networking" "external-dns")
SIGNOZ_STATUS=$(get_service_status "platform-observability")
REGISTRY_STATUS=$(get_service_status "platform-registry")

# Helper to format service row
format_service_row() {
    local name="$1"
    local status_str="$2"

    local status=$(echo "$status_str" | cut -d'|' -f1)
    local running=$(echo "$status_str" | cut -d'|' -f2)
    local total=$(echo "$status_str" | cut -d'|' -f3)

    local icon pods
    case "$status" in
        healthy) icon="✅ Healthy" ;;
        degraded) icon="⚠️ Degraded" ;;
        down) icon="❌ Down" ;;
        notdeployed) icon="⏸️ Not deployed"; pods="-" ;;
    esac

    [[ -z "${pods:-}" ]] && pods="$running/$total"

    echo "| $name | $icon | $pods |"
}

# Get certificates dynamically
CERTS_JSON=$(kubectl_json "get certificates -A")

# Generate summary
STATUS_EMOJI="✅"
[[ "$DEPLOY_STATUS" != "success" ]] && STATUS_EMOJI="❌"

cat << EOF
## 🚀 Deployment Summary

### ⏱️ Deployment Info
| Field | Value |
|-------|-------|
| Status | $STATUS_EMOJI $DEPLOY_STATUS |
| Duration | $DEPLOY_DURATION |
| Commit | \`${COMMIT_SHA:0:7}\` |
| Branch | \`main\` |
| Triggered by | @$GITHUB_ACTOR |

### 🖥️ Infrastructure
| Resource | Value |
|----------|-------|
| Server | \`jterrazz-vps\` |
| Public IP | \`$SERVER_IP\` |
| Tailscale IP | \`${TAILSCALE_IP:-N/A}\` |
| OS | ${OS_INFO:-Linux} |
| K3s | ${K3S_VERSION:-N/A} |

### 🔒 Security
| Check | Status |
|-------|--------|
| Firewall (UFW) | $([ "$UFW_STATUS" = "active" ] && echo "✅ Active" || echo "⚠️ ${UFW_STATUS:-unknown}") |
| Fail2ban | ✅ ${FAIL2BAN_BANNED:-0} IPs banned |
| SSH | ✅ Key-only |
| Tailscale | $([ "$TAILSCALE_CONNECTED" = "yes" ] && echo "✅ Connected ($TAILSCALE_IP)" || echo "⚠️ Disconnected") |

### 📦 Platform Services
| Service | Status | Pods |
|---------|--------|------|
$(format_service_row "Portainer" "$PORTAINER_STATUS")
$(format_service_row "Traefik" "$TRAEFIK_STATUS")
$(format_service_row "Cert-Manager" "$CERTMGR_STATUS")
$(format_service_row "External-DNS" "$EXTDNS_STATUS")
$(format_service_row "SigNoz" "$SIGNOZ_STATUS")
$(format_service_row "Registry" "$REGISTRY_STATUS")

### 📱 Applications (Helm Releases)
| App | Namespace | Status |
|-----|-----------|--------|
EOF

# Get Helm releases across all namespaces
HELM_RELEASES=$(remote "helm list -A --output json 2>/dev/null" || echo "[]")
release_count=$(echo "$HELM_RELEASES" | jq 'length')
if [[ "$release_count" -gt 0 && "$release_count" != "null" ]]; then
    echo "$HELM_RELEASES" | jq -r '.[] | select(.namespace | startswith("staging-") or startswith("prod-")) | "\(.name)|\(.namespace)|\(.status)"' | while IFS='|' read -r name ns status; do
        status_icon="✅"
        [[ "$status" != "deployed" ]] && status_icon="⚠️"
        echo "| $name | $ns | $status_icon $status |"
    done
    # If no app releases found
    if ! echo "$HELM_RELEASES" | jq -e '.[] | select(.namespace | startswith("staging-") or startswith("prod-"))' > /dev/null 2>&1; then
        echo "| No app releases | - | - |"
    fi
else
    echo "| No app releases | - | - |"
fi

cat << EOF

### 📜 Certificates
| Domain | Status | Expires |
|--------|--------|---------|
EOF

# Parse certificates from JSON
cert_count=$(echo "$CERTS_JSON" | jq '.items | length')
if [[ "$cert_count" -gt 0 && "$cert_count" != "null" ]]; then
    echo "$CERTS_JSON" | jq -r '.items[] | "\(.metadata.name)|\(.status.conditions[]? | select(.type == "Ready") | .status // "Unknown")|\(.status.notAfter // "Unknown")"' | while IFS='|' read -r name ready expiry; do
        status_icon="✅ Valid"
        [[ "$ready" != "True" ]] && status_icon="⚠️ Pending"
        expiry_date="${expiry:0:10}"
        echo "| $name | $status_icon | $expiry_date |"
    done
else
    echo "| No certificates | - | - |"
fi

cat << EOF

### 📊 Resources
| Metric | Current | Limit |
|--------|---------|-------|
| CPU | ${CPU_USAGE:-0}% | ${CPU_CORES:-?} vCPU |
| Memory | ${MEM_USED:-0} GB | ${MEM_TOTAL:-0} GB |
| Disk | ${DISK_USED:-0} | ${DISK_TOTAL:-0} |
| Pods | $RUNNING_PODS running | $TOTAL_PODS total |

### 🔗 Quick Links
- [Portainer Dashboard](https://portainer.jterrazz.com) (Tailscale)
- [SigNoz Observability](https://signoz.jterrazz.com) (Tailscale)
- [GitHub Commit](https://github.com/jterrazz/jterrazz-infra/commit/$COMMIT_SHA)
EOF
