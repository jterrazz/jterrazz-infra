# CLAUDE.md

Delta-only notes for agents: what the tree does **not** tell you. Architecture
is in [README.md](README.md), operations in [docs/RUNBOOK.md](docs/RUNBOOK.md),
the `application.yaml` schema in
[kubernetes/charts/app/README.md](kubernetes/charts/app/README.md).

## Active state

One cluster: k3s on an OrbStack VM (`jterrazz-infrastructure`, Debian 13
trixie, arm64) on the dev Mac. Pulumi stack `jterrazz/local`, Ansible inventory
`inventories/laptop.yml`. Hetzner is a recipe in `docs/hetzner.md` and git
history, **not** a live mode — do not reintroduce a `target` / `manageDns` /
`deployment_target` branch anywhere.

## Hand-synced pairs

Nothing enforces these at runtime; each has a CI assertion in `validate.yaml`
because each has drifted at least once. Change one, change all.

| A                                                     | B                                                        | Why they must match                                                    |
| ----------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------- |
| `private_hostnames` (`ansible/inventories/group_vars/all.yml`) | `PRIVATE_HOSTS` (`pulumi/src/dns.ts`)             | A creates the in-cluster CoreDNS override, B the public CNAME. One without the other = a name that resolves nowhere useful. |
| `helm_version` (`group_vars/all.yml`)                 | `azure/setup-helm` version in `validate.yaml` **and** `publish-chart.yaml` | Three machines, one Helm. A chart packaged by one version and rendered by another is a silent behaviour difference. |
| `SCOPES` in `scripts/lib/infisical-vars.py`           | the `assert` list in `roles/platform/tasks/preflight.yml` | Preflight is the second gate on the same secret set; a secret fetched but unasserted fails halfway through a deploy instead of at the start. |
| `forwardedHeaders.trustedIPs` (`cluster/traefik/traefik-config.yaml`) | `rate-limit` `ipStrategy.excludedIPs` (`cluster/traefik/middleware.yaml`) | Both enumerate "hops that are ours". If they disagree, the rate limiter keys on the wrong XFF element or on nothing. |
| `security_ci_deploy_pubkey` (`roles/security/defaults/main.yml`) | GitHub secret `CI_DEPLOY_SSH_PRIVATE`              | Split keypair. Rotating needs both plus a `make deploy` to roll the pubkey onto the VM. |
| `version:` in `charts/app/Chart.yaml`                 | the published OCI chart                                   | The chart is pulled **unversioned** by every app. Two publish guards exist (`publish-chart.yaml` and `roles/platform/tasks/publish-app-chart.yml`) and both skip rather than overwrite — so forgetting the bump publishes nothing, silently. |
| `ci/test-values.yaml` fixtures                        | the chart templates                                       | Both charts render near-zero objects with default values. A branch no fixture reaches is a branch CI does not check. |

## Gotchas

Repo-specific, each one paid for at least once.

- **`orb create debian` gives you bookworm.** Debian is the one distro where
  OrbStack's bare image name resolves to the *previous* stable, so
  `pulumi/src/targets/orbstack.ts` pins `version: "trixie"` explicitly. Never
  drop it — every Ansible role is Debian-13-native (deb822 repositories,
  socket-activated sshd, systemd-resolved as a separate package).
- **`orbctl create -u root` is broken** since OrbStack 2.2.0 (its setup runs
  `usermod --uid 501 root`, which fails against PID 1). The VM is created with
  the default macOS-named user; Ansible connects as `root@<vm>@orb`.
- **OrbStack DHCP hands out a bogus resolver** (`0.250.250.200`) that silently
  drops queries. The `tailscale` role writes
  `/etc/systemd/resolved.conf.d/upstream.conf` (1.1.1.1 + 9.9.9.9). If CoreDNS
  is ever seen forwarding to a `0.250.x.x` address, that file is missing.
- **cloudflared must run `hostNetwork: true`** on this target. The CNI bridge
  mangles outbound TCP/7844 to the Cloudflare edge and the tunnel handshake
  gets RSTed — while plain `curl` from the same pod IP works fine. `--protocol
  http2` is set for the same class of reason (OrbStack's NAT eats outbound
  UDP/443).
- **kubelet's resolv-conf is pinned** to `/run/systemd/resolve/resolv.conf` in
  `roles/k3s/templates/config.yaml.j2`. Point it at `/etc/resolv.conf` and
  CoreDNS (which uses `dnsPolicy: Default`) forwards into its own 127.0.0.53
  stub and the loop plugin fatals on startup.
- **buildkit needs `network=host` in CI.** `jterrazz-actions/actions/docker-build`
  sets it so buildkit sees the runner's Tailscale resolver; without it
  `docker push registry.jterrazz.com/…` NXDOMAINs on the public CNAME chain.
- **Tailscale identity collision.** A VM destroyed without `tailscale logout`
  leaves its device behind; the replacement joins as `<hostname>-2` and MagicDNS
  stops resolving the canonical name, which breaks every private hostname. Fix
  in `docs/RUNBOOK.md`.
- **cert-manager loses its API connection after any k3s churn** — restart
  cert-manager, its webhook and cainjector together. This is the single most
  common cause of a stuck Certificate.
- **Helm adoption of existing objects** needs the annotations
  `meta.helm.sh/release-name` + `meta.helm.sh/release-namespace` and the label
  `app.kubernetes.io/managed-by=Helm`, or the install fails on conflict.
