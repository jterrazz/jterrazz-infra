# @jterrazz/infra

Production Kubernetes infrastructure on Hetzner Cloud.

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
| **OpenClaw**     | Personal AI assistant (Claude Max)    |

## Quick Start

```bash
# Deploy to production (or push to main for automatic deployment)
make deploy
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
│   └── platform/               # Platform services (one folder per app)
│       ├── portainer/          # Cluster dashboard
│       ├── signoz/
│       ├── n8n/
│       ├── openclaw/
│       ├── cert-manager/
│       ├── external-dns/
│       └── infisical/
│
├── pulumi/                     # Infrastructure as Code (Hetzner VPS)
└── scripts/                    # Automation scripts
    ├── prod/                   #   Production (deploy, bootstrap)
    ├── ci/                     #   CI/CD (deployment summary)
    └── lib/                    #   Shared utilities
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
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Push Code     │ ──► │  Fetch secrets   │ ──► │   Build & Push  │ ──► │  helm upgrade   │
│   (main/v*)     │     │  from Infisical  │     │   Docker Image  │     │  --install      │
└─────────────────┘     └──────────────────┘     └─────────────────┘     └─────────────────┘
                                                                                │
                                                                                ▼
                                                                        ┌─────────────────┐
                                                                        │   App is Live   │
                                                                        │   (~1 minute)   │
                                                                        └─────────────────┘
```

Each app's CI workflow:

1. Fetches infrastructure secrets from Infisical (`/infrastructure-apps` folder)
2. Connects to Tailscale VPN
3. Builds and pushes Docker image to `registry.jterrazz.com`
4. Runs `helm upgrade --install` using the shared OCI chart with `--atomic` (auto-rollback on failure)

```yaml
# Example app CI deploy step
- name: Deploy
  run: |
    helm upgrade --install $ENV-$APP \
      oci://registry.jterrazz.com/charts/app \
      -f .deploy/manifest.yaml \
      --set environment=$ENV \
      --set spec.image=registry.jterrazz.com/$APP:$TAG \
      -n $ENV-$APP --create-namespace \
      --wait --timeout 3m --atomic
```

### Conventions

| Property         | Convention                                            |
| ---------------- | ----------------------------------------------------- |
| **Namespace**    | `{environment}-{name}` (e.g. `staging-my-app`)        |
| **Image**        | `registry.jterrazz.com/{name}:{sha}` (digest-pinned)  |
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
./scripts/prod/trigger-app-deploys.sh
```

Or pass `bootstrap_apps=true` to Ansible to trigger automatically.

## Services & Access

### Private Services (via Tailscale)

| Service   | URL                              | Purpose             |
| --------- | -------------------------------- | ------------------- |
| Portainer | `https://portainer.jterrazz.com` | Cluster dashboard   |
| SigNoz    | `https://signoz.jterrazz.com`    | Observability       |
| n8n       | `https://n8n.jterrazz.com`       | Workflow automation |
| OpenClaw  | `https://openclaw.jterrazz.com`  | AI assistant        |

All private services use valid Let's Encrypt TLS certificates, DNS points to Tailscale IP, and are only accessible when connected to Tailscale VPN.

## Storage

All persistent data lives in `/var/lib/k8s-data/` on the VPS.

```
/var/lib/k8s-data/
├── openclaw/      # AI assistant config, memories, Signal data
├── n8n/           # n8n workflows and credentials
├── signews-api/   # App database (SQLite)
└── signoz/        # Traces, metrics, logs, dashboards
```

Data survives pod restarts, app redeployments, K3s restarts, full cluster rebuilds, and VPS reboots.

### Backup

```bash
tar -czvf backup-$(date +%Y%m%d).tar.gz /var/lib/k8s-data/
```

PVs use `hostPath` pointing to `/var/lib/k8s-data/{name}`. All apps using the standard chart run as UID 1000 — new storage folders should be `chown -R 1000:1000`.

## Certificates & DNS

1. **ClusterIssuer** allows certificates for any `*.jterrazz.com` subdomain
2. **Cert-Manager** requests certificates from Let's Encrypt via DNS-01 challenge
3. **External-DNS** automatically creates/updates DNS records in Cloudflare
4. Each app defines its own Certificate in its `ingress.yaml`

### Adding a new application

1. Create `.deploy/manifest.yaml` in your app repository (see format above)
2. Add the CI deploy workflow
3. Add `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET` as GitHub repo secrets
4. Push your code — CI builds, pushes, and deploys automatically
5. Add your repo to `scripts/prod/trigger-app-deploys.sh` for cluster rebuilds

