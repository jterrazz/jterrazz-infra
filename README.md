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
│   │       └── network-policies/
│   │
│   ├── platform/               # Platform services (one folder per app)
│   │   ├── argocd/
│   │   │   ├── app.yaml        # ArgoCD Application
│   │   │   └── ingress.yaml    # IngressRoute + Certificate
│   │   ├── signoz/
│   │   │   ├── app.yaml
│   │   │   ├── ingress.yaml
│   │   │   └── storage.yaml    # Static PV/PVC
│   │   ├── n8n/
│   │   │   ├── app.yaml
│   │   │   ├── ingress.yaml
│   │   │   └── storage.yaml
│   │   ├── cert-manager/
│   │   │   ├── app.yaml
│   │   │   └── issuers.yaml    # ClusterIssuers
│   │   ├── external-dns/
│   │   │   └── app.yaml
│   │   ├── infisical/
│   │   │   └── app.yaml
│   │   └── signoz-k8s-infra/
│   │       └── app.yaml
│   │
│   └── applications/           # Your app definitions
│
├── pulumi/                     # Infrastructure as Code (Hetzner VPS)
└── scripts/                    # Automation scripts
```

## App-Centric Folder Pattern

Each platform service is **fully self-contained** in its own folder:

```
kubernetes/platform/my-app/
├── app.yaml        # ArgoCD Application (helm chart + references this folder)
├── ingress.yaml    # IngressRoute + Certificate
└── storage.yaml    # PV/PVC (if needed)
```

The ArgoCD Application uses multi-source to deploy both the Helm chart and local resources:

```yaml
# kubernetes/platform/my-app/app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  sources:
    # Source 1: Helm chart
    - repoURL: https://charts.example.com
      chart: my-app
      helm:
        values: |
          ingress:
            enabled: false  # We use Traefik IngressRoute

    # Source 2: Resources from this folder (ingress, storage, etc.)
    - repoURL: https://github.com/jterrazz/jterrazz-infra.git
      path: kubernetes/platform/my-app
      directory:
        exclude: "app.yaml" # Don't apply the Application itself
```

**Adding a new app = one folder** with clear file responsibilities.

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

### Dynamic Storage (local-path)

For ephemeral data, use the K3s built-in `local-path` provisioner:

- **Data location**: `/var/lib/rancher/k3s/storage/`
- **Behavior**: PVCs get UUID-named folders, deleted when PVC is deleted
- **Usage**: Set `storageClass: local-path` in Helm values

### Static Storage (manual)

For persistent data that survives app deletion (databases, user data):

```yaml
# storage.yaml - Static PV with Retain policy
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-app-data
spec:
  capacity:
    storage: 1Gi
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /var/lib/k8s-data/my-app
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - jterrazz-vps
```

Current static volumes:

- `/var/lib/k8s-data/n8n` - n8n workflows and credentials
- `/var/lib/k8s-data/signoz/clickhouse` - SigNoz traces, metrics, logs
- `/var/lib/k8s-data/signoz/db` - SigNoz user accounts, dashboards

## Certificates & DNS

### How it works

1. **ClusterIssuer** (in `platform/cert-manager/issuers.yaml`) allows certificates for any `*.jterrazz.com` subdomain
2. **Cert-Manager** requests certificates from Let's Encrypt via DNS-01 challenge
3. **External-DNS** automatically creates/updates DNS records in Cloudflare
4. Each app defines its own Certificate in its `ingress.yaml`

### Adding a new internal service

1. Create folder `kubernetes/platform/my-app/`

2. Create `app.yaml`:

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
    - repoURL: https://charts.example.com
      chart: my-app
      targetRevision: 1.0.0
      helm:
        values: |
          ingress:
            enabled: false
    - repoURL: https://github.com/jterrazz/jterrazz-infra.git
      targetRevision: HEAD
      path: kubernetes/platform/my-app
      directory:
        exclude: "app.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

3. Create `ingress.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-app.jterrazz.com
    external-dns.alpha.kubernetes.io/target: "jterrazz-vps.tail77a797.ts.net"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`my-app.jterrazz.com`)
      kind: Rule
      middlewares:
        - name: private-access
          namespace: platform-networking
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
