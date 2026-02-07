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
│  │  │   Traefik   │  │  Portainer  │  │     SigNoz      │  │   │
│  │  │  (Ingress)  │  │ (Dashboard) │  │ (Observability) │  │   │
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
| **Portainer**    | Cluster dashboard                     |
| **SigNoz**       | Observability (traces, metrics, logs) |
| **Cert-Manager** | Automatic Let's Encrypt certificates  |
| **External-DNS** | Automatic Cloudflare DNS management   |
| **Infisical**    | Automated secrets management          |
| **Tailscale**    | Private VPN for secure access         |
| **n8n**          | Workflow automation                   |
| **Clawdbot**     | Personal AI assistant (Claude Max)    |

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
├── kubernetes/                 # Cluster manifests (applied via Ansible/Helm)
│   ├── applications/           # App deployments
│   │   └── chart/              # Standard Helm chart (published to OCI registry)
│   │
│   ├── infrastructure/         # Base capabilities (rarely changes)
│   │   └── base/
│   │       ├── storage/        # StorageClass definitions
│   │       ├── traefik/        # Middlewares (private-access, rate-limit)
│   │       └── network-policies/
│   │
│   ├── platform/               # Platform services (one folder per app)
│   │   ├── portainer/          # Cluster dashboard
│   │   ├── signoz/
│   │   ├── n8n/
│   │   ├── clawdbot/
│   │   ├── cert-manager/
│   │   ├── external-dns/
│   │   └── infisical/
│
├── pulumi/                     # Infrastructure as Code (Hetzner VPS)
└── scripts/                    # Automation scripts
```

## Deploying Applications

### Standard App Chart

The `kubernetes/applications/chart/` Helm chart provides a standardized way to deploy applications. It is published to the private OCI registry at `oci://registry.jterrazz.com/charts/app`. Apps only need a `.deploy/manifest.yaml` - the chart handles all Kubernetes complexity.

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
  name: my-app

spec:
  port: 3000
  resources:
    cpu: 100m
    memory: 256Mi
  health:
    path: /health

environments:
  staging:
    replicas: 1
    ingress:
      host: my-app-staging.jterrazz.com
    env:
      NODE_ENV: development

  prod:
    replicas: 2
    ingress:
      host: my-app.jterrazz.com
    env:
      NODE_ENV: production
```

### CI-Driven Deployment

Apps deploy themselves via their own GitHub Actions CI. No GitOps controller needed.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Push Code     │ ──► │   GitHub CI     │ ──► │   Build & Push  │ ──► │  helm upgrade   │
│   (main/v*)     │     │   Workflow      │     │   Docker Image  │     │  --install      │
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────┘
                                                                                │
                                                                                ▼
                                                                        ┌─────────────────┐
                                                                        │   App is Live   │
                                                                        │   (~1 minute)   │
                                                                        └─────────────────┘
```

Each app's CI workflow should:

1. Build and push Docker image to `registry.jterrazz.com`
2. Run `helm upgrade --install` using the shared OCI chart
3. Use `--atomic` for production (auto-rollback on failure)

```yaml
# Example app CI deploy step
- name: Deploy
  run: |
    helm upgrade --install $ENV-$APP \
      oci://registry.jterrazz.com/charts/app \
      -f .deploy/manifest.yaml \
      --set environment=$ENV \
      --set spec.image=registry.jterrazz.com/$APP@$DIGEST \
      -n $ENV-$APP --create-namespace \
      --wait --timeout 3m --atomic
```

### Conventions

| Property         | Convention                                            |
| ---------------- | ----------------------------------------------------- |
| **Namespace**    | `{environment}-{name}` (e.g. `staging-my-app`)        |
| **Image**        | `registry.jterrazz.com/{name}:latest`                 |
| **Storage path** | `/var/lib/k8s-data/{name}-{environment}/` on host     |
| **Secrets**      | Infisical `dev` env for staging, `prod` for prod      |
| **Domains**      | `{name}-staging.jterrazz.com` / `{name}.jterrazz.com` |

### Platform Services

Platform services (SigNoz, n8n, Portainer, etc.) are installed via Helm in the Ansible playbook. Each is **self-contained** in its own folder:

```
kubernetes/platform/my-service/
├── values.yaml     # Helm chart values
├── ingress.yaml    # IngressRoute + Certificate
└── storage.yaml    # PV/PVC (if needed)
```

### Bootstrap After Cluster Rebuild

On a fresh cluster, apps don't exist yet. Run the bootstrap script to trigger all app CIs:

