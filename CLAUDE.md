# Infra Project

## Project Overview

Single-node k3s cluster (**SQLite/kine datastore** — no `cluster-init`;
embedded etcd is intentionally avoided on a single node to save
~150-300Mi RSS, since the cluster is fully reproducible and app data is
hostPath on the Mac), **dual-mode** — interchangeably deployable on
either of two Pulumi stacks:

- **`jterrazz/production`** — Hetzner cax21 VPS in nbg1, live production
  with a real public IPv4
- **`jterrazz/local`** — OrbStack VM on the dev Mac, used today as the
  active prod (cheaper, faster iteration, no monthly bill)

Both run the exact same Ansible playbook (`site.yml`) and Helm charts.
`pulumi/src/targets/{hetzner.ts,orbstack.ts}` are the only files that
differ between them; everything downstream (Ansible roles, the app
chart, the platform chart) is target-agnostic.

The active production today is **OrbStack** (May 2026 swap). Hetzner is
fully supported as an alternative — if you ever want it back, `pulumi
stack init jterrazz/production` + `pulumi up` from `pulumi/`.

## Stack

- Traefik, cert-manager (Let's Encrypt DNS-01 via Cloudflare), Infisical operator
- Grafana + Loki + Tempo + Prometheus + OTel Collector
- n8n, Portainer, LibreChat, private Docker registry
- **cloudflared** for public traffic (outbound QUIC tunnel)
- **Tailscale** for SSH and private service access
- **No GitOps controller** — CI-driven deploys via `helm upgrade --install`
- App chart published to `oci://registry.jterrazz.com/charts/app`

## DNS

- **Public hostnames** (apex domains routed to apps) — cloudflared's
  Public Hostname feature in the Zero Trust UI auto-creates the CNAME
  to `<tunnel-id>.cfargotunnel.com`.
- **Private hostnames** (n8n, portainer, grafana, registry, gateway, chat,
  openpanel) — Pulumi-managed in `pulumi/src/dns.ts`, CNAMEd to the active
  cluster's Tailscale FQDN. Only the stack with `manageDns=true` owns the records
  (production by default; flipped to local for the active swap).
- **In-cluster lookups** for the same private hostnames are
  short-circuited by a CoreDNS `coredns-custom` ConfigMap (in
  `ansible/playbooks/platform.yml`) to the cluster's own tailnet IP.
  The public CNAME chain stops at `*.ts.net` which CoreDNS can't chase
  through public DNS, so without this override registry pulls + helm
  pushes NXDOMAIN.
- TLS — cert-manager via Let's Encrypt DNS-01 using the
  `CLOUDFLARE_API_TOKEN` secret.

## Deployed Apps

- **spwn-web** (`jterrazz/spwn-web`): Next.js at `spwn.sh`
- **signews-web** (`jterrazz/signews-web`): Next.js at `sig.news`
- **signews-api** (`jterrazz/signews-api`): 3 envs (prod/next/staging) at `signews{,-next,-staging}.jterrazz.com/api`
- **clawssify-web** (`jterrazz/clawssify-web`): at `clawssify.com`
- **clawrr-web-landing** (`clawrr/web-landing`): at `clawrr.com`
- **gateway-intelligence** (`jterrazz/gateway-intelligence`): private at `gateway.jterrazz.com`

Platform services (installed by `ansible/playbooks/platform.yml`, not the app
chart): n8n, Portainer, and **LibreChat** — private AI chat UI at
`chat.jterrazz.com` (`platform-ai` ns). LibreChat talks to the gateway as a
custom OpenAI endpoint via the gateway's in-cluster Service
(`http://gateway-intelligence.prod-gateway-intelligence.svc.cluster.local/v1`)
— NOT `gateway.jterrazz.com`, because that resolves to the node's own tailnet
IP and a pod can't hairpin to the node's ServiceLB. The gateway's app-chart
NetworkPolicy can't list a platform ns, so `gateway-netpol.yaml` adds an
additive ingress rule for `platform-ai` → gateway:8317. Its datastore is a
standalone `mongo:7`
(`kubernetes/platform/librechat/mongodb.yaml`) — the chart's bundled Bitnami
mongo subchart is disabled (deprecated upstream + no dynamic StorageClass
here). Secrets sync from Infisical `/librechat`. Private-only for now
(`ALLOW_REGISTRATION=false` + `private-access` middleware); going public means
dropping `private` and relying on LibreChat's own auth.

The UI defaults to a single agent — **"Opus 4.8 — Web + Artifacts"** — using the
native `anthropic` endpoint so Claude's server-side `web_search` works (the
Agent framework's web_search would be orchestrated/SearXNG instead; not used).
`ANTHROPIC_API_KEY` is mapped from the existing `GATEWAY_API_KEY` and
`ANTHROPIC_REVERSE_PROXY` points at the gateway. Persistence: users, login and
chat history live in `mongo` (PVC `librechat-data`); uploads/generated images
in PVC `librechat-uploads`. Both are `Retain` hostPath under
`/var/lib/k8s-data` → the Mac on OrbStack, so they survive pod restarts, helm
reinstalls and `pulumi destroy` repaves (on Hetzner they'd be node-disk).

**OpenPanel** — self-hosted product analytics (`platform-analytics` ns),
raw manifests under `kubernetes/platform/openpanel/` (does not fit the platform
chart: 3 apps + 3 stateful stores + split ingress). See that dir's `README.md`
for versions, data paths, upgrade and backup/restore. 6 workloads: Postgres 14
+ Redis 7.2 + ClickHouse 25.10 (hostPath `Retain` PVCs) and op-api / op-worker
/ op-dashboard (`lindesvard/openpanel-*:2.2`). op-api runs Prisma + ClickHouse
migrations on boot. **Split exposure**: private dashboard on
`openpanel.jterrazz.com` (Tailscale, `private-access`), public event ingest on
`analytics.jterrazz.com` exposing **only** `/api/track` (cloudflared tunnel →
Traefik, `stripPrefix /api`). ClickHouse runs upstream's log-to-stdout config
(issue #324) + a per-query mem cap (#382), no CH/Redis auth (firewalled by
`netpol.yaml`). Secrets from Infisical `/openpanel`. The public host needs a
per-hostname Public Hostname entry in the cloudflared Zero Trust dashboard (the
tunnel is not a true wildcard).

### LibreChat: upgrading the default model

There is **no auto-"latest Opus"** (model IDs are opaque; the gateway exposes
no `-latest` alias). To move the default agent to a newer Opus: bump `model`
**and** `label`/`description` in the `opus-full` modelSpec in
`kubernetes/platform/librechat/helm.yaml`, then push to main (CI redeploys).
It's server-side config, so it applies to **every user automatically** — no
per-user migration; existing conversations keep their original model, new chats
use the new default. (If you ever want this centralized across all gateway
clients instead, CLIProxyAPI supports a `claude-opus-latest` alias in
`gateway-intelligence/config.yaml` — deferred.)

## Managed Domains

- `jterrazz.com`, `spwn.sh`, `clawrr.com`, `clawssify.com`, `sig.news` — all in cert-manager's `dnsZones`.
- New public domain: add to cert-manager `issuers.yaml` (both
  ClusterIssuers) + add a Public Hostname in the cloudflared tunnel UI
  (auto-creates the CNAME).
- New private hostname: add the host to `PRIVATE_HOSTS` in
  `pulumi/src/dns.ts`, then `pulumi up` from `pulumi/`. Also add it to
  the `coredns-custom` block in `ansible/playbooks/platform.yml` so
  in-cluster lookups resolve.
- Cloudflare SSL mode must be **Full (Strict)** on every zone.

## Key Patterns

- Platform services installed via Helm in `ansible/playbooks/platform.yml`.
- Shared platform chart (`kubernetes/charts/platform/`) generates
  Certificate + IngressRoute + PV/PVC from a thin `platform.yaml`.
- App chart at `kubernetes/charts/app/`, published to OCI registry
  (currently 1.14.1). Injects a default
  `NODE_OPTIONS=--max-old-space-size` (~75% of the memory request)
  **only for apps requesting >= 512Mi** (e.g. signews-api), unless the
  app sets its own `NODE_OPTIONS`. 1.14.0 applied it to all apps, which
  crash-looped small Next.js services (96MB cap starved SSR boot);
  1.14.1 added the 512Mi floor.
- Per-service config split: `helm.yaml` (upstream chart values) +
  `platform.yaml` (ingress / cert / storage).
- PVCs use `storageClassName: manual` with hostPath PVs, bound via
  `volumeName` (not selector).
- Traefik **IngressRoutes** (not plain Ingress) for routing.
- cert-manager Certificates with `letsencrypt-production` ClusterIssuer.
- Telemetry PVs (Grafana / Prometheus / Loki / Tempo) have
  `nodeAffinity` matching the actual node name, injected by Ansible
  via `templates/kubernetes/telemetry-storage.yaml.j2`.
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

Promotion: change `prod.tag` in `application.yaml`, push to main,
trigger `workflow_dispatch`.

Use `secretsEnv: prod` on non-standard environments (like `next`) to
map to an existing Infisical env.

### Reusable Workflows

- **`validate.yaml`** — Runs `make build`, `make lint`, `make test`.
- **`release-docker.yaml`** — Full pipeline: validate → Docker build+push → Helm deploy → cleanup old images.

### Composite Actions

- **`actions/infra-connect`** — Fetches Infisical secrets (from
  `/jterrazz-ci`), connects Tailscale, logs into the OCI registry.
- **`actions/docker-build`** — Builds and pushes the Docker image.
  Buildkit runs with `network=host` so it can resolve `*.ts.net`
  through the runner's Tailscale interface.
- **`actions/docker-deploy`** — Deploys via `helm upgrade --install`
  using the app chart.
- **`actions/docker-cleanup`** — Removes old `v*` tags and runs registry GC.

### Makefile convention

All app repos must define a `Makefile` with `build`, `lint`, `test`
targets. This is the universal CI interface regardless of toolchain.

## App Deployment Pattern (for new apps)

1. **In app repo**: `Dockerfile` (multi-stage),
   `.infrastructure/application.yaml`, `Makefile`,
   `.github/workflows/release-docker.yaml` + `validate.yaml`.
2. **In infra repo**: add the domain to cert-manager `issuers.yaml` if
   it's a new zone; add the repo to `scripts/trigger-app-deploys.sh` if
   you want it in the rebuild bootstrap.
3. **GitHub secrets**: set `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET` on the app repo.
4. **Cloudflare** (new public domain): add Public Hostname in the tunnel UI; SSL mode Full (Strict).
5. CI flow: validate (`make build/lint/test`) → Docker build+push to `registry.jterrazz.com` → `helm upgrade --install` via Tailscale → cleanup old images.

## Connection Details

- Pulumi stacks: `jterrazz/production` (Hetzner), `jterrazz/local` (OrbStack). `PULUMI_ACCESS_TOKEN` required.
- **Pulumi commands must run from `pulumi/`** (not repo root).
- OrbStack VM reachable via the OrbStack SSH proxy: `ssh root@jterrazz-infra@orb`.
- Hetzner (when up): `ssh -i /tmp/ssh_key root@$(cd pulumi && pulumi stack output sshHost --stack production)`.

`.env` (gitignored, in repo root):

```
PULUMI_ACCESS_TOKEN
INFISICAL_CLIENT_ID
INFISICAL_CLIENT_SECRET
CLOUDFLARE_TUNNEL_TOKEN   # only if you'll modify the tunnel locally; otherwise sourced from Infisical at deploy time
```

The Hetzner API token is stored as a Pulumi-encrypted stack config
(`hcloud:token` on `jterrazz/production`), not in `.env` or GitHub
secrets. `pulumi config set --secret hcloud:token <new>` from `pulumi/`
to rotate.

## Common Operations

### Run a fresh deploy

```bash
make deploy-local  # OrbStack (default for now)
make deploy        # Hetzner
make apps          # trigger every app's CI to (re)deploy
```

### SSH to the cluster

```bash
ssh root@jterrazz-infra@orb                                                       # OrbStack
ssh -i /tmp/ssh_key root@$(cd pulumi && pulumi stack output sshHost --stack production)  # Hetzner
```

### Restart cert-manager (after k3s churn)

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

### Promote a new app version

```bash
# In the app repo:
#   1. Bump prod.tag in .infrastructure/application.yaml
#   2. git push (no auto-deploy — prod is pinned)
gh workflow run "Build and Deploy" -R jterrazz/<app>
```

### Swap Hetzner ↔ OrbStack

```bash
cd pulumi
pulumi config set manageDns false --stack production
pulumi config set manageDns true  --stack local
pulumi up --stack production    # removes DNS records
pulumi up --stack local         # creates them pointing at OrbStack
# Then scale Hetzner cloudflared to 0 (and OrbStack to 1) to flip
# public traffic. Apps need to be re-pushed if you want fresh images
# on the new cluster's registry — `make apps`.
```

### Bring a torn-down stack back

```bash
cd pulumi
pulumi stack init jterrazz/production
pulumi config set target hetzner
pulumi config set --secret hcloud:token <token>
pulumi config set --secret cloudflare:apiToken <token>
pulumi up
```

## Gotchas

- **OrbStack DHCP DNS**: the VM's default DHCP server hands out a bogus
  resolver (`0.250.250.200`) that silently drops queries. The
  `tailscale` Ansible role writes
  `/etc/systemd/resolved.conf.d/upstream.conf` to override with
  `1.1.1.1` + `9.9.9.9`. If you ever see CoreDNS forwarding to a
  `0.250.x.x` IP, this file is missing.
- **cloudflared on OrbStack**: must run with `hostNetwork: true`
  (`kubernetes/platform/cloudflared/deployment.yaml`). The CNI bridge
  mangles outbound TCP/7844 to Cloudflare's edge and the tunnel
  handshake gets RSTed.
- **kubelet resolv-conf**: k3s config (`ansible/roles/k3s/templates/config.yaml.j2`)
  pins `--resolv-conf=/run/systemd/resolve/resolv.conf` so CoreDNS
  doesn't loop on the 127.0.0.53 stub.
- **buildkit DNS in CI**: `jterrazz-actions/actions/docker-build` uses
  `driver-opts: network=host` so buildkit sees the runner's Tailscale
  resolver. Without it, `docker push registry.jterrazz.com/…` NXDOMAINs
  on the public CNAME chain.
- **Infisical secret names**: CI workflows expect `TAILSCALE_OAUTH_CLIENT_SECRET`
  (not `TAILSCALE_OAUTH_SECRET`). Match exactly.
- **Next.js standalone Docker**: needs `output: 'standalone'` in
  `next.config.mjs`. If `public/` is gitignored, `mkdir -p public`
  before `next build`.
- **pnpm in Docker**: pnpm 11+ errors on unapproved postinstall scripts
  (`ERR_PNPM_IGNORED_BUILDS`). Pass `--ignore-scripts` to
  `pnpm install --frozen-lockfile` in the Dockerfile.
- **cert-manager after k3s restart**: cert-manager + webhook +
  cainjector lose API connection. Restart all three.
- **OrbStack VM after Mac reboot**: k3s auto-restarts via systemd,
  Tailscale auto-reconnects, but cert-manager may need a rollout
  restart before any new Certificate operations.
- **Tailscale identity collision**: if a previous VM with the same
  hostname was unceremoniously destroyed (no `tailscale logout`), the
  new VM joins as `<hostname>-2` and MagicDNS no longer resolves the
  canonical name. Rename via the Tailscale API
  (`POST /api/v2/device/<id>/name {"name":"jterrazz-infra"}`).
- **`tag` field on legacy apps**: apps without `tag: main` on prod fall
  into the workflow's legacy branch which deploys "staging" (which
  doesn't exist for them) and silently leaves prod stale. Always
  declare `tag` explicitly.
- **Helm adoption**: annotate existing resources with
  `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`, and
  label `app.kubernetes.io/managed-by=Helm`.
- **Immutable k8s fields**: Deployment selectors, PV `hostPath.type`,
  PVC `spec.selector` — delete and recreate if they need to change.
- **CRD kubectl names**: use fully-qualified names:
  `certificate.cert-manager.io`, `ingressroute.traefik.io`.
- **Renaming an app**: when `metadata.name` changes in
  `application.yaml`, CI creates a new Helm release under the new name
  but the old release keeps running. `helm uninstall prod-<old-name>
  -n prod-<old-name> && kubectl delete namespace prod-<old-name>` to
  clean up.
- **registry.jterrazz.com multi-arch GC** (historical): the
  `docker-cleanup` action previously stripped multi-arch layers because
  its HEAD used only the Docker manifest Accept header. Fixed in
  jterrazz-actions@6061ab2 — multi-arch tags now resolve to the index
  digest.
