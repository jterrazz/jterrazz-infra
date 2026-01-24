# @jterrazz/infra

Minimal Kubernetes infrastructure with local development and production deployment on Hetzner Cloud.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         INTERNET                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Cloudflare DNS                               │
│  *.jterrazz.com → Tailscale IP (private) or Public IP          │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          ▼                                       ▼
┌──────────────────────┐              ┌──────────────────────┐
│   Public Access      │              │  Tailscale VPN       │
│   (ports 80/443)     │              │  (private services)  │
└──────────────────────┘              └──────────────────────┘
          │                                       │
          └───────────────────┬───────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Hetzner VPS                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    K3s Cluster                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │   Traefik   │  │   ArgoCD    │  │     SigNoz      │  │   │
│  │  │  (Ingress)  │  │   (GitOps)  │  │ (Observability) │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘  │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │  Registry   │  │ Cert-Manager│  │  External-DNS   │  │   │
│  │  │  (Private)  │  │(Let's Encr.)│  │  (Cloudflare)   │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘  │   │
│  │  ┌───────────────────────────────────────────────────┐  │   │
│  │  │              Your Applications                    │  │   │
│  │  └───────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Stack

| Component              | Purpose                               |
| ---------------------- | ------------------------------------- |
| **K3s**                | Lightweight Kubernetes                |
| **Traefik**            | Ingress controller with automatic TLS |
| **ArgoCD**             | GitOps continuous deployment          |
| **SigNoz**             | Observability (traces, metrics, logs) |
| **Cert-Manager**       | Automatic Let's Encrypt certificates  |
| **External-DNS**       | Automatic Cloudflare DNS management   |
| **Infisical Operator** | Automated secrets management          |
| **Tailscale**          | Private VPN for secure access         |
| **Docker Registry**    | Private container registry            |
| **n8n**                | Workflow automation                   |

## Quick Start

```bash
# Local development
make start    # Full setup with Multipass VM
make status   # Check services
make ssh      # Access VM

# Production
make deploy   # Deploy to Hetzner (or push to main)
```

## Project Structure

```
├── ansible/                    # Server configuration
│   ├── playbooks/              # Orchestration playbooks
│   └── roles/                  # Reusable roles (k3s, security, tailscale)
│
├── kubernetes/                 # GitOps manifests (ArgoCD syncs these)
│   ├── infrastructure/         # Base capabilities (rarely changes)
│   │   └── base/
│   │       ├── storage/        # StorageClass definitions
│   │       ├── traefik/        # Middlewares (private-access, rate-limit)
│   │       ├── cert-manager/   # ClusterIssuers (wildcard for *.jterrazz.com)
│   │       └── network-policies/
│   │
│   ├── platform/               # Platform services (one file per app)
│   │   ├── argocd.yaml         # ArgoCD + IngressRoute + Certificate
│   │   ├── signoz.yaml         # SigNoz + IngressRoute + Certificate
│   │   ├── n8n.yaml            # n8n + IngressRoute + Certificate
│   │   └── ...
│   │
│   └── applications/           # Your app definitions
│
├── pulumi/                     # Infrastructure as Code (Hetzner VPS)
└── scripts/                    # Automation scripts
```

## Self-Contained Apps Pattern

Each platform service is **fully self-contained** in a single ArgoCD Application:

```yaml
# kubernetes/platform/my-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  sources:
    # Source 1: Helm chart
    - repoURL: https://charts.example.com
      chart: my-app
      helm:
        values: |
          persistence:
            storageClass: local-path  # Dynamic provisioning
          ingress:
            enabled: false  # We use Traefik IngressRoute

    # Source 2: IngressRoute + Certificate
    - repoURL: https://github.com/jterrazz/jterrazz-infra.git
      path: kubernetes/platform/my-app-resources
```

**Adding a new app = one file** (+ a resources directory for ingress/certs).

### Internal vs External Services

```yaml
# Internal (Tailscale-only) - add private-access middleware
middlewares:
  - name: private-access
    namespace: platform-ingress

# External (Public) - no private-access middleware
middlewares:
  - name: rate-limit
    namespace: platform-ingress
```

## Services & Access

### Private Services (via Tailscale)

| Service  | URL                             | Purpose             |
| -------- | ------------------------------- | ------------------- |
| ArgoCD   | `https://argocd.jterrazz.com`   | GitOps dashboard    |
| SigNoz   | `https://signoz.jterrazz.com`   | Observability       |
| Registry | `https://registry.jterrazz.com` | Container images    |
| n8n      | `https://n8n.jterrazz.com`      | Workflow automation |

All private services:

- Use valid Let's Encrypt TLS certificates (wildcard for \*.jterrazz.com)
- DNS points to Tailscale IP
- Only accessible when connected to Tailscale VPN

### ArgoCD Admin Password

```bash
kubectl -n platform-gitops get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## Storage

All apps use the K3s built-in `local-path` provisioner:

- **Dynamic provisioning**: No pre-created PVs needed
- **Data location**: `/var/lib/rancher/k3s/storage/`
- **Usage**: Set `storageClass: local-path` in Helm values

## Private Docker Registry

### Registry Access

- **URL**: `registry.jterrazz.com`
- **Auth**: htpasswd (username: `deploy`)
- **Password**: Stored in Pulumi state

```bash
# Get registry password
cd pulumi && pulumi stack output dockerRegistryPassword --show-secrets

# Docker login
docker login registry.jterrazz.com -u deploy
```

### Using from CI (GitHub Actions)

```yaml
- name: Setup Tailscale
  uses: tailscale/github-action@v2
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci

- name: Login to Registry
  uses: docker/login-action@v3
  with:
    registry: registry.jterrazz.com
    username: deploy
    password: ${{ secrets.REGISTRY_PASSWORD }}
```

## Certificates & DNS

### How it works

1. **ClusterIssuer** allows certificates for any `*.jterrazz.com` subdomain
2. **Cert-Manager** requests certificates from Let's Encrypt via DNS-01 challenge
3. **External-DNS** automatically creates/updates DNS records in Cloudflare
4. Each app defines its own Certificate in its resources directory

### Adding a new internal service

1. Create the app manifest in `kubernetes/platform/my-app.yaml`
2. Create `kubernetes/platform/my-app-resources/ingress.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-app.jterrazz.com
    external-dns.alpha.kubernetes.io/target: "100.109.91.57" # Tailscale IP
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`my-app.jterrazz.com`)
      kind: Rule
      middlewares:
        - name: private-access
          namespace: platform-ingress
      services:
        - name: my-app
          port: 8080
  tls:
    secretName: my-app-tls
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app-tls
spec:
  secretName: my-app-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - my-app.jterrazz.com
