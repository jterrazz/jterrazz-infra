# 🚀 GitHub Actions Deployment

Deploy your infrastructure automatically using GitHub Actions - no local tools required!

## 🎯 Why GitHub Actions?

### ✅ **Better than Local Deployment:**

- **🔧 No local dependencies** - No need to install Terraform/Ansible
- **🔒 Secure secrets management** - API tokens stored in GitHub Secrets
- **📊 Full audit trail** - Every deployment tracked and logged
- **👥 Team collaboration** - Anyone can trigger deployments
- **🔄 Consistent environment** - Same Ubuntu runner every time
- **📱 Deploy from anywhere** - Just click a button in GitHub

### **Local vs GitHub Actions:**

| Aspect            | Local Deployment            | GitHub Actions             |
| ----------------- | --------------------------- | -------------------------- |
| **Setup**         | Install Terraform + Ansible | Just configure secrets     |
| **Secrets**       | Store locally (risky)       | GitHub Secrets (secure)    |
| **Environment**   | Your machine (varies)       | Ubuntu runner (consistent) |
| **Collaboration** | Share credentials           | Team access control        |
| **Audit**         | No tracking                 | Full deployment history    |
| **Access**        | Need laptop                 | Deploy from mobile!        |

## ⚙️ Setup Instructions

### 1. **Required GitHub Secrets**

Go to your repository → **Settings** → **Secrets and variables** → **Actions**

#### **🔐 Add these Repository Secrets:**

| Secret Name       | Description             | Example                               |
| ----------------- | ----------------------- | ------------------------------------- |
| `HCLOUD_TOKEN`    | Hetzner Cloud API token | `abcdef123456...`                     |
| `SSH_PRIVATE_KEY` | Your SSH private key    | `-----BEGIN OPENSSH PRIVATE KEY-----` |
| `SSH_PUBLIC_KEY`  | Your SSH public key     | `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...` |

#### **🌐 Optional Domain Secrets:**

| Secret Name            | Description                        | Required for Custom Domain |
| ---------------------- | ---------------------------------- | -------------------------- |
| `DOMAIN_NAME`          | Your domain (e.g., `jterrazz.com`) | ✅ For custom domain       |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token               | ✅ For automatic DNS       |
| `CLOUDFLARE_ZONE_ID`   | Cloudflare zone ID                 | ✅ For automatic DNS       |

#### **☁️ State Management Secret:**

| Secret Name     | Description                    | Required for Reusability |
| --------------- | ------------------------------ | ------------------------ |
| `TF_CLOUD_TOKEN` | Terraform Cloud API token     | ✅ **Highly Recommended** |

**⚠️ Important**: Without remote state, Terraform will try to create resources every time instead of reusing them!

📚 **[Complete State Management Guide →](TERRAFORM_STATE_MANAGEMENT.md)**

#### **🔗 Optional Tailscale Secret:**

| Secret Name          | Description        | Required for Private Access |
| -------------------- | ------------------ | --------------------------- |
| `TAILSCALE_AUTH_KEY` | Tailscale auth key | ✅ For VPN access           |

### 2. **Optional Repository Variables**

**Settings** → **Secrets and variables** → **Actions** → **Variables** tab:

| Variable Name     | Description            | Default     |
| ----------------- | ---------------------- | ----------- |
| `SERVER_TYPE`     | Hetzner server type    | `cx21`      |
| `SERVER_LOCATION` | Hetzner location       | `nbg1`      |
| `SUBDOMAIN`       | Subdomain for services | `manager`   |
| `ALLOWED_SSH_IPS` | IPs allowed to SSH     | `0.0.0.0/0` |
| `ALLOWED_K8S_IPS` | IPs allowed to K8s API | `0.0.0.0/0` |

### 3. **Get Required Tokens**

#### **🏗️ Hetzner Cloud Token:**

