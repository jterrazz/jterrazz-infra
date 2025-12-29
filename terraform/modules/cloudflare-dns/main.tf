/**
 * Cloudflare DNS Module
 *
 * Creates DNS records for the infrastructure.
 */

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4.0.0"
    }
  }
}

resource "cloudflare_record" "main" {
  zone_id = var.zone_id
  name    = var.subdomain
  content = var.ip_address
  type    = "A"
  ttl     = var.ttl
  proxied = var.proxied

  comment = "Managed by Terraform"
}

resource "cloudflare_record" "wildcard" {
  count = var.create_wildcard ? 1 : 0

  zone_id = var.zone_id
  name    = "*.${var.subdomain}"
  content = var.ip_address
  type    = "A"
  ttl     = var.ttl
  proxied = false # Wildcards cannot be proxied on free plan

  comment = "Wildcard for applications - Managed by Terraform"
}
