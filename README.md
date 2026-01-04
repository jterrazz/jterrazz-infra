# @jterrazz/infra

Minimal Kubernetes infrastructure with local development and production deployment on Hetzner Cloud.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         INTERNET                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Cloudflare DNS                               │
│  *.jterrazz.com → Tailscale IP (private) or Public IP          │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          ▼                                       ▼
┌──────────────────────┐              ┌──────────────────────┐
│   Public Access      │              │  Tailscale VPN       │
│   (ports 80/443)     │              │  (private services)  │
└──────────────────────┘              └──────────────────────┘
          │                                       │
          └───────────────────┬───────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Hetzner VPS                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    K3s Cluster                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │   Traefik   │  │   ArgoCD    │  │     SigNoz      │  │   │
│  │  │  (Ingress)  │  │   (GitOps)  │  │ (Observability) │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘  │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │  Registry   │  │ Cert-Manager│  │  External-DNS   │  │   │
│  │  │  (Private)  │  │(Let's Encr.)│  │  (Cloudflare)   │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘  │   │
│  │  ┌───────────────────────────────────────────────────┐  │   │
│  │  │              Your Applications                    │  │   │
│  │  └───────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Stack

| Component | Purpose |
|-----------|---------|
| **K3s** | Lightweight Kubernetes |
| **Traefik** | Ingress controller with automatic TLS |
| **ArgoCD** | GitOps continuous deployment |
| **SigNoz** | Observability (traces, metrics, logs) |
| **Cert-Manager** | Automatic Let's Encrypt certificates |
| **External-DNS** | Automatic Cloudflare DNS management |
| **Infisical Operator** | Automated secrets management |
| **Tailscale** | Private VPN for secure access |
| **Docker Registry** | Private container registry |

## Quick Start

```bash
# Local development
make start    # Full setup with Multipass VM
make status   # Check services
make ssh      # Access VM

# Production
make deploy   # Deploy to Hetzner (or push to main)
```

## Project Structure

```
├── ansible/                    # Server configuration
│   ├── playbooks/              # Orchestration playbooks
│   │   ├── site.yml            # Main entry point
│   │   ├── base.yml            # System packages, users
│   │   ├── security.yml        # UFW, fail2ban, SSH hardening
│   │   ├── kubernetes.yml      # K3s installation
│   │   └── platform.yml        # ArgoCD, platform services
│   ├── roles/                  # Reusable roles
│   │   ├── k3s/                # K3s installation
│   │   ├── security/           # Firewall, fail2ban
│   │   ├── storage/            # Persistent volumes
│   │   └── tailscale/          # VPN setup
│   ├── templates/              # Jinja2 templates
│   │   └── kubernetes/         # K8s manifests with secrets
│   └── inventories/            # Host definitions
│
├── kubernetes/                 # GitOps manifests (ArgoCD syncs these)
│   ├── applications/           # Your app definitions
│   ├── platform/               # Platform ArgoCD apps
│   └── infrastructure/         # Base resources
│       └── base/
│           ├── cert-manager/   # TLS certificates
│           ├── traefik/        # Ingress configuration
│           └── platform-namespaces.yaml
│
├── pulumi/                     # Infrastructure as Code
│   └── index.ts                # Hetzner VPS + secrets
│
├── scripts/                    # Automation scripts
└── data/                       # Local data (gitignored)
    ├── kubeconfig/             # Fetched kubeconfig
    └── ssh/                    # Local SSH keys
```

## Services & Access

### Public Services (via Traefik Ingress)
Your applications are exposed publicly on ports 80/443.

### Private Services (via Tailscale)

| Service | URL | Access |
|---------|-----|--------|
| ArgoCD | `https://argocd.jterrazz.com` | Tailscale only |
| SigNoz | `https://signoz.jterrazz.com` | Tailscale only |
| Registry | `https://registry.jterrazz.com` | Tailscale only |

All private services:
- Use valid Let's Encrypt TLS certificates
- DNS points to Tailscale IP (not public IP)
- Only accessible when connected to Tailscale VPN

### ArgoCD Admin Password

```bash
kubectl -n platform-gitops get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## Private Docker Registry

The infrastructure includes a private Docker registry for your container images.

### Registry Access
- **URL**: `registry.jterrazz.com`
- **Auth**: htpasswd (username: `deploy`)
- **Password**: Stored in Pulumi state

```bash
# Get registry password
cd pulumi && pulumi stack output dockerRegistryPassword --show-secrets

# Docker login
docker login registry.jterrazz.com -u deploy
```

### Using from CI (GitHub Actions)

Your application repos need these secrets:

| Secret | Value |
|--------|-------|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret |
| `REGISTRY_USERNAME` | `deploy` |
| `REGISTRY_PASSWORD` | From `pulumi stack output dockerRegistryPassword --show-secrets` |

Example workflow:
```yaml
- name: Setup Tailscale
  uses: tailscale/github-action@v2
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci

- name: Login to Registry
  uses: docker/login-action@v3
  with:
    registry: registry.jterrazz.com
    username: ${{ secrets.REGISTRY_USERNAME }}
    password: ${{ secrets.REGISTRY_PASSWORD }}

- name: Build and Push
  uses: docker/build-push-action@v5
  with:
    push: true
    tags: registry.jterrazz.com/my-app:latest
```

### Using in Kubernetes Deployments

```yaml
spec:
  imagePullSecrets:
    - name: registry-credentials  # Created by Ansible
  containers:
    - name: my-app
      image: registry.jterrazz.com/my-app:latest
```

## Deploy an Application

### 1. Create ArgoCD Application

```yaml
# kubernetes/applications/my-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: platform-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/you/your-app.git
    path: k8s
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: app-my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 2. Add Registry Pull Secret (for private registry)

Add to `ansible/templates/kubernetes/registry-pull-secret.yaml.j2`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: app-my-app
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-credentials
  namespace: app-my-app
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {"auths":{"registry.jterrazz.com":{"username":"deploy","password":"{{ registry_password }}"}}}
```

### 3. Push and Deploy

Push to main - ArgoCD auto-syncs your application.

## Production Setup

### Prerequisites

```bash
# macOS
brew install multipass ansible pulumi node

# Required accounts (free tiers available)
# - Pulumi: https://app.pulumi.com
# - Hetzner: https://console.hetzner.cloud
# - Tailscale: https://tailscale.com
# - Cloudflare: https://cloudflare.com (for DNS)
```

### 1. Pulumi Setup

```bash
cd pulumi
npm install
pulumi login
pulumi stack init production
```

### 2. Configure Secrets

```bash
# Hetzner API token
pulumi config set hcloud:token <token> --secret

# Cloudflare API token (for DNS and cert-manager)
pulumi config set cloudflareApiToken <token> --secret

# Tailscale OAuth (create at https://login.tailscale.com/admin/settings/oauth)
pulumi config set tailscaleOauthClientId <client-id>
pulumi config set tailscaleOauthClientSecret <secret> --secret
```

### 3. Tailscale ACL Configuration

Add to your Tailscale ACL policy (https://login.tailscale.com/admin/acls/file):

```json
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"],
    "tag:ci": ["autogroup:admin"]
  },
  "acls": [
    {"action": "accept", "src": ["autogroup:admin"], "dst": ["*:*"]},
    {"action": "accept", "src": ["tag:ci"], "dst": ["tag:server:*"]}
  ]
}
```

### 4. GitHub Actions Secrets

| Secret | Description |
|--------|-------------|
| `PULUMI_ACCESS_TOKEN` | Pulumi API token |
| `HCLOUD_TOKEN` | Hetzner Cloud API token |
| `TAILSCALE_OAUTH_CLIENT_ID` | For server provisioning |
| `TAILSCALE_OAUTH_CLIENT_SECRET` | For server provisioning |
| `CLOUDFLARE_API_TOKEN` | For DNS and certificates |

### 5. Deploy

```bash
# Manual deploy
make deploy

