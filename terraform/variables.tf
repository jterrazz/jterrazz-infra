# Jterrazz Infrastructure - Terraform Variables
# Configure your VPS and DNS settings here

variable "project_name" {
  description = "Name of the project (used for resource naming)"
  type        = string
  default     = "jterrazz-infra"
}

variable "environment" {
  description = "Environment (production, staging, development)"
  type        = string
  default     = "production"
}

# Hetzner Cloud Configuration
variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx21" # 2 vCPU, 4 GB RAM, 40 GB SSD
}

variable "server_image" {
  description = "Server OS image"
  type        = string
  default     = "ubuntu-24.04"
}

variable "server_location" {
  description = "Server location"
  type        = string
  default     = "nbg1" # Nuremberg, Germany (EU location)
}

variable "enable_floating_ip" {
  description = "Create a floating IP for the server"
  type        = bool
  default     = true
}

# SSH Configuration
variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string
}

variable "allowed_ssh_ips" {
  description = "IP addresses allowed to SSH to the server"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict this in production!
}

variable "allowed_k8s_ips" {
  description = "IP addresses allowed to access Kubernetes API"
  type        = list(string)
  default     = ["100.64.0.0/10"] # Tailscale IP range only (secure)
}

# Cloudflare DNS Configuration
variable "cloudflare_api_token" {
  description = "Cloudflare API token for DNS management"
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for your domain"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Your domain name (e.g., jterrazz.com)"
  type        = string
  default     = ""
}

variable "subdomain" {
  description = "Subdomain for the server (e.g., manager)"
  type        = string
  default     = "manager"
}
