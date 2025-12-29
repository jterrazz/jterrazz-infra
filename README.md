# Jterrazz Infrastructure

Infrastructure as Code for Kubernetes with local development and production deployment.

## Quick Start

```bash
make start    # Complete local setup
make status   # Check services
make ssh      # Access VM
```

## Architecture

```
Local (Multipass VM)          Production (Hetzner VPS)
├── k3s Kubernetes            ├── k3s Kubernetes
├── Traefik Ingress           ├── Traefik + Let's Encrypt
├── ArgoCD (GitOps)           ├── ArgoCD (GitOps)
├── Portainer                 ├── Portainer
├── Self-signed TLS           ├── Tailscale VPN
└── mDNS (*.local)            └── Cloudflare DNS
```

## Commands

```bash
# Local
make start    # Create VM + deploy everything
make status   # Show services and URLs
make ssh      # SSH into VM
make stop     # Delete VM

# Production
make deploy   # Deploy via Terraform + Ansible
```

## Project Structure

```
├── ansible/
│   ├── playbooks/           # Split playbooks (base, security, k3s, etc.)
│   ├── roles/               # k3s, security, storage, tailscale
│   ├── inventories/         # local/, production/
│   └── group_vars/          # Environment variables
│
├── kubernetes/
│   ├── applications/        # ArgoCD app definitions
│   └── infrastructure/
│       ├── base/            # Shared (argocd, portainer, traefik)
│       └── environments/    # local/, production/ overlays
│
├── terraform/
│   ├── modules/             # hetzner-server, cloudflare-dns
│   ├── main.tf
│   └── variables.tf
│
└── scripts/                 # local-dev.sh, bootstrap.sh
```

## Storage

Uses k3s built-in `local-path` StorageClass. Add to your app:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

## Deploy Applications

Create ArgoCD application:

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

## Security

- SSH: Key-only, no root login (production)
- Firewall: UFW with minimal ports
- Network Policies: Default-deny
- Tailscale: VPN for private access
- Auto-updates: Unattended security patches

## Prerequisites

**Local:** Multipass, Ansible
**Production:** Terraform, Hetzner account

```bash
# macOS
brew install multipass ansible terraform
```

## Production Setup

Create `terraform/terraform.tfvars`:

```hcl
hcloud_token   = "your-token"
ssh_public_key = "ssh-ed25519 ..."
```

Then run `make deploy`.
