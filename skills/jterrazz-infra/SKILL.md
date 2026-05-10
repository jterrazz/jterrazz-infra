---
name: jterrazz-infra
description: Infrastructure for the @jterrazz ecosystem — defines how all apps deploy. K3s, Helm, Traefik, cert-manager. Activates when deploying, configuring Kubernetes, or troubleshooting.
---

# @jterrazz Infrastructure

Part of the @jterrazz ecosystem. Defines how all apps deploy.

Single-node K3s cluster, deployable on Hetzner (`stack=production`) or
a local OrbStack VM (`stack=local`). Same playbooks and Helm charts on
either target. CI-driven app deploys via Helm.

## Stack

- **Cluster**: K3s (single-node, etcd embedded)
- **Ingress**: Traefik IngressRoutes
- **Public traffic**: cloudflared (outbound QUIC tunnel — no host port exposure)
- **Private access**: Tailscale (SSH + internal services)
- **TLS**: cert-manager + Let's Encrypt DNS-01 via Cloudflare
- **DNS**: Pulumi-managed Cloudflare records (private CNAMEs in `pulumi/src/dns.ts`) + cloudflared auto-DNS for public tunnel hostnames
- **Secrets**: Infisical
- **Observability**: Grafana + Loki + Tempo + Prometheus + OTel Collector
- **Registry**: Private Docker registry at `registry.jterrazz.com`

## Deploying a new app

1. **App repo**: add `Dockerfile`, `.infrastructure/application.yaml`, `Makefile`, CI workflows
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
    tag: main
    replicas: 1
    ingress:
      host: {domain}
      path: /
      public: true
```

## Namespace convention

- `prod-{app-name}` for production
- `platform-*` for infrastructure services

## Domains

Managed zones: `jterrazz.com`, `clawrr.com`, `clawssify.com`, `sig.news`, `spwn.sh`.

## Key commands

```bash
# SSH to Hetzner (key from Pulumi state)
ssh -i /tmp/ssh_key root@$(cd pulumi && pulumi stack output sshHost --stack production)

# SSH to OrbStack VM (via OrbStack proxy)
ssh -F ~/.orbstack/ssh/config root@jterrazz-infra@orb

# Check an app
kubectl get pods -n prod-{app-name}
kubectl get ingressroute -n prod-{app-name}

# Restart cert-manager after disruption
kubectl rollout restart -n platform-networking \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector

# Deploy from scratch (provision + configure)
./scripts/deploy.sh production    # Hetzner
./scripts/deploy.sh local         # OrbStack

# Mirror Hetzner's app releases onto OrbStack
./scripts/deploy-apps-local.sh
```

## Never

- Never force push to main
- Never delete PVCs without backing up data
- Never skip Cloudflare Full (Strict) SSL mode
- Never commit secrets — use Infisical
