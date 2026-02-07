# OpenClaw Setup

Personal AI assistant using Claude Max with Signal integration.

## Architecture

- **Secrets**: Stored encrypted in Pulumi, deployed as K8s secrets via Ansible
- **Authentication**: Uses `ANTHROPIC_API_KEY` environment variable (from Claude Max OAuth token)
- **Config**: Init container creates gateway config on first deploy
- **Storage**: PersistentVolume for memories, sessions, and Signal data

## Secrets Management

OpenClaw secrets are managed via Pulumi and deployed by Ansible:

```bash
# Set secrets in Pulumi (one-time setup)
cd pulumi
pulumi config set --secret openclawGatewayToken "<your-gateway-token>"
pulumi config set --secret openclawClaudeToken "<your-claude-oauth-token>"
```

The Ansible playbook creates the `openclaw-secrets` K8s secret with:

- `GATEWAY_TOKEN` - For web UI authentication
- `CLAUDE_TOKEN` - Claude Max OAuth token (used as ANTHROPIC_API_KEY)

## Getting a Claude OAuth Token

You need a Claude Max subscription. To get the OAuth token:

```bash
# On your local machine with Claude CLI installed
claude login

# After OAuth flow completes, get the token from:
cat ~/.claude/.credentials.json
# Look for the "oauthToken" field - it looks like: sk-ant-oat01-...
```

## Initial Setup (First deployment only)

After deploying, device pairing must be done manually:

### 1. Access the Control UI

```
https://openclaw.jterrazz.com/?token=<gateway-token>
```

The UI will show "pairing required". This creates a pairing request.

### 2. Approve the pairing

```bash
# SSH via Tailscale
ssh root@jterrazz-vps.tail77a797.ts.net

# List pending requests
kubectl exec -n platform-openclaw deploy/openclaw -- node /app/dist/entry.js devices list

# Approve the request
kubectl exec -n platform-openclaw deploy/openclaw -- node /app/dist/entry.js devices approve <request-id>
```

### 3. (Optional) Link Signal account

You need a **separate phone number** for the bot (not your personal Signal).

```bash
kubectl exec -it -n platform-openclaw deploy/openclaw -- node /app/dist/entry.js channels login --channel signal
```

## Data Persistence

All OpenClaw data is stored on a PersistentVolume at `/var/lib/k8s-data/openclaw/`:

- `config/` - Gateway configuration, auth profiles, device pairings
- `workspace/` - Agent workspace and memories
- `signal-cli/` - Signal credentials and message history

This data persists across pod restarts and redeployments.

## Access

- **Web UI**: https://openclaw.jterrazz.com (requires gateway token)
- **DNS**: Points to Tailscale hostname via external-dns

## Troubleshooting

```bash
# Check logs
kubectl logs -n platform-openclaw deploy/openclaw -f

# Check init container logs
kubectl logs -n platform-openclaw deploy/openclaw -c init-config

# Check health
kubectl exec -n platform-openclaw deploy/openclaw -- node /app/dist/entry.js doctor

# List paired devices
kubectl exec -n platform-openclaw deploy/openclaw -- node /app/dist/entry.js devices list
```

## Updating Claude Token

If your Claude token expires:

```bash
# 1. Get new token via claude login on your machine
claude login
cat ~/.claude/.credentials.json

# 2. Update in Pulumi
cd pulumi
pulumi config set --secret openclawClaudeToken "<new-token>"

# 3. Re-run Ansible to update the K8s secret
cd ../ansible
./run.sh platform

# 4. Restart the pod to pick up new secret
kubectl rollout restart deployment/openclaw -n platform-openclaw
```

## Resources

- Memory: 2Gi request, 4Gi limit
- Node heap: 3072MB (via NODE_OPTIONS)
- Server: Hetzner CAX31 (16GB RAM total)
