# 🏠 Local Development Environment

Test your Kubernetes and Ansible configurations locally using Docker before deploying to your VPS.

## 🎯 Why Local Development?

### **✅ Benefits:**

- **Fast iteration** - Test changes in seconds, not minutes
- **Cost-effective** - No VPS costs for testing
- **Safe testing** - Break things without consequences
- **Offline development** - Work without internet
- **Debug easily** - Full access to logs and debugging

### **🔄 Development Workflow:**

```
1. 💻 Test locally     → Docker containers
2. ✅ Validate setup   → Ansible + k3s locally
3. 🚀 Deploy to VPS    → GitHub Actions + Terraform
```

## 📋 Prerequisites

### **Required:**

- **Docker** & **Docker Compose** - Container runtime
- **Ansible** - Configuration management (`pip install ansible`)
- **kubectl** - Kubernetes CLI

### **Optional but Recommended:**

- **k9s** - Kubernetes TUI (`brew install k9s`)
- **kubectx** - Context switching (`brew install kubectx`)

## 🚀 Quick Start

### **🎯 Easy Way (Using Makefile):**

```bash
# Complete development setup in one command
make dev-full

# Or step by step:
make local-start      # Start Docker containers
make local-ansible    # Run Ansible configuration  
make local-kubeconfig # Get kubeconfig
make local-test       # Test Kubernetes

# Other useful commands:
make help            # Show all available commands
make local-status    # Check environment status
make local-shell     # SSH into container
```

### **📜 Script Way (Manual):**

```bash
# Start Docker containers
./scripts/local-dev.sh start

# Check status
./scripts/local-dev.sh status

# Test playbook (dry-run)
./scripts/local-dev.sh ansible --check

# Apply configuration
./scripts/local-dev.sh ansible

# Get kubeconfig
./scripts/local-dev.sh get-kubeconfig

# Test cluster
./scripts/local-dev.sh test-k8s
```

**💡 Tip:** The Makefile provides convenient shortcuts for all common operations. Use `make help` to see all available commands!

## 🏗️ Architecture Overview

### **Docker Environment:**

```
┌─────────────────────────────────────────────────────────────┐
│ Host Machine (macOS/Linux)                                 │
├─────────────────────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ jterrazz-server (Ubuntu 22.04) - Single Container      │ │
│ │ ├── SSH Server (port 2222)                             │ │
│ │ ├── k3s Kubernetes Cluster                             │ │
│ │ │   ├── Portainer (pod)                                │ │
│ │ │   ├── Nginx Ingress Controller                       │ │
│ │ │   ├── ArgoCD (pod)                                   │ │
│ │ │   └── Your Apps/Databases (pods)                     │ │
│ │ └── Host Services (installed by Ansible)               │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Key Point**: Everything runs inside the **single Ubuntu container**, just like on your real VPS. Databases, if needed, are deployed as **Kubernetes pods** inside k3s.

### **Network Mapping:**

| Service    | Container Port | Host Port | Access URL                                |
| ---------- | -------------- | --------- | ----------------------------------------- |
| SSH        | 22             | 2222      | `ssh ubuntu@localhost -p 2222`            |
| HTTP       | 80             | 80        | `http://localhost`                        |
| HTTPS      | 443            | 443       | `https://localhost`                       |
| k3s API    | 6443           | 6443      | `kubectl --server https://localhost:6443` |
| Portainer  | 9000           | 9000      | `http://localhost:9000` (via k3s ingress) |

**Note**: Databases (PostgreSQL, Redis, etc.) run as **Kubernetes pods** inside k3s, not as separate Docker containers.

## 📖 Detailed Usage

### **🔧 Makefile Commands (Recommended):**

```bash
# Environment Management
make local-start         # Start Docker environment
make local-stop          # Stop environment (keeps data)
make local-clean         # Clean everything (removes all data!)
make local-status        # Check environment status
make dev-reset           # Stop -> Clean -> Start (full reset)

# Ansible Operations  
make local-ansible       # Run full Ansible playbook
make local-ansible-check # Dry-run (check mode)
make local-ansible-tags TAGS=k3s,helm  # Run specific roles

# Kubernetes Management
make local-kubeconfig    # Get kubeconfig from k3s
make local-test          # Test Kubernetes connectivity
make k8s-nodes           # Show cluster nodes
make k8s-pods            # Show all pods
make k8s-services        # Show all services

# Development Workflows
make dev-full            # Complete cycle: clean -> start -> ansible -> test
make dev-quick           # Quick test: start -> ansible -> kubeconfig

# Utilities
make local-shell         # SSH into container
make local-logs          # Show container logs  
make local-exec CMD="kubectl get nodes"  # Execute command in container
make help               # Show all commands
```

