# @jterrazz/infrastructure

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
│  (Hetzner cax21 ARM64 OR local OrbStack VM, Debian 13 on both)     │
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
| **Debian 13**     | Host OS on *both* targets (trixie; no dual-distro path) |
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
# jterrazz-infrastructure:target: orbstack   → pulumi/src/targets/orbstack.ts
# jterrazz-infrastructure:target: hetzner    → pulumi/src/targets/hetzner.ts
```

Only `pulumi/Pulumi.local.yaml` is committed — it's the stack that is up
today. There is **no** `Pulumi.production.yaml` in the repo: the Hetzner
stack currently doesn't exist and its config file is written by `pulumi
stack init` + `pulumi config set` when you recreate it (see "Bringing a
stack back from scratch" below). `index.ts` defaults `target` to
`hetzner` when a stack sets nothing.

Both targets run **Debian 13 (trixie)** — `image: debian-13` on Hetzner
(`pulumi/src/targets/hetzner.ts`), `debian:trixie` on OrbStack
(`pulumi/src/targets/orbstack.ts`; the version must stay explicit, `orb
create debian` still defaults to bookworm).

**Which one owns DNS?** Only one stack at a time should own the
Cloudflare CNAMEs for the private services (n8n, portainer, grafana,
registry, gateway, chat, openpanel). Whichever stack has
`jterrazz-infrastructure:manageDns: "true"` creates them. To swap:

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
make lint          # the same checks CI runs (shellcheck, ansible-lint, helm lint)
make deps          # check the local toolchain
```

