# Jterrazz Infrastructure

Minimal Kubernetes infrastructure with local development and production deployment.

## Stack

```
Local (Multipass)              Production (Hetzner)
├── k3s + Traefik              ├── k3s + Traefik
├── ArgoCD                     ├── ArgoCD
├── SigNoz (observability)     ├── SigNoz (observability)
└── Your Apps                  └── Your Apps + Tailscale VPN
```

## Quick Start

```bash
# Local development
make start    # Full setup
make status   # Check services
make ssh      # Access VM

# Production
make deploy   # Deploy to Hetzner
```

## Project Structure

```
├── ansible/              # Server configuration (idempotent)
│   ├── playbooks/        # base, security, networking, storage, kubernetes, platform
│   ├── roles/            # k3s, security, storage, tailscale
│   └── inventories/      # local, production
│
├── kubernetes/           # K8s manifests
│   ├── applications/     # Your ArgoCD apps
│   ├── platform/         # Platform services (ArgoCD, SigNoz)
│   └── infrastructure/   # Base resources (namespaces, ingress)
│
├── pulumi/               # Infrastructure as Code (Hetzner VPS)
│   └── index.ts          # TypeScript - auto-generates SSH keys
│
└── scripts/              # Automation
```

## Deploy Applications

Add an ArgoCD application:

```yaml
# kubernetes/applications/my-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: platform-gitops
spec:
  source:
    repoURL: https://github.com/you/your-app
    path: k8s/
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: app-my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Then push - ArgoCD auto-syncs.

## Production Setup

### Prerequisites

```bash
# macOS
brew install multipass ansible pulumi node
```

### 1. Create Accounts

- **Pulumi** (free): https://app.pulumi.com
- **Hetzner Cloud**: https://console.hetzner.cloud
- **Tailscale** (free): https://tailscale.com

### 2. Configure Tailscale OAuth

1. Go to https://login.tailscale.com/admin/settings/oauth
2. Create OAuth client with scopes:
   - **Devices: Core** (Write)
   - **Auth Keys** (Write)
3. Add tag in ACL policy (https://login.tailscale.com/admin/acls/file):
   ```json
   {
     "tagOwners": {
       "tag:ci": ["autogroup:admin"]
     }
   }
   ```
4. Configure OAuth client to use `tag:ci`

### 3. GitHub Actions Secrets

Set these secrets in your repository (Settings → Secrets → Actions):

| Secret | Description | Where to get it |
|--------|-------------|-----------------|
| `PULUMI_ACCESS_TOKEN` | Pulumi API token | https://app.pulumi.com/account/tokens |
| `HCLOUD_TOKEN` | Hetzner Cloud API token | Hetzner Console → Security → API Tokens |
| `TAILSCALE_OAUTH_CLIENT_ID` | Tailscale OAuth client ID | https://login.tailscale.com/admin/settings/oauth |
| `TAILSCALE_OAUTH_CLIENT_SECRET` | Tailscale OAuth client secret | Same as above (starts with `tskey-client-`) |

### 4. Deploy

Push to `main` branch - GitHub Actions will:
1. Provision VPS with Pulumi (auto-generates SSH keys)
2. Configure server with Ansible (security, k3s, Tailscale)
3. Deploy platform services (ArgoCD, SigNoz)

## Accessing Services

Internal services (ArgoCD, SigNoz) are **not exposed to the internet**. Access via Tailscale:

### Option 1: kubectl port-forward (recommended)

```bash
# Use the fetched kubeconfig
export KUBECONFIG=./data/kubeconfig/k3s.yaml

# ArgoCD UI
kubectl port-forward svc/argocd-server -n platform-gitops 8080:80
# Open http://localhost:8080

# SigNoz UI
kubectl port-forward svc/signoz-frontend -n platform-observability 3301:3301
# Open http://localhost:3301
```

### Option 2: SSH tunnel via Tailscale

```bash
# Get VPS Tailscale IP
ssh root@<PUBLIC_IP> "tailscale ip -4"

# Connect via Tailscale IP
ssh root@<TAILSCALE_IP> -L 8080:localhost:8080
```

### ArgoCD Admin Password

```bash
kubectl -n platform-gitops get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Security Model

| Port | Service | Access |
|------|---------|--------|
| 22 | SSH | Public (key-only, fail2ban protected) |
| 80/443 | Traefik | Public (for your apps) |
| 6443 | K8s API | Tailscale + private networks only |
| ArgoCD | Platform | Tailscale only (no ingress) |
| SigNoz | Platform | Tailscale only (no ingress) |

## Local Development

```bash
make start          # Create VM + deploy everything
make status         # Check cluster status
make ssh            # SSH into VM
make ansible        # Re-run Ansible
make destroy        # Destroy VM
```

## GitHub Actions

| Workflow | Trigger | Description |
|----------|---------|-------------|
| `validate.yaml` | PR/push | Lint, syntax check |
| `deploy.yaml` | Push to main | Full production deploy |
