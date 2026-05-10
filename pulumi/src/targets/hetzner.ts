import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as tls from "@pulumi/tls";
import { MachineOutputs } from "./types";

/**
 * Hetzner target — provisions a single Cloud VPS that runs the same
 * k3s+platform stack as the OrbStack VM. Behaviour is unchanged from the
 * pre-target-abstraction setup; this file just lifts the existing logic
 * out of index.ts so the dispatch there stays small.
 */
export function createHetznerMachine(config: pulumi.Config): MachineOutputs {
    // Stack config with defaults. cax21 is the smallest ARM box that fits
    // the current platform's footprint; nbg1 (Nuremberg) is the closest
    // ARM-capable region; ubuntu-24.04 mirrors the OrbStack default for
    // parity.
    const serverType = config.get("serverType") || "cax21";
    const location = config.get("location") || "nbg1";
    const image = config.get("image") || "ubuntu-24.04";

    // Generate an SSH key pair on every `pulumi up`. The private key is
    // stored encrypted in Pulumi state and exported as a secret output for
    // Ansible to consume. Rotation = `pulumi up -t '**main'` then Ansible
    // re-runs.
    const sshKeyPair = new tls.PrivateKey("main", { algorithm: "ED25519" });

    const sshKey = new hcloud.SshKey("main", {
        name: "jterrazz-infra",
        publicKey: sshKeyPair.publicKeyOpenssh,
    });

    // Cloud-init installs the public key for the root user so Ansible can
    // SSH in immediately on first boot, without manual intervention.
    const cloudInit = pulumi.interpolate`#cloud-config
package_update: true
packages:
  - curl
  - wget

ssh_authorized_keys:
  - ${sshKeyPair.publicKeyOpenssh}
`;

    const server = new hcloud.Server("main", {
        name: "jterrazz-vps",
        serverType,
        location,
        image,
        sshKeys: [sshKey.name],
        userData: cloudInit,
        labels: {
            environment: "production",
            managed_by: "pulumi",
        },
    });

    return {
        sshHost: server.ipv4Address,
        sshPrivateKey: pulumi.secret(sshKeyPair.privateKeyOpenssh),
        // Tailscale hostname — keeps the historical `jterrazz-vps` name
        // because external-dns has been populating CNAMEs (n8n, portainer,
        // grafana, registry) pointing at `jterrazz-vps.tail77a797.ts.net`
        // for months. Renaming would invalidate those records until the
        // next reconcile and re-issue tailnet host lookups for clients.
        // OrbStack's identity is `jterrazz-orbstack`, so the tailnet still
        // has a clean per-target identity.
        tailscaleHostname: pulumi.output("jterrazz-vps"),
        status: server.status,
        name: server.name,
    };
}