### **📜 Script Commands (Alternative):**

```bash
# Start environment
./scripts/local-dev.sh start

# Stop environment (keeps data)
./scripts/local-dev.sh stop

# Clean everything (removes all data!)
./scripts/local-dev.sh clean

# Check status
./scripts/local-dev.sh status
```

### **Ansible Testing:**

```bash
# Full playbook dry-run
./scripts/local-dev.sh ansible --check

# Apply full configuration
./scripts/local-dev.sh ansible

# Run specific roles only
./scripts/local-dev.sh ansible --tags k3s,helm

# Skip specific roles  
./scripts/local-dev.sh ansible --skip-tags security,tailscale

# Verbose output for debugging
./scripts/local-dev.sh ansible -vv
```

**Key Feature**: Uses the **same unified playbook** (`site.yml`) as production, but with different inventory and variables! No separate local playbook needed.

### **Kubernetes Operations:**

```bash
# Get kubeconfig
./scripts/local-dev.sh get-kubeconfig

# Set environment
export KUBECONFIG="$(pwd)/local-kubeconfig.yaml"

# Test connectivity
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A

# Use k9s for interactive management
k9s

# Deploy test applications
kubectl apply -f kubernetes/applications/
```

### **Direct Container Access:**

```bash
# SSH into main container
ssh ubuntu@localhost -p 2222
# Password: localdev

# Docker exec (root access)
docker exec -it jterrazz-infra-server bash

# View logs
docker logs jterrazz-infra-server

# Monitor resource usage
docker stats
```

## 🔧 Configuration

### **Unified Playbook Architecture:**

**Key Innovation**: Uses the **same `ansible/site.yml` playbook** for both local and production! Environment differences handled via inventory and variables.

**`ansible/site.yml`** - Unified playbook with smart conditionals:
```yaml
- name: JTerrazz Infrastructure Setup
  hosts: all  # Works with any inventory
  
  roles:
    - role: security
      when: not (skip_security | default(false))  # Skipped in local
      
    - role: tailscale
      when: not (skip_tailscale | default(false)) # Skipped in local
      
    - role: k3s     # Always runs
    - role: helm    # Always runs
    # etc...
```

### **Local Environment Configuration:**

**`ansible/inventories/local/hosts.yml`** - Local container targeting:
```yaml
jterrazz-local:
  ansible_host: localhost
  ansible_port: 2222
  environment_type: "local"        # Triggers local behavior  
  skip_tailscale: true            # No VPN in local env
  skip_security: true             # Keep SSH accessible  
  use_self_signed_certs: true     # No real SSL needed
```

**`ansible/group_vars/all/local.yml`** - Local-specific variables:
```yaml
environment_type: "local"
security_level: "development"
k3s_token: "local-dev-token-insecure-but-fine"
argocd_admin_password: "localdev123"
```

### **Production Environment Configuration:**

**`ansible/inventories/production/hosts.yml`** - Production VPS targeting:
```yaml
jterrazz-vps:
  ansible_host: "{{ server_ip }}"    # Real VPS IP
  environment_type: "production"     # Triggers production behavior
  skip_tailscale: false             # Enable VPN
  skip_security: false              # Full security hardening
  use_self_signed_certs: false      # Real SSL certificates
```

### **Environment Variables:**

```bash
# Set kubeconfig
export KUBECONFIG="$(pwd)/local-kubeconfig.yaml"

# Enable Ansible debugging
export ANSIBLE_DEBUG=1

# Use local inventory by default
export ANSIBLE_INVENTORY="ansible/inventories/local/hosts.yml"
```

## 🔍 Testing Scenarios

### **1. Full Infrastructure Test:**

```bash
# Complete local deployment
./scripts/local-dev.sh start
./scripts/local-dev.sh ansible
./scripts/local-dev.sh get-kubeconfig
kubectl get pods -A
```

### **2. Component-Specific Testing:**

```bash
# Test only k3s installation
./scripts/local-dev.sh ansible --tags k3s

# Test only Nginx Ingress
./scripts/local-dev.sh ansible --tags nginx-ingress

# Test application deployment
kubectl apply -f kubernetes/applications/portainer.yml
```

### **3. Configuration Changes:**

