# Clawdbot Setup

Personal AI assistant using Claude Max with Signal integration.

## Initial Setup (One-time)

After deploying, you need to complete the interactive setup:

### 1. Create storage directory on VPS

```bash
ssh root@jterrazz.com
mkdir -p /var/lib/k8s-data/clawdbot/{config,workspace,signal-cli}
chown -R 1000:1000 /var/lib/k8s-data/clawdbot
```

### 2. Run the onboarding

```bash
# Exec into the pod
kubectl exec -it -n platform-clawdbot deploy/clawdbot -- /bin/bash

# Run onboarding (will open browser for Claude OAuth)
clawdbot onboard
```

This will:

- Authenticate with your Claude Max subscription
- Generate gateway token
- Create initial config

### 3. Link Signal account

You need a **separate phone number** for the bot (not your personal Signal).

```bash
# Inside the pod
signal-cli link -n "Clawdbot"
```

This displays a QR code. Scan it with Signal app:

- Open Signal > Settings > Linked Devices > Link New Device

### 4. Configure Signal channel

Edit the config file:

```bash
# On VPS
nano /var/lib/k8s-data/clawdbot/config/config.json5
```

Add Signal configuration:

```json5
{
  channels: {
    signal: {
      enabled: true,
      account: "+33XXXXXXXXX", // Your bot's phone number
      cliPath: "signal-cli",
      dmPolicy: "pairing",
      allowFrom: ["+33YYYYYYYYY"], // Your personal number
    },
  },
}
```

### 5. Restart the pod

```bash
kubectl rollout restart deployment/clawdbot -n platform-clawdbot
```

## Usage

- Send a message to your bot's Signal number
- First message triggers pairing mode (you'll receive a code)
- Approve pairing: `kubectl exec -n platform-clawdbot deploy/clawdbot -- clawdbot pairing approve signal <CODE>`
- After approval, the bot responds using Claude

## Access

- **Web UI**: https://clawdbot.jterrazz.com (Tailscale only)
- **Gateway**: ws://clawdbot.platform-clawdbot:18789

## Troubleshooting

```bash
# Check logs
kubectl logs -n platform-clawdbot deploy/clawdbot -f

# Check signal-cli status
kubectl exec -n platform-clawdbot deploy/clawdbot -- signal-cli -a +33XXXXXXXXX receive
```
