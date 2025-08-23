# Jterrazz Infrastructure

**Modern Infrastructure as Code** for VPS deployment on Hetzner Cloud with **Kubernetes (k3s)**, **GitOps (ArgoCD)**, and **cloud-native tooling**.

## 🎯 What This Deploys

A complete, production-ready infrastructure stack:

- **☁️ Hetzner Cloud VPS** - Affordable, reliable hosting
- **🔐 Kubernetes (k3s)** - Lightweight Kubernetes cluster
- **🌐 Nginx Ingress** - Professional load balancing and routing
- **🔒 cert-manager** - Automatic SSL certificates via Let's Encrypt
- **🔄 ArgoCD** - GitOps continuous deployment
- **🔗 Tailscale** - Secure private network access
- **🛡️ Security** - UFW firewall, fail2ban, automatic updates

## 🏗️ Architecture

```
📱 Your Domain (manager.jterrazz.com)
            ↓
🌐 Cloudflare DNS
            ↓
☁️ Hetzner VPS (Nuremberg, Germany)
  ├── 🔐 k3s Kubernetes Cluster
  ├── 🌐 Nginx Ingress Controller
  ├── 🔒 cert-manager (Auto SSL)
  ├── 🔄 ArgoCD (GitOps)
  └── 🔗 Tailscale (Private Access)
```

## 📁 Project Structure

```
jterrazz-infra/
├── 🚀 .github/workflows/      # GitHub Actions CI/CD
│   └── deploy-infrastructure.yml # Automated deployment
├── 🏗️ terraform/              # Infrastructure provisioning
│   ├── main.tf                # Hetzner Cloud VPS
│   ├── variables.tf           # Configuration options
│   ├── outputs.tf             # Connection details
│   └── backend.tf             # Remote state management
├── ⚙️ ansible/                # Server configuration
│   ├── site.yml               # Unified playbook (local + production)
│   ├── inventories/           # Environment-specific targeting
│   │   ├── local/             # Docker containers
│   │   └── production/        # VPS servers
│   └── roles/                 # Component roles
│       ├── security/          # VPS hardening & protection
│       ├── tailscale/         # Private network
│       ├── k3s/               # Kubernetes cluster
│       ├── helm/              # Package manager
│       ├── cert-manager/      # SSL certificates
│       ├── nginx-ingress/     # Load balancer
│       └── argocd/            # GitOps deployment
├── ☸️ kubernetes/             # Application manifests
│   ├── applications/          # App definitions
│   ├── argocd/               # GitOps configs
│   └── ingress/              # Routing rules
├── 📚 docs/                   # Documentation
│   └── GITHUB_ACTIONS_DEPLOYMENT.md # Deployment guide
├── 📜 scripts/
│   ├── bootstrap.sh          # Local deployment (alternative)
│   └── local-dev.sh          # Local Docker development
└── 🔧 Makefile               # Convenient command shortcuts
```

## 🚀 Quick Start

Choose your deployment method:

### **🏠 Local Development (Test First!)**

**Test everything locally before VPS deployment:**

```bash
# 🎯 Easy way (using Makefile):
make dev-full        # Complete setup: clean -> start -> ansible -> test

# 📜 Direct script way:
./scripts/local-dev.sh start
./scripts/local-dev.sh ansible
./scripts/local-dev.sh get-kubeconfig
./scripts/local-dev.sh test-k8s

# 💡 More Makefile shortcuts:
make local-start     # Start environment
make local-ansible   # Run Ansible  
make local-test      # Test Kubernetes
make help           # See all commands
```

**⚡ Perfect for:** Testing changes, learning, debugging without VPS costs!

**🎯 Key Feature:** Uses the **same unified Ansible playbook** as production - just different inventory and variables!

📚 **[Complete Local Development Guide →](docs/LOCAL_DEVELOPMENT.md)**

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

| Component         | Purpose            | Access                                         |
| ----------------- | ------------------ | ---------------------------------------------- |
| **k3s**           | Kubernetes cluster | `kubectl get nodes`                            |
| **ArgoCD**        | GitOps deployment  | `https://argocd.yourdomain.com`                |
| **Portainer**     | Kubernetes UI      | `https://portainer.yourdomain.com` (Tailscale) |
| **Nginx Ingress** | Load balancer      | Automatic routing                              |
| **cert-manager**  | SSL certificates   | Automatic renewal                              |
| **Tailscale**     | Private access     | Private IP for management tools                |
| **Security**      | VPS hardening      | SSH/UFW/fail2ban/auto-updates                 |

## 🎛️ Management

### Access Your Cluster

```bash
# Get kubeconfig (generated automatically)
export KUBECONFIG=./kubeconfig

# Verify cluster
kubectl get nodes
kubectl get pods --all-namespaces
```

### ArgoCD Access

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Access: https://argocd.yourdomain.com
# User: admin
# Password: (from above command)
```

### Deploy Applications

```bash
# Via ArgoCD (GitOps)
kubectl apply -f kubernetes/applications/my-app.yml

# Via Helm
helm install my-app bitnami/nginx
```

## 🛠️ Development

### Local Testing

```bash
# Test Terraform
cd terraform
terraform plan

# Test Ansible
cd ansible
ansible-playbook -i inventory.yml site.yml --check
```

### Custom Applications

Add your apps to `kubernetes/applications/`:

```yaml
# kubernetes/applications/my-app.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
spec:
  source:
    repoURL: https://github.com/your-org/your-app
    path: k8s/
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: default
```

## 💰 Cost Breakdown

| Resource     | Cost/Month | Description                               |
| ------------ | ---------- | ----------------------------------------- |
| Hetzner cx21 | €5.00      | 2 vCPU, 4GB RAM, 40GB SSD (Nuremberg, DE) |
| Floating IP  | €1.00      | Static IP address                         |
| **Total**    | **€6.00**  | (~$6.50 USD)                              |

✅ **EU-based hosting** - GDPR compliant, low latency for European users

## 🔒 Security Features

### **🛡️ VPS-Level Security:**
- ✅ **SSH Hardening** - Key-only auth, encrypted ciphers, timeouts
- ✅ **UFW Firewall** - Only essential ports open, deny by default
- ✅ **fail2ban** - Automatic IP banning for brute force attacks
- ✅ **Automatic Updates** - Security patches applied daily
- ✅ **Audit Logging** - System changes monitored via auditd
- ✅ **Kernel Hardening** - TCP/IP stack security parameters
- ✅ **Security Monitoring** - Daily status reports and alerts

### **🌐 Network Security:**
- ✅ **Tailscale VPN** - Private network for management tools
- ✅ **SSL Certificates** - Automatic Let's Encrypt for all services
- ✅ **IP Whitelisting** - Restrict management access to Tailscale IPs

### **☸️ Kubernetes Security:**
- ✅ **RBAC** - Role-based access control
- ✅ **Network Policies** - Pod-to-pod communication restrictions
- ✅ **Secret Management** - Encrypted storage of sensitive data
- ✅ **Private Registry** - Secure container image storage

## 🎯 Why Infrastructure as Code?

This modern Infrastructure as Code approach provides:

- ✅ **Idempotent** - Safe to run multiple times
- ✅ **Version controlled** - Track all changes in Git
- ✅ **Professional** - Industry-standard tools (Terraform + Ansible + k3s)
- ✅ **Scalable** - Easy to add new servers or applications
- ✅ **Maintainable** - Clear, well-documented configuration

## 🤝 Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature/amazing-feature`
3. Test changes: `terraform validate && ansible-playbook --syntax-check site.yml`
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
