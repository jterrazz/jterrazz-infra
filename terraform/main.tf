/**
 * Jterrazz Infrastructure - Main Configuration
 *
 * Provisions a Hetzner Cloud VPS with optional Cloudflare DNS.
 * Designed for single-node k3s Kubernetes deployment.
 */

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------------

provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# -----------------------------------------------------------------------------
# Local Values
# -----------------------------------------------------------------------------

locals {
  server_name = "${var.project_name}-server"

  common_labels = {
    project     = var.project_name
    environment = var.environment
  }

  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml", {
    hostname = local.server_name
  })
}

# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------

module "server" {
  source = "./modules/hetzner-server"

  name           = local.server_name
  server_type    = var.server_type
  location       = var.server_location
  ssh_public_key = var.ssh_public_key
  user_data      = local.cloud_init
  labels         = local.common_labels
}

# -----------------------------------------------------------------------------
# DNS (Optional)
# -----------------------------------------------------------------------------

module "dns" {
  source = "./modules/cloudflare-dns"
  count  = var.cloudflare_zone_id != "" ? 1 : 0

  zone_id         = var.cloudflare_zone_id
  subdomain       = var.subdomain
  ip_address      = module.server.ipv4_address
  create_wildcard = true
}
