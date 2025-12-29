import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as tls from "@pulumi/tls";

const config = new pulumi.Config();

// Configuration with defaults
const serverType = config.get("serverType") || "cx22";
const location = config.get("location") || "nbg1";
const image = config.get("image") || "ubuntu-24.04";

// Generate SSH key pair (stored encrypted in Pulumi state)
const sshKeyPair = new tls.PrivateKey("main", {
  algorithm: "ED25519",
});

// Register SSH key with Hetzner
const sshKey = new hcloud.SshKey("main", {
  name: "jterrazz-infra",
  publicKey: sshKeyPair.publicKeyOpenssh,
});

// Cloud-init to setup SSH key and packages
const cloudInit = pulumi.interpolate`#cloud-config
package_update: true
packages:
  - curl
  - wget

ssh_authorized_keys:
  - ${sshKeyPair.publicKeyOpenssh}
`;

// VPS Server
const server = new hcloud.Server("main", {
  name: "jterrazz-vps",
  serverType: serverType,
  location: location,
  image: image,
  sshKeys: [sshKey.name],
  userData: cloudInit,
  labels: {
    environment: "production",
    managed_by: "pulumi",
  },
});

// Outputs
export const serverIp = server.ipv4Address;
export const serverName = server.name;
export const serverStatus = server.status;

// SSH private key (secret - for Ansible to use)
export const sshPrivateKey = pulumi.secret(sshKeyPair.privateKeyOpenssh);
