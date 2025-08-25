# 🚀 Jterrazz Infrastructure

**Modern Infrastructure as Code** with **one-command local development** and **production-ready Kubernetes deployment**.

## ✨ Quick Start

```bash
# Complete local setup (one command!)
make start

# Check everything is working
make status

# Access your applications
open https://app.local        # Landing page
open https://argocd.local     # GitOps dashboard
open https://portainer.local  # Kubernetes management
```

**That's it!** Automatic VM creation, Kubernetes cluster, SSL certificates, and DNS resolution. Zero manual configuration. 🎯

---

## 🎯 What This Provides

### 🏠 **Local Development**

- **🖥️ Multipass VM** - Real Ubuntu VM with production-like environment
- **📱 `.local` domains** - Automatic mDNS resolution (no hosts file editing)
- **🔒 HTTPS everywhere** - Self-signed certificates with shared SSL
- **⚡ One-command setup** - `make start` creates VM + Kubernetes + everything
- **🛡️ Production security** - Same UFW/fail2ban configuration as production
- **📊 Rich status dashboard** - Comprehensive system and security overview

### ☁️ **Production Ready**

- **🏗️ Hetzner Cloud VPS** - Affordable, reliable European hosting
- **🔐 Kubernetes (k3s)** - Lightweight, production-grade cluster
- **🌐 Traefik Ingress** - Cloud-native load balancing and routing
- **🔒 Let's Encrypt SSL** - Automatic certificate management
- **🔄 ArgoCD GitOps** - Git-driven application deployments
- **🔗 Tailscale VPN** - Secure remote access to management tools
- **🛡️ Security Hardened** - UFW firewall, fail2ban, audit logging, auto-updates

## 🏗️ Architecture

### 🏠 Local Development

```
🖥️ Multipass VM (Ubuntu 24.04)
  ├── 🔐 k3s Kubernetes Cluster
  ├── 🌐 Traefik Ingress + Load Balancer
  ├── 📱 mDNS Publisher (*.local domains)
  ├── 🔒 Self-signed SSL Certificates
  ├── 🔄 ArgoCD (GitOps)
  ├── 🐳 Portainer (K8s Management)
  └── 🛡️ UFW + fail2ban (Security)
```

### ☁️ Production

```
📱 Your Domain (manager.jterrazz.com)
            ↓
🌐 Cloudflare DNS
            ↓
☁️ Hetzner VPS (Nuremberg, Germany)
  ├── 🔐 k3s Kubernetes Cluster
  ├── 🌐 Traefik Ingress Controller
  ├── 🔒 cert-manager (Auto SSL)
  ├── 🔄 ArgoCD (GitOps)
  └── 🔗 Tailscale (Private Access)
```

## 📚 Documentation

- **[🚀 QUICKSTART](QUICKSTART.md)** - Get running in 2 minutes
- **[📊 LOCAL-VS-PRODUCTION](LOCAL-VS-PRODUCTION.md)** - Environment comparison
- **[🔧 TROUBLESHOOTING](TROUBLESHOOTING.md)** - Fix issues fast
- **[⚡ COMMANDS](COMMANDS.md)** - All available commands

---

## 📁 Project Structure

```
jterrazz-infra/
├── 🚀 .github/workflows/      # GitHub Actions CI/CD (TODO)
│   └── deploy-infrastructure.yml # Automated deployment
├── 🏗️ terraform/              # Infrastructure provisioning (TODO)
│   ├── main.tf                # Hetzner Cloud VPS
│   ├── variables.tf           # Configuration options
│   ├── outputs.tf             # Connection details
│   └── backend.tf             # Remote state management
├── ⚙️ ansible/                # Complete infrastructure automation
│   ├── site.yml               # Unified playbook (everything!)
│   ├── inventories/           # Environment-specific targeting
│   │   ├── multipass/         # Local development VMs
│   │   └── production/        # VPS servers
│   ├── group_vars/            # Environment configuration
│   │   ├── all/common.yml     # Shared settings
│   │   ├── development/       # Local dev settings
│   │   └── production/        # Production settings
│   └── roles/                 # Component roles
│       ├── security/          # VPS hardening & UFW
│       ├── k3s/               # Kubernetes cluster
│       └── helm/              # Package manager
├── ☸️ kubernetes/             # Infrastructure manifests (deployed by Ansible)
│   ├── applications/          # Portainer, ArgoCD, landing page
│   ├── ingress/              # mDNS ingresses for local dev
│   ├── jobs/                 # TLS certificate creation
│   ├── services/             # mDNS publisher
│   └── traefik/              # Middleware & HTTPS redirect
├── 📜 scripts/                # Development utilities
│   ├── lib/                   # Shared libraries
│   │   ├── common.sh          # Colors, logging, VM utilities
│   │   ├── vm-utils.sh        # Multipass VM management
│   │   └── status-checks.sh   # Comprehensive status dashboard
│   ├── bootstrap.sh          # Production deployment (TODO)
│   └── local-dev.sh          # Local VM management
└── 🔧 Makefile               # Simple command interface
```

## 🚀 Available Commands

### **🏠 Local Development**

**Perfect for testing, development, and learning Kubernetes:**

