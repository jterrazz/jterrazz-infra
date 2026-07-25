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

**Host OS is Debian 13 (trixie) on both targets** — `image: debian-13`
on Hetzner, `debian:trixie` on OrbStack. There is no dual-distro
support: package names and templates are Debian-native. See the Debian
13 gotchas below before touching the base/security/networking roles.

The active production today is **OrbStack** (May 2026 swap). Hetzner is
fully supported as an alternative; only `Pulumi.local.yaml` is committed,
so bringing Hetzner back means `pulumi stack init jterrazz/production`
first — full procedure in README.md ("Bringing a stack back from
scratch").

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
  short-circuited by a CoreDNS `coredns-custom` ConfigMap to the
  cluster's own tailnet IP. The public CNAME chain stops at `*.ts.net`
  which CoreDNS can't chase through public DNS, so without this override
  registry pulls + helm pushes NXDOMAIN. The list is
  **`private_hostnames` in `ansible/playbooks/group_vars/all.yml`**
  (keep in sync with `PRIVATE_HOSTS` in `pulumi/src/dns.ts`), rendered by
  `ansible/templates/kubernetes/coredns-custom.yaml.j2` and applied by
  `ansible/playbooks/tasks/platform/coredns.yml`.
  A second list, `private_hostnames_via_traefik`, maps to Traefik's
  **ClusterIP** instead of the node tailnet IP — `openpanel` is its only
  member, so the OpenPanel dashboard's SSR doesn't hairpin; see
  `kubernetes/platform/openpanel/README.md`.
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
chart): n8n, Portainer, LibreChat and OpenPanel.

**LibreChat** — private AI chat UI at `chat.jterrazz.com` (`platform-ai` ns),
upstream chart + values in `kubernetes/platform/librechat/`. See that dir's
`README.md` for versions, secrets, gateway wiring, PVC layout and the
default-model-upgrade procedure. The load-bearing bits: it reaches the gateway
via the **in-cluster Service** (`http://gateway-intelligence.prod-gateway-intelligence.svc.cluster.local`),
never `gateway.jterrazz.com` (a pod can't hairpin to the node's ServiceLB);
`gateway-netpol.yaml` adds the additive ingress rule for `platform-ai` →
gateway:8317 because LibreChat isn't an app-chart workload and can't stamp the
platform-client label; the API key is the non-secret placeholder
`gateway-noauth` (see "gateway-intelligence: auth model" below); its datastore
is a standalone `mongo:7.0`, the bundled Bitnami subchart being disabled; and
both PVCs (`librechat-data`, `librechat-uploads`) come from the platform
chart's named-volume storage map. Private-only for now
(`ALLOW_REGISTRATION=false` + `private-access`).

