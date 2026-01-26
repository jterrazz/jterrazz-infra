# Clawdbot Setup

Personal AI assistant using Claude Max with Signal integration.

## Initial Setup (One-time)

After deploying, you need to complete the interactive setup from your terminal.

### 1. Create storage directory on VPS

```bash
ssh root@46.224.186.190
mkdir -p /var/lib/k8s-data/clawdbot/{config,workspace,signal-cli}
```

### 2. Authenticate with Claude Max

The pod is deployed with `sleep infinity` to allow manual onboarding.

```bash
# SSH into the server
ssh root@46.224.186.190

# Exec into the pod with interactive TTY
kubectl exec -it -n platform-clawdbot deploy/clawdbot -- bash

# Inside the pod, run auth setup (prints OAuth URL to copy/paste to browser)
node /app/dist/entry.js models auth setup-token --provider anthropic --yes
```

This will print an OAuth URL. Copy it to your browser to authenticate with your Claude Max subscription.

### 3. Link Signal account

You need a **separate phone number** for the bot (not your personal Signal).

```bash
# Still inside the pod
node /app/dist/entry.js channels login --channel signal
```

Or use signal-cli directly:

```bash
signal-cli link -n "Clawdbot"
```

This displays a QR code or link. Scan it with Signal app:

- Open Signal > Settings > Linked Devices > Link New Device

### 4. Run the full setup wizard

```bash
# Inside the pod
node /app/dist/entry.js onboard
```

This will configure:

- Workspace directory
- Gateway settings
- Channel configuration

### 5. Update deployment to run gateway

After onboarding, update the deployment to run the gateway instead of sleep:

Edit `deployment.yaml`:

```yaml
# Remove command/args to use default entrypoint
# command: ["/bin/sh", "-c"]
# args: ["sleep infinity"]
```

Then push and sync:

```bash
git add . && git commit -m "chore: enable clawdbot gateway" && git push
```

## Usage

- Send a message to your bot's Signal number
- First message triggers pairing mode (you'll receive a code)
- Approve pairing: `kubectl exec -n platform-clawdbot deploy/clawdbot -- node /app/dist/entry.js pairing approve signal <CODE>`
- After approval, the bot responds using Claude

## Access

- **Web UI**: https://clawdbot.jterrazz.com (Tailscale only)
- **Gateway**: ws://clawdbot.platform-clawdbot:18789

## Troubleshooting

```bash
# Check logs
kubectl logs -n platform-clawdbot deploy/clawdbot -f

# Check health
kubectl exec -n platform-clawdbot deploy/clawdbot -- node /app/dist/entry.js doctor

# Check signal-cli status
kubectl exec -n platform-clawdbot deploy/clawdbot -- signal-cli -a +33XXXXXXXXX receive
```
