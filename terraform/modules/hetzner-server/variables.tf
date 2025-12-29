variable "name" {
  description = "Server name"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.name))
    error_message = "Name must start with a letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx22"

  validation {
    condition     = contains(["cx22", "cx32", "cx42", "cx52", "cpx11", "cpx21", "cpx31", "cpx41", "cpx51"], var.server_type)
    error_message = "Must be a valid Hetzner Cloud server type."
  }
}

variable "image" {
  description = "OS image"
  type        = string
  default     = "ubuntu-24.04"
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1", "ash", "hil"], var.location)
    error_message = "Must be a valid Hetzner location."
  }
}

variable "ssh_public_key" {
  description = "SSH public key for server access"
  type        = string

  validation {
    condition     = can(regex("^ssh-(rsa|ed25519|ecdsa)", var.ssh_public_key))
    error_message = "Must be a valid SSH public key."
  }
}

variable "user_data" {
  description = "Cloud-init user data"
  type        = string
  default     = ""
}

variable "labels" {
  description = "Resource labels"
  type        = map(string)
  default     = {}
}
