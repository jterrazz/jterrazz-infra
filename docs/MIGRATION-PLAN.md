# Migration Plan: Self-Contained Platform Apps

## Objective

Refactor infrastructure so that adding a new app = **one file in `kubernetes/platform/`**.

**Before**: App config scattered across 5+ files (infrastructure/, ansible/, templates/)
**After**: Single self-contained file per app, infrastructure provides reusable capabilities

---

## Current Architecture Analysis

### Security Components (DO NOT BREAK)

| Component                     | Purpose                                | Risk Level                                  |
| ----------------------------- | -------------------------------------- | ------------------------------------------- |
| **ClusterIssuer**             | Issues TLS certs via Cloudflare DNS-01 | HIGH - has domain whitelist                 |
| **external-dns**              | Creates DNS records in Cloudflare      | MEDIUM - uses `upsert-only`, has txtOwnerId |
| **private-access middleware** | IP whitelist for Tailscale-only access | HIGH - protects internal services           |
| **Cloudflare API Token**      | DNS management + cert validation       | HIGH - scoped to zone                       |

### Current Security Constraints

```yaml
# ClusterIssuer - WHITELIST of allowed domains
selector:
  dnsNames:
    - signoz.jterrazz.com
    - argocd.jterrazz.com
    - registry.jterrazz.com
    # n8n.jterrazz.com is MISSING - explains no TLS!

# external-dns - Safe settings
policy: upsert-only # Won't delete unmanaged records
txtOwnerId: "jterrazz-k8s" # Tags records it manages
domainFilters:
  - jterrazz.com # Only touches this zone
```

### Why n8n Has No TLS Certificate

The ClusterIssuer only allows issuing certs for whitelisted domains. `n8n.jterrazz.com` is not in the list.

**Immediate Fix Required**: Add n8n to ClusterIssuer whitelist.

---

## Target Architecture

```
kubernetes/
├── infrastructure/              # CAPABILITIES (stable, rarely changes)
│   └── base/
│       ├── storage/
│       │   └── storage-class.yaml        # "manual" StorageClass only
│       ├── traefik/
│       │   ├── middleware.yaml           # private-access, rate-limit, https-redirect
│       │   ├── traefik-config.yaml       # Global Traefik settings
│       │   └── global-https-redirect.yaml
│       ├── cert-manager/
│       │   └── cluster-issuer.yaml       # Wildcard: *.jterrazz.com
│       ├── network-policies/
│       └── platform-namespaces.yaml      # Core namespaces only
│
├── platform/                    # APPS (one file = one complete app)
│   ├── argocd.yaml             # App + Ingress + Certificate + PVC
│   ├── signoz.yaml             # App + Ingress + Certificate + PVC
│   ├── n8n.yaml                # App + Ingress + Certificate + PVC
│   └── ...
│
└── applications/                # User apps (same pattern)

ansible/
└── roles/k3s/
    └── main.yml                 # Creates /var/lib/k8s-data/ (ONE directory)
```

---

## Migration Steps

### Phase 1: Fix n8n TLS (Immediate)

**Goal**: Get n8n working with TLS certificate.

#### Step 1.1: Add n8n to ClusterIssuer whitelist

```yaml
# kubernetes/infrastructure/base/cert-manager/cluster-issuer.yaml
selector:
  dnsNames:
    - signoz.jterrazz.com
    - argocd.jterrazz.com
    - registry.jterrazz.com
    - n8n.jterrazz.com # ADD THIS
```

#### Step 1.2: Create n8n Certificate

```yaml
# Add to cluster-issuer.yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: n8n-tls
  namespace: platform-automation
spec:
  secretName: n8n-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - n8n.jterrazz.com
```

**Verification**:

```bash
kubectl get certificate n8n-tls -n platform-automation
# Should show READY=True
```

---

### Phase 2: Wildcard Certificate (Simplification)

**Goal**: Stop whitelisting individual domains. Use wildcard.

#### Step 2.1: Update ClusterIssuer for wildcard

```yaml
# kubernetes/infrastructure/base/cert-manager/cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: podcasterr@proton.me
    privateKeySecretRef:
      name: letsencrypt-production-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
        selector:
          dnsZones:
            - jterrazz.com # Allow ANY subdomain of jterrazz.com
```

