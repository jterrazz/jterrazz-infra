# Infra Project

## Project Overview
- K3s single-node cluster on Hetzner VPS (46.224.186.190)
- SSH: `root@<ip>` with Ed25519 key from Pulumi output `sshPrivateKey`
- Stack: Traefik, cert-manager, external-dns, SigNoz, n8n, Infisical, OpenClaw, Portainer, Docker registry
- **No GitOps controller** — CI-driven deploys via `helm upgrade --install`
- App chart published to `oci://registry.jterrazz.com/charts/app`

## Deployed Apps
- **signews-web** (`jterrazz/n00-web`): Next.js 16 at `sig.news`, namespace `prod-signews-web`
- **signews-api** (`jterrazz/signews-api`): namespace `prod-signews-api`
- **clawssify-web-landing** (`jterrazz/clawssify-web-landing`): at `clawssify.com`, namespace `prod-clawssify-web-landing`
- **clawrr-web-landing** (`clawrr/web-landing`): at `clawrr.com` (uses separate `github_pat_clawrr`)
- **gateway-intelligence** (`jterrazz/gateway-intelligence`): namespace `prod-gateway-intelligence`

## Managed Domains
- `jterrazz.com`, `clawrr.com`, `clawssify.com`, `sig.news` — all in cert-manager dnsZones + external-dns domainFilters
- Adding a new domain requires: cert-manager `issuers.yaml` (both prod+staging), external-dns `helm.yaml`, and Cloudflare API token with Zone:Read + DNS:Edit for that zone
- Cloudflare SSL mode must be **Full (Strict)** for all domains

## Key Patterns
- Platform services installed via Helm in Ansible `playbooks/platform.yml`
- Shared platform chart (`kubernetes/charts/platform/`) generates Certificate + IngressRoute + PV/PVC from simple `platform.yaml` values
- App chart at `kubernetes/charts/app/`, published to OCI registry
- Platform service configs: `helm.yaml` (upstream chart values) + `platform.yaml` (ingress/cert/storage)
- PVCs use `storageClassName: manual` with hostPath PVs, bound via `volumeName` (not selector)
- Traefik IngressRoutes (not plain Ingress) for routing
- cert-manager Certificates with `letsencrypt-production` ClusterIssuer
- Tailscale for private service access

## App Deployment Pattern (for new apps)
1. **In app repo**: `Dockerfile` (multi-stage), `.deploy/manifest.yaml` (jterrazz.com/v1 Application), `.github/workflows/deploy.yaml` + `validate.yaml`
2. **In infra repo**: Add domain to `issuers.yaml` + `helm.yaml`, add repo to bootstrap list in `platform.yml`
3. **GitHub secrets**: Set `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET` on the app repo (same values as other jterrazz repos)
4. **Cloudflare**: Domain on CF nameservers, API token with zone access, SSL mode **Full (Strict)**
5. CI flow: validate → build+push to `registry.jterrazz.com` → `helm upgrade --install` via Tailscale
6. Manifest format: `apiVersion: jterrazz.com/v1`, `kind: Application`, with `metadata.name`, `spec.port`, `spec.resources`, `environments.prod` (host, replicas, ingress)

## Connection Details
- Pulumi stack: `jterrazz/production` (needs `PULUMI_ACCESS_TOKEN`)
- **Pulumi commands must run from `pulumi/` subdirectory** (not repo root)
- Server IP: `pulumi stack output serverIp`
- SSH key: `pulumi stack output sshPrivateKey --show-secrets`
- Registry password: `pulumi stack output dockerRegistryPassword --show-secrets`
- `.env` file has: PULUMI_ACCESS_TOKEN, HCLOUD_TOKEN, TAILSCALE_*, CLOUDFLARE_API_TOKEN, INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET
- Infisical secrets at path `/infrastructure-apps` contain: DOCKER_REGISTRY_*, TAILSCALE_OAUTH_CLIENT_ID, TAILSCALE_OAUTH_CLIENT_SECRET, KUBECONFIG_BASE64

## OpenClaw
- Deployed in `platform-automation` namespace, image-based (not Helm chart)
- Config at `/root/.openclaw/openclaw.json` inside container
- CLI: `kubectl exec -n platform-automation deploy/openclaw -- node /app/openclaw.mjs <command>` (no `openclaw` binary in PATH)
- Gateway token in k8s secret `openclaw-secrets` (keys: `GATEWAY_TOKEN`, `CLAUDE_TOKEN`)
- Control UI pairing through reverse proxy (Traefik) requires `gateway.controlUi.dangerouslyDisableDeviceAuth: true`
- `trustedProxies: ["10.42.0.0/16"]` for k8s pod network

## Common Operations

### SSH to server
```bash
source .env && export PULUMI_ACCESS_TOKEN
SSH_KEY=$(cd pulumi && pulumi stack output sshPrivateKey --show-secrets)
echo "$SSH_KEY" > /tmp/ssh_key && chmod 600 /tmp/ssh_key
ssh -i /tmp/ssh_key root@46.224.186.190
```

### Restart cert-manager (after k3s disruption)
```bash
kubectl rollout restart deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector -n platform-networking
```

### Check app deployment
```bash
kubectl get pods -n prod-<app-name>
kubectl get certificate -n prod-<app-name>
kubectl get ingressroute -n prod-<app-name>
```

## Gotchas
- **Infisical secret names**: CI workflows use `TAILSCALE_OAUTH_CLIENT_SECRET` (not `TAILSCALE_OAUTH_SECRET`). Always match the exact env var name from Infisical.
- **Next.js standalone Docker**: Requires `output: 'standalone'` in `next.config.mjs`. If `public/` dir doesn't exist in repo (gitignored contents), use `mkdir -p public` before build in Dockerfile.
- **cert-manager after k3s restart**: cert-manager + webhook + cainjector lose API connection. Must restart all three.
- **New GitHub repo secrets**: New app repos need `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET` GitHub secrets set.
- **Helm adoption**: Annotate existing resources with `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`, and label `app.kubernetes.io/managed-by=Helm`.
- **Immutable k8s fields**: Deployment selectors, PV `hostPath.type`, PVC `spec.selector` — delete and recreate if they need to change.
- **CRD kubectl names**: Use fully qualified names: `certificate.cert-manager.io`, `ingressroute.traefik.io`.
