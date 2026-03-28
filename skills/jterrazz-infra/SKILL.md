---
name: jterrazz-infra
description: Infrastructure for the @jterrazz ecosystem — defines how all apps deploy. K3s, Helm, Traefik, cert-manager. Activates when deploying, configuring Kubernetes, or troubleshooting.
---

# @jterrazz Infrastructure

Part of the @jterrazz ecosystem. Defines how all apps deploy.

Single-node K3s cluster on Hetzner VPS. CI-driven deploys via Helm.

## Stack

- **Cluster**: K3s on Hetzner VPS
- **Ingress**: Traefik IngressRoutes
- **TLS**: cert-manager + Let's Encrypt
- **DNS**: external-dns + Cloudflare
- **Secrets**: Infisical
- **Monitoring**: Grafana + Loki + Tempo + Prometheus + OTel Collector
- **Registry**: Private Docker registry at `registry.jterrazz.com`

## Deploying a new app

1. **App repo**: Add `Dockerfile`, `.infrastructure/application.yaml`, `Makefile`, CI workflows
2. **Infra repo**: Add domain to `issuers.yaml` + `helm.yaml`
3. **GitHub secrets**: Set `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET`
4. **Cloudflare**: Domain on CF nameservers, SSL mode Full (Strict)

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

Managed: `jterrazz.com`, `clawrr.com`, `clawssify.com`, `sig.news`

## Key commands

```bash
# SSH to server
ssh -i /tmp/ssh_key root@46.224.186.190

# Check app
kubectl get pods -n prod-{app-name}
kubectl get ingressroute -n prod-{app-name}

# Restart cert-manager after disruption
kubectl rollout restart deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector -n platform-networking
```

## Never

- Never force push to main
- Never delete PVCs without backing up data
- Never skip Cloudflare Full (Strict) SSL mode
- Never commit secrets — use Infisical