**Security Note**: This is SAFE because:

- Cloudflare API token is scoped to jterrazz.com zone only
- You control what IngressRoutes/Certificates you create
- DNS-01 challenge proves you own the domain

**Verification**:

```bash
# Test with a new subdomain
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-tls
  namespace: default
spec:
  secretName: test-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - test.jterrazz.com
EOF

# Check it gets issued
kubectl get certificate test-tls -n default
kubectl delete certificate test-tls -n default
```

---

### Phase 3: Self-Contained App Pattern

**Goal**: Each app defines its own Ingress + Certificate.

#### Step 3.1: Use ArgoCD Multi-Source

Convert apps to include their own IngressRoute and Certificate:

```yaml
# kubernetes/platform/n8n.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: n8n
  namespace: platform-gitops
spec:
  project: default
  sources:
    # Source 1: Helm chart
    - repoURL: https://8gears.container-registry.com/chartrepo/library
      chart: n8n
      targetRevision: 0.25.2
      helm:
        values: |
          persistence:
            enabled: true
            storageClass: local-path
          ingress:
            enabled: false  # We use Traefik IngressRoute

    # Source 2: Our own manifests (Ingress, Cert, PVC)
    - repoURL: https://github.com/jterrazz/jterrazz-infra.git
      targetRevision: HEAD
      path: kubernetes/platform/n8n-resources

  destination:
    server: https://kubernetes.default.svc
    namespace: platform-automation
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```yaml
# kubernetes/platform/n8n-resources/ingress.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: n8n
  annotations:
    external-dns.alpha.kubernetes.io/hostname: n8n.jterrazz.com
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`n8n.jterrazz.com`)
      kind: Rule
      middlewares:
        - name: private-access
          namespace: platform-ingress
      services:
        - name: n8n
          port: 5678
  tls:
    secretName: n8n-tls
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: n8n-tls
spec:
  secretName: n8n-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - n8n.jterrazz.com
```

#### Step 3.2: Remove Tailscale IP injection

**Current Problem**: Ansible injects Tailscale IP into IngressRoute annotations.

**Solution**: external-dns can determine target automatically, OR use a ConfigMap.

Option A: Let external-dns use the node IP (for public services)

```yaml
# No target annotation needed - external-dns reads from Traefik
annotations:
  external-dns.alpha.kubernetes.io/hostname: api.jterrazz.com
```

Option B: Use a ConfigMap for Tailscale IP (for private services)

```yaml
# Created by Ansible once
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-info
  namespace: platform-ingress
data:
  tailscale-ip: "100.x.x.x"
```

Then reference in annotations via a mutating webhook or simply hardcode per-app (Tailscale IP is stable).

**Recommended**: For private services, keep the target annotation but accept it's set per-app. Tailscale IPs are stable and rarely change.

---

### Phase 4: Storage Simplification

**Goal**: Use dynamic provisioning, remove static PVs.

#### Step 4.1: Use local-path StorageClass

K3s includes `local-path` provisioner. Apps request storage, it's created automatically.

```yaml
# In app helm values
persistence:
  enabled: true
  storageClass: local-path
  size: 1Gi
```

**Data Location**: `/var/lib/rancher/k3s/storage/pvc-xxxxx`

#### Step 4.2: For predictable paths (optional)

Configure local-path to use PVC name:

```yaml
# kubernetes/infrastructure/base/storage/local-path-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config
  namespace: kube-system
data:
  config.json: |
    {
      "nodePathMap": [{
        "node": "DEFAULT",
        "paths": ["/var/lib/k8s-data"]
      }]
    }
