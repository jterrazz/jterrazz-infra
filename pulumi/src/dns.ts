import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";

/**
 * Cloudflare-side DNS for the cluster's private services. Apex CNAMEs for
 * PUBLIC hostnames are deliberately absent: cloudflared's Public-Hostname
 * feature auto-creates those, and declaring them here would fight it.
 *
 * Auth is `CLOUDFLARE_API_TOKEN` (env) or `cloudflare:apiToken` config;
 * DNS:Edit on the managed zones suffices.
 *
 * PROVIDER v5 -> v6. `cloudflare.Record` became `cloudflare.DnsRecord` (type
 * token `cloudflare:index/record:Record` -> `cloudflare:index/dnsRecord:
 * DnsRecord`) when provider 6 picked up the Cloudflare Terraform provider's
 * ground-up, OpenAPI-generated rewrite. Notes for the next person:
 *
 *  - NO `aliases:` are written here on purpose. The v6 SDK injects
 *    `aliases: [{ type: "cloudflare:index/record:Record" }]` into every
 *    DnsRecord constructor itself, so keeping the Pulumi resource NAMES
 *    unchanged (`private-grafana`, ...) is all that is needed for the URNs to
 *    carry over. Adding our own would be a redundant duplicate.
 *  - `content` is unchanged; it is the v5 `value` field that was removed, and
 *    this file already used `content`.
 *  - `ttl` is now REQUIRED (it was optional in v5). Every record here already
 *    passes `ttl: 1`.
 *  - `name` may still be the SHORT name — the provider stores the zone name in
 *    private state and suppresses the FQDN diff.
 *
 * Expect the first `pulumi preview` after the bump to show `~ update` on
 * computed metadata only (settings/meta/createdOn/modifiedOn/proxiable) and
 * ZERO creates, deletes or replaces.
 */

// Hardcoded rather than looked up, to save an API round-trip on every
// `pulumi up`. Zone IDs are stable; a moved zone 404s at apply time.
const JTERRAZZ_ZONE_ID = "ca5eefcd2d8b1d8895fc255f26141d46";

// Tailnet suffix; the only variable part is the cluster hostname, passed in
// from createMachine() in src/targets/orbstack.ts.
const TAILNET_DOMAIN = "tail77a797.ts.net";

export function createPrivateDnsRecords(tailscaleHostname: pulumi.Output<string>): void {
    const fqdn = tailscaleHostname.apply((h) => `${h}.${TAILNET_DOMAIN}`);

    // THE ONLY DNS RECORD THIS REPO OWNS.
    //
    // Every private surface is `<svc>.internal.jterrazz.com` and is covered by
    // this one wildcard, so adding or removing a private service needs no DNS
    // change anywhere — not here, not in group_vars, not in the Cloudflare UI.
    // That is the whole point: a per-service record here would make Pulumi (a
    // machine provisioner) the owner of a service-level fact, which is how the
    // previous shape ended up with the same hostname list maintained in two
    // files and a CI assertion to stop them drifting.
    //
    // Public hostnames are NOT here: the tunnel's Public Hostname feature
    // creates their CNAMEs itself, in the Zero Trust dashboard. One owner per
    // kind — machine here, services there.
    //
    // external-dns would be the k8s-native way to own per-service records, and
    // it is deliberately absent: with this wildcard there are zero per-service
    // records to reconcile, so it would have nothing to do.
    //
    // Explicit records always beat a wildcard in DNS, so pre-existing names on
    // this zone (www → Vercel, blog, mail) are unaffected.
    //
    // One label deep, on purpose: a wildcard TLS cert for
    // *.internal.jterrazz.com covers `svc.internal` but not `a.b.internal`.
    //
    // DNS-only: proxied wildcards need a paid plan, and Tailscale-routed
    // traffic must skip the Cloudflare edge anyway.
    new cloudflare.DnsRecord("private-wildcard-internal", {
        zoneId: JTERRAZZ_ZONE_ID,
        name: "*.internal",
        type: "CNAME",
        content: fqdn,
        proxied: false,
        ttl: 1,
        comment: "Managed by Pulumi — wildcard for *.internal.jterrazz.com → tailnet",
    });
}