- **Immutable fields mean delete-and-recreate**: Deployment selectors, PV
  `hostPath.type`, PVC `spec.selector`. Changing a `pathSuffix` or a PV name in
  a `service.yaml` moves live data — the current paths are byte-identical to
  what the pre-chart manifests produced, on purpose.
- **Never chain `private-access` and `cluster-internal-access`.** Traefik ANDs
  chained ipAllowLists, so chaining allows strictly *less*, not more. The
  second is a strict superset of the first; a route picks one.
- **Use fully-qualified CRD names** with kubectl: `certificate.cert-manager.io`,
  `ingressroute.traefik.io`.

## Conventions that are not obvious from the tree

- **One directory per app** under `/var/lib/k8s-data`. A multi-component app
  nests its volumes (`librechat/{mongo,uploads}`,
  `openpanel/{postgres,clickhouse,redis}`) via `storage.<key>.pathSuffix`.
- **`ansible/inventories/group_vars/all.yml` is the config surface.** It sits
  next to the *inventory files*, which is the only place Ansible auto-loads it
  from here — a top-level `ansible/group_vars/` was adjacent to neither
  inventory nor playbook and was silently never loaded. Role `defaults/` is for
  values a human should not touch; `k3s_version` is single-sourced in
  group_vars and deliberately absent from `roles/k3s/defaults/` (which is why
  that file does not exist).
- **Namespaces**: `prod-<app>` / `next-<app>` / `staging-<app>` for apps,
  `platform-*` for infrastructure. All platform namespaces are declared in
  `kubernetes/cluster/namespaces.yaml` — never `kubectl create ns`.
- **Adding a private hostname** = two edits (the hand-synced pair above) plus
  `pulumi up`. An app that only needs a private surface should use the existing
  `*.internal.jterrazz.com` wildcard CNAME instead and needs no DNS work.
- **New public zone** = add it to both ClusterIssuers in
  `kubernetes/services/cert-manager/issuers.yaml`, add a Public Hostname in the
  Cloudflare Zero Trust tunnel UI (which auto-creates the CNAME), and set the
  zone's SSL mode to Full (Strict).
- **fail2ban and auditd are absent on purpose.** fail2ban guarded a public SSH
  port that does not exist (there is no public inbound path at all), and auditd
  needs `CAP_AUDIT_*` which the OrbStack hypervisor withholds. Do not "restore"
  them.
- **`deploy-platform.yaml` never runs the host layer.** The base/security/
  tailscale/k3s roles restart sshd or tailscaled and would kill the runner's own
  SSH session. Anything below the platform layer is `make deploy` from the
  laptop. Pulumi is out of scope for CI entirely — it drives `orbctl` on the Mac.

## Deployed services

Each has its own README with versions, data paths, secrets and gotchas:

- **LibreChat** — private AI chat at `chat.jterrazz.com`, `platform-ai`.
  [README](kubernetes/services/librechat/README.md)
- **OpenPanel** — product analytics; private dashboard at
  `openpanel.jterrazz.com`, public ingest at `analytics.jterrazz.com/api/track`,
  `platform-analytics`. [README](kubernetes/services/openpanel/README.md)
- **cloudflared** — the public-traffic tunnel, `platform-networking`.
  [README](kubernetes/services/cloudflared/README.md)
- Telemetry (`platform-telemetry`): Prometheus, Loki, Tempo, Grafana, OTel
  Collector, and **Alloy**, which tails every pod's stdout into Loki via the
  Kubernetes API — so `kubectl logs` is never the only copy.
- **Registry** — `registry.jterrazz.com`, `platform-registry`. Its IngressRoute
  uses `cluster-internal-access` because containerd's hairpin pull is sourced
  from a pod-CIDR/node address, not a tailnet IP.
- **gateway-intelligence** (an app-chart workload, deployed by its own repo)
  runs CLIProxyAPI with `api-keys: []`, which leaves its auth middleware
  allowing everything. The security boundary is **NetworkPolicy + private-only
  ingress**, not a bearer token; consumers pass the non-secret placeholder
  `gateway-noauth` only because the OpenAI/Anthropic SDKs require a non-empty
  string. There is no gateway API key in Infisical.

n8n and Portainer were **removed**. Their `/var/lib/k8s-data` directories are
kept (PVs were `Retain`); everything else — namespace, CNAME, manifests — is
gone. Do not resurrect them by accident when editing lists.

## App repos

Apps are deployed by `jterrazz/jterrazz-actions`, not from here. This repo only
owns the chart they render through. Working on an app repo:

- `application.yaml` schema, merge semantics, `platformServices`, storage:
  [kubernetes/charts/app/README.md](kubernetes/charts/app/README.md).
- Every app repo must expose `make build`, `make lint`, `make test` — the
  universal CI interface, regardless of toolchain.
- `tag:` is mandatory on every environment. Without it the workflow takes a
  legacy branch that deploys "staging" and leaves prod silently stale.
- Node/Next.js packaging traps (pnpm `--ignore-scripts`, `output: 'standalone'`,
  `mkdir -p public`) live with the shared workflows in `jterrazz-actions`.
- Renaming an app creates a *new* Helm release; the old one keeps running.
  `helm uninstall <env>-<old> -n <env>-<old> && kubectl delete ns <env>-<old>`.
