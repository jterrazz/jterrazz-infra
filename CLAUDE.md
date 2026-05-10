# Infra Project

## Project Overview

Single-node K3s cluster with two interchangeable deployment targets:

- **Hetzner** (Pulumi stack `production`) — cax21 VPS in nbg1, live prod
- **OrbStack** (Pulumi stack `local`) — Ubuntu VM on the dev Mac, hot standby

Both run the exact same Ansible playbooks (`site.yml`) and Helm charts.
The Pulumi target abstraction (`pulumi/src/targets/*`) outputs a uniform
`MachineOutputs` so downstream tooling stays target-agnostic.

## Stack

- Traefik, cert-manager (Let's Encrypt DNS-01 via Cloudflare), Infisical operator
- Grafana + Loki + Tempo + Prometheus + OTel Collector
- n8n, Portainer, private Docker registry
- **cloudflared** for public traffic (outbound QUIC tunnel)
- **Tailscale** for SSH and private service access
- **No GitOps controller** — CI-driven deploys via `helm upgrade --install`
- App chart published to `oci://registry.jterrazz.com/charts/app`

## DNS

- **Public hostnames** (apex domains routed to apps) — cloudflared's
  Public Hostname feature in the Zero Trust UI auto-creates the CNAME
  to `<tunnel-id>.cfargotunnel.com`.
- **Private hostnames** (n8n, portainer, grafana, registry, gateway) —
  Pulumi-managed in `pulumi/src/dns.ts`, CNAME to the active cluster's
  Tailscale FQDN. Only the stack with `manageDns=true` owns the records
  (production by default).
- TLS — cert-manager via Let's Encrypt DNS-01 using the
  `CLOUDFLARE_API_TOKEN` secret.

## Deployed Apps

- **spwn-web** (`jterrazz/spwn-web`): Next.js at `spwn.sh`
- **signews-web** (`jterrazz/signews-web`): Next.js at `sig.news`
- **signews-api** (`jterrazz/signews-api`): 3 envs (prod/next/staging) at `signews{,-next,-staging}.jterrazz.com/api`
- **clawssify-web-landing** (`jterrazz/clawssify-web-landing`): at `clawssify.com`
- **clawrr-web-landing** (`clawrr/web-landing`): at `clawrr.com`
- **gateway-intelligence** (`jterrazz/gateway-intelligence`): private at `gateway.jterrazz.com`

## Managed Domains

- `jterrazz.com`, `spwn.sh`, `clawrr.com`, `clawssify.com`, `sig.news` — all in cert-manager's `dnsZones`.
- New public domain: add to cert-manager `issuers.yaml` (both
  ClusterIssuers) + add a Public Hostname in the cloudflared tunnel UI
  (auto-creates CNAME).
- New private hostname: add the host to `PRIVATE_HOSTS` in
  `pulumi/src/dns.ts`, then `pulumi up --stack production`.
- Cloudflare SSL mode must be **Full (Strict)** on every zone.

## Key Patterns

- Platform services installed via Helm in `ansible/playbooks/platform.yml`.
- Shared platform chart (`kubernetes/charts/platform/`) generates
  Certificate + IngressRoute + PV/PVC from a thin `platform.yaml`.
- App chart at `kubernetes/charts/app/`, published to OCI registry.
- Per-service config split: `helm.yaml` (upstream chart values) +
  `platform.yaml` (ingress / cert / storage).
- PVCs use `storageClassName: manual` with hostPath PVs, bound via
  `volumeName` (not selector).
- Traefik **IngressRoutes** (not plain Ingress) for routing.
- cert-manager Certificates with `letsencrypt-production` ClusterIssuer.
- Telemetry PVs (Grafana / Prometheus / Loki / Tempo) have
  `nodeAffinity` matching `inventory_hostname` — the
  `templates/kubernetes/telemetry-storage.yaml.j2` template injects the
  right hostname per target.
- On OrbStack, `/var/lib/k8s-data` is a symlink to
  `/mnt/mac/Users/<user>/.jterrazz-infra/data` so the data survives
  `pulumi destroy && pulumi up`.

## Centralized CI/CD Workflows (`jterrazz/jterrazz-actions`)

All app repos use shared reusable workflows and composite actions from
`jterrazz/jterrazz-actions`.

### Environment Strategy (Tag-Based Deployments)

Environments in `application.yaml` declare a `tag` field controlling
when the env deploys:

- **`tag: main`** → deployed on `main` push, image `latest`
- **`tag: next`** → deployed on `v*` tag push, image is that tag
- **`tag: v1.2.0`** (pinned) → deployed only on `workflow_dispatch`
- **No `tag` field** (legacy) → main → staging, v* → prod

Promotion: change `prod.tag` in `application.yaml`, push to main,
trigger `workflow_dispatch`.

Use `secretsEnv: prod` on non-standard environments (like `next`) to
map to an existing Infisical env.

### Reusable Workflows

- **`validate.yaml`** — Runs `make build`, `make lint`, `make test`.
- **`build-and-deploy.yaml`** — Full pipeline: validate → Docker build+push → Helm deploy → cleanup old images.

### Composite Actions

- **`actions/setup-infra`** — Fetches Infisical secrets, connects Tailscale, logs into the OCI registry.
- **`actions/docker-build-push`** — Builds and pushes the Docker image.
- **`actions/helm-deploy`** — Deploys via `helm upgrade --install` using the app chart.
- **`actions/cleanup-images`** — Removes old `v*` tags, registry GC, containerd prune.

### Makefile convention

All app repos must define a `Makefile` with `build`, `lint`, `test`
targets. This is the universal CI interface regardless of toolchain.

## App Deployment Pattern (for new apps)

1. **In app repo**: `Dockerfile` (multi-stage),
   `.infrastructure/application.yaml`, `Makefile`,
   `.github/workflows/build-and-deploy.yaml` + `validate.yaml`.
2. **In infra repo**: add the domain to cert-manager `issuers.yaml` if it's a new zone; add the repo to `scripts/trigger-app-deploys.sh` if you want it in the rebuild bootstrap.
3. **GitHub secrets**: set `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET` on the app repo.
4. **Cloudflare** (new public domain): add Public Hostname in the tunnel UI; SSL mode Full (Strict).
5. CI flow: validate (`make build/lint/test`) → Docker build+push to `registry.jterrazz.com` → `helm upgrade --install` via Tailscale → cleanup old images.

## Connection Details

- Pulumi stacks: `jterrazz/production` (Hetzner), `jterrazz/local` (OrbStack). `PULUMI_ACCESS_TOKEN` required.
- **Pulumi commands must run from `pulumi/` subdirectory** (not repo root).
- Production server IP: `pulumi stack output sshHost --stack production`
- SSH key: `pulumi stack output sshPrivateKey --show-secrets --stack production`
- OrbStack VM is reachable via the OrbStack SSH proxy as `root@jterrazz-infra@orb`.

`.env` (gitignored, in repo root):

```
PULUMI_ACCESS_TOKEN
HCLOUD_TOKEN
INFISICAL_CLIENT_ID
INFISICAL_CLIENT_SECRET
CLOUDFLARE_TUNNEL_TOKEN   # only required if you'll modify the tunnel locally; otherwise sourced from Infisical at deploy time
```

## Common Operations

### SSH to the Hetzner server

```bash
source .env && export PULUMI_ACCESS_TOKEN
SSH_KEY=$(cd pulumi && pulumi stack output sshPrivateKey --show-secrets --stack production)
echo "$SSH_KEY" > /tmp/ssh_key && chmod 600 /tmp/ssh_key
ssh -i /tmp/ssh_key root@$(cd pulumi && pulumi stack output sshHost --stack production)
```

### Restart cert-manager (after K3s disruption)

```bash
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector
```

### Check an app deployment

```bash
kubectl get pods -n prod-<app>
kubectl get certificate -n prod-<app>
kubectl get ingressroute -n prod-<app>
```

### Swap Hetzner ↔ OrbStack (future)

```bash
cd pulumi
pulumi config set manageDns false --stack production
pulumi config set manageDns true  --stack local
pulumi up --stack local       # Pulumi repoints private CNAMEs at jterrazz-infra
# Scale cloudflared on Hetzner to 0 and on OrbStack to 1 to flip public traffic.
```

## Gotchas

- **Infisical secret names**: CI workflows expect `TAILSCALE_OAUTH_CLIENT_SECRET` (not `TAILSCALE_OAUTH_SECRET`). Match exactly.
- **Next.js standalone Docker**: needs `output: 'standalone'` in `next.config.mjs`. If `public/` is gitignored, `mkdir -p public` before `next build`.
- **cert-manager after K3s restart**: cert-manager + webhook + cainjector lose API connection. Restart all three.
- **OrbStack VM after Mac reboot**: K3s auto-restarts via systemd, Tailscale auto-reconnects, but cert-manager may need a rollout restart before any new Certificate operations.
- **Helm adoption**: annotate existing resources with `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`, and label `app.kubernetes.io/managed-by=Helm`.
- **Immutable k8s fields**: Deployment selectors, PV `hostPath.type`, PVC `spec.selector` — delete and recreate if they need to change.
- **CRD kubectl names**: use fully-qualified names: `certificate.cert-manager.io`, `ingressroute.traefik.io`.
- **Renaming an app**: when `metadata.name` changes in `application.yaml`, CI creates a new Helm release under the new name but the old release keeps running. `helm uninstall prod-<old-name> -n prod-<old-name> && kubectl delete namespace prod-<old-name>` to clean up.
- **registry.jterrazz.com layer GC**: the `docker-cleanup` action in jterrazz-actions previously stripped multi-arch layers because its HEAD used only the Docker manifest Accept header. Fixed in commit 6061ab2 — multi-arch tags now resolve to the index digest.
