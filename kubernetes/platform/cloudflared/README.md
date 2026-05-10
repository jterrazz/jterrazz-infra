# Cloudflared

Cloudflare Tunnel runtime that brings public traffic into the cluster
without exposing any host port. Cloudflared maintains an outbound QUIC
connection to the Cloudflare edge; traffic for any of our public
hostnames flows back through that tunnel and lands on the cluster-
internal Traefik service.

## How it routes

```
client ──https──► Cloudflare edge ──QUIC tunnel──► this Deployment
                                                       │
                                                       ▼
                                  traefik.kube-system.svc.cluster.local:443
                                                       │
                                                       ▼
                                            IngressRoute → app
```

Per-hostname routing is configured in Cloudflare's Zero Trust UI under
the tunnel's "Public Hostname" tab — adding a hostname there creates the
DNS CNAME automatically. The tunnel forwards everything to Traefik with
`No TLS Verify: ON` (internal traffic, no need to validate the cluster's
self-signed serving cert).

## One-time setup

Done once per tunnel; recorded here for reference and recovery.

### 1. Create the tunnel

Cloudflare → Zero Trust → Networks → Tunnels → Create a tunnel.
Connector type **Cloudflared**, name `jterrazz-infra`. On the next
screen Cloudflare shows a connection token (starts with `eyJ…`).

### 2. Store the token in Infisical

`https://eu.infisical.com` → project `jterrazz` → env `prod` → path
`/infrastructure` → add secret `CLOUDFLARE_TUNNEL_TOKEN` with that
value. Ansible decodes the token at deploy time to derive the tunnel
hostname (`<tunnel-id>.cfargotunnel.com`) used as the DNS target for
public records.

### 3. Public Hostname per zone

In the tunnel detail page, "Public Hostname" tab → Add for each apex
zone you route through this tunnel (`jterrazz.com`, `clawrr.com`,
`clawssify.com`, `sig.news`, `spwn.sh`).

- Subdomain: empty
- Service type: HTTPS
- URL: `traefik.kube-system.svc.cluster.local:443`
- Additional application settings → TLS → **No TLS Verify: ON**

## Deploy

`platform.yml` applies this manifest automatically. For a targeted
apply from the cluster host:

```bash
kubectl apply -f /tmp/k8s-manifests/kubernetes/platform/cloudflared/deployment.yaml
```

## Verify

```bash
# Pod healthy?
kubectl get pod -n platform-networking -l app.kubernetes.io/name=cloudflared

# Connected to Cloudflare edge?
kubectl logs -n platform-networking deploy/cloudflared --tail=30 | grep -E 'Registered|edge'

# Token synced from Infisical?
kubectl get secret cloudflared-token -n platform-networking \
  -o jsonpath='{.data.CLOUDFLARE_TUNNEL_TOKEN}' | base64 -d | head -c 20; echo

# Live traffic counter
POD_IP=$(kubectl get pod -n platform-networking -l app.kubernetes.io/name=cloudflared -o jsonpath='{.items[0].status.podIP}')
curl -s "http://$POD_IP:2000/metrics" | grep '^cloudflared_tunnel_total_requests '
```

The Cloudflare dashboard shows the tunnel as **HEALTHY** within ~30s of
pod start.

## Swapping between Hetzner and OrbStack

Both clusters run cloudflared with the same `CLOUDFLARE_TUNNEL_TOKEN`,
which means both can register as connectors for the same tunnel and
Cloudflare load-balances between them. To send traffic to only one:

```bash
# On the cluster that should NOT serve:
kubectl scale -n platform-networking deploy/cloudflared --replicas=0
```
