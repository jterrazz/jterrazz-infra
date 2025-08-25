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
- **Real Ubuntu VM** - Production-like environment via Multipass
- **`.local` domains** - Automatic mDNS resolution (no hosts file editing)
- **HTTPS everywhere** - Self-signed certificates with shared SSL
- **One-command setup** - `make start` creates VM + Kubernetes + everything
- **Production security** - Same UFW/fail2ban configuration as production

### ☁️ **Production Ready**
- **Hetzner Cloud VPS** - Affordable, reliable European hosting (€6/month)
- **Kubernetes (k3s)** - Lightweight, production-grade cluster
- **Traefik Ingress** - Cloud-native load balancing and routing
- **Let's Encrypt SSL** - Automatic certificate management
- **ArgoCD GitOps** - Git-driven application deployments
- **Security Hardened** - UFW firewall, fail2ban, audit logging, auto-updates

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
📱 Your Domain (manager.yourdomain.com)
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

## 📋 Available Commands

```bash
# 🏠 Local Development
make start              # Complete setup - VM + K8s + apps
make status             # Show health, services, URLs
make ssh                # SSH into VM
make stop               # Delete VM

# ☁️ Production (see docs/PRODUCTION.md)
./scripts/bootstrap.sh  # Deploy to production

# 🛠️ Utilities  
make deps               # Check required tools
make clean              # Force cleanup everything
```

## 🎯 Why This Architecture?

**Clean Separation of Concerns:**
```
🔄 INFRASTRUCTURE LAYER (Ansible + Kustomize)
   └── OS setup, k3s installation, infrastructure components

🚀 APPLICATION LAYER (ArgoCD GitOps)  
   └── User applications from separate repositories
```

**Key Benefits:**
- ✅ **One Source of Truth** - Single `site.yml` playbook for everything
- ✅ **Environment Consistency** - Identical local/production deployment  
- ✅ **Kubernetes-native** - Infrastructure managed via Kustomize
- ✅ **Professional Grade** - Industry-standard tools (Ansible + k3s + Traefik)

## 📁 Project Structure

```
jterrazz-infra/
├── 🏗️ terraform/              # Infrastructure provisioning
├── ⚙️ ansible/                # Complete infrastructure automation
│   ├── site.yml               # Unified playbook (everything!)
│   ├── inventories/           # Environment targeting
│   ├── group_vars/            # Environment configuration
│   └── roles/                 # Security, k3s components
├── ☸️ kubernetes/             # Kubernetes-native infrastructure
│   ├── applications/          # ArgoCD user application templates
│   └── infrastructure/        # Infrastructure components (Kustomize)
└── 📜 scripts/                # Development utilities
```

## 🚀 Deploy Your Applications

Create ArgoCD applications pointing to your repositories:

```yaml
# kubernetes/applications/my-app.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/your-org/your-app-repo
    path: k8s/
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## 🛠️ Prerequisites

**Local Development:**
- [Multipass](https://multipass.run/) - VM management  
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) - Configuration

**Production Deployment:**
- [Terraform](https://terraform.io/) - Infrastructure
- [Hetzner Cloud Account](https://hetzner.cloud/) - Hosting

## 🤝 Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature/amazing-feature`
3. Test locally: `make stop && make start && make status`
4. Submit Pull Request

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for detailed guidelines.

## 📞 Support

- 🐛 **Issues**: [GitHub Issues](https://github.com/jterrazz/jterrazz-infra/issues)
- 💬 **Discussions**: [GitHub Discussions](https://github.com/jterrazz/jterrazz-infra/discussions)
- 📚 **Documentation**: [docs/](docs/)

## 📜 License

MIT License - see [LICENSE](LICENSE) file.

---

**Made with ❤️ for modern DevOps practices**