# Or push to main branch for automatic deployment
git push origin main
```

## Security Model

### Network Security

| Port | Service | Access Level |
|------|---------|--------------|
| 22 | SSH | Public (key-only, fail2ban) |
| 80 | HTTP | Public (redirects to HTTPS) |
| 443 | HTTPS | Public (your apps) |
| 6443 | K8s API | Tailscale + private only |
| 30000+ | NodePorts | Blocked publicly |

### Service Security

- **ArgoCD/SigNoz/Registry**: Only accessible via Tailscale VPN
- **TLS**: All services use Let's Encrypt certificates (auto-renewed)
- **DNS**: Managed by external-dns, points to Tailscale IPs for private services
- **Secrets**: Stored in Pulumi state (encrypted), injected via Ansible

### Firewall Rules (UFW)

```
Default: deny incoming, allow outgoing
Allow: 22/tcp (SSH), 80/tcp (HTTP), 443/tcp (HTTPS)
Allow from Tailscale (100.64.0.0/10): 6443/tcp (K8s API)
```

## Certificates & DNS

### How it works

1. **Cert-Manager** requests certificates from Let's Encrypt
2. **DNS-01 Challenge**: Uses Cloudflare API to prove domain ownership
3. **External-DNS** automatically creates/updates DNS records
4. **Certificates** are stored as Kubernetes secrets

### Adding a new domain

1. Add to `ClusterIssuer` in `kubernetes/infrastructure/base/cert-manager/cluster-issuer.yaml`:
   ```yaml
   selector:
     dnsNames:
       - existing.jterrazz.com
       - new-service.jterrazz.com  # Add here
   ```

2. Create Certificate and IngressRoute for your service

3. External-DNS will auto-create the DNS record

## Secrets Management with Infisical

The Infisical Operator syncs secrets from Infisical to Kubernetes Secrets automatically.

### Setup

1. Create a project in Infisical (e.g., `jterrazz-apps`)
2. Organize secrets in folders (e.g., `/n00-api`, `/n00-web`)
3. Create a Machine Identity with **Viewer** role
4. Add `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET` to GitHub Secrets

### Using in Applications

Add an `InfisicalSecret` resource to sync secrets:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: my-app-infisical
spec:
  hostAPI: https://app.infisical.com
  resyncInterval: 60
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: jterrazz-apps
        envSlug: prod
        secretsPath: /my-app
      credentialsRef:
        secretName: infisical-credentials
        secretNamespace: platform-secrets
  managedSecretReference:
    secretName: my-app-secrets
    secretType: Opaque
```

