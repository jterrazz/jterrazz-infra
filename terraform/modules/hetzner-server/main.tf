/**
 * Hetzner Cloud Server Module
 *
 * Creates a VPS instance with proper configuration for k3s deployment.
 */

terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.45.0"
    }
  }
}

resource "hcloud_ssh_key" "this" {
  name       = "${var.name}-key"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "this" {
  name        = var.name
  image       = var.image
  server_type = var.server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.this.id]

  user_data = var.user_data

  labels = merge(var.labels, {
    managed_by = "terraform"
  })

  lifecycle {
    ignore_changes = [user_data]
  }
}
