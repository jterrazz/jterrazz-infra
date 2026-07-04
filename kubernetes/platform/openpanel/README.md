# OpenPanel (self-hosted product analytics)

Private dashboard on **`openpanel.jterrazz.com`** (Tailscale-only) + public
event ingest on **`analytics.jterrazz.com/api/track`** (cloudflared tunnel).
Namespace **`platform-analytics`**. Backend for the future `@jterrazz/analytics`
package.

## Architecture

```
 SDK (browser/server) ──► analytics.jterrazz.com/api/track ──► Cloudflare edge
        │                                                          │ tunnel
        ▼                                                          ▼
   op-api (/track only, public IngressRoute, stripPrefix /api) ◄─ Traefik
        │                                                          ▲
   me on tailnet ──► openpanel.jterrazz.com (private IngressRoute) ┘
        │  /api/*  → op-api (dashboard tRPC + realtime /api/live/*)
        │  /*      → op-dashboard (UI)
        ▼
   op-worker (BullMQ)   Postgres   ClickHouse   Redis
```

- **op-api** owns DB migrations (`pnpm -r run migrate:deploy` on boot: Prisma
  for Postgres + code-migrations for ClickHouse), then `pnpm start`.
- **op-worker** runs the BullMQ queues/crons (event/session/profile flushers).
- **op-dashboard** is the Next.js UI; SSR talks to op-api in-cluster via
  `API_URL_SSR=http://op-api:3000`.
- Public host routes **only** `/api/track`; everything else (dashboard,
  `/api/export`, `/api/live`, admin) is reachable only via the tailnet.

## Deployed versions (pinned)

| Component     | Image                                          |
|---------------|------------------------------------------------|
| op-api        | `lindesvard/openpanel-api:2.2`                 |
| op-worker     | `lindesvard/openpanel-worker:2.2`              |
| op-dashboard  | `lindesvard/openpanel-dashboard:2.2`           |
| ClickHouse    | `clickhouse/clickhouse-server:25.10.2.65`      |
| PostgreSQL    | `postgres:14-alpine`                           |
| Redis         | `redis:7.2.5-alpine`                           |
| (init) chown  | `busybox:1.36`                                 |

