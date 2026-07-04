# @jterrazz/infra

Single-node k3s cluster, **dual-mode**: deployable on Hetzner Cloud
(`stack=production`) or on a local OrbStack VM (`stack=local`). Same
Ansible playbooks, same Helm charts, same service topology on either
target — only the underlying compute differs. The currently-active
stack is whichever one you bring up with `make deploy` / `make
deploy-local`; you flip between them by `pulumi destroy`ing the
inactive one (or just letting it sit empty).

## Architecture

```
┌───────────────────────────── INTERNET ─────────────────────────────┐
│                                                                    │
│                          Cloudflare edge                           │
│                                                                    │
└────────────────────────────────────┬───────────────────────────────┘
                                     │ outbound QUIC tunnel
                                     ▼
┌───────────────────────── cluster host ─────────────────────────────┐
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
│   │                       k3s cluster                          │   │
│   │                                                            │   │
│   │   Traefik (LoadBalancer pinned to Tailscale) → IngressRoutes
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
| **k3s**           | Single-node Kubernetes (SQLite/kine datastore)         |
| **Traefik**       | Ingress controller (LoadBalancer pinned to Tailscale)  |
| **cloudflared**   | Cloudflare tunnel — public traffic via outbound QUIC   |
| **Tailscale**     | Private VPN for SSH and internal services              |
| **cert-manager**  | Let's Encrypt certs via DNS-01 (Cloudflare)            |
| **Pulumi**        | Provisions the machine + manages Cloudflare DNS        |
| **Infisical**     | Secrets sync into the cluster                          |
| **Grafana stack** | Prometheus + Loki + Tempo + OTel Collector             |
| **Portainer**     | Cluster dashboard                                      |
| **n8n**           | Workflow automation                                    |
| **LibreChat**     | Private AI chat UI (`chat.jterrazz.com`)               |
| **OpenPanel**     | Self-hosted product analytics                          |
| **Registry**      | Private Docker registry (Tailscale-only)               |

## Dual-mode — choose your production

Two Pulumi stacks share the codebase. They're interchangeable: pick
the one that fits your context, deploy it, and the cluster comes up
the same way.

| Stack                 | Target                        | Use                                                  |
| --------------------- | ----------------------------- | ---------------------------------------------------- |
| `jterrazz/production` | Hetzner cax21 VPS in nbg1     | Live production with a real public IP & 24/7 uptime  |
| `jterrazz/local`      | OrbStack VM on the dev Mac    | Local prod, dev, or "I don't want to pay for Hetzner this month" |

The `target` config on each stack picks which target file under
`pulumi/src/targets/` to invoke:

```bash
# pulumi/Pulumi.production.yaml  → jterrazz-infra:target: hetzner
# pulumi/Pulumi.local.yaml       → jterrazz-infra:target: orbstack
```

**Which one owns DNS?** Only one stack at a time should own the
Cloudflare CNAMEs for the private services (n8n, portainer, grafana,
registry, gateway, chat, openpanel). Whichever stack has
`jterrazz-infra:manageDns: "true"` creates them. To swap:

```bash
cd pulumi
pulumi config set manageDns false --stack production
pulumi config set manageDns true  --stack local
pulumi up --stack production    # removes the records
pulumi up --stack local         # re-creates them pointing at OrbStack
# Then scale Hetzner cloudflared to 0 (and OrbStack's to 1) to flip
# public traffic too.
```

**Bringing a stack back from scratch**: if the Pulumi stack itself
was `stack rm`ed (not just `destroy`ed), recreate it before `up`:

```bash
cd pulumi
pulumi stack init jterrazz/production
pulumi config set target hetzner
pulumi config set --secret hcloud:token <token>            # rotate-friendly
pulumi config set --secret cloudflare:apiToken <token>
pulumi up
```

## Quick start

```bash
make deploy        # pulumi up + ansible site.yml on Hetzner
make deploy-local  # same, on OrbStack
make apps          # trigger every app's CI to (re)deploy
make destroy-local # tear down the OrbStack VM (data on the Mac stays)
```

`scripts/deploy.sh` is the canonical entry point. It pulls every Ansible
secret from Infisical `/jterrazz-infra` env=prod using the
universal-auth credentials in `.env`, passes them as extra-vars, and
runs the playbook against the chosen target.

## Project layout

```
ansible/
├── playbooks/     site.yml → base, security, networking, storage, kubernetes, platform
├── roles/         k3s, security, tailscale, storage
├── inventories/   production/ (Hetzner)   local/ (OrbStack)
└── templates/     Jinja templates rendered at deploy time

kubernetes/
├── charts/
│   ├── app/       Standard app chart, published to oci://registry.jterrazz.com/charts/app
│   └── platform/  Shared chart used by n8n / portainer / grafana for ingress + cert + PVC
├── infrastructure/  Base manifests applied directly (namespaces, Traefik config, …)
└── platform/      Per-service chart values