The operator creates a Kubernetes Secret (`my-app-secrets`) that your deployment can reference via `secretKeyRef`.


## Observability with SigNoz

### Sending Traces (OpenTelemetry)

```yaml
# In your app deployment
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://signoz-otel-collector.platform-observability:4318"
```

### Accessing SigNoz

1. Connect to Tailscale VPN
2. Go to `https://signoz.jterrazz.com`

## Local Development

```bash
make start          # Create Multipass VM + full deploy
make status         # Cluster status
make ssh            # SSH into VM
make ansible        # Re-run Ansible playbooks
make logs           # View deployment logs
make destroy        # Destroy VM
```

## Troubleshooting

### Check ArgoCD sync status
```bash
kubectl get applications -n platform-gitops
```

### View pod logs
```bash
kubectl logs -n <namespace> <pod-name>
```

### Certificate issues
```bash
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
```

### DNS not updating
External-DNS uses `upsert-only` policy. To update an existing record:
1. Delete the record in Cloudflare
2. External-DNS will recreate it with the correct value

### Registry access issues
```bash
# Test from Tailscale
curl -u deploy:<password> https://registry.jterrazz.com/v2/

# Check certificate
openssl s_client -connect registry.jterrazz.com:443 -servername registry.jterrazz.com
```

## Maintenance

### Updating K3s
```bash
# SSH to server
curl -sfL https://get.k3s.io | sh -
```

### Rotating secrets
```bash
cd pulumi
pulumi config set <secret-name> <new-value> --secret
pulumi up
# Then re-run Ansible to apply changes
```

### Backup
- **Pulumi state**: Automatically stored in Pulumi Cloud
- **Application data**: Use PersistentVolumes with appropriate backup strategy
- **Cluster state**: ArgoCD can recreate from Git

## Contributing

1. Test changes locally with `make start`
2. Create a PR
3. CI validates Ansible syntax and Pulumi preview
4. Merge to main triggers production deploy