**OpenPanel** — self-hosted product analytics (`platform-analytics` ns),
raw manifests under `kubernetes/platform/openpanel/` (does not fit the platform
chart: 3 apps + 3 stateful stores + split ingress). See that dir's `README.md`
for versions, data paths, upgrade and backup/restore. 6 workloads: Postgres 14
+ Redis 7.2 + ClickHouse 25.10 (hostPath `Retain` PVCs) and op-api / op-worker
/ op-dashboard (`lindesvard/openpanel-*:2.2`). op-api runs Prisma + ClickHouse
migrations on boot. **Split exposure**: private dashboard on
`openpanel.jterrazz.com` (Tailscale — `cluster-internal-access`, NOT
`private-access`, because the SSR caller is a pod IP), public event ingest on
`analytics.jterrazz.com` exposing **only** `/api/track` (cloudflared tunnel →
Traefik, `stripPrefix /api`). ClickHouse runs upstream's log-to-stdout config
(issue #324) + a per-query mem cap (#382), no CH/Redis auth (firewalled by
`netpol.yaml`). Secrets from Infisical `/jterrazz-infrastructure/openpanel`. Two DNS quirks (details in
the dir's README): the public `analytics` CNAME is Pulumi-managed
(`dns.ts`) but its **tunnel route** is a per-hostname rule in the Zero Trust
dashboard (the tunnel isn't a wildcard); and `openpanel.jterrazz.com` resolves
**in-cluster** to Traefik's ClusterIP, not the node tailnet IP, so the
dashboard's server-side rendering doesn't hairpin (`API_URL_SSR` *is* set in
`config.yaml`, but image 2.2 was not observed to honor it — see the post-repave
checklist below).

## Managed Domains

- `jterrazz.com`, `spwn.sh`, `clawrr.com`, `clawssify.com`, `sig.news` — all in cert-manager's `dnsZones`.
- New public domain: add to cert-manager `issuers.yaml` (both
  ClusterIssuers) + add a Public Hostname in the cloudflared tunnel UI
  (auto-creates the CNAME).
- New private hostname: add the host to `PRIVATE_HOSTS` in
  `pulumi/src/dns.ts`, then `pulumi up` from `pulumi/`. Also add it to
  `private_hostnames` in `ansible/playbooks/group_vars/all.yml` so
  in-cluster lookups resolve — the two lists are hand-synced.
- Cloudflare SSL mode must be **Full (Strict)** on every zone.

## Key Patterns

- Platform services installed via Helm by `ansible/playbooks/platform.yml`,
  which is a **thin orchestrator**: the body lives in 17 files under
  `ansible/playbooks/tasks/platform/`, each imported with a tag. Targeted
  re-run: `ansible-playbook playbooks/platform.yml -i inventories/local/hosts.yml
  -e "@<vars>" --tags telemetry`. Tags: `prereqs`, `coredns`/`dns`,
  `infrastructure`/`namespaces`, `helm`, `secrets`, `certmanager`,
  `infisical`, `cloudflared`, `telemetry`, `services`, `n8n`, `portainer`,
  `librechat`, `gateway`, `openpanel`, `registry`, `chart-publish`.
  `preflight` + `cleanup` are `always`; `--skip-tags chart-publish` leaves the
  published OCI chart alone.
- **Ansible variables** live in `ansible/playbooks/group_vars/all.yml` —
  playbook-adjacent, not `ansible/group_vars/`. Ansible only auto-loads
  `group_vars/` next to the *inventory file* or next to the *playbook*; the
  old top-level dir was adjacent to neither and was silently never loaded
  (every var in it was dead). Don't move it back. `k3s_version` is
  single-sourced here, deliberately not duplicated in
  `roles/k3s/defaults/main.yml`.
- Shared platform chart (`kubernetes/charts/platform/`, **2.0.0**) generates
  Certificate + IngressRoute + PV/PVCs from a thin `platform.yaml`. `storage`
  is a **map of named volumes** (`storage.<key>.{size,pathSuffix}`) → objects
  named `<name>-<key>`; the key `data` reproduces the historical `<name>-data`
  names exactly, and hostPath is `/var/lib/k8s-data/<name>[/<pathSuffix>]`.
  This is how librechat declares both `librechat-data` and
  `librechat-uploads` (the hand-written `uploads.yaml` is gone).
- App chart at `kubernetes/charts/app/`, published to the OCI registry
  (currently **2.2.0**) — full `application.yaml` reference in
  `kubernetes/charts/app/README.md`. Notable behaviours: hardened container
  securityContext with a `spec.securityContext` / `spec.runAsRoot` escape
  hatch; hostPath PV `nodeAffinity` only when `infrastructure.nodeName` is
  passed; `spec.storage.{size,mountPath}` are `required`; and a default
  `NODE_OPTIONS=--max-old-space-size` (~75% of the memory request) injected
  **only for apps requesting >= 512Mi** (e.g. signews-api), unless the app
  sets its own `NODE_OPTIONS` — below that floor the derived cap starves
  small Next.js services' SSR boot and crash-loops them.
- **The kustomize entry point is `kubernetes/infrastructure/base`**
  (`kubectl apply -k`). The `environments/production` overlay and the
  single-file sub-kustomizations were deleted — base *is* the deployed state.
  It carries namespaces, Traefik HelmChartConfig + middlewares + TLS options,
  the default-deny NetworkPolicies for `platform-management` /
  `platform-registry`, and the `manual` StorageClass.
- **Traefik access middlewares** (`infrastructure/base/traefik/middleware.yaml`):
  `private-access` is the tailnet-only ipAllowList attached by `private: true`
  and by any app ingress entry with `public: false`.
  `cluster-internal-access` is a strict **superset** used by routes that must
  also be reachable from inside the cluster or via a node hairpin — the
  registry (containerd pulls) and openpanel's private route (dashboard SSR).
  **Never chain the two**: Traefik ANDs chained ipAllowLists, so chaining
  allows strictly less, not more.
- **Platform-service opt-in (app-chart 2.0)**: an app declares
  `spec.platformServices: [otel-collector, gateway-intelligence]` and the
  chart wires the whole bundle from a catalog in
  `kubernetes/charts/app/templates/_helpers.tpl` (`app.platformCatalog`):
  env injection + egress NetworkPolicy + — for a service that is itself a
  catalog target (gateway-intelligence) — a server-side ingress rule via a
  pod label (`platform-client.jterrazz.com/<svc>`), so a new consumer needs
  ZERO edit on the target. Env names are service-derived
  (`GATEWAY_INTELLIGENCE_BASE_URL`) except `OTEL_EXPORTER_OTLP_ENDPOINT`
  (the OTel SDK owns that contract). Unknown entries hard-fail the render.
  OTel is **opt-in** (was an unconditional default that was inert without the
  egress hole). Bespoke ingress is `spec.networkPolicy.allowedClients` (by
  namespace name); there is no egress-side alias.
- The app chart is pulled **UNVERSIONED** by CI (`oci://…/charts/app`), so a
  chart push reaches every app on its next deploy — additive, defaulted
  changes only. `publish-chart.yaml` refuses to overwrite an
  already-published version, so bump `version:` in `Chart.yaml` in the same
  commit as any template change.
- **gateway-intelligence: auth model (Option A — netpol-only).** CLIProxyAPI
  does NOT enforce client API keys. With `api-keys: []` in its config its
  access provider is unregistered and the auth middleware allows all
  requests (verified in upstream v7 source). The security boundary is
  therefore **NetworkPolicy + private-only ingress**, not a bearer token.
  Consumers pass a **non-secret static placeholder** apiKey
  (`gateway-noauth`) only to satisfy the OpenAI SDK's non-empty-string
  requirement — it is NOT a secret, NOT centralized, and there is NO gateway
  API key in Infisical anywhere. `MANAGEMENT_PASSWORD` (the mgmt API secret)
  IS real and stays in Infisical `/gateway-intelligence`. If per-client auth
  is ever wanted, it must be rendered into `config.yaml` `api-keys:` (no env
  path exists in CLIProxyAPI) — deferred.
- Per-service config split: `helm.yaml` (upstream chart values) +
  `platform.yaml` (ingress / cert / storage).
- PVCs use `storageClassName: manual` with hostPath PVs, bound via
  `volumeName` (not selector).
- **hostPath layout: one dir per app** under `/var/lib/k8s-data/`. A
  multi-component app nests its volumes under `<app>/` (e.g.
  `librechat/{mongo,uploads}`, `openpanel/{postgres,clickhouse,redis}`).
  Platform-chart volumes set `storage.<key>.pathSuffix` for this; raw
  manifests just set the nested `hostPath.path`.
- Traefik **IngressRoutes** (not plain Ingress) for routing.
- cert-manager Certificates with `letsencrypt-production` ClusterIssuer.
- Telemetry PVs (Grafana / Prometheus / Loki / Tempo) have
  `nodeAffinity` matching the actual node name, injected by Ansible
  via `templates/kubernetes/telemetry-storage.yaml.j2`.
- On OrbStack, `/var/lib/k8s-data` is a symlink to
  `/mnt/mac/Users/<user>/.jterrazz-infrastructure/data` so the data survives
  `pulumi destroy && pulumi up`.
- **Host security posture**: UFW (80/443/6443 tailnet-only; klipper-lb's
  `loadBalancerSourceRanges` is the real gate), sshd hardening as a validated
  `sshd_config.d` **drop-in**, unattended-upgrades, sysctl hardening.
  **fail2ban and auditd are gone on purpose** — fail2ban guarded a public SSH
  port that doesn't exist (no public inbound at all; SSH is tailnet-only), and
  auditd needs `CAP_AUDIT_*` which the OrbStack hypervisor withholds, so it
  was already skipped on the active target. Don't "restore" them.

## This repo's CI (`.github/workflows/`)

- **`validate.yaml`** — PRs *and* pushes to main. Pulumi `tsc --noEmit` +
  `preview`; `ansible-lint` (**production** profile, config in
  `ansible/.ansible-lint`) + `--syntax-check`; `kubectl kustomize
  kubernetes/infrastructure/base`, both Helm charts rendered against their
  `ci/test-values.yaml` fixtures, and every raw manifest under
  `kubernetes/platform/**`, all piped through `kubeconform -strict` with the
  datreeio CRD catalog. Default values render ~zero objects for these charts,
  so **a template branch not reached by a fixture is not validated** — extend
  the fixture when you add one. `make lint` runs the local subset.
- **`deploy-platform.yaml`** — push to main touching
  `ansible/playbooks/platform.yml`, `kubernetes/platform/**` or
  `kubernetes/infrastructure/**` (or manual). Runs **`platform.yml` only**,
  over Tailscale, against the OrbStack VM. It deliberately skips
  base/security/networking/storage/k3s — those restart sshd/tailscaled and
  would kill the runner's own SSH session. Pulumi is out of scope (needs
  `orbctl` on the Mac). Its extra-vars step mirrors `fetch_secrets_file()` in
  `scripts/deploy.sh`; **the two are hand-synced — change one, change both**
  (and `tasks/platform/preflight.yml` asserts the same set).
- **`publish-chart.yaml`** — push to main touching
  `kubernetes/charts/app/**`. Guarded against republishing an existing
  version (see above).
- SSH auth for CI is a **split keypair**: public half committed as
  `security_ci_deploy_pubkey` in `ansible/roles/security/defaults/main.yml`,
  private half the `CI_DEPLOY_SSH_PRIVATE` GitHub secret. Rotating needs
  both plus a `make deploy-local` to roll the pubkey onto the VM.
- Third-party actions are SHA-pinned; `jterrazz/jterrazz-actions/*` floats on
  `@main` on purpose (first-party, meant to roll across the fleet).

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
- OrbStack VM reachable via the OrbStack SSH proxy: `ssh root@jterrazz-infrastructure@orb`.
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

### Targeted platform re-run

```bash
cd ansible && ansible-playbook playbooks/platform.yml \
  -i inventories/local/hosts.yml -e "@<extra-vars>" --tags <tag>
```

(SSH one-liners are in "Connection Details" above.)

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

### Swap Hetzner ↔ OrbStack / bring a torn-down stack back

Both procedures (the `manageDns` flip + cloudflared scale, and the
`pulumi stack init` sequence) are in **README.md** — "Dual-mode — choose your
production". Only one stack may have `manageDns: true` at a time, and after a
swap `make apps` re-pushes every app onto the new cluster's registry.

## Post-repave verification checklist (TEMPORARY — delete once done)

The Debian 13 refactor left five things deliberately unverified because they
can only be checked against a freshly repaved cluster. Work through these
after the next `make deploy-local`, then delete this section **and** the
matching `TODO`s in the source files.

1. **`private-access` still allowlists `10.42.0.0/16`** (the k3s pod CIDR),
   which is exactly what keeps a pod able to reach Portainer through Traefik.
   It's retained only because klipper-lb MASQUERADEs LoadBalancer traffic
   inside the svclb pod's netns, so a tailnet client's request *may* arrive
   with an svclb pod IP. **Test**: hit a private host from the tailnet and
   read Traefik's access-log `ClientAddr`. If it shows `100.64.x.x`, delete
   that line from `infrastructure/base/traefik/middleware.yaml` — one edit,
   and the pod → Portainer hole closes.
2. **OpenPanel `API_URL_SSR`.** `API_URL_SSR=http://op-api:3000` is set in
   `openpanel/config.yaml` but image 2.2 was not observed to honor it, so the
   CoreDNS Traefik-ClusterIP mapping carries SSR today. **Test**: remove
   `openpanel.jterrazz.com` from `private_hostnames_via_traefik` in
   `ansible/playbooks/group_vars/all.yml`, restart CoreDNS + op-dashboard,
   load `/onboarding`. If it renders, drop the mapping for good.
3. **`op-*` uid.** The three OpenPanel app images don't document their user,
   so they run hardened but **without** a uid pin (TODO in
   `openpanel/apps.yaml`). Check the running uid (`kubectl exec … -- id`) and
   pin it.
4. **Datastore uid pins hold.** ClickHouse **101**, Postgres **70** (alpine
   variant), Redis **999**, LibreChat's mongod **999** — each paired with a
   root `fix-perms` initContainer, because pinning the uid bypasses the
   entrypoint's own chown. Verify each pod is actually running as that uid and
   that no `Permission denied` appears on first boot.
5. **cert-manager webhook NetworkPolicy fix.** `platform-networking`'s policy
   now admits **port 10250**, which the kube-apiserver dials for the admission
   webhook. That omission is the most plausible cause of the recurring "no
   endpoints available for service cert-manager-webhook" breakage. **Test**:
   create/renew a Certificate right after a fresh k3s start and confirm it
   succeeds without the manual rollout restart below.

Also still marked "tighten after repave validation": the deliberately-wide
egress rules in the `platform-management` and `platform-registry`
NetworkPolicies (443 to anywhere). Narrow them once a full CI push/pull cycle
and the Portainer dashboard are confirmed green.

## Gotchas

### Debian 13 (trixie) — host level

- **`orb create debian` gives you bookworm.** Debian is the one distro where
  OrbStack's bare image name is the *previous* stable, so
  `pulumi/src/targets/orbstack.ts` pins `version: "trixie"` explicitly. Never
  drop that.
- **`apt-key` is removed in trixie**, so `ansible.builtin.apt_key` has nothing
  to call. The Tailscale repo is added with
  `ansible.builtin.deb822_repository` (suite `trixie`), which needs
  **`python3-debian` on the target** — installed by `base.yml`.
- **`systemd-resolved` is a separate, non-default package on Debian 12+** and
  the OrbStack image ships it **masked**. `base.yml` installs it; the
  `tailscale` role unmasks and starts it. Without a stub resolver Tailscale
  writes `/etc/resolv.conf` itself with `100.100.100.100`, which does *not*
  chase CNAMEs from a public zone into the tailnet zone — the deploy then
  fails at `helm registry login registry.jterrazz.com`.
- **sshd is socket-activated on Debian 13.** `ssh.socket` owns the listening
  port, so `Port` in sshd_config is ignored and restarting `ssh.service`
  doesn't re-bind. `base.yml` disables the socket unit and runs the classic
  daemon; the security role's handler restarts `ssh.service` (not
  `ssh.socket`).