`scripts/deploy.sh` is the canonical entry point. It pulls every Ansible
secret from Infisical env=prod (see [Required secrets](#required-secrets)
for the exact paths) using the universal-auth credentials in `.env`,
passes them as extra-vars, and runs `playbooks/site.yml` against the
chosen target. A missing secret **hard-fails** the run — there are no
fallback defaults.

Targeted re-runs skip the parts you don't need. `platform.yml` imports
17 tagged task files from `ansible/playbooks/tasks/platform/`:

```bash
cd ansible
ansible-playbook playbooks/platform.yml -i inventories/local/hosts.yml \
  -e "@<extra-vars>" --tags telemetry        # just Grafana/Prom/Loki/Tempo/OTel
# tags: prereqs, coredns/dns, infrastructure/namespaces, helm, secrets,
#       certmanager, infisical, cloudflared, telemetry, services, n8n,
#       portainer, librechat, gateway, openpanel, registry, chart-publish
# `--skip-tags chart-publish` leaves the published OCI chart alone.
```

## Project layout

```
ansible/
├── playbooks/
│   ├── site.yml       → base, security, networking, storage, kubernetes, platform
│   ├── platform.yml   thin orchestrator: imports tasks/platform/*.yml, one tag each
│   ├── group_vars/    all.yml — the visible config surface (timezone, k3s_version,
│   │                  private_hostnames). Playbook-adjacent on purpose: a top-level
│   │                  ansible/group_vars/ is next to neither inventory nor playbook
│   │                  and was silently never loaded.
│   └── tasks/platform/  17 task files (preflight, prereqs, coredns, infrastructure,
│                        helm, secrets, certmanager, infisical, cloudflared, telemetry,
│                        n8n, portainer, librechat, openpanel, registry, chart-publish,
│                        cleanup)
├── roles/         k3s, security, tailscale, storage
├── inventories/   production/ (Hetzner)  local/ (OrbStack, via the orb SSH proxy)
│                  ci/ (OrbStack, reached over Tailscale by GitHub Actions)
└── templates/     Jinja rendered at deploy time (coredns-custom, registry,
                   telemetry-storage)

kubernetes/
├── charts/
│   ├── app/       Standard app chart (2.2.0), published to
│   │              oci://registry.jterrazz.com/charts/app — schema reference in
│   │              kubernetes/charts/app/README.md
│   └── platform/  Shared chart (2.0.0) used by n8n / portainer / grafana / librechat
│                  for ingress + cert + named hostPath volumes
├── infrastructure/base/  THE kustomize entry point — `kubectl apply -k` (namespaces,
│                  Traefik HelmChartConfig + middlewares + TLS options, default-deny
│                  NetworkPolicies, the `manual` StorageClass). The old
│                  environments/production overlay is gone; base is the deployed state.
└── platform/      Per-service Helm values (helm.yaml + platform.yaml) and the raw
                   manifests that don't fit a chart (librechat/, openpanel/, …)

pulumi/
├── src/
│   ├── index.ts         Dual-mode dispatcher (`target=hetzner|orbstack`)
│   ├── targets/         hetzner.ts, orbstack.ts, types.ts
│   └── dns.ts           Cloudflare DNS records for private services
└── Pulumi.local.yaml    (production's stack config is created by `pulumi stack init`)

scripts/
├── deploy.sh                Provision + configure either stack
└── trigger-app-deploys.sh   Re-trigger every app's CI (used after a fresh cluster rebuild)

.github/workflows/   validate.yaml, deploy-platform.yaml, publish-chart.yaml
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
  which CoreDNS can't chase). The host list is `private_hostnames` in
  `ansible/playbooks/group_vars/all.yml` — **keep it in sync with
  `PRIVATE_HOSTS` in `pulumi/src/dns.ts`** — rendered into the
  `coredns-custom` ConfigMap by
  `ansible/templates/kubernetes/coredns-custom.yaml.j2`
  (applied by `playbooks/tasks/platform/coredns.yml`).
* A second list, `private_hostnames_via_traefik`, maps a host to
  Traefik's **ClusterIP** instead of the node's tailnet IP. Only
  `openpanel.jterrazz.com` uses it — its dashboard SSRs against its own
  public URL from inside the pod and can't hairpin through the node's
  ServiceLB. Routes reached that way carry the
  `cluster-internal-access` middleware rather than `private-access`.

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
    ingress:                  # always a LIST; `public` is mandatory per entry
      - { host: my-app-staging.jterrazz.com, path: /, public: true }
  prod:
    tag: v1.0.0               # pinned — only deploys on workflow_dispatch
    ingress:
      - { host: my-app.jterrazz.com, path: /, public: true }
```

The shared reusable workflow at
`jterrazz/jterrazz-actions/.github/workflows/release-docker.yaml`
takes care of validate → build → push → `helm upgrade --install`
against the OCI app chart. Apps need `INFISICAL_CLIENT_ID` /
`INFISICAL_CLIENT_SECRET` as GitHub repo secrets.

`./scripts/trigger-app-deploys.sh` triggers every app's workflow at
once. Use after rebuilding the cluster from scratch — apps get a fresh
build + helm install on the new registry.

## This repo's own CI

Three workflows under `.github/workflows/`. All third-party actions are
SHA-pinned; `jterrazz/jterrazz-actions/*` stays on `@main` on purpose
(first-party, and it's meant to roll across the fleet).

| Workflow                | Trigger                                                     | Does                                                                   |
| ----------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------- |
| `validate.yaml`         | PR to main **and** push to main                              | Pulumi `tsc --noEmit` + `preview`; `ansible-lint` (production profile) + `--syntax-check`; kustomize/Helm/raw-manifest validation |
| `deploy-platform.yaml`  | push to main touching `ansible/playbooks/platform.yml`, `kubernetes/platform/**`, `kubernetes/infrastructure/**`; or manual | Runs `platform.yml` only, over Tailscale, against the OrbStack VM |
| `publish-chart.yaml`    | push to main touching `kubernetes/charts/app/**`; or manual  | Packages + pushes the app chart to the OCI registry                    |

**`validate.yaml`** validates for real rather than smoke-testing: each
chart is rendered against its own `kubernetes/charts/{app,platform}/ci/test-values.yaml`
fixture (with default values these charts render *zero* objects, so
plain `helm lint` proved nothing) and piped through `kubeconform -strict`
with the datreeio CRD catalog, so Traefik / cert-manager / Infisical CRs
are schema-checked too. `kubectl kustomize kubernetes/infrastructure/base`
and every raw manifest under `kubernetes/platform/**` (detected by having
a top-level `apiVersion:`) go through the same check. Keep the fixtures
exercising every template branch — a branch not reachable from a fixture
is a branch CI does not check.

**`deploy-platform.yaml`** is the *platform layer only*. It deliberately
skips base/security/networking/storage/k3s: those roles restart sshd or
tailscaled and would kill the runner's own SSH session mid-run. Use
`make deploy-local` from the laptop for anything below the platform
layer. Pulumi is out of scope too (needs `orbctl` on the Mac). Auth is
the split CI deploy keypair described under [Security at the
host](#security-at-the-host); the extra-vars file it builds mirrors
`fetch_secrets_file()` in `scripts/deploy.sh` byte-for-byte in intent —
the two are hand-synced.

**`publish-chart.yaml`** refuses to overwrite an already-published
version: it `helm pull`s the version in `Chart.yaml` first and fails the
build if it resolves. The chart is consumed **unversioned** by every
app, so silently republishing a version would mean two different sets of
templates answering to the same tag. Bump `version:` in
`kubernetes/charts/app/Chart.yaml` with every change.

## Storage

All persistent data lives at `/var/lib/k8s-data/` on the cluster host.
**Convention: one directory per app** — a multi-component app nests its
volumes under `<app>/` (e.g. `librechat/mongo`, `openpanel/clickhouse`).

* On **Hetzner**, that's the VPS's local disk — survives reboots, not
  VM destruction.
* On **OrbStack**, it's a symlink to `~/.jterrazz-infrastructure/data/` on the
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
├── librechat/                 LibreChat — {mongo, uploads}
└── openpanel/                 OpenPanel — {postgres, clickhouse, redis}
```

Backup: `tar -czvf backup-$(date +%Y%m%d).tar.gz /var/lib/k8s-data/`
(or, on OrbStack, the Mac-side `~/.jterrazz-infrastructure/data/`).

## Required secrets

### GitHub Actions

| Secret                    | Infra repo | App repos | Used by                                    |
| ------------------------- | ---------- | --------- | ------------------------------------------ |
| `PULUMI_ACCESS_TOKEN`     | ✓          |           | `validate.yaml` (Pulumi preview on PRs)    |
| `INFISICAL_CLIENT_ID`     | ✓          | ✓         | `deploy-platform.yaml`, `publish-chart.yaml` |
| `INFISICAL_CLIENT_SECRET` | ✓          | ✓         | same                                       |
| `CI_DEPLOY_SSH_PRIVATE`   | ✓          |           | `deploy-platform.yaml` (SSH into the VM)   |

The Hetzner API token lives in the Pulumi stack config as
`hcloud:token` (encrypted via Pulumi Cloud), not in GitHub secrets.
Rotate with `pulumi config set --secret hcloud:token <new>` in
`pulumi/` against the `jterrazz/production` stack.

### Infisical — project `jterrazz`, env `prod`

**Consumed by the deploy** — `fetch_secrets_file()` in `scripts/deploy.sh`
and the identical `Build extra-vars file` step in
`.github/workflows/deploy-platform.yaml` fetch these four paths
**explicitly, not recursively**, so short keys can repeat across service
folders (grafana and portainer both use `ADMIN_PASSWORD`). Any missing
value aborts the run; `playbooks/tasks/platform/preflight.yml` asserts
the same set again on the host. Change one copy → change all three.

| Infisical path                        | Key                             | Ansible var                      |
| ------------------------------------- | ------------------------------- | -------------------------------- |
| `/jterrazz-infrastructure`            | `CLOUDFLARE_API_TOKEN`          | `cloudflare_api_token`           |
|                                       | `CLOUDFLARE_TUNNEL_TOKEN`       | `cloudflare_tunnel_token`        |
|                                       | `TAILSCALE_OAUTH_CLIENT_ID`     | `tailscale_oauth_client_id`      |
|                                       | `TAILSCALE_OAUTH_CLIENT_SECRET` | `tailscale_oauth_client_secret`  |
|                                       | `DOCKER_REGISTRY_PASSWORD`      | `registry_password`              |
| `/jterrazz-infrastructure/grafana`    | `ADMIN_PASSWORD`                | `grafana_password`               |
| `/jterrazz-infrastructure/n8n`        | `ENCRYPTION_KEY`                | `n8n_encryption_key`             |
| `/jterrazz-infrastructure/portainer`  | `ADMIN_PASSWORD`                | `portainer_password`             |

`infisical_client_id` / `infisical_client_secret` are the one exception:
they come from `.env` locally (or the GitHub secrets in CI), never from
Infisical itself — chicken-and-egg, the operator needs them to log in.

**Consumed inside the cluster**, by `InfisicalSecret` CRs the operator
reconciles (the deploy script never sees these):

* **`/jterrazz-infrastructure/librechat`** → Secret `librechat-credentials-env`:
  `CREDS_KEY`, `CREDS_IV`, `JWT_SECRET`, `JWT_REFRESH_SECRET`
* **`/jterrazz-infrastructure/openpanel`** → Secret `openpanel-secrets`:
  `POSTGRES_PASSWORD`, `COOKIE_SECRET`, `DATABASE_URL`, `DATABASE_URL_DIRECT`
* **`/<app>/…`** — each app's own path, declared as `spec.secrets.path`
  in its `application.yaml`
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

The rest of the `security` role: sshd hardening as a **drop-in**
(`/etc/ssh/sshd_config.d/10-hardening.conf`, validated twice — `sshd -t
-f` on the candidate file, then `sshd -t` on the effective config, with
a rescue that removes the drop-in rather than locking you out),
`ssh.socket` disabled so `Port` and restarts actually take effect on
Debian 13, unattended-upgrades on Debian-Security origin patterns,
sysctl hardening, and blacklisting of dccp/sctp/rds/tipc.

**Not** installed, deliberately: **fail2ban** (it guarded a public SSH
port that doesn't exist — the only inbound path is the tailnet, so all
it could ever ban was a tailnet IP after a typo) and **auditd** (needs
`CAP_AUDIT_*`, which the OrbStack hypervisor withholds, so it was
already skipped on the active target and its rules never loaded). Both
also cost memory on a 4-8Gi node.

The `deploy-platform.yaml` CI workflow SSHes in with a **split
keypair**: the public half is committed as `security_ci_deploy_pubkey`
in `ansible/roles/security/defaults/main.yml` (the role installs it into
root's `authorized_keys`), the private half is the
`CI_DEPLOY_SSH_PRIVATE` GitHub secret. Rotate by regenerating the pair,
replacing the default, `gh secret set CI_DEPLOY_SSH_PRIVATE`, then
`make deploy-local` to roll the pubkey onto the VM.

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
ssh root@jterrazz-infrastructure@orb                          # OrbStack
ssh -i /tmp/ssh_key root@$(cd pulumi && pulumi stack output sshHost --stack production)  # Hetzner
```
