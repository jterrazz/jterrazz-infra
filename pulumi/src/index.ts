import * as pulumi from "@pulumi/pulumi";
import { createHetznerMachine } from "./targets/hetzner";
import { createOrbStackMachine } from "./targets/orbstack";
import { Target } from "./targets/types";
import { createPrivateDnsRecords } from "./dns";

/**
 * Top-level dispatcher. Stack config picks the target:
 *   pulumi config set target hetzner   # production VPS
 *   pulumi config set target orbstack  # local OrbStack VM
 *
 * Defaults to hetzner so the historical `production` stack stays the same
 * on `pulumi up` without re-configuring. The `local` stack opts into
 * orbstack via Pulumi.local.yaml.
 *
 * Outputs are unified across targets (see targets/types.ts) so Ansible
 * and downstream tooling stay target-agnostic.
 */
const config = new pulumi.Config();
const target = (config.get("target") || "hetzner") as Target;

const machine =
    target === "orbstack" ? createOrbStackMachine(config) : createHetznerMachine(config);

// Only one stack at a time owns the Cloudflare DNS records for the
// private services. Pulumi's perspective is "whatever the active stack
// is configured for, take over the records and point them at this
// machine's Tailscale hostname". Defaults: production manages DNS,
// local does NOT (so testing the OrbStack target doesn't accidentally
// repoint production names mid-experiment). Flip the local stack's
// `manageDns: true` to perform the actual swap.
const manageDns = config.getBoolean("manageDns") ?? (target === "hetzner");
if (manageDns) {
    createPrivateDnsRecords(machine.tailscaleHostname);
}

// Unified outputs consumed by Ansible (via `pulumi stack output`) and
// jterrazz-actions (via Infisical-synced KUBECONFIG_BASE64 etc.).
export const sshHost = machine.sshHost;
export const sshPrivateKey = machine.sshPrivateKey;
export const tailscaleHostname = machine.tailscaleHostname;
export const serverStatus = machine.status;
export const serverName = machine.name;
export const dnsManagedHere = pulumi.output(manageDns);

// Backwards-compat alias — older callers read `serverIp`.
export const serverIp = machine.sshHost;
