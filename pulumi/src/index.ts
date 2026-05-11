import * as pulumi from "@pulumi/pulumi";
import { createHetznerMachine } from "./targets/hetzner";
import { createOrbStackMachine } from "./targets/orbstack";
import { Target } from "./targets/types";
import { createPrivateDnsRecords } from "./dns";

/**
 * Dual-mode dispatcher — picks the machine target from stack config:
 *
 *   pulumi config set target hetzner   # production VPS in Hetzner Cloud
 *   pulumi config set target orbstack  # local VM on the dev Mac
 *
 * Conceptually the two are interchangeable: same Ansible playbooks,
 * same Helm charts, identical service topology. Only the underlying
 * compute (and the SSH path) differs. The Pulumi.<stack>.yaml file
 * records which one each stack runs.
 *
 * The cluster that owns the Cloudflare DNS records for the private
 * services is whichever stack has `manageDns: true`. Default is the
 * Hetzner stack so testing OrbStack doesn't accidentally repoint
 * production hostnames mid-experiment; override with
 * `pulumi config set manageDns true --stack local` (and `false` on
 * production) when promoting OrbStack.
 *
 * Outputs are unified across targets (see `targets/types.ts`) so
 * Ansible and downstream tooling stay target-agnostic.
 */
const config = new pulumi.Config();
const target = (config.get("target") || "hetzner") as Target;

const machine =
    target === "orbstack"
        ? createOrbStackMachine(config)
        : createHetznerMachine(config);

const manageDns = config.getBoolean("manageDns") ?? (target === "hetzner");
if (manageDns) {
    createPrivateDnsRecords(machine.tailscaleHostname);
}

// Consumed by Ansible (via `pulumi stack output`) and the app CI in
// jterrazz-actions (via `tailscaleHostname` → ingress helm flag).
export const sshHost = machine.sshHost;
export const sshPrivateKey = machine.sshPrivateKey;
export const tailscaleHostname = machine.tailscaleHostname;
export const serverStatus = machine.status;
export const serverName = machine.name;
export const dnsManagedHere = pulumi.output(manageDns);
