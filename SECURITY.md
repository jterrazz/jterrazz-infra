# 🔐 Security Architecture & Implementation

This document outlines the comprehensive security measures implemented in the Jterrazz Infrastructure project, covering both local development and production environments.

## 🏗️ Security Architecture Overview

Our infrastructure follows a **defense-in-depth** strategy with multiple security layers:

```
Internet → Firewall → VPN → Ingress → Services → Containers
   ↓         ↓        ↓       ↓         ↓          ↓
 Public    UFW/     Tailscale Traefik  ClusterIP  Security
 Access   Hetzner   IP Filter  TLS     Internal   Context
```

## 🛡️ Network Security

### Firewall Configuration (UFW)
**Location**: `ansible/roles/security/defaults/main.yml`

```yaml
security_ufw_rules:
  - { port: "22", proto: "tcp", rule: "allow", comment: "SSH" }
  - { port: "80", proto: "tcp", rule: "allow", comment: "HTTP (Let's Encrypt)" }
  - { port: "443", proto: "tcp", rule: "allow", comment: "HTTPS" }
  - { port: "6443", proto: "tcp", rule: "allow", comment: "Kubernetes API" }
  - { port: "41641", proto: "udp", rule: "allow", comment: "Tailscale" }
```

**Why**: Only essential ports are exposed. Default policy denies all incoming traffic.

### Kubernetes API Restriction
**Location**: `terraform/variables.tf`

```hcl
allowed_k8s_ips = ["100.64.0.0/10"]  # Tailscale IP range only
```

**Why**: Kubernetes API (port 6443) is restricted to Tailscale VPN users only. This prevents unauthorized access to cluster management.

**Impact Analysis**:
- ✅ **Internet → K8s API**: Blocked
- ✅ **Tailscale → K8s API**: Allowed  
- ✅ **Local Dev (VM-VM)**: Unaffected (private network)
- ✅ **Production Ansible**: Unaffected (localhost access)

## 🔒 VPN & Access Control

### Tailscale Integration
**Why Tailscale**: 
- Zero-trust network access
- Automatic WireGuard encryption
- Identity-based access control
- No complex VPN server management

**Implementation**:
- **Production**: All administrative access via Tailscale
- **CI/CD**: GitHub Actions connects via Tailscale OAuth
- **Local Dev**: Uses private VM network (not affected)

**Configuration**: `ansible/roles/tailscale/`

## 🔐 TLS/HTTPS Security

### Production TLS
- **Real certificates**: Let's Encrypt via ACME
- **Automatic renewal**: Traefik handles certificate lifecycle
- **HTTPS redirect**: All HTTP traffic redirected to HTTPS

### Local Development TLS
- **Self-signed certificates**: Traefik generates automatically
- **HTTPS-only**: Global HTTP→HTTPS redirect enforced
- **Production parity**: Same TLS workflow as production

**Configuration**: `kubernetes/traefik/global-https-redirect.yml`

```yaml
# Enforces HTTPS for ALL traffic
redirectScheme:
  scheme: https
  permanent: true
```

## 🚪 Ingress Security

### Traefik Middleware
**Location**: `kubernetes/traefik/middleware.yml`

```yaml
# Tailscale IP restriction
ipWhiteList:
  sourceRange:
    - "100.64.0.0/10"  # Tailscale only
    - "127.0.0.1/32"   # Localhost
    - "10.0.0.0/8"     # Private networks
```

**Why**: Additional layer of protection at ingress level, even if firewall is bypassed.

### Service Isolation
- **ClusterIP Services**: Internal-only by default
- **No NodePort exposure**: Services not directly accessible from internet
- **Ingress-only access**: All external access through controlled ingress points

## 🖥️ SSH Security

### SSH Hardening
**Location**: `ansible/roles/security/templates/sshd_config.j2`

```yaml
# Authentication
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3

# Security
AllowTcpForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
```

**Why**: Prevents brute force attacks, eliminates password-based authentication, reduces attack surface.

## 🛡️ System Hardening

### Fail2ban Protection
**Location**: `ansible/roles/security/templates/jail.local.j2`

- **SSH protection**: Automatic IP banning after failed attempts
- **Service-specific jails**: Conditional protection for nginx, ArgoCD
- **Intelligent filtering**: Only applies to installed services

### Kernel Security
**Location**: `ansible/roles/security/tasks/main.yml`

```yaml
# Network security
net.ipv4.tcp_syncookies: 1
net.ipv4.icmp_echo_ignore_broadcasts: 1
net.ipv4.conf.all.accept_source_route: 0

# IP forwarding: Conditionally disabled
# Only set to 0 if k3s is not installed
```

