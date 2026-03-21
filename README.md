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
│  │  │   Traefik   │  │  Portainer  │  │    Grafana      │  │   │
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
| **Grafana**      | Observability dashboards              |
| **Prometheus**   | Metrics collection                    |
| **Loki**         | Log aggregation                       |
| **Tempo**        | Distributed tracing                   |
| **OTel Collector** | Telemetry pipeline                  |
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

The `kubernetes/charts/app/` Helm chart provides a standardized deployment for all applications. Published to `oci://registry.jterrazz.com/charts/app`. Apps only need a `.infrastructure/application.yaml`.

**What the chart generates:** Deployment with health probes + resource limits + OTEL, Service, Traefik IngressRoute with TLS, PV/PVC (if storage defined), InfisicalSecret, registry pull secrets.

### App Manifest (`.infrastructure/application.yaml`)

Each app defines its deployment in a single `application.yaml`. The Helm chart reads `spec` for base config and `environments` for per-environment overrides (environment values take precedence).

#### Full Example

```yaml
apiVersion: jterrazz.com/v1
kind: Application

metadata:
  name: my-app

spec:
  port: 3000

  resources:
    cpu: 100m
    memory: 512Mi
    memoryLimit: 1024Mi       # Optional, defaults to 2x memory

  storage:                    # Optional — enables PV/PVC, switches to Recreate strategy
    size: 1Gi
    mountPath: /data

  secrets:
    path: /my-app             # Infisical folder path
    env:                      # Secret keys injected as env vars
      - DATABASE_PASSWORD
      - API_KEY

  env:                        # Plain environment variables
    DATABASE_URL: file:/data/db.sqlite

  configFiles:                # Optional — mounted as files at /app/{filename}
    config.json: |
      {"key": "value"}

  networkPolicy:
    allowedServices:          # Egress allowed to these services' namespaces
      - otel-collector        # Special: routes to platform-telemetry:4317/4318
      - other-service         # Routes to {prod,staging}-other-service

  health:
    path: /health             # Liveness probe path (default: /health)
    initialDelaySeconds: 10   # Default: 10
    periodSeconds: 30         # Default: 30

  ingress:                    # Base ingress (can be overridden per env)
    path: /api                # Optional path prefix (stripped before forwarding)

environments:
  staging:
    tag: main                 # Deployed on main branch push (image: latest)
    replicas: 1
    ingress:
      host: my-app-staging.jterrazz.com
      public: true
    env:
      LOG_LEVEL: debug

  next:
    tag: next                 # Deployed on v* tag push (image: that tag)
    replicas: 1
    secretsEnv: prod          # Use prod secrets from Infisical (no 'next' env in Infisical)
    ingress:
      host: my-app-next.jterrazz.com
      public: true

  prod:
    tag: v1.2.0               # Pinned — only deployed on workflow_dispatch
    replicas: 2
    ingress:
      host: my-app.jterrazz.com
      public: true
    env:
      LOG_LEVEL: warn
```

#### Spec Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `spec.port` | int | `3000` | Container port (also injected as `PORT` env var) |
| `spec.image` | string | `registry.jterrazz.com/{name}:latest` | Full image reference (typically set by CI via `--set`) |
| `spec.runAsRoot` | bool | `false` | Skip security context (default: runs as UID 1000) |
| `spec.resources.cpu` | string | `100m` | CPU request |
| `spec.resources.memory` | string | `256Mi` | Memory request |
| `spec.resources.memoryLimit` | string | 2x memory | Memory limit |
| `spec.storage.size` | string | — | PV size (enables persistent storage) |
| `spec.storage.mountPath` | string | — | Container mount path |
| `spec.secrets.path` | string | — | Infisical folder path |
| `spec.secrets.env` | string[] | — | Secret keys to inject as env vars |
| `spec.env` | map | — | Plain environment variables |
| `spec.configFiles` | map | — | Files mounted at `/app/{filename}` |
| `spec.networkPolicy.allowedServices` | string[] | `[]` | Services allowed for egress |
| `spec.health.path` | string | `/health` | Liveness/readiness probe path |
| `spec.health.initialDelaySeconds` | int | `10` | Liveness probe initial delay |
| `spec.health.periodSeconds` | int | `30` | Liveness probe interval |
| `spec.ingress.host` | string | — | Hostname for routing |
| `spec.ingress.path` | string | `/` | Path prefix (stripped by middleware) |
| `spec.ingress.public` | bool | `false` | Public (Cloudflare proxy) vs private (Tailscale) |
| `spec.dashboards` | map | — | Grafana dashboard JSON files (prod only) |