1. Go to [Hetzner Console](https://console.hetzner.cloud/)
2. Select your project → **Security** → **API Tokens**
3. **Generate API Token** with **Read & Write** permissions
4. Copy token → Add as `HCLOUD_TOKEN` secret

#### **🔐 SSH Key Pair:**

```bash
# Generate new SSH key pair
ssh-keygen -t ed25519 -f ~/.ssh/hetzner-key -C "github-actions"

# Private key (add as SSH_PRIVATE_KEY secret)
cat ~/.ssh/hetzner-key

# Public key (add as SSH_PUBLIC_KEY secret)
cat ~/.ssh/hetzner-key.pub
```

#### **⚡ k3s Token:**

✅ **Auto-generated!** Ansible creates a secure k3s token automatically for single-node clusters. No manual setup required!

#### **☁️ Terraform Cloud Token (Recommended):**

1. Sign up at [app.terraform.io](https://app.terraform.io)
2. **Create Organization** → Choose a name (e.g., `yourname-infra`)
3. **Create Workspace** → Name: `jterrazz-infra-production`
4. **User Settings** → **Tokens** → **Create API token**
5. Copy token → Add as `TF_CLOUD_TOKEN` secret

**Why needed?** Ensures Terraform reuses existing resources instead of trying to create duplicates on each deployment!

#### **🔗 Tailscale Auth Key (Optional):**

1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. **Generate auth key** (reusable, no expiry)
3. Copy key → Add as `TAILSCALE_AUTH_KEY` secret

#### **🌐 Cloudflare Tokens (Optional):**

1. Go to [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. **Create Token** → **Custom token**
3. **Permissions**: `Zone:Zone:Read`, `Zone:DNS:Edit`
4. **Zone Resources**: `Include: Specific zone: yourdomain.com`
5. Copy token → Add as `CLOUDFLARE_API_TOKEN` secret
6. Get Zone ID from domain overview → Add as `CLOUDFLARE_ZONE_ID` secret

## 🚀 How to Deploy

### **Method 1: Manual Trigger (Recommended)**

1. Go to your repository on GitHub
2. **Actions** tab → **🚀 Deploy Infrastructure**
3. **Run workflow** button
4. Select options:
   - **Environment**: `production` / `staging` / `development`
   - **Action**: `deploy` / `destroy` / `plan-only`
5. **Run workflow**

### **Method 2: API/CLI Trigger**

```bash
# Deploy production
gh workflow run deploy-infrastructure.yml \
  -f environment=production \
  -f action=deploy

# Plan only (see what changes)
gh workflow run deploy-infrastructure.yml \
  -f environment=production \
  -f action=plan-only

# Destroy infrastructure
gh workflow run deploy-infrastructure.yml \
  -f environment=production \
  -f action=destroy
```

## 📊 Deployment Process

### **What Happens During Deployment:**

1. **🔧 Setup Tools** - Install Terraform & Ansible on runner
2. **🏗️ Provision VPS** - Create server, networking, DNS on Hetzner
3. **🛡️ Harden Security** - SSH, UFW, fail2ban, automatic updates
4. **🔗 Setup VPN** - Configure Tailscale private network
5. **⚙️ Install k3s** - Kubernetes cluster with security policies
6. **📦 Deploy Apps** - ArgoCD, Portainer, cert-manager, ingress
7. **📥 Download Assets** - Get kubeconfig, connection details
8. **📊 Show Results** - Access URLs, security status, next steps

### **Deployment Timeline:**

- **Terraform Apply**: ~2-3 minutes
- **Server Boot**: ~1-2 minutes
- **Ansible Setup**: ~5-8 minutes
- **Total Time**: **~10 minutes** ⚡

## 🎛️ After Deployment

### **1. Access Your Infrastructure**

Check the **Actions** run summary for:

- ✅ Server IP address
- ✅ SSH connection command
- ✅ Service URLs (ArgoCD, Portainer)
- ✅ Next steps

### **2. Download Kubeconfig**

1. Go to successful **Actions** run
2. **Artifacts** section → Download `kubeconfig-production`
3. Extract and use:

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes
```

### **3. Get ArgoCD Password**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### **4. Access Services**

- **ArgoCD**: `https://argocd.yourdomain.com` (admin + password above)
- **Portainer**: `https://portainer.yourdomain.com` (Tailscale only)
- **Homepage**: `https://yourdomain.com`

### **5. Verify Security Setup**

```bash
# Check security status
ssh root@your-server-ip '/usr/local/bin/security-status'

# Check firewall status
ssh root@your-server-ip 'ufw status numbered'

# Check fail2ban status
ssh root@your-server-ip 'fail2ban-client status'

# View recent security events
ssh root@your-server-ip 'tail -f /var/log/fail2ban.log'
```

## 🔒 Security Benefits

### **GitHub Actions Security:**

- ✅ **Encrypted secrets** - Tokens never exposed in logs
- ✅ **Audit trail** - Every deployment tracked
- ✅ **Access control** - Team permissions via GitHub
- ✅ **No local storage** - Credentials never leave GitHub
- ✅ **Isolated environment** - Fresh runner for each deployment

### **Infrastructure Security:**

- ✅ **SSH Hardening** - Key-only auth, encrypted ciphers, connection timeouts
- ✅ **UFW Firewall** - Deny by default, only essential ports open
- ✅ **fail2ban Protection** - Automatic IP banning for brute force attacks
- ✅ **Automatic Updates** - Security patches applied daily
- ✅ **Audit Logging** - System changes monitored via auditd
- ✅ **Tailscale VPN** - Private network for management tools
- ✅ **Let's Encrypt SSL** - Automatic HTTPS certificates
- ✅ **Kubernetes RBAC** - Role-based access control
- ✅ **Network Policies** - Pod-to-pod communication restrictions

## 🛠️ Troubleshooting

### **Common Issues:**

#### **❌ "Hetzner API authentication failed"**

- Check `HCLOUD_TOKEN` secret is correct
- Ensure token has **Read & Write** permissions

#### **❌ "SSH connection failed"**

- Verify `SSH_PRIVATE_KEY` matches `SSH_PUBLIC_KEY`
- Check key format (should include `-----BEGIN/END-----`)

#### **❌ "Domain not found"**

- Verify `CLOUDFLARE_ZONE_ID` is correct
- Check `DOMAIN_NAME` secret matches your domain

#### **❌ "Ansible playbook failed"**

- Check server has internet connectivity
- Verify all required secrets are set

### **Getting Help:**

- Check **Actions** logs for detailed error messages
- Use `plan-only` action to preview changes
- Run `destroy` action to clean up failed deployments

## 🎉 Benefits Summary

**With GitHub Actions, you get:**

- 🚀 **One-click deployments** from anywhere
- 🔒 **Enterprise-grade security**
- 👥 **Team collaboration** capabilities
- 📊 **Full deployment history**
- ⚡ **Simplified setup** → Just 3 secrets needed (k3s token auto-generated!)
- ⚡ **10-minute deployment** → production infrastructure
- 💰 **€6/month** total cost (same as before!)

**Your infrastructure deployment is now as easy as clicking a button!** 🎊