- **sshd hardening is a drop-in**, `/etc/ssh/sshd_config.d/10-hardening.conf`,
  never a wholesale replacement of the distro file. The `Include` line must
  stay at the **top** of `/etc/ssh/sshd_config`: the first occurrence of a
  keyword wins, so an Include at the bottom would let the stock defaults beat
  every value we set. Validation is two-stage (`sshd -t -f` on the candidate,
  then `sshd -t` on the effective config) with a rescue that removes the
  drop-in rather than locking you out.
- **unattended-upgrades needs Debian-Security origin patterns.** The
  Ubuntu-style pattern silently disables security updates on Debian — it
  matches nothing, and the failure mode is a green deploy with no patching.
- **OrbStack VMs ship without sshd**, so `openssh-server` is installed
  explicitly (the security role needs `sshd -t` to validate its config).
- **`orbctl create -u root` is broken since OrbStack 2.2.0** (its setup runs
  `usermod --uid 501 root`, which fails against PID 1). The VM is created with
  the default macOS-named user; Ansible connects as `root@<vm>@orb`.

### Cluster / networking

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
  (`POST /api/v2/device/<id>/name {"name":"jterrazz-infrastructure"}`).
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
- **CI fixtures are the validation contract.** Both charts render zero (or
  near-zero) objects with default values, so a template branch that
  `kubernetes/charts/{app,platform}/ci/test-values.yaml` doesn't reach is a
  branch CI silently doesn't check.