```bash
# Modify Ansible variables in group_vars/all/local.yml
# Test changes
./scripts/local-dev.sh ansible --diff

# Verify with kubectl
kubectl get configmaps -A
```

### **4. Troubleshooting:**

```bash
# Check Ansible connectivity
ansible -i ansible/inventories/local/hosts.yml -m ping all

# Debug SSH connection
ssh -vvv ubuntu@localhost -p 2222

# Check k3s status
docker exec jterrazz-infra-server systemctl status k3s

# View k3s logs
docker exec jterrazz-infra-server journalctl -u k3s
```

## 🚨 Troubleshooting

### **Common Issues:**

#### **🔐 SSH Connection Failed:**

```bash
# Wait longer for container startup
./scripts/local-dev.sh status

# Check container logs
docker logs jterrazz-infra-server

# Reset SSH known hosts
ssh-keygen -R "[localhost]:2222"
```

#### **☸️ k3s Not Starting:**

```bash
# Check if running in privileged mode
docker inspect jterrazz-infra-server | grep Privileged

# Restart with clean state
./scripts/local-dev.sh clean
./scripts/local-dev.sh start

# Check kernel modules
docker exec jterrazz-infra-server lsmod | grep ip_tables
```

#### **📦 Ansible Role Failures:**

```bash
# Skip problematic roles
./scripts/local-dev.sh ansible --skip-tags security,tailscale

# Run with maximum verbosity
./scripts/local-dev.sh ansible -vvv

# Check container systemd
docker exec jterrazz-infra-server systemctl status
```

#### **🌐 Port Conflicts:**

```bash
# Check port usage
lsof -i :2222
lsof -i :6443

# Modify docker-compose.yml ports if needed
# Then restart:
./scripts/local-dev.sh stop
./scripts/local-dev.sh start
```

### **Debugging Commands:**

```bash
# Container inspection
docker exec jterrazz-infra-server ps aux
docker exec jterrazz-infra-server netstat -tlnp
docker exec jterrazz-infra-server df -h

# Kubernetes debugging
kubectl describe node
kubectl get events --sort-by='.lastTimestamp'
kubectl logs -n kube-system -l app=local-path-provisioner

# Ansible debugging
export ANSIBLE_DEBUG=1
export ANSIBLE_VERBOSITY=3
```

## 🔄 Local vs Production Differences

| Feature         | Local Development    | Production VPS           |
| --------------- | -------------------- | ------------------------ |
| **Environment** | Docker containers    | Hetzner VPS              |
| **Access**      | localhost ports      | Tailscale VPN            |
| **SSL**         | Self-signed certs    | Let's Encrypt            |
| **Security**    | Relaxed settings     | Hardened (fail2ban, UFW) |
| **SSH**         | Password auth OK     | Key-only auth            |
| **Networking**  | Bridge network       | Public IP + firewall     |
| **Persistence** | Local volumes        | Cloud storage            |
| **DNS**         | localhost/hosts file | Real domain names        |
| **Monitoring**  | Manual inspection    | Production logging       |

## 🎯 Best Practices

### **✅ Do:**

- Test all Ansible changes locally first
- Use `--check` mode before applying changes
- Keep local environment updated (`./scripts/local-dev.sh clean && start`)
- Use realistic test data and configurations
- Document any local-specific workarounds

### **❌ Don't:**

- Use local environment for real workloads
- Store important data in local environment
- Skip security testing (test on VPS)
- Assume local behavior = production behavior
- Commit local kubeconfig files

## 🚀 Next Steps

### **After Local Testing:**

1. **Commit changes** to Git
2. **Push to GitHub**
3. **Deploy via GitHub Actions**:
   - Go to **Actions** → **🚀 Deploy Infrastructure**
   - Select **production** environment
   - Run workflow

### **Continuous Development:**

1. **Make changes** in code
2. **Test locally** with `./scripts/local-dev.sh ansible`
3. **Verify with kubectl**
4. **Deploy to VPS** when ready

---

## 📋 Summary

**Local development environment gives you:**

- ✅ **Fast feedback loop** for Ansible and Kubernetes changes
- ✅ **Safe testing environment** without VPS costs
- ✅ **Full debugging access** to containers and logs
- ✅ **Offline development** capabilities

**Perfect for:**

- 🧪 Testing new Ansible roles
- 📦 Validating Kubernetes manifests
- 🐛 Debugging configuration issues
- 🎓 Learning and experimentation

**Ready to test locally?** → `./scripts/local-dev.sh start` 🚀
