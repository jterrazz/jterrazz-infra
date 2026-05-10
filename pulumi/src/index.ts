import * as pulumi from "@pulumi/pulumi";
import { createHetznerMachine } from "./targets/hetzner";
import { createOrbStackMachine } from "./targets/orbstack";
import { Target } from "./targets/types";

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

// Unified outputs consumed by Ansible (via `pulumi stack output`) and
// jterrazz-actions (via Infisical-synced KUBECONFIG_BASE64 etc.).
export const sshHost = machine.sshHost;
export const sshPrivateKey = machine.sshPrivateKey;
export const tailscaleHostname = machine.tailscaleHostname;
export const serverStatus = machine.status;
export const serverName = machine.name;

// Backwards-compat alias — older callers read `serverIp`.
export const serverIp = machine.sshHost;
