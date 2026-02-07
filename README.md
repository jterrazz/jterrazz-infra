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
make deploy    # Or push to main for automatic deployment
```

## Project Structure

```
├── ansible/                    # Server configuration
│   ├── playbooks/              # Orchestration playbooks
│   └── roles/                  # Reusable roles (k3s, security, tailscale)
│
├── kubernetes/                 # Cluster manifests
│   ├── charts/
│   │   ├── app/                # App Helm chart (published to OCI registry)
│   │   └── platform/           # Shared chart for platform ingress + certs + storage
│   ├── infrastructure/         # Base: namespaces, storage, traefik, network policies
│   └── platform/               # Platform services (one folder per service)
│
├── pulumi/                     # Infrastructure as Code (Hetzner VPS)
└── scripts/
    ├── deploy.sh               # Production deploy (Pulumi + Ansible)
    ├── trigger-app-deploys.sh  # Bootstrap all app CIs after cluster rebuild
    ├── ci/                     # CI scripts (deployment summary)
    └── lib/                    # Shared utilities (colors, logging)
```

## Deploying Applications

### Standard App Chart

The `kubernetes/charts/app/` Helm chart provides a standardized deployment for all applications. Published to `oci://registry.jterrazz.com/charts/app`. Apps only need a `.deploy/manifest.yaml`.

**What the chart generates:** Deployment with health probes + resource limits + OTEL, Service, Traefik IngressRoute with TLS, PV/PVC (if storage defined), InfisicalSecret, registry pull secrets.

### App Manifest (`.deploy/manifest.yaml`)

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

  prod:
    replicas: 2
    ingress:
      host: my-app.jterrazz.com
    env:
      NODE_ENV: production
```

### CI-Driven Deployment

Apps deploy via their own GitHub Actions CI — no GitOps controller needed.

```
Push code → Fetch secrets from Infisical → Connect Tailscale → Build + push image → helm upgrade --install
```

Each app's CI:

1. Fetches secrets from Infisical (`/infrastructure-apps` folder)
2. Connects to Tailscale VPN
3. Builds and pushes Docker image to `registry.jterrazz.com`
4. Runs `helm upgrade --install` with `--atomic` (auto-rollback on failure)

```yaml
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

### Adding a New Application

1. Create `.deploy/manifest.yaml` in your app repo (see format above)
2. Add CI deploy workflow
3. Add `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET` as GitHub repo secrets
4. Push — CI builds, pushes, and deploys automatically
5. Add repo to `scripts/trigger-app-deploys.sh` for cluster rebuilds

### Adding a New Platform Service

1. Create `kubernetes/platform/my-service/` with:
   - `helm.yaml` — upstream Helm chart values
   - `platform.yaml` — ingress + storage config (uses shared `kubernetes/charts/platform/` chart)
2. Add `helm upgrade --install` commands to `ansible/playbooks/platform.yml`

Platform service `platform.yaml` example:

```yaml
name: my-service
host: my-service.jterrazz.com
port: 8080
private: true
storage:
  size: 1Gi
```

### Bootstrap After Cluster Rebuild

```bash
./scripts/trigger-app-deploys.sh
```

Or pass `bootstrap_apps=true` to the Ansible playbook.

## Services & Access

| Service   | URL                              | Access    |
| --------- | -------------------------------- | --------- |
| Portainer | `https://portainer.jterrazz.com` | Tailscale |
| SigNoz    | `https://signoz.jterrazz.com`    | Tailscale |
| n8n       | `https://n8n.jterrazz.com`       | Tailscale |
| OpenClaw  | `https://openclaw.jterrazz.com`  | Tailscale |

All private services use Let's Encrypt TLS. DNS points to Tailscale IP — only accessible on Tailscale VPN.

## OpenClaw Setup

OpenClaw is a personal AI assistant using Claude Max with Signal integration.

### Secrets

Managed via Infisical, deployed as K8s secrets by Ansible:

- `GATEWAY_TOKEN` — Web UI authentication
- `CLAUDE_TOKEN` — Claude Max OAuth token (used as `ANTHROPIC_API_KEY`)

### Getting a Claude OAuth Token

