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

    // API token from the `hcloud:token` Pulumi-encrypted stack config.
    // We construct an explicit Provider because the default provider
    // doesn't auto-inject `hcloud:token` into the schema's `token`
    // attribute (unlike e.g. `cloudflare:apiToken`), so refresh-time
    // API calls would fail with a "Missing Hetzner Cloud API token"
    // error. Storing the token in Pulumi state (vs `.env` + GH secret)
    // removes one credential from circulation.
    const hcloudConfig = new pulumi.Config("hcloud");
    const provider = new hcloud.Provider("hcloud", {
        token: hcloudConfig.requireSecret("token"),
    });
    const providerOpts = { provider };

    // Generate an SSH key pair on every `pulumi up`. The private key is
    // stored encrypted in Pulumi state and exported as a secret output for
    // Ansible to consume. Rotation = `pulumi up -t '**main'` then Ansible
    // re-runs.
    const sshKeyPair = new tls.PrivateKey("main", { algorithm: "ED25519" });

    const sshKey = new hcloud.SshKey("main", {
        name: "jterrazz-infra",
        publicKey: sshKeyPair.publicKeyOpenssh,
    }, providerOpts);

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
    }, providerOpts);

    return {
        sshHost: server.ipv4Address,
        sshPrivateKey: pulumi.secret(sshKeyPair.privateKeyOpenssh),
        // Tailscale hostname — historical `jterrazz-vps`. Pulumi's DNS
        // module (pulumi/src/dns.ts) consumes this to point the private
        // service CNAMEs at the active machine; renaming would force a
        // re-issue of every tailnet host lookup, so we keep it.
        // OrbStack's identity is `jterrazz-infra`, so the tailnet has a
        // distinct identity per target.
        tailscaleHostname: pulumi.output("jterrazz-vps"),
        status: server.status,
        name: server.name,
    };
}
