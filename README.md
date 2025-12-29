# Jterrazz Infrastructure

Modern Infrastructure as Code with one-command local development and production-ready Kubernetes deployment.

## Quick Start

```bash
# Complete local setup (one command)
make start

# Check status
make status

# Access applications
open https://infra.local      # Infrastructure dashboard
open https://argocd.local     # GitOps dashboard
open https://portainer.local  # Kubernetes management
```

## Architecture

### Local Development

```
Multipass VM (Ubuntu 24.04)
├── k3s Kubernetes Cluster
├── Traefik Ingress + Load Balancer
├── mDNS Publisher (*.local domains)
├── Self-signed SSL Certificates
├── ArgoCD (GitOps)
├── Portainer (K8s Management)
└── UFW + fail2ban (Security)
```

### Production

```
Cloudflare DNS
    ↓
Hetzner VPS (Nuremberg, Germany)
├── k3s Kubernetes Cluster
├── Traefik Ingress Controller
├── cert-manager (Auto SSL)
├── ArgoCD (GitOps)
└── Tailscale (Private Access)
```

## Storage

All applications use the k3s built-in `local-path` StorageClass. Data is stored on the VPS SSD at `/var/lib/k8s-data`.

### Adding Persistent Storage to Your App

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
---
# In your deployment
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-app-data
```

## Commands

### Local Development

```bash
make start    # Complete setup - VM + K8s + apps
make status   # Show health, services, URLs
make ssh      # SSH into VM
make stop     # Delete VM
make clean    # Force cleanup everything
```

### Production

```bash
make deploy   # Deploy to production VPS
```

### Utilities

```bash
make deps     # Check required tools
make vm       # Create VM only
make ansible  # Run Ansible only
```

## Project Structure

```
jterrazz-infra/
├── terraform/                    # Infrastructure provisioning
│   ├── main.tf                   # Hetzner VPS + Cloudflare DNS
│   └── variables.tf              # Configuration variables
│
├── ansible/                      # Server configuration
│   ├── site.yml                  # Main playbook
│   ├── roles/
│   │   ├── security/             # UFW, fail2ban, SSH hardening
│   │   ├── k3s/                  # Kubernetes installation
│   │   ├── storage/              # Storage directory setup
│   │   └── tailscale/            # VPN (production only)
│   ├── inventories/
│   │   ├── multipass/            # Local VM inventory
│   │   └── vps/                  # Production inventory
│   └── group_vars/
│       ├── all/                  # Global variables
│       ├── local/                # Local overrides
│       └── production/           # Production overrides
│
├── kubernetes/
│   ├── applications/             # ArgoCD app definitions
│   │   └── *.yml                 # Your apps (GitOps)
│   └── infrastructure/
│       ├── base/                 # Shared infrastructure
│       │   ├── storage/          # local-path config
│       │   ├── network-policies/ # Security policies
│       │   ├── argocd/           # GitOps controller
│       │   ├── portainer/        # K8s management UI
│       │   ├── dashboard/        # Infrastructure dashboard
│       │   └── traefik/          # Ingress config
│       └── environments/
│           ├── local/            # Local-specific (mDNS, TLS)
│           └── production/       # Prod-specific (cert-manager)
│
└── scripts/                      # Automation utilities
```

## Deploy Your Applications

Create an ArgoCD application pointing to your repository:

```yaml
# kubernetes/applications/my-app.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: platform-gitops
spec:
  source:
    repoURL: https://github.com/your-org/your-app
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

## Security Features

- **Firewall**: UFW with minimal open ports (22, 80, 443)
- **SSH**: Key-only authentication, strong ciphers
- **Intrusion Prevention**: fail2ban for brute force protection
- **Network Policies**: Default-deny with explicit allows
- **RBAC**: Minimal permissions for all services
- **Auto Updates**: Unattended security patches
- **VPN**: Tailscale for private access (production)

## Prerequisites

**Local Development:**
- [Multipass](https://multipass.run/) - `brew install multipass`
- [Ansible](https://docs.ansible.com/) - `brew install ansible`

**Production:**
- [Terraform](https://terraform.io/) - `brew install terraform`
- Hetzner Cloud account
- Cloudflare account (optional, for DNS)

## Environment Variables

For production deployment, create `terraform/terraform.tfvars`:

```hcl
hcloud_token         = "your-hetzner-api-token"
ssh_public_key       = "ssh-ed25519 AAAA..."
cloudflare_api_token = "your-cloudflare-token"  # optional
cloudflare_zone_id   = "your-zone-id"           # optional
domain_name          = "yourdomain.com"         # optional
```

## License

MIT License - see [LICENSE](LICENSE) file.
