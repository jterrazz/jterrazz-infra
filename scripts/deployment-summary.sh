#!/bin/bash
# Deployment Summary Script
# Collects comprehensive deployment information for GitHub Actions summary

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
    $SSH_CMD "$1" 2>/dev/null || echo "N/A"
}

# Collect data
echo "Collecting deployment information..." >&2

# Infrastructure info
TAILSCALE_IP=$(remote "tailscale ip -4 2>/dev/null || echo ''")
K3S_VERSION=$(remote "k3s --version 2>/dev/null | head -1 | awk '{print \$3}' || echo ''")
OS_INFO=$(remote "grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"' || echo 'Linux'")

# Security info
UFW_STATUS=$(remote "ufw status | head -1 | awk '{print \$2}' || echo 'unknown'")
FAIL2BAN_BANNED=$(remote "fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | awk '{print \$NF}' || echo '0'")
# Simpler Tailscale check - just verify we can get an IP
TAILSCALE_CONNECTED=$(remote "tailscale ip -4 2>/dev/null && echo 'yes' || echo 'no'")

# Kubernetes info
TOTAL_PODS=$(remote "kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' '")
RUNNING_PODS=$(remote "kubectl get pods -A --no-headers 2>/dev/null | grep -c 'Running' || echo 0")

# Platform services
ARGOCD_PODS=$(remote "kubectl get pods -n platform-gitops --no-headers 2>/dev/null | grep -c 'Running' || echo 0")
ARGOCD_TOTAL=$(remote "kubectl get pods -n platform-gitops --no-headers 2>/dev/null | wc -l | tr -d ' '")
# k3s traefik uses different labels - check by name pattern
TRAEFIK_STATUS=$(remote "kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c 'traefik.*Running' || echo 0")
CERTMGR_PODS=$(remote "kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c 'Running' || echo 0")
CERTMGR_TOTAL=$(remote "kubectl get pods -n cert-manager --no-headers 2>/dev/null | wc -l | tr -d ' '")
EXTDNS_STATUS=$(remote "kubectl get pods -n external-dns --no-headers 2>/dev/null | grep -c 'Running' || echo 0")
SIGNOZ_PODS=$(remote "kubectl get pods -n platform-observability --no-headers 2>/dev/null | grep -c 'Running' || echo 0")
SIGNOZ_TOTAL=$(remote "kubectl get pods -n platform-observability --no-headers 2>/dev/null | wc -l | tr -d ' '")
# Registry is optional - check if namespace exists first
REGISTRY_EXISTS=$(remote "kubectl get ns platform-registry --no-headers 2>/dev/null && echo 'yes' || echo 'no'")
REGISTRY_STATUS=$(remote "kubectl get pods -n platform-registry --no-headers 2>/dev/null | grep -c 'Running' || echo 0")

# Applications - get sync and health status
ARGOCD_APPS=$(remote "kubectl get applications -n platform-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2>/dev/null")

# Certificates with proper expiry
CERTS_INFO=$(remote "kubectl get certificates -A -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRY:.status.notAfter --no-headers 2>/dev/null")

# Resources
CPU_USAGE=$(remote "top -bn1 | grep 'Cpu(s)' | awk '{print 100 - \$8}' | cut -d. -f1")
MEM_INFO=$(remote "free -m | awk 'NR==2{printf \"%.1f|%.1f\", \$3/1024, \$2/1024}'")
DISK_INFO=$(remote "df -h / | awk 'NR==2{print \$3\"|\"\$2}'")

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
| Tailscale IP | \`$TAILSCALE_IP\` |
| OS | $OS_INFO |
| K3s | $K3S_VERSION |

### 🔒 Security
| Check | Status |
|-------|--------|
| Firewall (UFW) | $([ "$UFW_STATUS" = "active" ] && echo "✅ Active" || echo "⚠️ $UFW_STATUS") |
| Fail2ban | ✅ $FAIL2BAN_BANNED IPs banned |
| SSH | ✅ Key-only |
| Tailscale | $(echo "$TAILSCALE_CONNECTED" | grep -q "yes" && echo "✅ Connected ($TAILSCALE_IP)" || echo "⚠️ Disconnected") |

### 📦 Platform Services
| Service | Status | Pods |
|---------|--------|------|
| ArgoCD | $([ "$ARGOCD_PODS" = "$ARGOCD_TOTAL" ] && [ "$ARGOCD_TOTAL" != "0" ] && echo "✅ Healthy" || echo "⚠️ Degraded") | $ARGOCD_PODS/$ARGOCD_TOTAL |
| Traefik | $([ "$TRAEFIK_STATUS" -ge 1 ] && echo "✅ Healthy" || echo "❌ Down") | $TRAEFIK_STATUS/1 |
| Cert-Manager | $([ "$CERTMGR_PODS" = "$CERTMGR_TOTAL" ] && [ "$CERTMGR_TOTAL" != "0" ] && echo "✅ Healthy" || echo "⚠️ Degraded") | $CERTMGR_PODS/$CERTMGR_TOTAL |
| External-DNS | $([ "$EXTDNS_STATUS" -ge 1 ] && echo "✅ Healthy" || echo "❌ Down") | $EXTDNS_STATUS/1 |
| SigNoz | $([ "$SIGNOZ_PODS" = "$SIGNOZ_TOTAL" ] && [ "$SIGNOZ_TOTAL" != "0" ] && echo "✅ Healthy" || echo "⚠️ Degraded") | $SIGNOZ_PODS/$SIGNOZ_TOTAL |
| Registry | $(echo "$REGISTRY_EXISTS" | grep -q "yes" && ([ "$REGISTRY_STATUS" -ge 1 ] && echo "✅ Healthy" || echo "❌ Down") || echo "⏸️ Not deployed") | $(echo "$REGISTRY_EXISTS" | grep -q "yes" && echo "$REGISTRY_STATUS/1" || echo "-") |

### 📱 Applications
| App | Sync Status | Health |
|-----|-------------|--------|
EOF

# Parse applications
if [[ -n "$ARGOCD_APPS" && "$ARGOCD_APPS" != "N/A" ]]; then
    echo "$ARGOCD_APPS" | while read -r name sync health; do
        [[ -z "$name" ]] && continue
        sync_icon="✅"
        [[ "$sync" != "Synced" ]] && sync_icon="⚠️"
        echo "| $name | $sync_icon $sync | $health |"
    done
else
    echo "| No applications | - | - |"
fi

cat << EOF

### 📜 Certificates
| Domain | Status | Expires |
|--------|--------|---------|
EOF

# Parse certificates
if [[ -n "$CERTS_INFO" && "$CERTS_INFO" != "N/A" ]]; then
    echo "$CERTS_INFO" | while read -r name ready expiry; do
        [[ -z "$name" ]] && continue
        status_icon="✅ Valid"
        [[ "$ready" != "True" ]] && status_icon="⚠️ Pending"
        # Format expiry date
        if [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
            expiry_date="${expiry:0:10}"
        else
            expiry_date="$expiry"
        fi
        echo "| $name | $status_icon | $expiry_date |"
    done
else
    echo "| No certificates | - | - |"
fi

# Parse memory and disk
MEM_USED=$(echo "$MEM_INFO" | cut -d'|' -f1)
MEM_TOTAL=$(echo "$MEM_INFO" | cut -d'|' -f2)
DISK_USED=$(echo "$DISK_INFO" | cut -d'|' -f1)
DISK_TOTAL=$(echo "$DISK_INFO" | cut -d'|' -f2)

cat << EOF

### 📊 Resources
| Metric | Current | Limit |
|--------|---------|-------|
| CPU | ${CPU_USAGE:-0}% | 2 vCPU |
| Memory | ${MEM_USED:-0} GB | ${MEM_TOTAL:-0} GB |
| Disk | ${DISK_USED:-0} | ${DISK_TOTAL:-0} |
| Pods | $RUNNING_PODS running | $TOTAL_PODS total |

### 🔗 Quick Links
- [ArgoCD Dashboard](https://argocd.jterrazz.com) (Tailscale)
- [SigNoz Observability](https://signoz.jterrazz.com) (Tailscale)
- [GitHub Commit](https://github.com/jterrazz/jterrazz-infra/commit/$COMMIT_SHA)
EOF