### Adding a new platform service

1. Create folder `kubernetes/platform/my-service/`
2. Create `values.yaml`, `ingress.yaml`, and optionally `storage.yaml`
3. Add the `helm upgrade --install` command to `ansible/playbooks/platform.yml`

## Setup

### Prerequisites

```bash
brew install ansible pulumi node
```

### Required Secrets

#### GitHub Actions secrets

| Secret                    | Infra repo | App repos | Description                       |
| ------------------------- | ---------- | --------- | --------------------------------- |
| `PULUMI_ACCESS_TOKEN`     | Yes        |           | Pulumi API token                  |
| `HCLOUD_TOKEN`            | Yes        |           | Hetzner Cloud API token           |
| `INFISICAL_CLIENT_ID`     | Yes        | Yes       | Infisical machine identity ID     |
| `INFISICAL_CLIENT_SECRET` | Yes        | Yes       | Infisical machine identity secret |

All other secrets are fetched at runtime from Infisical.

#### Infisical — `jterrazz` project, `/infrastructure` folder (prod env)

| Secret                          | Description                                  |
| ------------------------------- | -------------------------------------------- |
| `TAILSCALE_OAUTH_CLIENT_ID`     | Tailscale OAuth client for VPN access        |
| `TAILSCALE_OAUTH_CLIENT_SECRET` | Tailscale OAuth secret for VPN access        |
| `CLOUDFLARE_API_TOKEN`          | Cloudflare API token for DNS/certificates    |
| `GITHUB_TOKEN_JTERRAZZ`         | GitHub token for triggering jterrazz app CIs |
| `GITHUB_TOKEN_CLAWRR`           | GitHub token for triggering clawrr app CIs   |
| `DOCKER_REGISTRY_PASSWORD`      | Docker registry password                     |
| `PORTAINER_ADMIN_PASSWORD`      | Portainer admin password                     |
| `OPENCLAW_CLAUDE_TOKEN`         | Claude API token for openclaw                |
| `OPENCLAW_GATEWAY_TOKEN`        | Gateway token for openclaw                   |
| `N8N_ENCRYPTION_KEY`            | n8n credentials encryption key               |

#### Infisical — `jterrazz` project, `/infrastructure-apps` folder (prod env)

| Secret                          | Description                                 |
| ------------------------------- | ------------------------------------------- |
| `TAILSCALE_OAUTH_CLIENT_ID`     | Tailscale OAuth client for CI VPN access    |
| `TAILSCALE_OAUTH_CLIENT_SECRET` | Tailscale OAuth secret for CI VPN access    |
| `DOCKER_REGISTRY_USERNAME`      | Docker registry username (`deploy`)         |
| `DOCKER_REGISTRY_PASSWORD`      | Docker registry password                    |
| `KUBECONFIG_BASE64`             | Base64-encoded kubeconfig with Tailscale IP |

### Deploy

```bash
make deploy    # Or push to main for automatic deployment
```

## Security Model

| Port | Service | Access Level                |
| ---- | ------- | --------------------------- |
| 22   | SSH     | Public (key-only, fail2ban) |
| 80   | HTTP    | Public (redirects to HTTPS) |
| 443  | HTTPS   | Public (your apps)          |
| 6443 | K8s API | Tailscale + private only    |

- **Private services**: IP whitelist via `private-access` middleware (Tailscale IPs only)
- **TLS**: All services use Let's Encrypt certificates
- **DNS**: Managed by external-dns with `upsert-only` policy
- **Secrets**: Stored in Infisical, fetched at CI runtime and injected via Ansible

## Observability

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://signoz-otel-collector.platform-observability:4318"
```

## Deployment Architecture

```
INFRA REPO (push to main):
  Pulumi → Ansible → helm install platform services + publish app chart to OCI registry

APP REPO (push to main / tag v*):
  CI → fetch secrets from Infisical → connect Tailscale → build + push image → helm upgrade --install

CLUSTER:
  Portainer (dashboard) | cert-manager | external-dns | signoz | n8n | infisical | openclaw | registry
  No GitOps controller. No image polling. CI deploys directly over Tailscale.
```

## Troubleshooting

```bash
helm list -A                                          # Check Helm releases
kubectl get certificates -A                           # Certificate status
kubectl describe certificate <name> -n <namespace>    # Certificate details
kubectl logs -n <namespace> <pod-name>                # Pod logs
```
