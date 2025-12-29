variable "zone_id" {
  description = "Cloudflare zone ID"
  type        = string
}

variable "subdomain" {
  description = "Subdomain name (e.g., 'infra' for infra.example.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.subdomain))
    error_message = "Subdomain must start with a letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "ip_address" {
  description = "IP address for the DNS record"
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.ip_address))
    error_message = "Must be a valid IPv4 address."
  }
}

variable "ttl" {
  description = "DNS TTL in seconds (1 = auto for proxied)"
  type        = number
  default     = 300

  validation {
    condition     = var.ttl == 1 || (var.ttl >= 60 && var.ttl <= 86400)
    error_message = "TTL must be 1 (auto) or between 60 and 86400 seconds."
  }
}

variable "proxied" {
  description = "Enable Cloudflare proxy"
  type        = bool
  default     = false
}

variable "create_wildcard" {
  description = "Create wildcard DNS record"
  type        = bool
  default     = true
}