pulumi/
├── src/
│   ├── index.ts         Dual-mode dispatcher (`target=hetzner|orbstack`)
│   ├── targets/         hetzner.ts, orbstack.ts, types.ts
│   └── dns.ts           Cloudflare DNS records for private services
└── Pulumi.{local,production}.yaml

scripts/
├── deploy.sh                Provision + configure either stack
└── trigger-app-deploys.sh   Re-trigger every app's CI (used after a fresh cluster rebuild)
```

## How traffic flows

### Public (internet → app)

```
client ──https──► Cloudflare edge ──QUIC tunnel──► cloudflared pod
                                    ──http──► Traefik → app pod
```

* No public ports on the host (besides 22) — `cloudflared` is
  outbound-only.
* Cloudflare DNS records for public hostnames are CNAMEs to
  `<tunnel-id>.cfargotunnel.com`. The Public Hostname feature in the
  Cloudflare Zero Trust dashboard creates them automatically when you
  attach a new hostname to the tunnel.

### Private (laptop → internal service)

```
client (on Tailscale) ──► cluster Tailscale IP:443 ──► Traefik LoadBalancer
                       ──► IngressRoute (private-access middleware) ──► service
```

* Traefik's Service is `LoadBalancer` but `loadBalancerSourceRanges`
  pins it to the Tailscale CGNAT range (`100.64.0.0/10`); UFW double-
  enforces. From the public internet `:443` simply times out.
* Cloudflare DNS records for private hostnames are CNAMEs to the
  active cluster's Tailscale FQDN, **managed by Pulumi**
  (`pulumi/src/dns.ts`).
* CoreDNS inside the cluster overrides those same hostnames to the
  cluster's own tailnet IP so in-cluster image pulls and helm pushes
  stay on the local Traefik (the public CNAME chain stops at `*.ts.net`
  which CoreDNS can't chase). Set in `ansible/playbooks/platform.yml`.

## DNS at a glance

| Kind                                                  | Who manages | How                                                                |
| ----------------------------------------------------- | ----------- | ------------------------------------------------------------------ |
| Public (`spwn.sh`, `sig.news`, …)                     | cloudflared | Add Public Hostname in the CF Zero Trust UI → auto-creates a CNAME |
| Private (`n8n.jterrazz.com`, `gateway.jterrazz.com`, …) | Pulumi      | Edit `pulumi/src/dns.ts`, `pulumi up`                              |
| TLS certificates                                      | cert-manager + Let's Encrypt DNS-01 | Auto, via Cloudflare API token                     |

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
    tag: main                 # deploys on main push (image = latest)
    ingress: { host: my-app-staging.jterrazz.com, public: true }
  prod:
    tag: v1.0.0               # pinned — only deploys on workflow_dispatch
    ingress: { host: my-app.jterrazz.com, public: true }
```

The shared reusable workflow at
`jterrazz/jterrazz-actions/.github/workflows/release-docker.yaml`
takes care of validate → build → push → `helm upgrade --install`
against the OCI app chart. Apps need `INFISICAL_CLIENT_ID` /
`INFISICAL_CLIENT_SECRET` as GitHub repo secrets.

`./scripts/trigger-app-deploys.sh` triggers every app's workflow at
once. Use after rebuilding the cluster from scratch — apps get a fresh
build + helm install on the new registry.

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
├── registry/                  Docker registry blobs
├── gateway-intelligence-prod/ Gateway app data
├── signews-api-{env}/         Per-env SQLite database
├── librechat/                 LibreChat MongoDB
├── librechat-uploads/         LibreChat uploads + generated images
└── openpanel-{postgres,clickhouse,redis}/  OpenPanel datastores
```

Backup: `tar -czvf backup-$(date +%Y%m%d).tar.gz /var/lib/k8s-data/`
(or, on OrbStack, the Mac-side `~/.jterrazz-infra/data/`).

## Required secrets

### GitHub Actions

| Secret                    | Infra repo | App repos |
| ------------------------- | ---------- | --------- |
| `PULUMI_ACCESS_TOKEN`     | ✓          |           |
| `INFISICAL_CLIENT_ID`     | ✓          | ✓         |
| `INFISICAL_CLIENT_SECRET` | ✓          | ✓         |

The Hetzner API token lives in the Pulumi stack config as
`hcloud:token` (encrypted via Pulumi Cloud), not in GitHub secrets.
Rotate with `pulumi config set --secret hcloud:token <new>` in
`pulumi/` against the `jterrazz/production` stack.

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

# SSH to the active cluster
ssh root@jterrazz-infra@orb                          # OrbStack
ssh -i /tmp/ssh_key root@$(cd pulumi && pulumi stack output sshHost --stack production)  # Hetzner
```
