import * as pulumi from "@pulumi/pulumi";
import { createMachine } from "./machine";
import { createPrivateDnsRecords } from "./dns";

/**
 * Pulumi entry point. Provisions the cluster machine (OrbStack VM via
 * `orbctl`) and the Cloudflare CNAMEs that point the private hostnames
 * at it.
 *
 * Outputs are consumed by:
 *   - `scripts/deploy.sh` (Ansible) — reads sshHost + sshPrivateKey
 *   - `jterrazz-actions` (app CI) — reads tailscaleHostname for the
 *     ingress public-target / tailscale-hostname helm flags
 *
 * Stack: jterrazz/local — the only live stack since the Hetzner
 * production stack was retired (see git log around commit b29f250).
 */
const machine = createMachine();

createPrivateDnsRecords(machine.tailscaleHostname);

export const sshHost = machine.sshHost;
export const sshPrivateKey = machine.sshPrivateKey;
export const tailscaleHostname = machine.tailscaleHostname;
export const serverStatus = machine.status;
export const serverName = machine.name;