```

---

### Phase 5: Remove Infrastructure Ingress File

**Goal**: Delete `internal-ingresses.yaml` - each app owns its ingress.

#### Step 5.1: Move existing ingresses to apps

For each service in `internal-ingresses.yaml`:

1. Add IngressRoute to the app's ArgoCD Application (multi-source)
2. Remove from infrastructure

#### Step 5.2: Delete the file

```bash
rm kubernetes/infrastructure/base/traefik/internal-ingresses.yaml
rm ansible/templates/kubernetes/internal-ingresses.yaml.j2
```

#### Step 5.3: Simplify Ansible

Remove per-app directory creation:

```yaml
# ansible/roles/k3s/tasks/main.yml
# BEFORE: Create directories for signoz, n8n, etc.
# AFTER: Just create base directory (if using manual storage)
- name: Create base storage directory
  ansible.builtin.file:
    path: /var/lib/k8s-data
    state: directory
    mode: "0755"
```

---

## Internal vs External Services Pattern

### Internal (Tailscale-only)

```yaml
# In app's IngressRoute
spec:
  routes:
    - match: Host(`n8n.jterrazz.com`)
      middlewares:
        - name: private-access # <-- This restricts to Tailscale
          namespace: platform-ingress
      services:
        - name: n8n
          port: 5678
  tls:
    secretName: n8n-tls
---
# DNS points to Tailscale IP
annotations:
  external-dns.alpha.kubernetes.io/hostname: n8n.jterrazz.com
  external-dns.alpha.kubernetes.io/target: "100.x.x.x" # Tailscale IP
```

### External (Public)

```yaml
# In app's IngressRoute
spec:
  routes:
    - match: Host(`api.jterrazz.com`)
      middlewares:
        - name: rate-limit # <-- No private-access = public
          namespace: platform-ingress
      services:
        - name: api
          port: 8080
  tls:
    secretName: api-tls
---
# DNS points to public IP (external-dns figures it out)
annotations:
  external-dns.alpha.kubernetes.io/hostname: api.jterrazz.com
  # No target = uses node's public IP
```

---

## Migration Checklist

### Phase 1: Fix n8n TLS (Do First)

- [ ] Add `n8n.jterrazz.com` to ClusterIssuer whitelist
- [ ] Add n8n Certificate to cluster-issuer.yaml
- [ ] Verify certificate is issued
- [ ] Test https://n8n.jterrazz.com works

### Phase 2: Wildcard Certificate

- [ ] Update ClusterIssuer to use `dnsZones` instead of `dnsNames`
- [ ] Test new certificate issuance
- [ ] Remove individual domain whitelisting
- [ ] Keep existing certificates (they'll renew automatically)

### Phase 3: Self-Contained Apps

- [ ] Create `kubernetes/platform/n8n-resources/` directory
- [ ] Move n8n IngressRoute + Certificate there
- [ ] Update n8n.yaml to use multi-source
- [ ] Test n8n still works
- [ ] Repeat for signoz, argocd, registry

### Phase 4: Storage

- [ ] Test with local-path StorageClass on new app
- [ ] Decide: predictable paths vs automatic
- [ ] Migrate existing PVCs (data migration required)

### Phase 5: Cleanup

- [ ] Remove internal-ingresses.yaml from infrastructure
- [ ] Remove Ansible template for ingresses
- [ ] Simplify Ansible k3s role (remove per-app dirs)
- [ ] Update README

---

## Rollback Plan

If anything breaks:

1. **DNS Issues**: Cloudflare dashboard, manually fix records
2. **Certificate Issues**: Delete Certificate, recreate
3. **Ingress Issues**: Revert git commit, ArgoCD auto-syncs

```bash
# Emergency: revert last commit
git revert HEAD
git push

# ArgoCD will auto-sync back to working state
```

---

## Files Changed Summary

### Modified

- `kubernetes/infrastructure/base/cert-manager/cluster-issuer.yaml` - Wildcard support
- `kubernetes/infrastructure/base/storage/` - Remove static PVs
- `kubernetes/platform/*.yaml` - Add multi-source with resources
- `ansible/roles/k3s/tasks/main.yml` - Remove per-app directories
- `README.md` - Document new pattern

### Deleted

- `kubernetes/infrastructure/base/traefik/internal-ingresses.yaml`
- `kubernetes/infrastructure/base/storage/static-volumes.yaml` (most of it)
- `kubernetes/infrastructure/base/storage/n8n-pvc.yaml`
- `ansible/templates/kubernetes/internal-ingresses.yaml.j2`

### Created

- `kubernetes/platform/*/` - Resource directories per app