```bash
# Complete setup (one command!)
make start           # Create VM + Install everything + Show status

# Individual operations
make stop            # Delete VM and cleanup
make status          # Show comprehensive dashboard
make ssh             # SSH into the VM

# Advanced
./scripts/local-dev.sh help  # See all VM management options
```

**✨ Features:**

- ⚡ **Real Ubuntu VM** - Production-like environment via Multipass
- 🔒 **Same security** - UFW firewall, fail2ban protection
- 📊 **Rich dashboard** - Port security, services, pods, system stats
- 🌐 **Automatic domains** - Access via `https://app.local`, etc.

**🎯 Key Benefit:** Uses the **exact same Ansible playbook** as production!

### **🎯 Recommended: GitHub Actions Deployment**

**Deploy from GitHub with zero local setup required!**

1. **Fork this repository**
2. **Add secrets** in GitHub repo settings:
   - `HCLOUD_TOKEN` - Get from [Hetzner Console](https://console.hetzner.cloud/)
   - `SSH_PUBLIC_KEY` / `SSH_PRIVATE_KEY` - Your SSH key pair
   - ✅ `K3S_TOKEN` - **Auto-generated!** No setup needed
   - `TF_CLOUD_TOKEN` - **Recommended** for state management
3. **Configure backend.tf** - Set your Terraform Cloud organization/workspace
4. **Deploy**: Go to **Actions** → **🚀 Deploy Infrastructure** → **Run workflow**

**⏱️ 10 minutes later**: Enterprise-grade Kubernetes cluster ready! 🎉

📚 **[Complete GitHub Actions Setup Guide →](docs/GITHUB_ACTIONS_DEPLOYMENT.md)**

#### **🎯 Why GitHub Actions?**

- 🔧 **Zero local setup** - No Terraform/Ansible installation needed
- 🔒 **Secure secrets** - API tokens stored safely in GitHub
- 👥 **Team friendly** - Anyone can deploy with proper permissions
- 📊 **Full audit trail** - Every deployment tracked and logged
- 📱 **Deploy anywhere** - From mobile, laptop, or any device
- ⚡ **Consistent environment** - Same Ubuntu runner every time

### **💻 Alternative: Local Deployment**

<details>
<summary>🔧 Local deployment with bootstrap script</summary>

#### 1. Prerequisites

```bash
# Install required tools
brew install terraform ansible
# or
pip install ansible
```

#### 2. Configure

```bash
# Clone repository
git clone https://github.com/jterrazz/jterrazz-infra.git
cd jterrazz-infra

# Configure Terraform variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
nano terraform/terraform.tfvars  # Add your Hetzner API token
```

#### 3. Deploy

```bash
# One-command deployment!
./scripts/bootstrap.sh production
```

</details>

## ⚙️ Configuration

### Terraform Variables (`terraform/terraform.tfvars`)

```hcl
# Required
hcloud_token   = "your-hetzner-api-token"
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKGXffmv69EOpZqZIWmzMgoCD5hCDR0k8iUKO2JJCdER hetzner-20250822"

# Optional (custom domain)
domain_name           = "jterrazz.com"
cloudflare_api_token = "your-cloudflare-token"
cloudflare_zone_id   = "your-zone-id"

# Server specs
server_type     = "cx21"  # 2 vCPU, 4GB RAM, €5/month
server_location = "nbg1"  # Nuremberg, Germany
```

### Ansible Secrets (`ansible/group_vars/all/vault.yml`)

```bash
# Create encrypted secrets file
cd ansible
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml

# Edit the vault file (will prompt for password)
ansible-vault edit group_vars/all/vault.yml

# Add your secrets:
# vault_k3s_token: AUTO-GENERATED! No setup needed for single-node k3s
vault_tailscale_auth_key: "tskey-auth-your-tailscale-key"  # From Tailscale admin
```

### Get Tailscale Auth Key

1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. Generate a new auth key
3. Add it to your vault.yml file

## 📋 What Gets Deployed

### 🏗️ **Infrastructure (Managed by Ansible)**

| Component     | Purpose                  | Access                           |
| ------------- | ------------------------ | -------------------------------- |
| **k3s**       | Kubernetes cluster       | `kubectl get nodes`              |
| **Traefik**   | Ingress & load balancer  | Automatic routing & SSL          |
| **Portainer** | Kubernetes management UI | `https://portainer.local/.com`   |
| **ArgoCD**    | GitOps platform          | `https://argocd.local/.com`      |
| **Security**  | VPS hardening            | UFW/fail2ban/audit/auto-updates  |
| **Tailscale** | Private VPN access       | Private IP for management (prod) |

### 🚀 **Applications (Managed by ArgoCD)**

ArgoCD is **only for your applications** - not infrastructure components. Example:

```yaml
# kubernetes/argocd/my-app.yml.template
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
spec:
  source:
    repoURL: https://github.com/your-org/your-app
    path: k8s/
  destination:
    server: https://kubernetes.default.svc
    namespace: default
```

## 🎛️ Management

### Status Dashboard

```bash
# Comprehensive infrastructure overview
make status
```

**Shows everything:**

- ✅ VM details, CPU, memory, disk usage
- 🔒 Port security analysis (OPEN/PRIVATE/BLOCKED)
- 🛡️ Security services (UFW, fail2ban, auditd)
- 📊 System stats (uptime, load, failed logins, updates)
- ☸️ Kubernetes services and pods
- 🎯 ArgoCD applications

### Access Your Cluster

```bash
# Kubeconfig created automatically at:
export KUBECONFIG=./local-kubeconfig.yaml

# Or SSH into VM directly
make ssh
```

### ArgoCD Access

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Local: https://argocd.local
# Production: https://argocd.yourdomain.com
# User: admin, Password: (from above)
```

### Deploy Your Applications

```bash
# Use ArgoCD for GitOps deployment (recommended)
kubectl apply -f kubernetes/argocd/my-app.yml

# Direct kubectl (for development)
kubectl apply -f my-manifests.yml

# Via Helm (if needed)
helm install my-app bitnami/nginx
```

## 🛠️ Development

### Testing Infrastructure Changes

```bash
# Test Ansible syntax
cd ansible
ansible-playbook site.yml --syntax-check

# Test local deployment
make stop && make start

# Check comprehensive status
make status
```

### Adding Your Applications

Create ArgoCD applications in `kubernetes/argocd/`:

```yaml
# kubernetes/argocd/my-app.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-app-repo
    path: k8s/
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Infrastructure Components

**All infrastructure** is deployed automatically by Ansible in `site.yml`:

- Kubernetes manifests in `kubernetes/` folder
- No manual deployment scripts needed
- Consistent across local development and production

## 💰 Cost Breakdown

| Resource     | Cost/Month | Description                               |
| ------------ | ---------- | ----------------------------------------- |
| Hetzner cx21 | €5.00      | 2 vCPU, 4GB RAM, 40GB SSD (Nuremberg, DE) |
| Floating IP  | €1.00      | Static IP address                         |
| **Total**    | **€6.00**  | (~$6.50 USD)                              |

✅ **EU-based hosting** - GDPR compliant, low latency for European users

## 🔒 Security Features

### **🛡️ Consistent Security (Local + Production):**

- ✅ **UFW Firewall** - Smart port access control (OPEN/PRIVATE/BLOCKED)
- ✅ **SSH Hardening** - Key-only auth, no root login, secure ciphers
- ✅ **fail2ban Protection** - Automatic IP blocking for suspicious activity
- ✅ **Audit Logging** - System changes tracked via auditd
- ✅ **Automatic Updates** - Security patches applied automatically
- ✅ **Security Dashboard** - Comprehensive status monitoring

### **🌐 Network Security:**

- ✅ **Smart Port Analysis** - Real-time firewall rule evaluation
- ✅ **SSL Everywhere** - Let's Encrypt (prod) + self-signed (local)
- ✅ **Private Management** - Kubernetes API restricted to internal networks
- ✅ **Tailscale VPN** - Secure remote access (production)

### **☸️ Kubernetes Security:**

- ✅ **RBAC Enabled** - Role-based access control
- ✅ **Network Policies** - Service-to-service restrictions
- ✅ **Secret Management** - Encrypted credential storage
- ✅ **Security Context** - Pod security standards enforced

### **📊 Security Monitoring:**

The `make status` command shows real-time security posture:

- Port access levels and firewall status
- Security service health (UFW, fail2ban, auditd)
- Failed login attempts and system integrity
- Kubernetes cluster security overview

## 🎯 Why This Architecture?

Our **Ansible-first** Infrastructure as Code approach provides:

- ✅ **One Source of Truth** - Single `site.yml` playbook for everything
- ✅ **Environment Consistency** - Identical local/production deployment
- ✅ **Idempotent & Safe** - Run multiple times without issues
- ✅ **Version Controlled** - All infrastructure changes tracked in Git
- ✅ **Zero Manual Steps** - Complete automation from VM to applications
- ✅ **Professional Grade** - Industry-standard tools (Ansible + k3s + Traefik)
- ✅ **Maintainable** - Clear separation of infrastructure vs applications
- ✅ **Scalable** - Easy to extend for new environments or services

**Key Innovation:** ArgoCD manages **only applications**, while Ansible handles **all infrastructure** - clean separation of concerns!

## 🤝 Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature/amazing-feature`
3. Test changes locally:

   ```bash
   # Test Ansible syntax
   cd ansible && ansible-playbook site.yml --syntax-check

   # Test full deployment
   make stop && make start && make status
   ```

4. Commit changes: `git commit -m 'Add amazing feature'`
5. Push branch: `git push origin feature/amazing-feature`
6. Create Pull Request

## 📞 Support

- 🐛 **Issues**: GitHub Issues
- 💬 **Discussions**: GitHub Discussions
- 📚 **Terraform Docs**: [terraform.io](https://terraform.io)
- 📚 **Ansible Docs**: [docs.ansible.com](https://docs.ansible.com)
- 📚 **k3s Docs**: [k3s.io](https://k3s.io)

## 📜 License

MIT License - see [LICENSE](LICENSE) file.

---

**Made with ❤️ for modern DevOps practices**
