import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";

/**
 * Cloudflare-side DNS for the cluster's private services.
 *
 * Replaces an in-cluster external-dns controller: every private CNAME
 * is declared here, statically, and Pulumi updates it when the
 * machine's Tailscale hostname changes.
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

// Tailscale tailnet suffix. Stable across the tailnet — the only
// variable is the cluster's hostname (= `jterrazz-infra` today),
// passed in from machine.ts.
const TAILNET_DOMAIN = "tail77a797.ts.net";

/**
 * Private services whose hostname routes to the cluster via Tailscale.
 * Each one becomes a CNAME from `<host>.jterrazz.com` to the active
 * cluster's Tailscale FQDN. The Traefik private-access middleware on the
 * cluster handles the IP allow-list; this layer just keeps DNS honest.
 */
const PRIVATE_HOSTS = ["n8n", "portainer", "grafana", "registry", "gateway", "chat"];

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

    // Wildcard for the *.internal.jterrazz.com namespace: any new app
    // exposing a private surface picks its own subdomain
    // (e.g. signews.internal.jterrazz.com) and resolves through this
    // record. Saves us from declaring a per-host CNAME for each new app
    // and from updating Pulumi every time an app gains a private side.
    // DNS-only (grey cloud) — proxied wildcards need a paid plan, and
    // Tailscale-routed traffic must skip the Cloudflare edge anyway.
    new cloudflare.Record("private-wildcard-internal", {
        zoneId: JTERRAZZ_ZONE_ID,
        name: "*.internal",
        type: "CNAME",
        content: fqdn,
        proxied: false,
        ttl: 1,
        comment: "Managed by Pulumi — wildcard for *.internal.jterrazz.com → tailnet",
    });
}
