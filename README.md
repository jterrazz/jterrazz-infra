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
├── kubernetes/                 # GitOps manifests (ArgoCD syncs these)
│   ├── charts/                 # Helm charts
│   │   └── app/                # Standard app chart (used by all apps)
│   │
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
│   │   ├── clawdbot/
│   │   ├── cert-manager/
│   │   ├── external-dns/
│   │   └── infisical/
│   │
│   └── applications/           # Your app definitions
│
├── pulumi/                     # Infrastructure as Code (Hetzner VPS)
└── scripts/                    # Automation scripts
```

## Deploying Applications

### Standard App Chart

The `kubernetes/charts/app/` Helm chart provides a standardized way to deploy applications. Apps only need to define a simple manifest file - the chart handles all Kubernetes complexity (Deployment, Service, Ingress, Storage, Secrets).

**What the chart auto-generates:**

- Deployment with health probes, resource limits, and OTEL integration
- Service pointing to the app's port
- Traefik IngressRoute with TLS certificate
- PersistentVolume/PVC (if storage is defined)
- InfisicalSecret for secrets management
- Image registry pull secrets

### App Manifest (`.deploy/manifest.yaml`)

Each application defines a single manifest file in its own repository with **multi-environment support**:

```yaml
# In your app repository: .deploy/manifest.yaml
apiVersion: jterrazz.com/v1
kind: Application

metadata:
  name: my-app # Used for namespace, image name, DNS

spec:
  # Base configuration (shared across all environments)
  port: 3000
  resources:
    cpu: 100m
    memory: 256Mi
    memoryLimit: 512Mi # Optional, defaults to 2x memory

  storage: # Optional
    size: 1Gi
    mountPath: /data

  secrets: # Optional - Infisical integration
    path: /my-app # Path in Infisical
    env:
      - DATABASE_PASSWORD
      - API_KEY

  env: # Base environment variables
    LOG_LEVEL: info

  health:
    path: /health

# Environment-specific configuration (overrides base spec)
environments:
  staging:
    branch: main # Informational - which branch deploys to staging
    replicas: 1
    ingress:
      host: my-app-staging.jterrazz.com
      path: /
      private: false
    env:
      NODE_ENV: development # App-specific env value

  prod:
    tag: v1.0.0 # Informational - which tag deploys to prod
    replicas: 2
    ingress:
      host: my-app.jterrazz.com
      path: /
      private: false
    env:
      NODE_ENV: production
```

**How it works:**

- `spec` contains base configuration shared by all environments
- `environments.staging` and `environments.prod` contain overrides
- Values are merged: environment-specific values override base `spec` values
- If an environment section doesn't exist, that environment won't be deployed
- Storage paths are environment-specific: `/var/lib/k8s-data/{name}-{environment}/`

**Enabling/disabling environments:**

- To deploy only staging: only define `environments.staging`
- To deploy only prod: only define `environments.prod`
- To deploy both: define both sections
- Comment out an environment section to disable it

### Single ApplicationSet (in this repo)

All apps are deployed via a single ApplicationSet in `kubernetes/applications/apps.yaml`. To add a new app, just add its repo name to the list:

```yaml
# kubernetes/applications/apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: apps
  namespace: platform-gitops
spec:
  generators:
    - matrix:
        generators:
          # Add your app repo here
          - list:
              elements:
                - repo: signews-api
                - repo: my-app # <-- Add new apps here
          # Environments to deploy
          - list:
              elements:
                - environment: staging
                - environment: prod
  template:
    metadata:
      name: "{{repo}}-{{environment}}"
    spec:
      sources:
        - repoURL: https://github.com/jterrazz/jterrazz-infra.git
          path: charts/app
          helm:
            valueFiles:
              - $app/.deploy/manifest.yaml
            values: |
              environment: {{environment}}
        - repoURL: "https://github.com/jterrazz/{{repo}}.git"
          targetRevision: main
          ref: app
      destination:
        namespace: "app-{{repo}}-{{environment}}"
