# @jterrazz/infra

Single-node K3s cluster, deployable on Hetzner Cloud (production) or a
local OrbStack VM (development), with the same playbooks and helm
charts on either target.

## Architecture

```
┌───────────────────────────── INTERNET ─────────────────────────────┐
│                                                                    │
│                          Cloudflare edge                           │
│                                                                    │
└────────────────────────────────────┬───────────────────────────────┘
                                     │ outbound QUIC tunnel
                                     ▼
┌──────────────────────────── cluster host ──────────────────────────┐
│  (Hetzner cax21 ARM64 OR local OrbStack VM, same Ubuntu image)     │
│                                                                    │
│   ┌──────────────────────────────┐   ┌──────────────────────────┐  │
│   │       Tailscale tailnet      │   │   cloudflared tunnel     │  │
│   │  (private services + SSH)    │   │    (public traffic)      │  │
│   └─────────────────┬────────────┘   └─────────────┬────────────┘  │
│                     │                              │               │
│                     └──────────────┬───────────────┘               │
│                                    ▼                               │
│   ┌────────────────────────────────────────────────────────────┐   │
│   │                       K3s cluster                          │   │
│   │                                                            │   │
│   │   Traefik (ClusterIP+Tailscale-only LB) ─► IngressRoutes  │   │
│   │      │                                                     │   │
│   │      ├─► Public apps (spwn.sh, sig.news, clawrr.com, …)   │   │
│   │      └─► Private services (n8n, Portainer, Grafana, …)    │   │
│   │                                                            │   │
│   │   cert-manager   Infisical operator   Prometheus + Loki    │   │
│   │   Docker registry          Tempo + Grafana + OTel          │   │
│   └────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────┘
```

## Stack

| Component         | Purpose                                                |
| ----------------- | ------------------------------------------------------ |
| **K3s**           | Lightweight Kubernetes (single-node, etcd embedded)    |
| **Traefik**       | Ingress controller (LoadBalancer locked to Tailscale)  |
| **cloudflared**   | Cloudflare tunnel — public traffic via outbound QUIC   |
| **Tailscale**     | Private VPN for SSH and internal services              |
| **cert-manager**  | Let's Encrypt certs via DNS-01 (Cloudflare)            |
| **Pulumi**        | Provisions the VM + manages Cloudflare DNS records     |
| **Infisical**     | Secrets sync into the cluster                          |
| **Grafana stack** | Prometheus + Loki + Tempo + OTel Collector             |
| **Portainer**     | Cluster dashboard                                      |
| **n8n**           | Workflow automation                                    |
| **Registry**      | Private Docker registry (Tailscale-only)               |

## Deployment targets

Two Pulumi stacks share the codebase:

| Stack | Target | Use |
|---|---|---|
| `jterrazz/production` | Hetzner cax21 VPS in nbg1 | Live production |
| `jterrazz/local` | OrbStack VM on the dev Mac | Development / hot standby |

Each stack runs the same `site.yml` playbook and ends up with an
identical K3s + platform stack. Only the underlying machine differs.

## Quick start

```bash
# Production (Hetzner) — uses CI by default; for a manual deploy:
./scripts/deploy.sh production

# Local (OrbStack)
./scripts/deploy.sh local
```

Both scripts pull the required secrets from Infisical
(`/infrastructure` env=prod) using the universal-auth credentials in
`.env` and pass them to Ansible as extra vars.

Apps mirror Hetzner → OrbStack via:

```bash
./scripts/deploy-apps-local.sh
```

## Project layout

```
ansible/
├── playbooks/        site.yml → base, security, networking, storage, kubernetes, platform
├── roles/            k3s, security, tailscale, storage
├── inventories/      production/ (Hetzner)   local/ (OrbStack)
└── templates/        Jinja templates rendered at deploy time

kubernetes/
├── charts/
│   ├── app/          Standard app chart, published to oci://registry.jterrazz.com/charts/app
│   └── platform/     Shared chart used by n8n / portainer / grafana for ingress+cert+PVC
├── infrastructure/   Base manifests applied directly (namespaces, Traefik config, …)
└── platform/         Per-service chart values

pulumi/
├── src/
│   ├── index.ts      Top-level dispatcher (target=hetzner | orbstack)
│   ├── targets/      hetzner.ts, orbstack.ts, types.ts
│   └── dns.ts        Cloudflare DNS records for private services
├── Pulumi.production.yaml   target=hetzner
└── Pulumi.local.yaml        target=orbstack

scripts/
├── deploy.sh         Provision + configure either stack
├── deploy-apps-local.sh   Mirror all Hetzner app releases onto OrbStack
└── trigger-app-deploys.sh Bootstrap CI runs after a cluster rebuild
```

## How traffic flows

### Public (internet → app)

```
client ──https──► Cloudflare edge ──QUIC tunnel──► cloudflared pod
       ──http──► Traefik (ClusterIP) ──► app pod
```

