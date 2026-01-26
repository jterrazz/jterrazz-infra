# Clawdbot Setup

Personal AI assistant using Claude Max with Signal integration.

## Secrets Management

Clawdbot secrets are managed via Pulumi and deployed by Ansible:

```bash
# Set secrets in Pulumi (one-time setup)
cd pulumi
pulumi config set --secret clawdbotGatewayToken "<your-gateway-token>"
pulumi config set --secret clawdbotClaudeToken "<your-claude-oauth-token>"
```

The Ansible playbook creates the `clawdbot-secrets` K8s secret, and an init container
writes the config files on first deploy.

## Getting a Claude OAuth Token

You need a Claude Max subscription. To get the OAuth token:

```bash
# On your local machine with Claude CLI installed
claude login

# The token is stored in ~/.claude or can be obtained via the OAuth flow
# It looks like: sk-ant-oat01-...
```

## Initial Setup (Only needed for fresh deployment)

After first deploy, the init container creates config from secrets. However, device
pairing must be done manually:

### 1. Access the Control UI

```
https://clawdbot.jterrazz.com/?token=<gateway-token>
```

The UI will show "pairing required". This creates a pairing request.

### 2. Approve the pairing

```bash
ssh root@<server-ip>
kubectl exec -n platform-clawdbot deploy/clawdbot -- node /app/dist/entry.js devices list
kubectl exec -n platform-clawdbot deploy/clawdbot -- node /app/dist/entry.js devices approve <request-id>
```

### 3. (Optional) Link Signal account

You need a **separate phone number** for the bot (not your personal Signal).

```bash
kubectl exec -it -n platform-clawdbot deploy/clawdbot -- node /app/dist/entry.js channels login --channel signal
```

## Data Persistence

All Clawdbot data is stored on a PersistentVolume at `/var/lib/k8s-data/clawdbot/`:

- `config/` - Clawdbot configuration, auth profiles, device pairings
- `workspace/` - Agent workspace
- `signal-cli/` - Signal credentials and message history

This data persists across pod restarts and redeployments.

## Access

- **Web UI**: https://clawdbot.jterrazz.com (Tailscale only)
- **Gateway**: ws://clawdbot.platform-clawdbot:18789

## Troubleshooting

```bash
# Check logs
kubectl logs -n platform-clawdbot deploy/clawdbot -f

# Check init container logs
kubectl logs -n platform-clawdbot deploy/clawdbot -c init-config

# Check health
kubectl exec -n platform-clawdbot deploy/clawdbot -- node /app/dist/entry.js doctor

# List paired devices
kubectl exec -n platform-clawdbot deploy/clawdbot -- node /app/dist/entry.js devices list
```

## Upgrading Claude Token

If your Claude token expires:

```bash
# Update in Pulumi
cd pulumi
pulumi config set --secret clawdbotClaudeToken "<new-token>"

# Re-run Ansible to update the K8s secret
cd ../ansible
./run.sh platform

# Delete the auth file so init container recreates it
ssh root@<server-ip>
kubectl exec -n platform-clawdbot deploy/clawdbot -- rm /root/.clawdbot/agents/main/agent/auth-profiles.json

# Restart the pod
kubectl rollout restart deployment/clawdbot -n platform-clawdbot
```
