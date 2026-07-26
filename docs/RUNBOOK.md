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

### Local `.env` (gitignored, repo root)

```
PULUMI_ACCESS_TOKEN
INFISICAL_CLIENT_ID
INFISICAL_CLIENT_SECRET
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

# Every pod's stdout is in Loki, shipped by Alloy. Query in Grafana:
#   {namespace="platform-analytics"}   {app="op-api"}
kubectl logs -n platform-telemetry ds/alloy | grep -i forbidden   # RBAC check

# Registry DNS is the usual suspect for a fleet-wide ImagePullBackOff.
# On the node: must resolve to a 100.x tailnet IP.
getent hosts registry.jterrazz.com ; tailscale status
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
on one node. Post-repave verification items (network-policy tightening, the
OpenPanel `API_URL_SSR` test, uid pins) live in the pinned GitHub issue.

## Restoring from backup

All persistent state is one directory: `/var/lib/k8s-data` on the node, which
is a symlink to `~/.jterrazz-infrastructure/data` on the Mac. Restore = stop
the consumer, replace the directory, start it again.

```
data/
├── grafana/                    grafana.db — users, API keys, alert state
├── prometheus/  loki/  tempo/  metrics, logs (90d), traces
├── registry/                   Docker registry blobs
├── librechat/                  mongo/ + uploads/
├── openpanel/                  postgres/ + clickhouse/ + redis/
├── signews-api-{prod,next,staging}/, gateway-intelligence-prod/
│                               per-app volumes from the app chart
├── n8n/                        ORPHANED — n8n was removed
└── portainer/                  ORPHANED — Portainer was removed
```

The last two have no workload and no PV any more: the services were deleted
(their namespaces are gone from `kubernetes/cluster/namespaces.yaml`, their
CNAMEs from `pulumi/src/dns.ts`), but the PVs were `Retain`, so either can be
resurrected from git history plus that directory.

For consistent database dumps rather than a file copy, see the backup sections
of [openpanel](../kubernetes/services/openpanel/README.md#backup--restore) and
[librechat](../kubernetes/services/librechat/README.md).

## Rotating credentials

| What                              | How                                                                                                   |
| --------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Any Infisical-held secret         | Change it in the Infisical UI, then `make deploy-platform`. In-cluster `InfisicalSecret`s resync in 60s. |
| `CLOUDFLARE_TUNNEL_TOKEN`         | New connector token in Zero Trust → store at `/jterrazz-infrastructure` → resyncs within a minute.       |
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

### 1. k3s v1.35.1+k3s1 → v1.36.2+k3s1 — BLOCKED until Traefik values are migrated

`kubernetes/cluster/traefik/traefik-config.yaml` is still written against
Traefik chart **v38**; k3s 1.36.2 bundles **v40.1.0**, which crosses two
breaking chart majors. Migrate that file *in the same change* — the full
before/after and the reasoning are in the boxed comment above `k3s_version` in
`ansible/inventories/group_vars/all.yml`. Summary:

| v38 key (current)                | v40 key (required)                                    |
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

### 2. Telemetry charts move to the `grafana-community` repo

Grafana relocated its OSS charts in Jan 2026 and renumbered them; `grafana/loki`
7.x in the **old** repo is Grafana Enterprise Logs, so this is a repo change,
not just a version bump. `make deploy-platform` adds the new repo and applies
all three. Release names are unchanged, so Helm upgrades in place.

| Release  | Old (repo/chart)      | New (repo/chart)                   | App               |
| -------- | --------------------- | ---------------------------------- | ----------------- |
| loki     | grafana/loki 6.53.0   | grafana-community/loki 18.5.4      | 3.6.5 → 3.7.4     |
| tempo    | grafana/tempo 1.24.4  | grafana-community/tempo 2.2.3      | 2.9.0 → 2.10.7    |
| grafana  | grafana/grafana 10.5.15 | grafana-community/grafana 12.8.0 | 12.3.1 → 13.1.1   |

**Grafana is the one-way door here:** Grafana 13 migrates `grafana.db` (sqlite)
on first boot and a 12.x binary will not read the migrated file afterwards.
The pre-upgrade tar is the only way back.

**Expected downtime:** one pod restart each, under a minute per release.

**Also lands with this:** the `loki-canary` DaemonSet disappears. It was never
meant to run — `lokiCanary.enabled` was nested under `monitoring:` where the
chart never read it — and Helm removes it automatically on upgrade.

**Verify:**

```bash
helm list -n platform-telemetry           # loki 18.5.4, tempo 2.2.3, grafana 12.8.0
kubectl get pod -n platform-telemetry     # no loki-canary; all Running
kubectl -n platform-telemetry logs deploy/grafana | grep -i "migrat"
# Grafana UI: dashboards, alert rules and all three datasources still resolve.
```

**Rollback:** restore `data/grafana` from the tar, then pin the previous chart
versions in `platform_chart_versions` **and** repoint the three `helm upgrade`
lines in `roles/platform/tasks/telemetry.yml` back at `grafana/`.

### 3. Prometheus — the chown initContainer starts running for the first time

`server.initContainers` was never a key this chart has (checked 28.13.0 and
29.19.0), so the `chown -R 65534:65534 /data` never ran. It is now
`server.extraInitContainers` and will actually execute. On the existing volume
this is a no-op (the data dir is already correctly owned, which is why nothing
ever broke); it matters on the next repave, where the hostPath dir is created
root-owned.

**Downtime:** one pod restart. The chown walks the whole TSDB dir — metadata
only, expect seconds.

**Verify:**

```bash
kubectl -n platform-telemetry get pod -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'   # fix-permissions
kubectl -n platform-telemetry logs deploy/prometheus-server -c prometheus | tail
```

### 4. Redis 7.2.5 → 7.4.9 (OpenPanel queue)

Minor bump inside the line OpenPanel pins. Verified locally to start under this
manifest's exact uid (`999:1000`) and args (`--maxmemory-policy noeviction
--appendonly yes`).

**One-way:** 7.4 writes an AOF/RDB that 7.2 will not read. Acceptable because
this volume is a rebuildable BullMQ queue, not a source of truth — the worst
case is losing in-flight jobs.

**Downtime:** seconds. `strategy: Recreate`, so the old pod is gone before the
new one starts; op-api/op-worker reconnect on their own.

**Verify:**

```bash
kubectl exec -n platform-analytics deploy/op-redis -- redis-cli INFO server | grep redis_version
kubectl exec -n platform-analytics deploy/op-redis -- redis-cli CONFIG GET maxmemory-policy
kubectl logs -n platform-analytics deploy/op-worker --tail=30   # no reconnect loop
```

**Rollback:** set the image back to `redis:7.2.5-alpine` and delete
`openpanel/redis/appendonlydir` + `dump.rdb` on the Mac (a 7.4 AOF blocks a 7.2
start). Queue contents are lost; nothing else is.

### 5. Registry 2.8 → 3.1.1

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
curl -sSf -u deploy:$PW https://registry.jterrazz.com/v2/_catalog
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
