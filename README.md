# Jterrazz Infrastructure

Minimal Kubernetes infrastructure with local development and production deployment.

## Stack

```
Local (Multipass)              Production (Hetzner)
├── k3s + Traefik              ├── k3s + Traefik
├── ArgoCD                     ├── ArgoCD
└── Your Apps                  └── Your Apps
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
│   ├── playbooks/        # base, security, k3s, platform
│   ├── roles/            # k3s, security, storage, tailscale
│   └── inventories/      # local, production
│
├── kubernetes/           # K8s manifests (Kustomize)
│   ├── applications/     # Your ArgoCD apps
│   └── infrastructure/   # Platform (ArgoCD, Traefik config)
│
├── pulumi/               # Infrastructure as Code (Hetzner VPS)
│   └── index.ts          # TypeScript
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

Then push - ArgoCD auto-syncs, or run `make ansible` to apply immediately.

## Production Setup

1. Create Pulumi account (free): https://app.pulumi.com
2. Set secrets:
   ```bash
   cd pulumi
   pulumi config set --secret sshPublicKey "ssh-ed25519 ..."
   export HCLOUD_TOKEN="your-hetzner-token"
   ```
3. Deploy: `make deploy`

## GitHub Actions

- **validate.yaml** - Runs on PR/push (lint, syntax check)
- **deploy.yaml** - Manual trigger for production deploy

Required secrets:
- `PULUMI_ACCESS_TOKEN`
- `HCLOUD_TOKEN`
- `SSH_PRIVATE_KEY`

## Prerequisites

```bash
# macOS
brew install multipass ansible pulumi node
```
