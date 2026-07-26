# Runbook

The 2am document: where the secrets are, what to run when something is down,
and how to rebuild from nothing. Design lives in [../README.md](../README.md).

## Reaching the cluster

```bash
orb -m jterrazz-infrastructure -u root kubectl get pod -A   # most reliable
ssh root@jterrazz-infrastructure@orb                        # OrbStack SSH proxy
export KUBECONFIG=./kubeconfig.yaml                         # written by `make deploy`
```

`kubeconfig.yaml` is fetched by the k3s role at the end of every `make deploy`
and rewritten to the node's MagicDNS name — it only works from a tailnet
client. The `orb` SSH alias resolves only with `~/.orbstack/ssh/config` in play
(which is why `inventories/laptop.yml` passes it explicitly); `orb -m …` needs
nothing but OrbStack.

## Secrets inventory

### Infisical — project `jterrazz`, environment `prod`

Fetched at deploy time by `scripts/lib/infisical-vars.py` — the single
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