**Why**: Prevents various network-based attacks while maintaining Kubernetes functionality.

### Audit Logging
- **Security events**: File access, user changes, SSH access
- **System monitoring**: Automated security status reporting
- **Intrusion detection**: Baseline for detecting anomalies

## 🐳 Container Security

### ArgoCD Security
- **Insecure mode**: Allows TLS termination at ingress
- **RBAC**: Role-based access control for GitOps operations
- **Namespace isolation**: Applications deployed in separate namespaces

### Pod Security
- **Security contexts**: Non-root containers where possible
- **Resource limits**: CPU/memory limits prevent resource exhaustion
- **Network policies**: Restrict pod-to-pod communication

## 🚀 CI/CD Security

### GitHub Actions Security
**Location**: `.github/workflows/deploy.yml`

```yaml
# Secure deployment via Tailscale
- name: 🌐 Connect to Tailscale
  uses: tailscale/github-action@v2
  with:
    oauth-client-id: ${{ secrets.TAILSCALE_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TAILSCALE_OAUTH_SECRET }}
    tags: tag:ci
```

**Required Secrets**:
- `SSH_PRIVATE_KEY`: Server access
- `TAILSCALE_OAUTH_CLIENT_ID`: VPN access
- `TAILSCALE_OAUTH_SECRET`: VPN authentication
- `SERVER_IP`: Target server
- `DOMAIN_NAME`: Deployment domain

**Why**: Deployment pipeline requires VPN access, preventing unauthorized deployments.

## 🏠 Local Development Security

### Security Parity
- **Same TLS workflow**: HTTPS-only, certificate warnings expected
- **Firewall simulation**: UFW rules applied but don't affect VM-to-VM traffic
- **Service isolation**: Same ClusterIP + Ingress pattern as production

### DNS Security
**Location**: `scripts/setup-local-dns.sh`

```bash
# Uses .local domains to avoid localhost conflicts
app.local → 192.168.64.x
argocd.local → 192.168.64.x  
portainer.local → 192.168.64.x
```

**Why**: Prevents DNS conflicts while maintaining production-like domain access patterns.

## 🔍 Security Monitoring

### Automated Monitoring
- **Security status script**: `/usr/local/bin/security-status`
- **Daily reports**: Cron job for security status
- **Log monitoring**: Fail2ban, SSH access, system changes

### Health Checks
- **Firewall status**: UFW active and properly configured
- **Service status**: All security services running
- **Certificate status**: TLS certificates valid and current

## ⚠️ Security Considerations

### Current Limitations
1. **Self-signed certificates** in local development (expected)
2. **ArgoCD insecure mode** required for ingress compatibility (standard practice)
3. **UFW allows all IPs** for ports 80/443 (required for Let's Encrypt and public access)

### Production Recommendations
1. **Regular security audits**: Run `security-status` script monthly
2. **Certificate monitoring**: Set up alerts for certificate expiration
3. **Log analysis**: Regular review of fail2ban and audit logs
4. **Backup security**: Encrypt and secure all backup data

## 🔄 Security Maintenance

### Updates
- **Automatic security updates**: Enabled via unattended-upgrades
- **Container updates**: ArgoCD GitOps ensures latest secure images
- **Certificate renewal**: Automatic via Traefik/Let's Encrypt

### Monitoring Commands
```bash
# Security status
sudo /usr/local/bin/security-status

# Firewall status  
sudo ufw status verbose

# Fail2ban status
sudo fail2ban-client status

# Certificate status
kubectl get certificates -A

# Service status
kubectl get pods -A
```

## 🎯 Security Benefits Achieved

### ✅ **Network Security**
- Firewall protection with minimal exposed ports
- VPN-only administrative access
- Network segmentation and isolation

### ✅ **Encryption**
- End-to-end TLS encryption
- Automatic certificate management
- Production-grade cipher suites

### ✅ **Access Control**  
- Identity-based VPN access
- SSH key-only authentication
- Role-based Kubernetes access

### ✅ **Monitoring**
- Intrusion detection and prevention
- Automated security reporting
- Audit trail for all changes

### ✅ **CI/CD Security**
- Secure deployment pipeline
- VPN-protected cluster access
- Encrypted secrets management

---

## 📚 Security References

- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/)
- [Traefik Security Documentation](https://doc.traefik.io/traefik/operations/security/)
- [UFW Documentation](https://help.ubuntu.com/community/UFW)
- [Fail2ban Configuration](https://www.fail2ban.org/wiki/index.php/MANUAL_0_8)

---

*This security documentation should be reviewed and updated whenever security configurations change.*
