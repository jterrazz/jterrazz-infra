# Cloudflared

Cloudflare Tunnel runtime that brings public traffic into the cluster
without exposing port 443 on the host. Phase 1 of the cloudflared
migration — the tunnel is deployed but DNS still points at the public IP
until you start switching domains.

## How it routes

Cloudflare → Cloudflared (this Deployment) → Traefik (cluster-internal).
Traefik continues to do per-hostname routing exactly as today; cloudflared
just forwards everything it receives to `traefik.kube-system.svc.cluster.local:443`.

## One-time setup (before deploying)

Three manual steps in the Cloudflare Zero Trust dashboard + Infisical:

### 1. Create the tunnel

- Cloudflare dashboard → Zero Trust → Networks → Tunnels → **Create a tunnel**
- Connector type: **Cloudflared**
- Name: `jterrazz-prod`
- Save → on the next screen Cloudflare shows a token (long string starting with `eyJ…`).
  Copy it.

### 2. Add the token to Infisical

- https://eu.infisical.com → project `jterrazz` → env `prod` → path `/infrastructure-apps`
- Add a secret: key `CLOUDFLARE_TUNNEL_TOKEN`, value = the token from step 1

### 3. Configure the catch-all public-hostname rule

In the same tunnel detail page in Cloudflare:

- Tab **Public Hostname** → **Add a public hostname**
- Subdomain: leave empty
- Domain: `jterrazz.com`  *(any zone you control; this is just the wildcard root)*
- Service type: `HTTPS`
- URL: `traefik.kube-system.svc.cluster.local:443`
- Additional application settings → TLS → **No TLS Verify: ON**
- Save.

Repeat for each apex zone you'll route through the tunnel (`clawrr.com`,
`clawssify.com`, `sig.news`, `spwn.sh`). Each entry lets the tunnel accept
traffic for `*.zone` and forwards it to Traefik's internal service.

## Deploy

After steps 1–3 above, the next `ansible-playbook` run of `platform.yml`
applies the manifest. For a targeted apply without re-running the whole
playbook:

```bash
kubectl apply -f kubernetes/platform/cloudflared/deployment.yaml
```

(Run from the cluster host or with a kubeconfig pointing at it.)

## Verify

```bash
# Pod healthy?
kubectl get pods -n platform-networking -l app.kubernetes.io/name=cloudflared

# Connected to Cloudflare edge?
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E "Registered|edge"

# Token synced from Infisical?
kubectl get secret cloudflared-token -n platform-networking -o jsonpath='{.data.CLOUDFLARE_TUNNEL_TOKEN}' | base64 -d | head -c 20
echo
```

In the Cloudflare dashboard the tunnel should show **HEALTHY** within ~30s.

## Phase 2 (later, separate PR)

Once the tunnel is healthy, switch domains one at a time by changing their
DNS records in Cloudflare from `A 46.224.186.190` to
`CNAME <tunnel-id>.cfargotunnel.com`. The tunnel-id is shown in the tunnel
detail page. Domains not yet switched continue to receive traffic the old
way.