ClickHouse config (`clickhouse.yaml` ConfigMap) is upstream's self-hosting
config = the **issue #324 mitigation**: logger→console, all heavy system log
tables removed, plus a per-query `max_memory_usage` 1 GiB cap (issue #382). No
ClickHouse/Redis password (upstream design); the datastores are firewalled to
the namespace by `netpol.yaml`.

## Where the data lives

All three datastores use manual **hostPath PVs (`Retain`)** under
`/var/lib/k8s-data` → on OrbStack that's a symlink to
`/mnt/mac/Users/jterrazz.agent/.jterrazz-infra/data` (the Mac), so data
survives pod restarts, `kubectl delete`, helm/redeploys and `pulumi destroy`.

| PVC / PV               | Size  | Path (`/var/lib/k8s-data/...`) |
|------------------------|-------|--------------------------------|
| `openpanel-postgres`   | 3Gi   | `openpanel-postgres/pgdata`    |
| `openpanel-clickhouse` | 10Gi  | `openpanel-clickhouse`         |
| `openpanel-redis`      | 1Gi   | `openpanel-redis`              |

## Secrets & config

- **Secrets** — Infisical `/openpanel` (prod) → synced to Secret
  `openpanel-secrets` by the Infisical operator (read-only CI identity). Keys:
  `POSTGRES_PASSWORD`, `COOKIE_SECRET`, `DATABASE_URL`, `DATABASE_URL_DIRECT`.
  The project **clientId/clientSecret** (from the OpenPanel UI) should also be
  stored here once created.
- **Non-secret config** — ConfigMap `openpanel-config` (URLs, CORS origins,
  `SELF_HOSTED=true`, Postgres user/db). Add a new sending app's origin to
  `API_CORS_ORIGINS`.

## Common operations

```bash
export KUBECONFIG=./kubeconfig.yaml
kubectl get pods -n platform-analytics
kubectl get certificate -n platform-analytics
kubectl logs -n platform-analytics deploy/op-api --tail=50
# ClickHouse shell
kubectl exec -n platform-analytics deploy/op-clickhouse -- clickhouse-client --query "SELECT count() FROM openpanel.events"
```

### Upgrade OpenPanel

Bump the `2.2` tags for `op-api`/`op-worker`/`op-dashboard` in `apps.yaml`
(keep the three in lockstep), then redeploy (`kubectl apply -f apps.yaml` or
re-run the playbook). op-api runs any new migrations on boot — watch its logs
for "Migrations finished" before trusting the new version. Bump ClickHouse /
Postgres / Redis only deliberately (Postgres major bumps need a dump/restore,
not an in-place image swap). Check the OpenPanel self-hosting changelog for the
matching ClickHouse version.

### Disable public registration (after admin is created)

`apps.yaml` deploys with `ALLOW_REGISTRATION=true` so the first admin can be
created. Once done, set both occurrences to `"false"` and redeploy. Keep a
password login (OAuth-only + signup-disabled can lock you out — issue #363).

## Backup & restore

Data is `Retain` hostPath on the Mac; the simplest durable backup is a
file-level snapshot of the three dirs, but for consistency use the DB-native
tools below.

### PostgreSQL

```bash
# Backup
kubectl exec -n platform-analytics deploy/op-postgres -- \
  pg_dump -U openpanel -d openpanel --clean --if-exists > openpanel-pg-$(date +%F).sql
# Restore (into a running, empty op-postgres)
kubectl exec -i -n platform-analytics deploy/op-postgres -- \
  psql -U openpanel -d openpanel < openpanel-pg-YYYY-MM-DD.sql
```

### ClickHouse

Native BACKUP to a file inside the data volume, then copy it off the Mac:

```bash
kubectl exec -n platform-analytics deploy/op-clickhouse -- \
  clickhouse-client --query "BACKUP DATABASE openpanel TO File('/var/lib/clickhouse/backups/openpanel-$(date +%F).zip')"
# The file lands at /var/lib/k8s-data/openpanel-clickhouse/backups/ on the Mac.
# Restore: RESTORE DATABASE openpanel FROM File('...').
```

For a cold copy instead: scale `op-clickhouse` to 0, `tar` the
`openpanel-clickhouse/` dir on the Mac, scale back to 1.

### Redis

It's a durable BullMQ queue (AOF on), not a source of truth — losing it drops
only in-flight jobs. `appendonly.aof`/`dump.rdb` live in `openpanel-redis/` on
the Mac; a file snapshot is sufficient. No scheduled backup needed.

## Gotchas seen during deploy

- **cert-manager webhook** was down at first apply (`no endpoints available`) —
  the documented post-k3s-churn issue. Fix: `kubectl rollout restart -n
  platform-networking deploy/cert-manager deploy/cert-manager-webhook
  deploy/cert-manager-cainjector`, then re-apply `ingress.yaml`.
- **Public ingest needs a per-hostname tunnel route.** The cloudflared tunnel
  routes per-hostname (not a wildcard), so `analytics.jterrazz.com` needs a
  Public Hostname entry in the Zero Trust dashboard (Service: HTTPS →
  `traefik.kube-system.svc.cluster.local:443`, No TLS Verify ON). A bare CNAME
  is not enough (returns cloudflared 404).
- **ClickHouse hostPath perms**: the pod runs as uid 101; an init container
  chowns `/var/lib/clickhouse` because hostPath dirs are created root-owned.
- **Dashboard SSR resolves `openpanel.jterrazz.com` to Traefik's ClusterIP,
  in-cluster.** Image 2.2 has no `API_URL_SSR` override (it's only on `main`),
  so op-dashboard SSR fetches its own public URL from inside the pod. Resolving
  that to the node tailnet IP hairpins through the ServiceLB and times out (→
  `/onboarding` throws `[tRPC SSR Error] fetch failed`). Fix: the `coredns-custom`
  block maps `openpanel.jterrazz.com` → Traefik ClusterIP (separate hosts line
  from the other private hosts, which use the node tailnet IP). The browser is
  unaffected (public DNS → node tailnet IP). Revisit once a released image
  supports `API_URL_SSR=http://op-api:3000` — then this coredns special-case
  can be dropped.
