---
name: jterrazz-infra
description: Infrastructure and deployment for jterrazz projects — K3s, Helm, Traefik, CI/CD deploy. Use when deploying apps, configuring Kubernetes, adding domains, or troubleshooting infra.
---

# @jterrazz Infrastructure

Part of the @jterrazz ecosystem. Defines how all apps deploy.

Single-node k3s cluster, **dual-mode** — pick which stack you bring up:

- `jterrazz/production` → Hetzner cax21 VPS (live, has a public IPv4)
- `jterrazz/local`      → OrbStack VM on the dev Mac (no monthly bill)

Same Ansible playbooks and Helm charts on either target. CI-driven app
deploys via Helm. OrbStack is the current active prod (May 2026 swap).

## Stack

- **Host OS**: Debian 13 (trixie) on both targets — no dual-distro support
- **Cluster**: k3s (single-node, SQLite/kine datastore — no embedded etcd)
- **Ingress**: Traefik IngressRoutes
- **Public traffic**: cloudflared (outbound QUIC tunnel — no host port exposure)
- **Private access**: Tailscale (SSH + internal services)
- **TLS**: cert-manager + Let's Encrypt DNS-01 via Cloudflare
- **DNS**: Pulumi-managed Cloudflare records (private CNAMEs in `pulumi/src/dns.ts`) + cloudflared auto-DNS for public tunnel hostnames
- **Secrets**: Infisical — `/jterrazz-infrastructure` (+ per-service subfolders
  `grafana`, `n8n`, `portainer`, `librechat`, `openpanel`) for Ansible,
  `/jterrazz-ci` for app CI
- **Observability**: Grafana + Loki + Tempo + Prometheus + OTel Collector
- **Registry**: Private Docker registry at `registry.jterrazz.com`

## Deploying a new app

1. **App repo**: add `Dockerfile`, `.infrastructure/application.yaml`, `Makefile`, CI workflows (reuses `jterrazz/jterrazz-actions/.github/workflows/release-docker.yaml`)
2. **Infra repo (only if new public zone)**: add domain to `kubernetes/platform/cert-manager/issuers.yaml`
3. **GitHub secrets** on the app repo: `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET`
4. **Cloudflare** (new public domain): SSL mode Full (Strict); add a Public Hostname in the tunnel UI — it auto-creates the CNAME

## Application manifest

Full schema reference: `kubernetes/charts/app/README.md`.

```yaml
apiVersion: jterrazz.com/v1
kind: Application
metadata:
  name: {app-name}
spec:
  port: 3000
  resources:
    cpu: 100m
    memory: 256Mi       # >= 512Mi also gets an auto NODE_OPTIONS heap cap
  health:
    path: /health
environments:
  prod:
    tag: main           # deploy on every main push (image: latest)
    replicas: 1
    ingress:            # ALWAYS a list; `public` is required per entry
      - host: {domain}
        path: /
        public: true
```

`tag` strategies:

- `tag: main` → deploys on `main` push, image `latest`
- `tag: next` → deploys on `v*` tag push, image is that tag
- `tag: v1.2.3` (pinned) → deploys only on `workflow_dispatch`
- `secretsEnv: prod` on a non-standard env (like `next`) maps it to an
  existing Infisical env

Opt into in-cluster platform services with
`spec.platformServices: [otel-collector, gateway-intelligence]` — that one
line wires env vars, the egress NetworkPolicy and (where relevant) the
server-side ingress rule. Telemetry is opt-in: no declaration, no OTLP.

## Namespace convention

- `prod-{app-name}` for production
- `platform-*` for infrastructure services

## Domains

Managed zones: `jterrazz.com`, `clawrr.com`, `clawssify.com`, `sig.news`, `spwn.sh`.

A new **private** hostname needs two edits, hand-synced: `PRIVATE_HOSTS` in
`pulumi/src/dns.ts` (the public CNAME) **and** `private_hostnames` in
`ansible/playbooks/group_vars/all.yml` (the in-cluster CoreDNS override).
Apps exposing a private surface can instead use the existing
`*.internal.jterrazz.com` wildcard and need no DNS change at all.

## Key commands

```bash
# Provision + configure the active target
make deploy-local                    # OrbStack
make deploy                          # Hetzner

# SSH to the cluster
ssh root@jterrazz-infrastructure@orb                       # OrbStack
ssh -i /tmp/ssh_key root@$(cd pulumi && pulumi stack output sshHost --stack production)  # Hetzner

# Check an app
kubectl get pods -n prod-{app-name}
kubectl get ingressroute -n prod-{app-name}
kubectl get certificate -n prod-{app-name}

# Restart cert-manager after k3s churn
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# Trigger every app's CI to (re)deploy (post-rebuild bootstrap)
make apps

# Re-run one slice of the platform layer (17 tagged task files)
cd ansible && ansible-playbook playbooks/platform.yml \
  -i inventories/local/hosts.yml -e "@<extra-vars>" --tags telemetry

# Run the same checks CI runs (shellcheck, ansible-lint, helm lint)
make lint

# Tear down (data on the Mac stays for OrbStack)
make destroy-local
./scripts/deploy.sh production --destroy
```

## Never

- Never force push to main
- Never delete PVCs without backing up data
- Never skip Cloudflare Full (Strict) SSL mode
- Never commit secrets — use Infisical
- Never change an app-chart template without bumping `version:` in
  `kubernetes/charts/app/Chart.yaml` — the chart is consumed unversioned, so
  the change lands on every app's next deploy (and CI refuses to republish an
  existing version)