```bash
claude login
cat ~/.claude/.credentials.json   # Look for "oauthToken": "sk-ant-oat01-..."
```

### Initial Setup (first deploy only)

1. **Access the Web UI**: `https://openclaw.jterrazz.com/?token=<gateway-token>`
2. **Approve device pairing**:
   ```bash
   kubectl exec -n platform-automation deploy/openclaw -- node /app/dist/entry.js devices list
   kubectl exec -n platform-automation deploy/openclaw -- node /app/dist/entry.js devices approve <request-id>
   ```
3. **(Optional) Link Signal** — requires a separate phone number:
   ```bash
   kubectl exec -it -n platform-automation deploy/openclaw -- node /app/dist/entry.js channels login --channel signal
   ```

### Updating Claude Token

```bash
# 1. Get new token
claude login && cat ~/.claude/.credentials.json

# 2. Update in Infisical, then re-deploy (push to main or make deploy)

# 3. Restart pod to pick up new secret
kubectl rollout restart deployment/openclaw -n platform-automation
```

### Data Persistence

Stored on PV at `/var/lib/k8s-data/openclaw/`:

- `config/` — Gateway config, auth profiles, device pairings
- `workspace/` — Agent workspace and memories
- `signal-cli/` — Signal credentials and message history

## Storage

All persistent data lives in `/var/lib/k8s-data/` on the VPS. Data survives pod restarts, redeployments, K3s restarts, cluster rebuilds, and VPS reboots.

```
/var/lib/k8s-data/
├── openclaw/      # AI assistant data
├── n8n/           # Workflows and credentials
├── signews-api/   # App database
└── signoz/        # Traces, metrics, logs
```

PVs use `hostPath`. All apps run as UID 1000 — new storage: `chown -R 1000:1000`.

**Backup**: `tar -czvf backup-$(date +%Y%m%d).tar.gz /var/lib/k8s-data/`

## Certificates & DNS

1. **ClusterIssuer** allows certificates for `*.jterrazz.com` and `*.clawrr.com`
2. **Cert-Manager** issues via Let's Encrypt DNS-01 challenge (Cloudflare)
3. **External-DNS** creates/updates Cloudflare DNS records automatically

## Setup

### Prerequisites

```bash
brew install ansible pulumi node
```

### Required Secrets

#### GitHub Actions

| Secret                    | Infra repo | App repos |
| ------------------------- | ---------- | --------- |
| `PULUMI_ACCESS_TOKEN`     | Yes        |           |
| `HCLOUD_TOKEN`            | Yes        |           |
| `INFISICAL_CLIENT_ID`     | Yes        | Yes       |
| `INFISICAL_CLIENT_SECRET` | Yes        | Yes       |

#### Infisical — `/infrastructure` folder (prod env)

`TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`, `CLOUDFLARE_API_TOKEN`, `GITHUB_TOKEN_JTERRAZZ`, `GITHUB_TOKEN_CLAWRR`, `DOCKER_REGISTRY_PASSWORD`, `PORTAINER_ADMIN_PASSWORD`, `OPENCLAW_CLAUDE_TOKEN`, `OPENCLAW_GATEWAY_TOKEN`, `N8N_ENCRYPTION_KEY`

#### Infisical — `/infrastructure-apps` folder (prod env)

`TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`, `DOCKER_REGISTRY_USERNAME`, `DOCKER_REGISTRY_PASSWORD`, `KUBECONFIG_BASE64`

## Security

| Port | Service | Access                      |
| ---- | ------- | --------------------------- |
| 22   | SSH     | Public (key-only, fail2ban) |
| 80   | HTTP    | Public (redirects to HTTPS) |
| 443  | HTTPS   | Public (your apps)          |
| 6443 | K8s API | Tailscale only              |

## Observability

Send traces via OpenTelemetry:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://signoz-otel-collector.platform-observability:4318"
```

## Troubleshooting

```bash
helm list -A                                          # Helm releases
kubectl get certificates -A                           # Certificate status
kubectl describe certificate <name> -n <namespace>    # Certificate details
kubectl logs -n <namespace> <pod-name>                # Pod logs
kubectl logs -n platform-automation deploy/openclaw -f # OpenClaw logs
```
