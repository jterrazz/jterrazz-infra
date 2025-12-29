/**
 * Input Variables
 */

# -----------------------------------------------------------------------------
# Project Configuration
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "jterrazz-infra"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "Project name must start with a letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be production, staging, or development."
  }
}

# -----------------------------------------------------------------------------
# Hetzner Cloud Configuration
# -----------------------------------------------------------------------------

variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "server_type" {
  description = "Hetzner server type (cx22 = 2 vCPU, 4GB RAM, 40GB SSD)"
  type        = string
  default     = "cx22"
}

variable "server_location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1"
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string

  validation {
    condition     = can(regex("^ssh-(rsa|ed25519|ecdsa)", var.ssh_public_key))
    error_message = "Must be a valid SSH public key."
  }
}

# -----------------------------------------------------------------------------
# Cloudflare DNS Configuration (Optional)
# -----------------------------------------------------------------------------

variable "cloudflare_api_token" {
  description = "Cloudflare API token for DNS management"
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID (leave empty to skip DNS setup)"
  type        = string
  default     = ""
}

variable "subdomain" {
  description = "Subdomain for the server (e.g., 'infra' for infra.example.com)"
  type        = string
  default     = "infra"
}
