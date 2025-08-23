# GitHub Secrets Configuration

This repository requires the following secrets to be configured in GitHub Actions:

## 🔐 Required Secrets

### Infrastructure Access
- `SSH_PRIVATE_KEY` - Private SSH key for server access
- `SERVER_IP` - Production server IP address  
- `DOMAIN_NAME` - Your domain name (e.g., `jterrazz.com`)

### Tailscale VPN (for secure K8s API access)
- `TAILSCALE_OAUTH_CLIENT_ID` - Tailscale OAuth client ID
- `TAILSCALE_OAUTH_SECRET` - Tailscale OAuth secret

## 🚀 Setup Instructions

### 1. SSH Key
```bash
# Generate or use existing SSH key
cat ~/.ssh/id_rsa  # Copy private key content
```

### 2. Tailscale OAuth (for CI/CD)
1. Visit [Tailscale Admin Console](https://login.tailscale.com/admin)
2. Go to **Settings** → **OAuth clients** 
3. Create new OAuth client with tags: `tag:ci`
4. Copy Client ID and Secret

### 3. Add to GitHub
1. Go to repository **Settings** → **Secrets and variables** → **Actions**
2. Add each secret with exact names listed above

## 🛡️ Security Notes

- K8s API (port 6443) is restricted to Tailscale IPs only
- GitHub Actions connects via Tailscale for secure cluster access
- All secrets are encrypted and only accessible to workflows
- Use principle of least privilege for OAuth client permissions

## 🧪 Testing

After setup, test the workflow:
```bash
git push origin main  # Triggers deployment
```

Check GitHub Actions tab for deployment status.
