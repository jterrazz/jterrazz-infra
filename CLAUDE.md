# Infra Project

## Project Overview

Single-node k3s cluster running on an OrbStack VM on the dev Mac.
Pulumi stack: `jterrazz/local` — the only live stack. (A Hetzner cax21
stack `jterrazz/production` existed historically and was destroyed in
May 2026; the migration trail is around git commit `b29f250`.)

The cluster is configured by `ansible/playbooks/site.yml` (base →
security → networking → storage → kubernetes → platform) and runs the
Helm charts in `kubernetes/charts/`.

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
  Pulumi-managed in `pulumi/src/dns.ts`, CNAMEd to the cluster's
  Tailscale FQDN (`jterrazz-infra.tail77a797.ts.net`).
- **In-cluster lookups** for those same private hostnames are
  short-circuited by a CoreDNS `coredns-custom` ConfigMap to the
  cluster's own tailnet IP. The public CNAME chain stops at `*.ts.net`
  which CoreDNS can't chase; the override keeps registry pulls + helm
  pushes on the local Traefik. Defined in `ansible/playbooks/platform.yml`.
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
- App chart at `kubernetes/charts/app/`, published to OCI registry.
- Per-service config split: `helm.yaml` (upstream chart values) +
  `platform.yaml` (ingress / cert / storage).
- PVCs use `storageClassName: manual` with hostPath PVs, bound via
  `volumeName` (not selector).
- Traefik **IngressRoutes** (not plain Ingress) for routing.
- cert-manager Certificates with `letsencrypt-production` ClusterIssuer.
- Telemetry PVs (Grafana / Prometheus / Loki / Tempo) have
  `nodeAffinity` matching the actual node name, injected by Ansible
  via `templates/kubernetes/telemetry-storage.yaml.j2`.
- `/var/lib/k8s-data` on the VM is a symlink to
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

- Pulumi stack: `jterrazz/local`. `PULUMI_ACCESS_TOKEN` required.
- **Pulumi commands must run from `pulumi/`** (not repo root).
- OrbStack VM reachable via the OrbStack SSH proxy: `ssh root@jterrazz-infra@orb`.

`.env` (gitignored, in repo root):

```
PULUMI_ACCESS_TOKEN
INFISICAL_CLIENT_ID
INFISICAL_CLIENT_SECRET
CLOUDFLARE_TUNNEL_TOKEN   # only if you'll modify the tunnel locally; otherwise sourced from Infisical at deploy time
```

## Common Operations

### Run a fresh deploy

```bash
make deploy        # pulumi up + ansible site.yml
make apps          # trigger every app's CI to (re)deploy
```

### SSH to the cluster

```bash
ssh root@jterrazz-infra@orb
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

## Gotchas

- **OrbStack DHCP DNS**: the VM's default DHCP server hands out a bogus
  resolver (`0.250.250.200`) that silently drops queries. The
  `tailscale` Ansible role writes `/etc/systemd/resolved.conf.d/upstream.conf`
  to override with `1.1.1.1` + `9.9.9.9`. If you ever see CoreDNS
  forwarding to a `0.250.x.x` IP, this file is missing.
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
  (`POST /api/v2/device/<id>/name {"name":"jterrazz-infra"}`) — there's
  a `gh tail77a797` admin link.
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
