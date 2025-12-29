import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";

const config = new pulumi.Config();

// Configuration with defaults
const serverType = config.get("serverType") || "cx22";
const location = config.get("location") || "nbg1";
const image = config.get("image") || "ubuntu-24.04";

// SSH Key
const sshKey = new hcloud.SshKey("main", {
  name: "jterrazz-infra",
  publicKey: config.require("sshPublicKey"),
});

// Cloud-init for minimal bootstrap (Ansible does the rest)
const cloudInit = `#cloud-config
package_update: true
packages:
  - curl
  - wget

users:
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${config.require("sshPublicKey")}
`;

// VPS Server
const server = new hcloud.Server("main", {
  name: "jterrazz-vps",
  serverType: serverType,
  location: location,
  image: image,
  sshKeys: [sshKey.id],
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
