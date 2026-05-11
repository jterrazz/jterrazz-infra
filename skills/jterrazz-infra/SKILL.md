---
name: jterrazz-infra
description: Infrastructure for the @jterrazz ecosystem — defines how all apps deploy. K3s, Helm, Traefik, cert-manager. Activates when deploying, configuring Kubernetes, or troubleshooting.
---

# @jterrazz Infrastructure

Part of the @jterrazz ecosystem. Defines how all apps deploy.

Single-node k3s cluster on an OrbStack VM on the dev Mac. Pulumi stack
`jterrazz/local` is the only live stack — a `jterrazz/production`
Hetzner stack existed historically and was destroyed in May 2026 (see
the migration trail around git commit `b29f250`).

## Stack

- **Cluster**: k3s (single-node, embedded etcd)
- **Ingress**: Traefik IngressRoutes
- **Public traffic**: cloudflared (outbound QUIC tunnel — no host port exposure)
- **Private access**: Tailscale (SSH + internal services)
- **TLS**: cert-manager + Let's Encrypt DNS-01 via Cloudflare
- **DNS**: Pulumi-managed Cloudflare records (private CNAMEs in `pulumi/src/dns.ts`) + cloudflared auto-DNS for public tunnel hostnames
- **Secrets**: Infisical (`/jterrazz-infra` for Ansible, `/jterrazz-ci` for app CI)
- **Observability**: Grafana + Loki + Tempo + Prometheus + OTel Collector
- **Registry**: Private Docker registry at `registry.jterrazz.com`

## Deploying a new app

1. **App repo**: add `Dockerfile`, `.infrastructure/application.yaml`, `Makefile`, CI workflows (reuses `jterrazz/jterrazz-actions/.github/workflows/release-docker.yaml`)
2. **Infra repo (only if new public zone)**: add domain to `kubernetes/platform/cert-manager/issuers.yaml`
3. **GitHub secrets** on the app repo: `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET`
4. **Cloudflare** (new public domain): SSL mode Full (Strict); add a Public Hostname in the tunnel UI — it auto-creates the CNAME

## Application manifest

```yaml
apiVersion: jterrazz.com/v1
kind: Application
metadata:
  name: {app-name}
spec:
  port: 3000
  resources:
    cpu: 100m
    memory: 512Mi
  health:
    path: /
environments:
  prod:
    tag: main           # deploy on every main push (image: latest)
    replicas: 1
    ingress:
      host: {domain}
      path: /
      public: true
```

`tag` strategies:

- `tag: main` → deploys on `main` push, image `latest`
- `tag: next` → deploys on `v*` tag push, image is that tag
- `tag: v1.2.3` (pinned) → deploys only on `workflow_dispatch`

## Namespace convention

- `prod-{app-name}` for production
- `platform-*` for infrastructure services

## Domains

Managed zones: `jterrazz.com`, `clawrr.com`, `clawssify.com`, `sig.news`, `spwn.sh`.

## Key commands

```bash
# SSH to the cluster (via the OrbStack SSH proxy)
ssh root@jterrazz-infra@orb

# Check an app
kubectl get pods -n prod-{app-name}
kubectl get ingressroute -n prod-{app-name}
kubectl get certificate -n prod-{app-name}

# Restart cert-manager after k3s churn
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# Deploy from scratch (provision + configure)
make deploy

# Trigger every app's CI to (re)deploy (post-rebuild bootstrap)
make apps

# Tear down the OrbStack VM (data on the Mac stays)
make destroy
```

## Never

- Never force push to main
- Never delete PVCs without backing up data
- Never skip Cloudflare Full (Strict) SSL mode
- Never commit secrets — use Infisical