```

The chart automatically skips environments that aren't defined in the app's manifest.

### Conventions

| Property         | Convention                                             |
| ---------------- | ------------------------------------------------------ |
| **Namespace**    | `app-{name}-{environment}` (e.g. `app-my-app-staging`) |
| **Image**        | `registry.jterrazz.com/{name}:latest`                  |
| **Storage path** | `/var/lib/k8s-data/{name}-{environment}/` on host      |
| **Secrets**      | Infisical `dev` env for staging, `prod` for prod       |
| **Domains**      | `{name}-staging.jterrazz.com` / `{name}.jterrazz.com`  |

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

## Automatic Deployment Pipeline

The infrastructure uses **ArgoCD Image Updater** to automatically deploy new container images without manual intervention.

### How It Works

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Push Code     │ ──► │   GitHub CI     │ ──► │ Container Image │ ──► │ Image Updater   │
│   (main/v*)     │     │   Builds Image  │     │   Registry      │     │   Detects New   │
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────┘
                                                                                │
                                                                                ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Pod Restarts  │ ◄── │   ArgoCD Syncs  │ ◄── │ Helm Parameters │ ◄── │   Updates App   │
│   With New Image│     │   Application   │     │   Updated       │     │   Spec          │
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Environment Strategies

| Environment | Image Tag | Strategy | Trigger                             |
| ----------- | --------- | -------- | ----------------------------------- |
| **Staging** | `:latest` | `digest` | Push to `main` branch               |
| **Prod**    | `v*`      | `semver` | Create version tag (e.g., `v1.0.0`) |

### Staging Deployment (Automatic)

Every push to `main` triggers automatic deployment:

1. CI builds and pushes image with `:latest` tag
2. Image Updater detects new digest (same tag, different content)
3. ArgoCD Application is updated with new image digest
4. Pod restarts with the new image

```bash
# Just push to main - staging deploys automatically
git push origin main
```

### Production Deployment (Version Tags)

Production deployments use semantic versioning:

1. Create a version tag (e.g., `v1.2.0`)
2. CI builds and pushes image with that version tag
3. Image Updater detects new semver tag matching `v*` pattern
4. ArgoCD Application is updated with new version
5. Pod restarts with the new image

```bash
# Create and push a version tag for production release
git tag v1.2.0
git push origin v1.2.0
```

### Configuration

The ApplicationSet in `kubernetes/applications/apps.yaml` configures both environments:

```yaml
generators:
  - matrix:
      generators:
        - list:
            elements:
              - repo: signews-api
        - list:
            elements:
              - environment: staging
                imageTag: latest
                updateStrategy: digest # Tracks :latest by digest
              - environment: prod
                imageTag: "v*"
                updateStrategy: semver # Tracks semver tags
```

Image Updater annotations on each Application:

- `argocd-image-updater.argoproj.io/image-list`: Defines which image to watch
- `argocd-image-updater.argoproj.io/app.update-strategy`: `digest` or `semver`
- `argocd-image-updater.argoproj.io/app.helm.image-spec`: Helm value to update

### CI Workflow Requirements

Your app's CI workflow (`.github/workflows/deploy.yaml`) should:

1. Trigger on `main` branch AND `v*` tags
2. Tag images with `:latest` for main branch, `:{version}` for tags
3. Clean up old images but keep `latest` and `v*` tags

```yaml
on:
  push:
    branches: [main]
    tags: ['v*']

# Determine image tag based on trigger
- name: Determine image tag
  id: tag
  run: |
    if [[ "${{ github.ref }}" == refs/tags/v* ]]; then
      echo "tag=${{ github.ref_name }}" >> $GITHUB_OUTPUT
    else
      echo "tag=latest" >> $GITHUB_OUTPUT
    fi
```

### Monitoring Deployments

```bash
# Check Image Updater logs
kubectl logs -n platform-gitops -l app.kubernetes.io/name=argocd-image-updater

# See which images are being tracked
kubectl get applications -n platform-gitops -o yaml | grep -A5 "image-updater"

# Check ArgoCD sync status
kubectl get applications -n platform-gitops
```

## Services & Access

### Private Services (via Tailscale)

| Service  | URL                             | Purpose             |
| -------- | ------------------------------- | ------------------- |
| ArgoCD   | `https://argocd.jterrazz.com`   | GitOps dashboard    |
| SigNoz   | `https://signoz.jterrazz.com`   | Observability       |
| n8n      | `https://n8n.jterrazz.com`      | Workflow automation |
| Clawdbot | `https://clawdbot.jterrazz.com` | AI assistant        |

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

All apps using `kubernetes/charts/app/` run as UID 1000. New storage folders should be owned by `1000:1000`:

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

2. In this infra repo, add your app to `kubernetes/applications/apps.yaml`:

```yaml
generators:
  - matrix:
      generators:
        - list:
            elements:
              - repo: signews-api
              - repo: my-app # <-- Add your repo here
```

3. Push both repos. ArgoCD will deploy staging automatically.

4. When ready for production:
   - Uncomment the `prod:` section in your app's manifest
   - Create the storage directory on VPS: `mkdir -p /var/lib/k8s-data/my-app-prod && chown 1000:1000 /var/lib/k8s-data/my-app-prod`
   - Push the changes

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
