# Local vs Production

📊 **Key differences between environments**

## Quick Overview

| Aspect             | **Local Development**     | **Production**             |
| ------------------ | ------------------------- | -------------------------- |
| **🏠 Environment** | Multipass VM on macOS     | Hetzner Cloud VPS          |
| **🌐 DNS**         | `.local` domains via mDNS | Real domains via DNS       |
| **🔒 SSL**         | Self-signed certificates  | Let's Encrypt certificates |
| **🚪 Access**      | Direct IP + localhost     | Tailscale VPN + public     |
| **📦 Deployment**  | Direct kubectl + ArgoCD   | Full GitOps via ArgoCD     |
| **🔧 Management**  | `make` commands           | Terraform + Ansible        |

## Infrastructure

| Component     | **Local**              | **Production**        |
| ------------- | ---------------------- | --------------------- |
| **Host OS**   | macOS (via Multipass)  | Ubuntu 24.04 LTS      |
| **VM/Server** | Ubuntu 24.04 LTS VM    | Hetzner Cloud VPS     |
| **CPU**       | 4 vCPUs (configurable) | 2-4 vCPUs (scalable)  |
| **Memory**    | 8GB (configurable)     | 4-16GB (scalable)     |
| **Storage**   | 20GB (local disk)      | 40-160GB SSD          |
| **Network**   | Private (192.168.64.x) | Public IP + Tailscale |

## Services & Access

| Service            | **Local URL**             | **Production URL**                 |
| ------------------ | ------------------------- | ---------------------------------- |
| **Landing Page**   | `https://app.local`       | `https://yourdomain.com`           |
| **ArgoCD**         | `https://argocd.local`    | `https://argocd.yourdomain.com`    |
| **Portainer**      | `https://portainer.local` | `https://portainer.yourdomain.com` |
| **Kubernetes API** | `local-kubeconfig.yaml`   | VPN + kubectl                      |

## DNS & SSL

| Aspect         | **Local**                | **Production**       |
| -------------- | ------------------------ | -------------------- |
| **Provider**   | Self-signed              | Let's Encrypt        |
| **Validity**   | 365 days                 | 90 days (auto-renew) |
| **Trust**      | Manual browser accept    | Globally trusted     |
| **Resolution** | mDNS broadcaster (5-10s) | Real DNS (instant)   |

## Deployment

| Operation         | **Local**       | **Production**       |
| ----------------- | --------------- | -------------------- |
| **Initial Setup** | `make start`    | `terraform apply`    |
| **App Deploy**    | `make k8s`      | Git push → ArgoCD    |
| **Updates**       | `kubectl apply` | Git → ArgoCD sync    |
| **Monitoring**    | `make status`   | Grafana + Prometheus |

## Local-Only Features

- **mDNS Publisher**: Publishes `.local` domains
- **Self-signed TLS**: Browser warnings (accept manually)
- **Direct VM Access**: No VPN required
- **Faster Iteration**: Direct kubectl access

## Production-Only Features

- **Real DNS**: Proper domain resolution
- **Let's Encrypt**: Trusted SSL certificates
- **Tailscale VPN**: Secure remote access
- **Cloud Integration**: Hetzner Cloud APIs
- **Monitoring Stack**: Full observability

## Migration Checklist

**Local → Production:**

- [ ] Update DNS records to point to production IP
- [ ] Configure Let's Encrypt for SSL certificates
- [ ] Set up Tailscale VPN access
- [ ] Update ArgoCD repository URLs
- [ ] Test all application endpoints
