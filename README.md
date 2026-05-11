# @jterrazz/infra

Single-node k3s cluster running on an OrbStack VM on the dev Mac.
Provisioned by Pulumi, configured by Ansible, fronted by Cloudflare
Tunnel (public) and Tailscale (private).

## Architecture

```
┌───────────────────────────── INTERNET ─────────────────────────────┐
│                                                                    │
│                          Cloudflare edge                           │
│                                                                    │
└────────────────────────────────────┬───────────────────────────────┘
                                     │ outbound QUIC tunnel
                                     ▼
┌──────────────────────── OrbStack VM (Mac) ─────────────────────────┐
│   (Ubuntu 24.04 ARM64, non-isolated → /mnt/mac auto-mount)         │
│                                                                    │
│   ┌──────────────────────────────┐   ┌──────────────────────────┐  │
│   │       Tailscale tailnet      │   │   cloudflared tunnel     │  │
│   │  (private services + SSH)    │   │    (public traffic)      │  │
│   └─────────────────┬────────────┘   └─────────────┬────────────┘  │
│                     │                              │               │
│                     └──────────────┬───────────────┘               │
│                                    ▼                               │
│   ┌────────────────────────────────────────────────────────────┐   │
│   │                       k3s cluster                          │   │
│   │                                                            │   │
│   │   Traefik (LoadBalancer locked to Tailscale) → IngressRoutes
│   │      │                                                     │   │
│   │      ├─► Public apps (spwn.sh, sig.news, clawrr.com, …)   │   │
│   │      └─► Private services (n8n, Portainer, Grafana, …)    │   │
│   │                                                            │   │
│   │   cert-manager   Infisical operator   Prometheus + Loki    │   │
│   │   Docker registry          Tempo + Grafana + OTel          │   │
│   └────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────┘
```

Historically this also ran on a Hetzner cax21 VPS (Pulumi stack
`jterrazz/production`). That stack was retired and destroyed in May
2026 — every CNAME, image, and workflow now points at the OrbStack VM.
The git log around commit `b29f250` has the migration trail.

## Stack

| Component         | Purpose                                                |
| ----------------- | ------------------------------------------------------ |
| **k3s**           | Single-node Kubernetes with embedded etcd              |
| **Traefik**       | Ingress controller (LoadBalancer pinned to Tailscale)  |
| **cloudflared**   | Cloudflare tunnel — public traffic via outbound QUIC   |
| **Tailscale**     | Private VPN for SSH and internal services              |
| **cert-manager**  | Let's Encrypt certs via DNS-01 (Cloudflare)            |
| **Pulumi**        | Provisions the OrbStack VM + manages Cloudflare DNS    |
| **Infisical**     | Secrets sync into the cluster                          |
| **Grafana stack** | Prometheus + Loki + Tempo + OTel Collector             |
| **Portainer**     | Cluster dashboard                                      |
| **n8n**           | Workflow automation                                    |
| **Registry**      | Private Docker registry (Tailscale-only)               |

## Quick start

```bash
make deploy        # pulumi up + ansible site.yml
make apps          # trigger every app's CI to (re)deploy
make destroy       # tear down the OrbStack VM
```

`scripts/deploy.sh` is the canonical entry point. It pulls every Ansible
secret from Infisical `/jterrazz-infra` env=prod using the
universal-auth credentials in `.env`, passes them as extra-vars, and
runs the playbook against the OrbStack VM.

## Project layout

```
ansible/
├── playbooks/     site.yml → base, security, networking, storage, kubernetes, platform
├── roles/         k3s, security, tailscale, storage
├── inventories/   local/ (only inventory — the OrbStack VM)
└── templates/     Jinja templates rendered at deploy time

kubernetes/
├── charts/
│   ├── app/       Standard app chart, published to oci://registry.jterrazz.com/charts/app
│   └── platform/  Shared chart used by n8n / portainer / grafana for ingress + cert + PVC
├── infrastructure/  Base manifests applied directly (namespaces, Traefik config, …)
└── platform/      Per-service chart values

pulumi/
├── src/
│   ├── index.ts   Entry point — provisions the VM + DNS records
│   ├── machine.ts OrbStack VM dynamic resource (wraps orbctl)
│   └── dns.ts     Cloudflare DNS records for private services
└── Pulumi.local.yaml

scripts/
├── deploy.sh                Provision + configure
└── trigger-app-deploys.sh   Re-trigger every app's CI (used after a fresh cluster rebuild)
```

## How traffic flows

### Public (internet → app)

```
client ──https──► Cloudflare edge ──QUIC tunnel──► cloudflared pod
                                    ──http──► Traefik → app pod
```

* No public ports on the OrbStack VM — `cloudflared` is outbound-only.
* Cloudflare DNS records for public hostnames are CNAMEs to
  `<tunnel-id>.cfargotunnel.com`. The Public Hostname feature in the
  Cloudflare Zero Trust dashboard creates them automatically when you
  attach a new hostname to the tunnel.

### Private (laptop → internal service)

```
client (on Tailscale) ──► VM Tailscale IP:443 ──► Traefik LoadBalancer
                       ──► IngressRoute (private-access middleware) ──► service
```

* Traefik's Service is `LoadBalancer` but `loadBalancerSourceRanges`
  pins it to the Tailscale CGNAT range (`100.64.0.0/10`); UFW double-
  enforces. From the public internet `:443` simply times out.
* Cloudflare DNS records for private hostnames are CNAMEs to the
  cluster's Tailscale FQDN, **managed by Pulumi** (`pulumi/src/dns.ts`).