* No public ports on the host — `cloudflared` is an outbound-only tunnel.
* Cloudflare DNS records for public hostnames are CNAMEs to
  `<tunnel-id>.cfargotunnel.com`. Cloudflared's Public Hostname feature
  in the Zero Trust dashboard creates these CNAMEs automatically when
  you add a new hostname.

### Private (laptop → internal service)

```
client (on Tailscale) ──► host's Tailscale IP:443 ──► Traefik LoadBalancer
                       ──► IngressRoute (private-access middleware) ──► service
```

* Traefik's Service is `LoadBalancer` but `loadBalancerSourceRanges`
  pins it to the Tailscale CGNAT range (`100.64.0.0/10`); UFW double-
  enforces. From the public internet `:443` simply times out.
* Cloudflare DNS records for private hostnames are CNAMEs to the
  cluster's Tailscale FQDN, **managed by Pulumi** (`pulumi/src/dns.ts`).

## DNS at a glance

| Kind | Who manages | How |
|---|---|---|
| Public (`spwn.sh`, `sig.news`, …) | cloudflared | Add Public Hostname in CF Zero Trust UI → auto-creates CNAME |
| Private (`n8n.jterrazz.com`, `portainer.jterrazz.com`, …) | Pulumi | Edit `pulumi/src/dns.ts`, `pulumi up` |
| TLS certificates | cert-manager + Let's Encrypt DNS-01 | Auto, via Cloudflare API token |

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
    tag: main
    ingress: { host: my-app-staging.jterrazz.com, public: true }
  prod:
    tag: v1.0.0
    ingress: { host: my-app.jterrazz.com, public: true }
```

The shared reusable workflow at
`jterrazz/jterrazz-actions/.github/workflows/build-and-deploy.yaml`
takes care of validate → build → push → `helm upgrade --install`
against the OCI app chart. Apps need `INFISICAL_CLIENT_ID` /
`INFISICAL_CLIENT_SECRET` as GitHub repo secrets.

## Storage

All persistent data lives at `/var/lib/k8s-data/` on the cluster host.

* On **Hetzner**, that's the VPS's local disk — survives reboots, not
  VM destruction.
* On **OrbStack**, it's a symlink to `~/.jterrazz-infra/data/` on the
  Mac (via OrbStack's auto file-share at `/mnt/mac/`) — survives the
  OrbStack VM being destroyed and recreated.

```
/var/lib/k8s-data/
├── n8n/                       Workflows + credentials
├── portainer/                 Dashboard config
├── grafana/                   Dashboards + datasources
├── prometheus/                Time-series
├── loki/                      Logs
├── tempo/                     Traces
├── gateway-intelligence-prod/ Gateway app data
└── signews-api-{env}/         Per-env SQLite database
```

Backup: `tar -czvf backup-$(date +%Y%m%d).tar.gz /var/lib/k8s-data/`.

## Required secrets

### GitHub Actions

| Secret                    | Infra repo | App repos |
| ------------------------- | ---------- | --------- |
| `PULUMI_ACCESS_TOKEN`     | ✓          |           |
| `HCLOUD_TOKEN`            | ✓          |           |
| `INFISICAL_CLIENT_ID`     | ✓          | ✓         |
| `INFISICAL_CLIENT_SECRET` | ✓          | ✓         |

### Infisical — project `jterrazz`, env `prod`

* **`/infrastructure`** (consumed by Ansible playbooks): `TAILSCALE_OAUTH_CLIENT_ID`,
  `TAILSCALE_OAUTH_CLIENT_SECRET`, `CLOUDFLARE_API_TOKEN`,
  `CLOUDFLARE_TUNNEL_TOKEN`, `GITHUB_TOKEN_JTERRAZZ`,
  `GITHUB_TOKEN_CLAWRR`, `DOCKER_REGISTRY_PASSWORD`,
  `PORTAINER_ADMIN_PASSWORD`, `GRAFANA_PASSWORD`, `N8N_ENCRYPTION_KEY`
* **`/infrastructure-apps`** (consumed by app CI workflows):
  `DOCKER_REGISTRY_USERNAME`, `DOCKER_REGISTRY_PASSWORD`,
  `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`,
  `KUBECONFIG_BASE64`

### Local `.env` (gitignored, in repo root)

```
PULUMI_ACCESS_TOKEN=…
HCLOUD_TOKEN=…
INFISICAL_CLIENT_ID=…
INFISICAL_CLIENT_SECRET=…
CLOUDFLARE_TUNNEL_TOKEN=…   # tunnel-token shortcut, also stored in Infisical
```

## Security at the host

| Port | Source                    | Used by         |
|------|---------------------------|-----------------|
| 22   | Anywhere                  | SSH             |
| 80   | Tailscale (100.64/10)     | Traefik HTTP    |
| 443  | Tailscale (100.64/10)     | Traefik HTTPS   |
| 6443 | Tailscale + private CIDRs | Kubernetes API  |
|  —   | Outbound only             | cloudflared QUIC|

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

# cert-manager after k3s restart (loses webhook leader)
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector
```
