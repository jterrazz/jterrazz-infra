import * as pulumi from "@pulumi/pulumi";

/**
 * Outputs every target (Hetzner, OrbStack, …) must produce so the rest of
 * the pipeline — Ansible, jterrazz-actions, status tooling — doesn't need to
 * know which provider booted the box.
 *
 * Adding a field here is a breaking change for downstream consumers — bump
 * everyone or add the field as optional.
 */
export interface MachineOutputs {
    /**
     * Reachable address for Ansible's `ansible_host`. Hetzner emits the
     * public IPv4; OrbStack emits the VM name (Ansible reaches it through
     * the OrbStack SSH ProxyCommand).
     */
    sshHost: pulumi.Output<string>;

    /**
     * The OpenSSH private key Ansible authenticates with. Marked secret
     * via `pulumi.secret()`. For OrbStack we emit the OrbStack-managed
     * key file's contents so the same Ansible invocation works for both
     * targets without per-target branching.
     */
    sshPrivateKey: pulumi.Output<string>;

    /**
     * Hostname this machine registers with Tailscale. Stable per target so
     * MagicDNS records don't collide when both stacks ever come up at the
     * same time (`jterrazz-vps` for Hetzner vs `jterrazz-infrastructure` for OrbStack).
     */
    tailscaleHostname: pulumi.Output<string>;

    /** Free-form status string for `pulumi stack output` readability. */
    status: pulumi.Output<string>;

    /**
     * Cosmetic — the resource's logical name. Distinct from the Tailscale
     * hostname (which is the *identity* in the tailnet) so `serverName`
     * stays informational without being a routing key.
     */
    name: pulumi.Output<string>;
}

/**
 * Possible deployment targets. Picked from `pulumi config get target`.
 * Each value maps to a file under `targets/`.
 */
export type Target = "hetzner" | "orbstack";
