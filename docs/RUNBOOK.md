# Runbook

The 2am document: where the secrets are, what to run when something is down,
and how to rebuild from nothing. Design lives in [../README.md](../README.md).

## Reaching the cluster

```bash
orb -m jterrazz-infrastructure -u root kubectl get pod -A   # most reliable
ssh root@jterrazz-infrastructure@orb                        # OrbStack SSH proxy
export KUBECONFIG=./kubeconfig.yaml                         # make kubeconfig
```

`kubeconfig.yaml` is fetched by the k3s role at the end of every `make deploy`
and rewritten to the node's MagicDNS name — it only works from a tailnet
client. `make kubeconfig` regenerates it (fetch + rewrite) without a deploy,
which is what `make diff` tells you to run when the file is missing or stale. The `orb` SSH alias resolves only with `~/.orbstack/ssh/config` in play
(which is why `inventories/laptop.yml` passes it explicitly); `orb -m …` needs
nothing but OrbStack.

## Secrets inventory

### Infisical — project `jterrazz`, environment `prod`

Fetched at deploy time by `scripts/infisical-vars.py` — the single
implementation, shared by `scripts/deploy.sh` and
`.github/workflows/deploy-platform.yaml`. Each path is fetched **explicitly**,
never recursively, so short key names can repeat across folders. A missing key
aborts the run; `roles/platform/tasks/preflight.yml` asserts the same set again
on the host.

| Path                               | Key                             | Ansible var                     | Scope         |
| ---------------------------------- | ------------------------------- | ------------------------------- | ------------- |
| `/jterrazz-infrastructure`         | `CLOUDFLARE_API_TOKEN`          | `cloudflare_api_token`          | site+platform |
|                                    | `CLOUDFLARE_TUNNEL_TOKEN`       | `cloudflare_tunnel_token`       | site+platform |
|                                    | `DOCKER_REGISTRY_PASSWORD`      | `registry_password`             | site+platform |
|                                    | `TAILSCALE_OAUTH_CLIENT_ID`     | `tailscale_oauth_client_id`     | site only     |
|                                    | `TAILSCALE_OAUTH_CLIENT_SECRET` | `tailscale_oauth_client_secret` | site only     |
| `/jterrazz-infrastructure/grafana` | `ADMIN_PASSWORD`                | `grafana_admin_password`        | site+platform |