```

## Production Setup

### Prerequisites

```bash
# macOS
brew install multipass ansible pulumi node
```

### Required Secrets (GitHub Actions)

| Secret                          | Description              |
| ------------------------------- | ------------------------ |
| `PULUMI_ACCESS_TOKEN`           | Pulumi API token         |
| `HCLOUD_TOKEN`                  | Hetzner Cloud API token  |
| `TAILSCALE_OAUTH_CLIENT_ID`     | For server provisioning  |
| `TAILSCALE_OAUTH_CLIENT_SECRET` | For server provisioning  |
| `CLOUDFLARE_API_TOKEN`          | For DNS and certificates |
| `ARGOCD_GITHUB_PAT`             | For private repo access  |
| `INFISICAL_CLIENT_ID`           | For secrets management   |
| `INFISICAL_CLIENT_SECRET`       | For secrets management   |

### Deploy

```bash
# Manual deploy
make deploy

# Or push to main branch for automatic deployment
git push origin main
```

## Security Model

### Network Security

| Port | Service | Access Level                |
| ---- | ------- | --------------------------- |
| 22   | SSH     | Public (key-only, fail2ban) |
| 80   | HTTP    | Public (redirects to HTTPS) |
| 443  | HTTPS   | Public (your apps)          |
| 6443 | K8s API | Tailscale + private only    |

### Service Security

- **Private services**: IP whitelist via `private-access` middleware (Tailscale IPs only)
- **TLS**: All services use Let's Encrypt certificates (wildcard for \*.jterrazz.com)
- **DNS**: Managed by external-dns with `upsert-only` policy (won't delete unmanaged records)
- **Secrets**: Stored in Pulumi state (encrypted), injected via Ansible

## Observability with SigNoz

### Sending Traces (OpenTelemetry)

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://signoz-otel-collector.platform-observability:4318"
```

## Troubleshooting

### Check ArgoCD sync status

```bash
kubectl get applications -n platform-gitops
```

### Certificate issues

```bash
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
```

### View pod logs

```bash
kubectl logs -n <namespace> <pod-name>
```

## Local Development

```bash
make start          # Create Multipass VM + full deploy
make status         # Cluster status
make ssh            # SSH into VM
make destroy        # Destroy VM
```
