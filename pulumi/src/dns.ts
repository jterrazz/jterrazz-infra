import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";

/**
 * Cloudflare-side DNS for the cluster's private services.
 *
 * Replaces the in-cluster external-dns controller: every CNAME we used to
 * have external-dns reconcile is declared here, statically, and Pulumi
 * updates it when the active target's Tailscale hostname changes (e.g.
 * Hetzner → OrbStack swap).
 *
 * Public records (apex CNAMEs to the Cloudflare tunnel) are intentionally
 * NOT in here — they're managed by cloudflared's Public-Hostname feature
 * in the Zero Trust dashboard, which auto-creates the CNAME when a new
 * hostname is wired into the tunnel.
 *
 * The Cloudflare provider authenticates via `CLOUDFLARE_API_TOKEN` (env)
 * or `cloudflare:apiToken` Pulumi config. The same token external-dns
 * was using (DNS:Edit on the managed zones) is sufficient.
 */

// jterrazz.com zone — looked up once via `cloudflare/v4/zones?name=…` and
// hardcoded so we don't pay the API round-trip on every `pulumi up`. Zones
// are stable identifiers; if it ever moves we'd see a 404 at apply time.
const JTERRAZZ_ZONE_ID = "ca5eefcd2d8b1d8895fc255f26141d46";

// Tailscale tailnet suffix. Same for every node in our tailnet — the part
// that varies is the hostname (jterrazz-vps vs jterrazz-infra), which is
// passed in from the active target's MachineOutputs.
const TAILNET_DOMAIN = "tail77a797.ts.net";

/**
 * Private services whose hostname routes to the cluster via Tailscale.
 * Each one becomes a CNAME from `<host>.jterrazz.com` to the active
 * cluster's Tailscale FQDN. The Traefik private-access middleware on the
 * cluster handles the IP allow-list; this layer just keeps DNS honest.
 */
const PRIVATE_HOSTS = ["n8n", "portainer", "grafana", "registry", "gateway"];

export function createPrivateDnsRecords(tailscaleHostname: pulumi.Output<string>): void {
    const fqdn = tailscaleHostname.apply((h) => `${h}.${TAILNET_DOMAIN}`);

    for (const host of PRIVATE_HOSTS) {
        new cloudflare.Record(`private-${host}`, {
            zoneId: JTERRAZZ_ZONE_ID,
            name: host,
            type: "CNAME",
            content: fqdn,
            // Tailscale-routed services must NOT be proxied through
            // Cloudflare — clients hit the Tailscale IP directly through
            // their tailnet, no edge involvement.
            proxied: false,
            ttl: 1, // 1 = "Auto" in Cloudflare's API
            comment: `Managed by Pulumi (replaces external-dns for ${host}.jterrazz.com)`,
        });
    }
}