* CoreDNS inside the cluster overrides those same hostnames to the
  cluster's own tailnet IP so in-cluster image pulls and helm pushes
  stay on the local Traefik (the public CNAME chain stops at `*.ts.net`
  which CoreDNS can't chase). Set in `ansible/playbooks/platform.yml`.

## DNS at a glance

| Kind                                              | Who manages | How                                                                |
| ------------------------------------------------- | ----------- | ------------------------------------------------------------------ |
| Public (`spwn.sh`, `sig.news`, …)                 | cloudflared | Add Public Hostname in the CF Zero Trust UI → auto-creates a CNAME |
| Private (`n8n.jterrazz.com`, `gateway.jterrazz.com`, …) | Pulumi      | Edit `pulumi/src/dns.ts`, `pulumi up`                              |
| TLS certificates                                  | cert-manager + Let's Encrypt DNS-01 | Auto, via Cloudflare API token                     |

## Deploying an application

Apps own their deployment via a single `application.yaml`. The full
shape and conventions are in
[`kubernetes/charts/app/README.md`](kubernetes/charts/app/README.md);
the short version:

```yaml
apiVersion: jterrazz.com/v1
kind: Application
metadata:
  name: my-app
spec:
  port: 3000
  resources: { cpu: 100m, memory: 256Mi }
  health: { path: /health }
environments:
  staging:
    tag: main                 # deployed on main push (image = latest)
    ingress: { host: my-app-staging.jterrazz.com, public: true }
  prod:
    tag: v1.0.0               # pinned — only deploys on workflow_dispatch
    ingress: { host: my-app.jterrazz.com, public: true }
```

The shared reusable workflow at
`jterrazz/jterrazz-actions/.github/workflows/build-and-deploy.yaml`
takes care of validate → build → push → `helm upgrade --install`
against the OCI app chart. Apps need `INFISICAL_CLIENT_ID` /
`INFISICAL_CLIENT_SECRET` as GitHub repo secrets.

`./scripts/trigger-app-deploys.sh` triggers every app's workflow at
once. Use after rebuilding the cluster from scratch — apps get a fresh
build + helm install on the new registry.

## Storage

All persistent data lives at `/var/lib/k8s-data/` on the cluster host.
That path is a symlink to `~/.jterrazz-infra/data/` on the Mac (via
OrbStack's auto file-share at `/mnt/mac/`), so the data survives the
OrbStack VM being destroyed and recreated.

```
/var/lib/k8s-data/
├── n8n/                       Workflows + credentials
├── portainer/                 Dashboard config
├── grafana/                   Dashboards + datasources
├── prometheus/                Time-series
├── loki/                      Logs
├── tempo/                     Traces
├── registry/                  Docker registry blobs
├── gateway-intelligence-prod/ Gateway app data
└── signews-api-{env}/         Per-env SQLite database
```

Backup: `tar -czvf backup-$(date +%Y%m%d).tar.gz ~/.jterrazz-infra/data/`.

## Required secrets

### GitHub Actions

| Secret                    | Infra repo | App repos |
| ------------------------- | ---------- | --------- |
| `PULUMI_ACCESS_TOKEN`     | ✓          |           |
| `INFISICAL_CLIENT_ID`     | ✓          | ✓         |
| `INFISICAL_CLIENT_SECRET` | ✓          | ✓         |

### Infisical — project `jterrazz`, env `prod`

* **`/jterrazz-infra`** (Ansible playbooks): `TAILSCALE_OAUTH_CLIENT_ID`,
  `TAILSCALE_OAUTH_CLIENT_SECRET`, `CLOUDFLARE_API_TOKEN`,
  `CLOUDFLARE_TUNNEL_TOKEN`, `GITHUB_TOKEN_JTERRAZZ`,
  `GITHUB_TOKEN_CLAWRR`, `DOCKER_REGISTRY_PASSWORD`,
  `PORTAINER_ADMIN_PASSWORD`, `GRAFANA_PASSWORD`, `N8N_ENCRYPTION_KEY`
* **`/jterrazz-ci`** (app CI workflows in `jterrazz-actions`):
  `DOCKER_REGISTRY_USERNAME`, `DOCKER_REGISTRY_PASSWORD`,
  `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`,
  `KUBECONFIG_BASE64`

### Local `.env` (gitignored, in repo root)

```
PULUMI_ACCESS_TOKEN=…
INFISICAL_CLIENT_ID=…
INFISICAL_CLIENT_SECRET=…
```

## Security at the host

| Port | Source                    | Used by          |
| ---- | ------------------------- | ---------------- |
| 22   | Anywhere                  | SSH              |
| 80   | Tailscale (100.64/10)     | Traefik HTTP     |
| 443  | Tailscale (100.64/10)     | Traefik HTTPS    |
| 6443 | Tailscale + private CIDRs | Kubernetes API   |
|  —   | Outbound only             | cloudflared QUIC |

UFW enforces these rules; klipper-lb's `loadBalancerSourceRanges` on
the Traefik service is the real gate (UFW alone is bypassable by
klipper-lb's pre-routing DNAT, so it doubles as defense-in-depth, not
the primary).

## Troubleshooting

```bash
# Live state
helm list -A                                          # Helm releases
kubectl get pod -A                                    # Pods on the cluster
kubectl get certificate -A                            # Cert-manager state

# Specific deployment
kubectl get pod -n <namespace>
kubectl describe pod -n <namespace> <pod>
kubectl logs -n <namespace> <pod>

# Cloudflare tunnel
kubectl logs -n platform-networking deploy/cloudflared --tail=20
curl -s http://<pod-ip>:2000/metrics | grep cloudflared_tunnel_total_requests

# cert-manager after a k3s restart (loses webhook leader)
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# SSH to the OrbStack VM
ssh root@jterrazz-infra@orb
```