```bash
./scripts/bootstrap-apps.sh
```

Or pass `bootstrap_apps=true` to Ansible to trigger automatically.

## Services & Access

### Private Services (via Tailscale)

| Service   | URL                              | Purpose             |
| --------- | -------------------------------- | ------------------- |
| Portainer | `https://portainer.jterrazz.com` | Cluster dashboard   |
| SigNoz    | `https://signoz.jterrazz.com`    | Observability       |
| n8n       | `https://n8n.jterrazz.com`       | Workflow automation |
| Clawdbot  | `https://clawdbot.jterrazz.com`  | AI assistant        |

All private services:

- Use valid Let's Encrypt TLS certificates
- DNS points to Tailscale IP
- Only accessible when connected to Tailscale VPN

## Storage

All persistent data lives in `/var/lib/k8s-data/` on the VPS. This single folder contains everything that matters.

### What's stored

```
/var/lib/k8s-data/
├── clawdbot/      # AI assistant config, memories, Signal data
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

All apps using `kubernetes/applications/chart/` run as UID 1000. New storage folders should be owned by `1000:1000`:

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
  resources:
    cpu: 100m
    memory: 256Mi
  health:
    path: /health

environments:
  staging:
    replicas: 1
    ingress:
      host: my-app-staging.jterrazz.com
    env:
      NODE_ENV: development

  # Uncomment when ready for production
  # prod:
  #   replicas: 2
  #   ingress:
  #     host: my-app.jterrazz.com
  #   env:
  #     NODE_ENV: production
```

2. Add the CI deploy workflow to your app repo (see "CI-Driven Deployment" above)

3. Add registry + kubeconfig secrets to your GitHub repo

4. Push your code — CI builds, pushes, and deploys automatically

5. Add your repo to `scripts/bootstrap-apps.sh` so it's included in cluster rebuilds

### Adding a new platform service

For third-party Helm charts (not your own apps), create a folder in `kubernetes/platform/`:

1. Create folder `kubernetes/platform/my-service/`

2. Create `values.yaml` with the Helm chart values

3. Create `ingress.yaml` for Traefik IngressRoute + Certificate

4. (Optional) Create `storage.yaml` if you need persistent data

5. Add the `helm upgrade --install` command to `ansible/playbooks/platform.yml`

## Production Setup

### Prerequisites

```bash
# macOS
brew install multipass ansible pulumi node
```

### Required Secrets (GitHub Actions)

| Secret                          | Description                                  |
| ------------------------------- | -------------------------------------------- |
| `PULUMI_ACCESS_TOKEN`           | Pulumi API token                             |
| `HCLOUD_TOKEN`                  | Hetzner Cloud API token                      |
| `TAILSCALE_OAUTH_CLIENT_ID`     | For server provisioning                      |
| `TAILSCALE_OAUTH_CLIENT_SECRET` | For server provisioning                      |
| `CLOUDFLARE_API_TOKEN`          | For DNS and certificates                     |
| `DEPLOY_PAT`                    | GitHub PAT for triggering app CI deployments |
| `DEPLOY_PAT_CLAWRR`             | GitHub PAT for clawrr org app CI deployments |
| `INFISICAL_CLIENT_ID`           | For secrets management                       |
| `INFISICAL_CLIENT_SECRET`       | For secrets management                       |

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

### Check Helm releases

```bash
helm list -A
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

## Migration TODOs

### Rename GitHub secrets

**DONE** — Secrets renamed in code from `ARGOCD_GITHUB_PAT` to `DEPLOY_PAT`:

- `DEPLOY_PAT` — used to trigger app CI deployments during bootstrap
- `DEPLOY_PAT_CLAWRR` — same for clawrr org repos

You need to create these secrets in GitHub repo settings (jterrazz/jterrazz-infra) with the same values as the old `ARGOCD_GITHUB_PAT` / `ARGOCD_GITHUB_PAT_CLAWRR` secrets, then delete the old ones.

### Clean up ArgoCD from live cluster

**DONE** — ArgoCD has been removed from the production cluster:

- Helm release uninstalled, CRDs deleted, `platform-gitops` namespace removed
- All platform services re-installed as Helm releases
- Portainer deployed and running at `portainer.jterrazz.com`
- App chart published to `oci://registry.jterrazz.com/charts/app`

### Redeploy user apps

User app deployments were removed during the ArgoCD cleanup. Redeploy them by triggering their CI workflows (once the CI deploy workflows are added to each app repo), or manually:

```bash
scripts/bootstrap-apps.sh
```