#### Environment Overrides

Each entry under `environments` can override any `spec` field plus these environment-specific fields:

| Field | Type | Description |
|-------|------|-------------|
| `tag` | string | Deployment trigger — see [Tag-Based Deployments](#tag-based-deployments) |
| `replicas` | int | Pod replica count (default: 1) |
| `secretsEnv` | string | Override Infisical environment (e.g. `next` env can use `prod` secrets) |
| `ingress` | object | Override ingress config (host, path, public) |
| `env` | map | Additional/override environment variables |
| `resources` | object | Override cpu, memory, memoryLimit |

#### Tag-Based Deployments

The `tag` field on each environment controls when it gets deployed:

| Tag Value | Trigger | Image Used | Use Case |
|-----------|---------|------------|----------|
| `main` | `git push main` | `latest` | Staging / dev |
| `next` | `git push v*` tag | The pushed tag | Pre-production, safe migration |
| `v1.2.0` (pinned) | `workflow_dispatch` only | Exact version | Production, frozen |

This enables running multiple API versions in parallel for safe client migration:

```yaml
environments:
  staging:
    tag: main           # Auto-deploys on every main push
  next:
    tag: next           # Auto-deploys on every v* tag
  prod:
    tag: v1.2.0         # Frozen — only changes via manual dispatch
```

**Promotion flow:** Change `prod.tag` to `v2.0.0` in `application.yaml`, push to main, then trigger `workflow_dispatch` in GitHub Actions.

**Backward compatible:** Apps without `tag` fields use the original behavior (main → staging, v* tags → prod).

#### Auto-Injected Environment Variables

These are set automatically on every deployment:

| Variable | Value |
|----------|-------|
| `PORT` | From `spec.port` |
| `OTEL_SERVICE_NAME` | App name |
| `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment={env}` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.platform-telemetry:4318` |

All can be overridden via `spec.env` or environment-level `env`.

### CI-Driven Deployment

Apps deploy via their own GitHub Actions CI using reusable workflows from `jterrazz/jterrazz-workflows`.

```
Push code → Fetch secrets from Infisical → Connect Tailscale → Build + push image → Deploy matching environments
```

App CI workflow (`.github/workflows/build-and-deploy.yaml`):

```yaml
jobs:
  build-and-deploy:
    uses: jterrazz/jterrazz-workflows/.github/workflows/build-and-deploy.yaml@main
    with:
      image-name: my-app
      timeout: '10m'
      node-version: '24'
    secrets:
      INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
      INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}
```

The workflow reads `application.yaml`, resolves which environments to deploy based on the trigger and `tag` fields, builds the Docker image, and runs `helm upgrade --install` with `--atomic` for each target environment.

### Conventions

| Property         | Convention                                            |
| ---------------- | ----------------------------------------------------- |
| **Namespace**    | `{environment}-{name}` (e.g. `staging-my-app`)        |
| **Image**        | `registry.jterrazz.com/{name}:{tag}`                  |
| **Storage path** | `/var/lib/k8s-data/{name}-{environment}/` on host     |
| **Secrets**      | Infisical env matches deployment env (override with `secretsEnv`) |
| **Domains**      | `{name}-staging.jterrazz.com` / `{name}.jterrazz.com` |

### Adding a New Application

1. Create `.infrastructure/application.yaml` in your app repo (see format above)
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
| Grafana   | `https://grafana.jterrazz.com`   | Tailscale |
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
└── portainer/     # Dashboard data
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

The app chart auto-injects `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, and `OTEL_EXPORTER_OTLP_ENDPOINT` into every deployment. Apps using the OpenTelemetry SDK will pick these up automatically.

## Troubleshooting

```bash
helm list -A                                          # Helm releases
kubectl get certificates -A                           # Certificate status
kubectl describe certificate <name> -n <namespace>    # Certificate details
kubectl logs -n <namespace> <pod-name>                # Pod logs
kubectl logs -n platform-automation deploy/openclaw -f # OpenClaw logs
```