`BACKUP_ENCRYPTION_KEY` also lives at `/jterrazz-infrastructure` but is **not**
in the table above: no deploy reads it, only `make backup` does, and it is
fetched directly rather than through the extra-vars file. See
[Backups](#backups).

The `platform` scope drops the Tailscale OAuth pair — `platform.yml` only reads
Tailscale *facts* off an already-joined node. `infisical_client_id` /
`infisical_client_secret` are the one exception to all of this: they come from
`.env` (or the GitHub secrets in CI) and are written into the extra-vars file,
because the in-cluster operator needs them and they cannot come from Infisical
itself.

Synced **into the cluster** by the operator from `InfisicalSecret` CRs — the
deploy script never sees these:

| Path                                       | Becomes Secret                | Keys                                                            |
| ------------------------------------------ | ----------------------------- | --------------------------------------------------------------- |
| `/jterrazz-infrastructure`                 | `cloudflared-secrets`         | `CLOUDFLARE_TUNNEL_TOKEN`                                        |
| `/jterrazz-infrastructure/librechat`       | `librechat-credentials-env`   | `CREDS_KEY`, `CREDS_IV`, `JWT_SECRET`, `JWT_REFRESH_SECRET`      |
| `/jterrazz-infrastructure/openpanel`       | `openpanel-secrets`           | `POSTGRES_PASSWORD`, `COOKIE_SECRET`, `DATABASE_URL`, `DATABASE_URL_DIRECT` |
| `/jterrazz-infrastructure/otel-collector`  | `otel-collector-secrets`      | `LANGFUSE_BASIC_AUTH`                                            |
| `/<app>/…`                                 | `<app>-secrets`               | whatever the app's `spec.secrets.env` lists                      |

There is no `/jterrazz-infrastructure/registry` folder: the registry's password
is `DOCKER_REGISTRY_PASSWORD` at the root path, bcrypt-hashed into the
`registry-auth` Secret by `roles/platform/tasks/registry.yml`.

### `/jterrazz-actions` — app CI

The default `infisical-secret-path` of `jterrazz-actions/actions/infra-connect`,
consumed by every app repo's pipeline: `DOCKER_REGISTRY_USERNAME`,
`DOCKER_REGISTRY_PASSWORD`, `TAILSCALE_OAUTH_CLIENT_ID`,
`TAILSCALE_OAUTH_CLIENT_SECRET`, `KUBECONFIG_BASE64`.

**`KUBECONFIG_BASE64` must be refreshed after every repave.** k3s regenerates
its CA on a fresh install, so the old client certificate stops authenticating
and every app deploy fails at `helm upgrade`. After `make deploy`:

```bash
base64 -i kubeconfig.yaml | pbcopy
```

then paste it into the Infisical UI at `/jterrazz-actions` (env `prod`). The
`.env` machine identity is **read-only** on that path — this step cannot be
scripted with the credentials this repo holds.

### GitHub secrets (repo `jterrazz/jterrazz-infrastructure`)

| Secret                    | Used by                                        |
| ------------------------- | ---------------------------------------------- |
| `INFISICAL_CLIENT_ID`     | `deploy-platform.yaml`, `publish-chart.yaml`   |
| `INFISICAL_CLIENT_SECRET` | same                                           |
| `CI_DEPLOY_SSH_PRIVATE`   | `deploy-platform.yaml` — SSH into the VM       |

The public half of that keypair is committed as `security_ci_deploy_pubkey` in
`ansible/roles/security/defaults/main.yml`; the `security` role installs it in
root's `authorized_keys`.

### GitHub secrets (every app repo)

`INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` — the same machine identity as
above, which `infra-connect` exchanges for `/jterrazz-actions`. One identity is
shared by CI, the cluster's Infisical operator and the local `.env`; rotating it
means updating every deploying repo. A repo that lacks them fails the *Release*
job at `Missing universal auth credentials` — after a green validate, so a first
deploy looks like it almost worked.

```bash
set -a; . ./.env; set +a
gh secret set INFISICAL_CLIENT_ID     -R jterrazz/<repo> --body "$INFISICAL_CLIENT_ID"
gh secret set INFISICAL_CLIENT_SECRET -R jterrazz/<repo> --body "$INFISICAL_CLIENT_SECRET"
```

### Local `.env` (gitignored, repo root)

```
PULUMI_ACCESS_TOKEN
INFISICAL_CLIENT_ID
INFISICAL_CLIENT_SECRET
```

## Security controls

Five things enforce the boundary. Each is here because a probe found a real
hole, and each names the check that proves it still holds.

| Control | Where | Verify |
| ------- | ----- | ------ |
| Peer-isolation firewall | `roles/security` -> `nft-guard.conf.j2`, unit `nft-guard.service` | from a second machine: `orb create debian:trixie t && orb -m t -u root bash -c 'echo > /dev/tcp/<node-ip>/6443'` must fail |
| Secrets encrypted at rest | `secrets-encryption: true` in the k3s config | `k3s secrets-encrypt status` -> Enabled; then grep a real Secret value in `state.db` and find nothing |
| API audit log | `audit-policy.yaml.j2`, Metadata level | `wc -l <data-dir>/server/logs/audit.log` grows |
| Pod Security Admission | `cluster/namespaces.yaml` | `kubectl get ns -L pod-security.kubernetes.io/enforce` |
| kube-system NetworkPolicy | `cluster/network-policies/kube-system.yaml` | DNS from a fresh pod, `kubectl top nodes`, and a tailnet curl (see below) |

### The two things that will bite

**OrbStack machines are not isolated from each other by default.** Every one
mounts every other's rootfs at `/mnt/machines/<name>/` and reads it **as
root** — so file permissions are irrelevant there, `0600` included. A plain
`orb create` machine can read this cluster's data directory and its
kubeconfig. Create dev machines with `--isolated` (no `/mnt/machines` at all)
and add `--isolate-network` for the host. Note that `--isolate-network` does
NOT block peer machines despite the docs, which is why the nftables guard
exists. `--isolated` is impossible for a k3s node: the unprivileged userns
refuses kubelet's `noswap` tmpfs and k3s restart-loops without ever serving.

**Test the tailnet path, not just the public one.** cloudflared dials
Traefik's ClusterIP directly, so a kube-system policy can break every tailnet
client while smoke stays 11/11 and the cluster looks green. CI is a tailnet
client — it pulls from the registry — so this surfaces as a failed deploy:

```bash
curl -sk -H "Host: registry.internal.jterrazz.com" https://<tailnet-ip>/v2/   # 401
curl -sk -H "Host: grafana.internal.jterrazz.com" https://<tailnet-ip>/api/health  # 200
```

## Troubleshooting

```bash
kubectl get pod -A | grep -v Running ; helm list -A ; kubectl get certificate -A

# cert-manager after any k3s churn (webhook + cainjector lose the API)
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# Cloudflare tunnel: connected? serving?
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E 'Registered|edge'
POD_IP=$(kubectl get pod -n platform-networking -l app.kubernetes.io/name=cloudflared \
  -o jsonpath='{.items[0].status.podIP}')
curl -s "http://$POD_IP:2000/metrics" | grep '^cloudflared_tunnel_total_requests '

# Every pod's stdout is in VictoriaLogs, shipped by the otel-collector's
# filelog receiver (it tails /var/log/pods off a hostPath; there is no separate
# log agent any more). Query in Grafana's "VictoriaLogs" datasource — the
# language is LogsQL, NOT LogQL:
#   {k8s.namespace.name="platform-analytics"}
#   {app="op-api"} error
#   {app="op-api"} | stats by (k8s.container.name) count()
# The four stream fields are k8s.namespace.name / k8s.pod.name /
# k8s.container.name / app — pinned by the VL-Stream-Fields header on the
# collector's exporter. Everything else (node, deployment, pod uid, file path)
# is a regular field: filter on it, just do not expect it to narrow the scan.
#
# LogQL -> LogsQL, the three that bite: `|=` "x" is just a bare word or
# "quoted phrase"; `| json` is unnecessary (JSON bodies are parsed on ingest);
# `| line_format` / `sum by (...) (rate(...))` become the `format` and `stats`
# pipes. Full mapping:
#   https://docs.victoriametrics.com/victorialogs/logsql/
#
# No logs arriving? Check the collector, not a DaemonSet:
kubectl logs -n platform-telemetry deploy/otel-collector | grep -iE 'permission denied|filelog|k8sattributes'
kubectl get clusterrole otel-collector -o yaml   # pods+namespaces+replicasets read

# Registry DNS is the usual suspect for a fleet-wide ImagePullBackOff.
# On the node: must resolve to a 100.x tailnet IP.
getent hosts registry.internal.jterrazz.com ; tailscale status
```

**Tailscale identity collision.** If a VM with the same hostname was destroyed
without `tailscale logout`, the new one joins as `jterrazz-infrastructure-2`,
MagicDNS stops resolving the canonical name, and every private hostname breaks.
Delete the stale device in the Tailscale admin console, or rename via the API:

```bash
curl -H "Authorization: Bearer $TS_API_KEY" -X POST \
  "https://api.tailscale.com/api/v2/device/<id>/name" \
  -d '{"name":"jterrazz-infrastructure"}'
```

A node that comes back **logged out** after a reboot self-heals through
`tailscale-autoauth.service` (installed by the `tailscale` role). If it did
not, check that unit's journal first — the failure chain is registry NXDOMAIN
→ ImagePullBackOff on every app pod → Cloudflare 503 on every public hostname.

## Repaving the cluster

The sequence as executed on 2026-07-25 (Debian 13 migration):

```bash
# 1. Stop the workloads. `systemctl stop k3s` does NOT stop running
#    containers — they keep writing to /var/lib/k8s-data mid-backup.
orb -m jterrazz-infrastructure -u root /usr/local/bin/k3s-killall.sh

# 2. Back up the data directory (it lives on the Mac, so tar it there).
tar -czf ~/k8s-data-$(date +%F).tar.gz -C ~/.jterrazz-infrastructure data

# 3. Repave. `make destroy` deletes the VM only; the Mac-side data dir stays.
make destroy
make deploy

# 4. Refresh KUBECONFIG_BASE64 in Infisical /jterrazz-actions (see above) —
#    nothing else will deploy until this is done.

# 5. Rebuild + redeploy every app onto the new (empty) registry.
make redeploy-apps
```

Step 5 is required, not optional: registry blobs are hostPath and do survive,
but no app's Helm release does — the cluster is new. The script staggers the
six dispatches by 20s so six simultaneous Docker builds don't compete for RAM
on one node. Post-repave verification items (uid pins, remaining egress
narrowing) live in the pinned GitHub issue. Two former items are closed:
every namespace in `kubernetes/cluster/namespaces.yaml` now has a
NetworkPolicy file, and the OpenPanel `API_URL_SSR` question is settled — the
published dashboard image cannot honour it, evidence in
`kubernetes/services/openpanel/config.yaml`, so the CoreDNS→Traefik mapping for
`openpanel.internal.jterrazz.com` stays load-bearing.

## Backups

`make backup` writes an AES-256 archive of `~/.jterrazz-infrastructure/data` to
`~/.jterrazz-infrastructure/backups/` and verifies it by decrypting it back —
an archive nobody has opened is a guess, not a backup.

`make backup ARGS=--consistent` runs `k3s-killall.sh` first. Without it the
databases are captured mid-write: `systemctl stop k3s` does NOT stop the
containers, which is how two earlier backups came out torn.

The passphrase is `BACKUP_ENCRYPTION_KEY` in Infisical at
`/jterrazz-infrastructure` (env `prod`). Nothing local is needed: with
`INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` in `.env`, `make backup`
fetches it itself. It is deliberately NOT routed through
`scripts/infisical-vars.py`, which writes the deploy extra-vars onto the node —
this key has no business there.
It is **permanent**: rotating it does not re-encrypt existing archives, it
orphans them, and losing it loses every archive it ever produced. That is the
whole point — a copy on Time Machine, an external disk or a future machine is
useless without it, and fully restorable with it.

Why encryption and not `chmod`: the data tree has to stay traversable by
"other". The pods write through virtiofs as uids 70, 101, 472, 999 and 1000,
so dropping world-execute on the directory breaks Postgres, ClickHouse,
Grafana, Mongo and signews-api at once. Permissions cannot protect this tree;
encrypting what leaves it can.

## Restoring from backup

All persistent state is one directory: `/var/lib/k8s-data` on the node, which
is a symlink to `~/.jterrazz-infrastructure/data` on the Mac. Restore = stop
the consumer, replace the directory, start it again.

```
data/
├── grafana/                    grafana.db — users, API keys, alert state
├── victoria-metrics/           metrics (30d)
├── victoria-logs/              logs (90d)
├── victoria-traces/            traces (720h)
├── registry/                   Docker registry blobs
├── librechat/                  mongo/ + uploads/
├── openpanel/                  postgres/ + clickhouse/ + redis/
├── signews-api-{prod,next,staging}/, gateway-intelligence-prod/
│                               per-app volumes from the app chart
├── prometheus/  loki/  tempo/  ORPHANED — replaced by the three above
├── n8n/                        ORPHANED — n8n was removed
└── portainer/                  ORPHANED — Portainer was removed
```

The orphans have no workload and no PV any more: the services were deleted
(namespaces, CNAMEs and manifests are gone), but the PVs were `Retain`, so any
of them can be resurrected from git history plus that directory. The
prometheus/loki/tempo trio is the ONLY copy of pre-migration metrics and logs —
nothing reads it, and no Victoria component can. Keep it until the new stores
have accumulated a window worth trusting, then delete it by hand.

For consistent database dumps rather than a file copy, see the backup sections
of [openpanel](../kubernetes/services/openpanel/README.md#backup--restore) and
[librechat](../kubernetes/services/librechat/README.md).

## Rotating credentials

| What                              | How                                                                                                   |
| --------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Any Infisical-held secret         | Change it in the Infisical UI, then `make deploy-platform`. No `InfisicalSecret` in this repo sets `spec.syncConfig`, so every one resyncs on the **operator's own default interval**; `kubectl delete pod -n platform-secrets -l control-plane=controller-manager` forces it now. Note the resync only updates the **Secret** — a consumer that reads it as `env` still needs a rollout restart. |
| `CLOUDFLARE_TUNNEL_TOKEN`         | New connector token in Zero Trust → store at `/jterrazz-infrastructure` → wait for the resync (or force it as above), then `kubectl rollout restart deploy/cloudflared -n platform-networking` (it reads `TUNNEL_TOKEN` once, at startup). |
| `DOCKER_REGISTRY_PASSWORD`        | Rotate in Infisical **and** at `/jterrazz-actions`, then `make deploy-platform` to regenerate `registry-auth`. |
| CI deploy SSH key                 | `ssh-keygen -t ed25519`, paste the pubkey into `security_ci_deploy_pubkey`, `gh secret set CI_DEPLOY_SSH_PRIVATE -R jterrazz/jterrazz-infrastructure`, then `make deploy` to roll it onto the VM. |
| `KUBECONFIG_BASE64`               | Regenerated by every repave — see the procedure above.                                                  |
| `cloudflare:apiToken` (Pulumi)    | `cd pulumi && pulumi config set --secret cloudflare:apiToken <new>`.                                     |

## One-time migrations pending

Everything in this section belongs to the 2026-07-26 dependency sweep and is
**executed once, then this whole section is deleted**. Order matters: 1 gates
everything else.

Take a fresh backup first — every rollback below assumes it exists:

```bash
orb -m jterrazz-infrastructure -u root /usr/local/bin/k3s-killall.sh
tar -czf ~/k8s-data-$(date +%F)-preupgrade.tar.gz -C ~/.jterrazz-infrastructure data
```

### 1. k3s v1.35.1+k3s1 → v1.36.2+k3s1

k3s 1.36.2 bundles Traefik chart **v40.1.0**, two breaking majors on from the
v38 that 1.35.1 bundled. `kubernetes/cluster/traefik/traefik-config.yaml` **is
already written against v40** — this table is the key mapping it encodes, kept
because the silent half below is what makes the upgrade dangerous. See also the
note above `k3s_version` in `ansible/inventories/group_vars/all.yml`.

| v38 key                          | v40 key (what the file uses now)                      |
| -------------------------------- | ----------------------------------------------------- |
| `service.type`                   | `service.spec.type`                                    |
| `service.loadBalancerSourceRanges` | `service.spec.loadBalancerSourceRanges`              |
| `ports.websecure.middlewares`    | `ports.websecure.http.middlewares`                     |
| `ports.web.redirectTo.port`      | `ports.web.http.redirections.entryPoint.{to,scheme}`   |

The `ports.*` keys **hard-fail** the `helm-install-traefik` job (each port entry
is `additionalProperties: false`). The `service.*` keys **fail silently** —
they render nothing and the tailnet-only restriction on host ports 80/443
simply disappears. Fixing only the loud ones looks like success.

**Downtime:** control plane down tens of seconds (containers keep running),
plus an ingress blip while the Helm controller redeploys Traefik.

**Verify — all three, the last one is the security gate:**

```bash
orb -m jterrazz-infrastructure -u root k3s --version              # v1.36.2+k3s1
kubectl -n kube-system get job helm-install-traefik -o jsonpath='{.status.succeeded}'
kubectl -n kube-system get svc traefik \
  -o jsonpath='{.spec.loadBalancerSourceRanges}'                  # MUST be non-empty
```

If that last command prints nothing, Traefik's host ports are open to anything
that can reach the node — treat it as an incident, not a warning.

**Rollback:** re-run the k3s installer pinned to the old version, then revert
the traefik-config change.
`INSTALL_K3S_VERSION=v1.35.1+k3s1 sh /tmp/k3s-install.sh`

### 2. Telemetry: Prometheus + Loki + Tempo + Alloy → the VictoriaMetrics family

**This is a replacement, not an upgrade.** Four Helm releases are deleted and
five appear; the new stores start EMPTY on new hostPath directories, and no
history is carried across (no Victoria component reads a TSDB, a Loki chunk
store or a Tempo block). Grafana keeps its datasource UIDs, so dashboards and
app-shipped alert rules need no edits.

| Was                                | Is                                                  |
| ---------------------------------- | --------------------------------------------------- |
| `prometheus` (+ 2 subcharts)       | `victoria-metrics` (vm/victoria-metrics-single 0.43.0, app v1.148.0) |
| ↳ its kube-state-metrics subchart  | `kube-state-metrics` (standalone, 8.0.0)            |
| ↳ its node-exporter subchart       | `node-exporter` (standalone, 4.56.1)                |
| `loki`                             | `victoria-logs` (vm/victoria-logs-single 0.13.9, app v1.52.0) |
| `tempo`                            | `victoria-traces` (vm/victoria-traces-single 0.1.10, app v0.9.4) |
| `alloy`                            | *nothing* — folded into the otel-collector's `filelog` receiver |

**VictoriaTraces is pre-1.0, accepted knowingly.** Trace history is the one
stream this cluster can afford to lose. That tolerance does not extend to the
other two, which are 1.x.

**Order matters. `make deploy-platform` installs the new releases but does NOT
uninstall the old ones** — Helm only manages releases it is told about. Do the
teardown first, or two metric collectors scrape the same targets and two log
paths write the same lines.

```bash
# 0. Back up. This is the last moment the old data is reachable in place.
orb -m jterrazz-infrastructure -u root /usr/local/bin/k3s-killall.sh
tar -czf ~/k8s-data-$(date +%F)-pre-victoria.tar.gz -C ~/.jterrazz-infrastructure data
orb -m jterrazz-infrastructure -u root systemctl start k3s

# 1. Stop the old writers/scrapers BEFORE uninstalling, so nothing is mid-write.
kubectl -n platform-telemetry scale --replicas=0 \
  deploy/prometheus-server sts/loki sts/tempo
kubectl -n platform-telemetry delete ds alloy --ignore-not-found

# 2. Uninstall the four upstream releases and their service-chart siblings.
#    `helm uninstall` leaves the PVs (Retain) and the hostPath dirs alone.
helm uninstall -n platform-telemetry prometheus loki tempo alloy
helm uninstall -n platform-telemetry prometheus-platform loki-platform tempo-platform

# 3. Delete the PVCs and PVs those left behind. REQUIRED: the PVs are Retain,
#    so they linger in state `Released` and are never rebound — but their names
#    do not collide with the new ones, so this is hygiene, not a blocker.
kubectl -n platform-telemetry delete pvc \
  prometheus-data storage-loki-0 storage-tempo-0 --ignore-not-found
kubectl delete pv prometheus-data loki-data tempo-data --ignore-not-found

# 4. Confirm the namespace is empty of the old stack, then deploy.
kubectl -n platform-telemetry get all
make deploy-platform
```

**Expected first-boot behaviour, none of which is a fault:**

- All three stores come up empty. Dashboards are blank until the first scrape
  lands (~1 min for metrics) — the panels are not broken.
- `/var/lib/k8s-data/{victoria-metrics,victoria-logs,victoria-traces}` are
  created fresh. VictoriaLogs and VictoriaTraces run as uid 1000 and each has a
  `fix-permissions` initContainer, because `fsGroup` is not applied to hostPath
  volumes.
- The otel-collector pod now runs as **root** and mounts the node's `/var/log`
  read-only. That is what lets it read containerd's container log files; a
  non-root collector starts fine and ships nothing.
- Grafana pulls the `victoriametrics-logs-datasource` plugin from grafana.com on
  every pod start. First start is slower; no egress, no logs datasource.
- The `Prometheus` / `Loki` / `Tempo` datasource rows are deleted and re-created
  as `VictoriaMetrics` / `VictoriaLogs` / `VictoriaTraces` **on the same UIDs**.
  Grafana's provisioner deletes by name before it inserts, which is the only
  reason reusing the uids works.

**Verify — the last two are the ones that actually prove it:**

```bash
helm list -n platform-telemetry     # victoria-{metrics,logs,traces}, kube-state-metrics,
                                    # node-exporter, otel-collector, grafana. No prometheus/loki/tempo/alloy.
kubectl -n platform-telemetry get pod          # all Running, no restarts
kubectl -n platform-telemetry logs deploy/otel-collector | grep -i 'permission denied'   # must be empty

# Scrape targets: kube-state-metrics and node-exporter must BOTH be up, or half
# of both dashboards is silently blank.
kubectl -n platform-telemetry exec sts/victoria-metrics -- \
  wget -qO- 'http://localhost:8428/api/v1/query?query=up' | grep -c kube-state-metrics

# Pod logs actually arriving, with the four stream fields:
kubectl -n platform-telemetry exec sts/victoria-logs -- \
  wget -qO- --post-data='query={app!=""} | stats by (k8s.namespace.name) count()' \
  'http://localhost:9428/select/logsql/query'
```

**Rollback:** `helm uninstall` the five new releases, delete their PVs/PVCs,
`git revert`, `make deploy-platform`. The old hostPath directories are still
there, so Prometheus/Loki/Tempo come back with their history intact — which is
exactly why step 3 above does not delete `data/{prometheus,loki,tempo}`.

### 3. Redis 7.2.5 → 7.4.9 (OpenPanel queue)

Minor bump inside the line OpenPanel pins. Verified locally to start under this
manifest's exact uid (`999:1000`) and args (`--appendonly yes`).

**One-way:** 7.4 writes an AOF/RDB that 7.2 will not read. Acceptable because
this volume is a rebuildable BullMQ queue, not a source of truth — the worst
case is losing in-flight jobs.

**Downtime:** seconds. `strategy: Recreate`, so the old pod is gone before the
new one starts; op-api/op-worker reconnect on their own.

**Verify:**

```bash
kubectl exec -n platform-analytics deploy/op-redis -- redis-cli INFO server | grep redis_version
kubectl exec -n platform-analytics deploy/op-redis -- redis-cli CONFIG GET appendonly   # yes
kubectl logs -n platform-analytics deploy/op-worker --tail=30   # no reconnect loop
```

**Rollback:** set the image back to `redis:7.2.5-alpine` and delete
`openpanel/redis/appendonlydir` + `dump.rdb` on the Mac (a 7.4 AOF blocks a 7.2
start). Queue contents are lost; nothing else is.

### 4. Registry 2.8 → 3.1.1

On-disk layout is unchanged (`storagePathVersion` is still `v2`), so
`/var/lib/registry` is read in place with no migration. Safe here specifically
because the Deployment configures everything through `REGISTRY_*` env vars and
mounts no config file — 3.0 moved the default config path to
`/etc/distribution/config.yml`, and a file mounted at the old path would be
ignored without error.

**Downtime:** one pod restart; pushes/pulls fail for a few seconds.

**Verify:**

```bash
kubectl -n platform-registry logs deploy/registry | head -5     # version 3.x
curl -sSf -u deploy:$PW https://registry.internal.jterrazz.com/v2/_catalog
# then confirm a real pull still works
kubectl -n prod-signews-api rollout restart deploy/signews-api
```

**Rollback:** image back to `registry:2.8`. Blobs written by 3.1.1 remain
readable by 2.8 (same layout).

### Deliberately NOT migrated — do not re-open without new evidence

| Component  | Held at        | Why                                                                                                                                                                                              |
| ---------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| MongoDB    | `7.0`          | LibreChat does support 8 (`mongo:8.0.20` in its compose at the v0.8.7 tag) but **8.0 will not boot on this host**: SERVER-121912 blocks MongoDB on Linux kernel ≥ 6.19 and this node runs OrbStack's 7.0.11 kernel. Measured: `mongo:8.0` exits 1, `mongo:7.0` and `mongo:8.2` start. 8.2 is outside the line LibreChat cites, and the FCV bump is irreversible. Retest when an 8.0.x carries the fix. |
| PostgreSQL | `14-alpine`    | OpenPanel pins `postgres:14-alpine` in both compose files and documents no other version. Only Prisma (the ORM, not the app) reaches higher. **EOL 2026-11-12 — schedule this separately.**          |
| ClickHouse | `25.10.2.65`   | Already exactly what OpenPanel's self-hosting compose pins. Newer is uncited and 26.5/26.7 change event-ingest datetime parsing and reject the AggregatingMergeTree schema shape OpenPanel uses.     |
| Redis 8.x  | staying on 7.x | Neither OpenPanel nor BullMQ publishes a Redis 8 support statement.                                                                                                                                |

#### If the PostgreSQL 14 → 17 migration is later approved

Not scheduled — recorded here so it is not re-derived under time pressure. DB is
~26 MB. **Dump with the *newer* server's `pg_dumpall`**, which is what the
PostgreSQL docs require across majors.

```bash
# 1. Stop the writers (NOT postgres itself — it must serve the dump).
kubectl scale -n platform-analytics --replicas=0 deploy/op-api deploy/op-worker deploy/op-dashboard

# 2. Dump using a throwaway PG 17 client against the live PG 14 service.
kubectl run pgdump-17 -n platform-analytics --rm -i --restart=Never \
  --image=postgres:17-alpine --env PGPASSWORD="$POSTGRES_PASSWORD" -- \
  pg_dumpall -h op-postgres -U openpanel --quote-all-identifiers > openpanel-all-$(date +%F).sql
test -s openpanel-all-*.sql && grep -c "CREATE DATABASE" openpanel-all-*.sql   # sanity

# 3. Stop postgres and MOVE the old data dir aside — never delete it; it is the
#    rollback. A PG 17 server cannot read a PG 14 cluster directory.
kubectl scale -n platform-analytics --replicas=0 deploy/op-postgres
#    On the Mac (/var/lib/k8s-data is a symlink to ~/.jterrazz-infrastructure/data):
mv ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata \
   ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata-pg14-$(date +%F)
mkdir -p ~/.jterrazz-infrastructure/data/openpanel/postgres/pgdata

# 4. Swap the image to postgres:17-alpine in kubernetes/services/openpanel/postgres.yaml.
#    uid/gid 70:70 is correct for the alpine variant on 17 as well; the
#    fix-perms initContainer chowns the new empty dir. PGDATA stays
#    /var/lib/postgresql/data/pgdata so initdb never sees lost+found.
kubectl apply -f kubernetes/services/openpanel/postgres.yaml
kubectl scale -n platform-analytics --replicas=1 deploy/op-postgres
kubectl rollout status -n platform-analytics deploy/op-postgres --timeout=180s

# 5. Restore, then bring the app back. op-api runs Prisma migrations on boot.
kubectl exec -i -n platform-analytics deploy/op-postgres -- \
  psql -X -U openpanel -d postgres < openpanel-all-YYYY-MM-DD.sql
kubectl scale -n platform-analytics --replicas=1 deploy/op-api deploy/op-worker deploy/op-dashboard
kubectl rollout status -n platform-analytics deploy/op-api --timeout=300s
```

**Downtime:** dashboard + ingest down for the whole procedure — budget 15-20
min at this data size.

**Verify:** `kubectl exec -n platform-analytics deploy/op-postgres -- psql -U openpanel -d openpanel -c '\dt'`
lists the OpenPanel tables; the dashboard loads projects; a test event reaches
`analytics.jterrazz.com/api/track` and appears in ClickHouse.

**Rollback:** scale everything to 0, `mv` the `pgdata-pg14-*` directory back to
`pgdata`, restore the `postgres:14-alpine` image, scale up. The old cluster
directory is untouched, which is the entire reason step 3 moves rather than
deletes it.
