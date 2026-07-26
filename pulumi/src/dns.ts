import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";

/**
 * Cloudflare-side DNS for the cluster's private services. Apex CNAMEs for
 * PUBLIC hostnames are deliberately absent: cloudflared's Public-Hostname
 * feature auto-creates those, and declaring them here would fight it.
 *
 * Auth is `CLOUDFLARE_API_TOKEN` (env) or `cloudflare:apiToken` config;
 * DNS:Edit on the managed zones suffices.
 */

// Hardcoded rather than looked up, to save an API round-trip on every
// `pulumi up`. Zone IDs are stable; a moved zone 404s at apply time.
const JTERRAZZ_ZONE_ID = "ca5eefcd2d8b1d8895fc255f26141d46";

// Tailnet suffix; the only variable part is the cluster hostname, passed in
// from createMachine() in src/targets/orbstack.ts.
const TAILNET_DOMAIN = "tail77a797.ts.net";

// Pulumi owns the CNAME; the Zero Trust dashboard owns the matching
// per-hostname tunnel ROUTE (that needs Tunnel:Edit, which the DNS token
// lacks). A record here without a route there returns 404 from cloudflared.
// The UUID is public — it is the CNAME target — so not a secret.
const TUNNEL_HOSTNAME = "8f4157bb-f883-424b-8ccd-8332867cf1b2.cfargotunnel.com";

/**
 * Private services, each a CNAME from `<host>.jterrazz.com` to the cluster's
 * Tailscale FQDN. Access control is the Traefik private-access middleware;
 * this layer only keeps DNS honest.
 *
 * KEEP IN SYNC with `private_hostnames` (+ `private_hostnames_via_traefik`,
 * which holds `openpanel`) in
 * ansible/inventories/group_vars/all.yml: this list creates the PUBLIC CNAME,
 * that one creates the in-cluster CoreDNS override. A host in only one of the
 * two resolves nowhere useful. Deleting a service means deleting both.
 */
const PRIVATE_HOSTS = ["grafana", "registry", "gateway", "chat", "openpanel"];

/**
 * Public services fronted by the Cloudflare tunnel. Each needs a matching
 * per-hostname route in the Zero Trust config, or cloudflared 404s it.
 */
const PUBLIC_TUNNEL_HOSTS = ["analytics"];

export function createPrivateDnsRecords(tailscaleHostname: pulumi.Output<string>): void {
    const fqdn = tailscaleHostname.apply((h) => `${h}.${TAILNET_DOMAIN}`);

    for (const host of PRIVATE_HOSTS) {
        new cloudflare.Record(`private-${host}`, {
            zoneId: JTERRAZZ_ZONE_ID,
            name: host,
            type: "CNAME",
            content: fqdn,
            // Tailscale-routed services must NOT be proxied: clients reach the
            // Tailscale IP directly, with no Cloudflare edge involvement.
            proxied: false,
            ttl: 1, // 1 = "Auto" in Cloudflare's API
            comment: `Managed by Pulumi (replaces external-dns for ${host}.jterrazz.com)`,
        });
    }

    for (const host of PUBLIC_TUNNEL_HOSTS) {
        new cloudflare.Record(`public-${host}`, {
            zoneId: JTERRAZZ_ZONE_ID,
            name: host,
            type: "CNAME",
            content: TUNNEL_HOSTNAME,
            // Must be proxied — cfargotunnel.com only resolves at the edge.
            proxied: true,
            ttl: 1, // 1 = "Auto"
            comment: `Managed by Pulumi — ${host}.jterrazz.com → Cloudflare tunnel → Traefik`,
        });
    }

    // Any app needing a private surface should take a subdomain here
    // (signews.internal.jterrazz.com) rather than a new PRIVATE_HOSTS entry —
    // this record covers it with no Pulumi change and no group_vars edit.
    // DNS-only: proxied wildcards need a paid plan, and Tailscale-routed
    // traffic must skip the Cloudflare edge anyway.
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
