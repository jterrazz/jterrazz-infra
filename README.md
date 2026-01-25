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
│  │  │     n8n     │  │ Cert-Manager│  │  External-DNS   │  │   │
│  │  │ (Workflows) │  │(Let's Encr.)│  │  (Cloudflare)   │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘  │   │
│  │  ┌───────────────────────────────────────────────────┐  │   │
│  │  │              Your Applications                    │  │   │
│  │  └───────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Stack

| Component        | Purpose                               |
| ---------------- | ------------------------------------- |
| **K3s**          | Lightweight Kubernetes                |
| **Traefik**      | Ingress controller with automatic TLS |
| **ArgoCD**       | GitOps continuous deployment          |
| **SigNoz**       | Observability (traces, metrics, logs) |
| **Cert-Manager** | Automatic Let's Encrypt certificates  |
| **External-DNS** | Automatic Cloudflare DNS management   |
| **Infisical**    | Automated secrets management          |
| **Tailscale**    | Private VPN for secure access         |
| **n8n**          | Workflow automation                   |

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
├── charts/                     # Helm charts
│   └── app/                    # Standard app chart (used by all apps)
│
├── kubernetes/                 # GitOps manifests (ArgoCD syncs these)
│   ├── infrastructure/         # Base capabilities (rarely changes)
│   │   └── base/
│   │       ├── storage/        # StorageClass definitions
│   │       ├── traefik/        # Middlewares (private-access, rate-limit)
│   │       └── network-policies/
│   │
│   ├── platform/               # Platform services (one folder per app)
│   │   ├── argocd/
│   │   ├── signoz/
│   │   ├── n8n/
│   │   ├── cert-manager/
│   │   ├── external-dns/
│   │   └── infisical/
│   │
│   └── applications/           # Your app definitions (use charts/app)
│
├── pulumi/                     # Infrastructure as Code (Hetzner VPS)
└── scripts/                    # Automation scripts
```

## Deploying Applications

### Standard App Chart

The `charts/app/` Helm chart provides a standardized way to deploy applications. Apps only need to define a simple manifest file - the chart handles all Kubernetes complexity (Deployment, Service, Ingress, Storage, Secrets).

**What the chart auto-generates:**

- Deployment with health probes, resource limits, and OTEL integration
- Service pointing to the app's port
- Traefik IngressRoute with TLS certificate
- PersistentVolume/PVC (if storage is defined)
- InfisicalSecret for secrets management
- Image registry pull secrets

### App Manifest (`.deploy/manifest.yaml`)

Each application defines a single manifest file in its own repository:

```yaml
# In your app repository: .deploy/manifest.yaml
apiVersion: jterrazz.com/v1
kind: Application

metadata:
  name: my-app # Used for namespace, image name, DNS

spec:
  port: 3000 # Container port
  replicas: 1

  resources:
    cpu: 100m
    memory: 256Mi
    memoryLimit: 512Mi # Optional, defaults to 2x memory

  storage: # Optional
    size: 1Gi
    mountPath: /data

  secrets: # Optional - Infisical integration
    path: /my-app # Path in Infisical
    env: # Secrets to map to environment variables
      - DATABASE_PASSWORD
      - API_KEY

  ingress: # Optional
    host: my-app.jterrazz.com
    path: / # Optional path prefix
    private: false # true = Tailscale-only access

  env: # Static environment variables
    NODE_ENV: production
    LOG_LEVEL: info

  health:
    path: /health # Health check endpoint
```

### ArgoCD Application (in this repo)

Create an ArgoCD Application in `kubernetes/applications/` that combines the chart with your app's manifest:

```yaml
# kubernetes/applications/my-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: platform-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    # Source 1: The standard app chart
    - repoURL: https://github.com/jterrazz/jterrazz-infra.git
      targetRevision: HEAD
      path: charts/app
      helm:
        valueFiles:
          - $app/.deploy/manifest.yaml # Values from the app repo

    # Source 2: Reference to the app repository
    - repoURL: https://github.com/jterrazz/my-app.git
      targetRevision: main
      ref: app # Referenced as $app above

  destination:
    server: https://kubernetes.default.svc
    namespace: app-my-app # Auto-created

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Conventions

| Property         | Convention                            |
| ---------------- | ------------------------------------- |
| **Namespace**    | `app-{name}`                          |
| **Image**        | `registry.jterrazz.com/{name}:latest` |
| **Storage path** | `/var/lib/k8s-data/{name}/` on host   |
| **Secrets env**  | `{name}-secrets` in Infisical         |

### Platform Services

For platform services (ArgoCD, SigNoz, n8n, etc.), each is **self-contained** in its own folder:

```
kubernetes/platform/my-service/
├── app.yaml        # ArgoCD Application (external helm chart + local resources)
├── ingress.yaml    # IngressRoute + Certificate
└── storage.yaml    # PV/PVC (if needed)
```

### Internal vs External Services

```yaml
# Internal (Tailscale-only) - add private-access middleware
spec:
  ingress:
    private: true

# External (Public) - no private-access middleware
spec:
  ingress:
    private: false
```

## Services & Access

### Private Services (via Tailscale)

| Service | URL                           | Purpose             |
| ------- | ----------------------------- | ------------------- |
| ArgoCD  | `https://argocd.jterrazz.com` | GitOps dashboard    |
| SigNoz  | `https://signoz.jterrazz.com` | Observability       |
| n8n     | `https://n8n.jterrazz.com`    | Workflow automation |

All private services:

- Use valid Let's Encrypt TLS certificates
- DNS points to Tailscale IP
- Only accessible when connected to Tailscale VPN

### ArgoCD Admin Password

```bash
kubectl -n platform-gitops get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## Storage

All persistent data lives in `/var/lib/k8s-data/` on the VPS. This single folder contains everything that matters.

### What's stored

```
/var/lib/k8s-data/
├── n8n/           # n8n workflows and credentials
├── signews-api/   # App database (SQLite)
└── signoz/        # Traces, metrics, logs, dashboards
```

### What survives

| Scenario             | Data preserved? |
| -------------------- | --------------- |
| Pod restart          | ✅ Yes          |
| App redeployment     | ✅ Yes          |
| K3s restart          | ✅ Yes          |
| Full cluster rebuild | ✅ Yes          |
| VPS reboot           | ✅ Yes          |

### Backup

To backup the entire VPS state, only this folder needs to be saved:

```bash
# Simple backup
tar -czvf backup-$(date +%Y%m%d).tar.gz /var/lib/k8s-data/

# Or rsync to remote
rsync -avz /var/lib/k8s-data/ backup-server:/backups/k8s-data/
```

### Future migration to block storage

When ready to move to Hetzner Volumes (or any block storage):

1. Attach volume to VPS
2. Mount it at `/var/lib/k8s-data/`
3. Copy existing data
4. Apps continue working - no config changes needed

The PVs use `hostPath` pointing to `/var/lib/k8s-data/{name}`, so as long as that path exists with the right data, everything works regardless of what's backing it.

### File ownership

All apps using `charts/app/` run as UID 1000. New storage folders should be owned by `1000:1000`:

```bash
chown -R 1000:1000 /var/lib/k8s-data/my-app
```

## Certificates & DNS

### How it works

1. **ClusterIssuer** (in `platform/cert-manager/issuers.yaml`) allows certificates for any `*.jterrazz.com` subdomain
2. **Cert-Manager** requests certificates from Let's Encrypt via DNS-01 challenge
3. **External-DNS** automatically creates/updates DNS records in Cloudflare
4. Each app defines its own Certificate in its `ingress.yaml`

### Adding a new application

1. In your app repository, create `.deploy/manifest.yaml`:

```yaml
apiVersion: jterrazz.com/v1
kind: Application

metadata:
  name: my-app

spec:
  port: 3000
  replicas: 1
  resources:
    cpu: 100m
    memory: 256Mi
  ingress:
    host: my-app.jterrazz.com
    private: false
  env:
    NODE_ENV: production
  health:
    path: /health
```

2. In this infra repo, create `kubernetes/applications/my-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: platform-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://github.com/jterrazz/jterrazz-infra.git
      targetRevision: HEAD
      path: charts/app
      helm:
        valueFiles:
          - $app/.deploy/manifest.yaml
    - repoURL: https://github.com/jterrazz/my-app.git
      targetRevision: main
      ref: app
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

3. Push both repos. ArgoCD will deploy automatically.

### Adding a new platform service

For third-party Helm charts (not your own apps), create a folder in `kubernetes/platform/`:

1. Create folder `kubernetes/platform/my-service/`

2. Create `app.yaml` with the external Helm chart:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: platform-gitops
spec:
  sources:
    - repoURL: https://charts.example.com
      chart: my-service
      targetRevision: 1.0.0
      helm:
        values: |
          ingress:
            enabled: false
    - repoURL: https://github.com/jterrazz/jterrazz-infra.git
      targetRevision: HEAD
      path: kubernetes/platform/my-service
      directory:
        exclude: "app.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: platform-my-service
```

3. Create `ingress.yaml` for Traefik IngressRoute + Certificate.

4. (Optional) Create `storage.yaml` if you need persistent data.

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
- **TLS**: All services use Let's Encrypt certificates
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
