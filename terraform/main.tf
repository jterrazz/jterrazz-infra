# JTerrazz Infrastructure - Hetzner Cloud VPS
# Modern Infrastructure as Code setup with Terraform + Ansible + k3s

terraform {
  required_version = ">= 1.0"
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

# Configure Hetzner Cloud Provider
provider "hcloud" {
  token = var.hcloud_token
}

# Configure Cloudflare Provider
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# SSH Key for server access
resource "hcloud_ssh_key" "main" {
  name       = "${var.project_name}-key"
  public_key = var.ssh_public_key
}

# Create the VPS
resource "hcloud_server" "main" {
  name        = "${var.project_name}-server"
  image       = var.server_image
  server_type = var.server_type
  location    = var.server_location
  
  ssh_keys = [hcloud_ssh_key.main.id]
  
  # Cloud-init configuration
  user_data = templatefile("${path.module}/cloud-init.yml", {
    ssh_public_key = var.ssh_public_key
    hostname      = "${var.project_name}-server"
  })

  labels = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# Floating IP (optional, for static IP)
resource "hcloud_floating_ip" "main" {
  count         = var.enable_floating_ip ? 1 : 0
  type          = "ipv4"
  home_location = var.server_location
  description   = "${var.project_name} floating IP"
  
  labels = {
    project = var.project_name
  }
}

# Assign floating IP to server
resource "hcloud_floating_ip_assignment" "main" {
  count          = var.enable_floating_ip ? 1 : 0
  floating_ip_id = hcloud_floating_ip.main[0].id
  server_id      = hcloud_server.main.id
}

# Firewall rules
resource "hcloud_firewall" "main" {
  name = "${var.project_name}-firewall"
  
  # SSH access
  rule {
    direction = "in"
    port      = "22"
    protocol  = "tcp"
    source_ips = var.allowed_ssh_ips
  }
  
  # HTTP/HTTPS for web services
  rule {
    direction = "in"
    port      = "80"
    protocol  = "tcp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  
  rule {
    direction = "in"
    port      = "443" 
    protocol  = "tcp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  
  # Kubernetes API (restricted)
  rule {
    direction = "in"
    port      = "6443"
    protocol  = "tcp"
    source_ips = var.allowed_k8s_ips
  }
  
  # Tailscale
  rule {
    direction = "in"
    port      = "41641"
    protocol  = "udp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

# Apply firewall to server
resource "hcloud_firewall_attachment" "main" {
  firewall_id = hcloud_firewall.main.id
  server_ids  = [hcloud_server.main.id]
}

# DNS Records (Cloudflare)
resource "cloudflare_record" "main" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.subdomain
  content = var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address
  type    = "A"
  ttl     = 300
  
  comment = "Managed by Terraform - ${var.project_name}"
}

# Wildcard DNS for applications
resource "cloudflare_record" "wildcard" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = "*.${var.subdomain}"
  content = var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address
  type    = "A"
  ttl     = 300
  
  comment = "Wildcard for applications - ${var.project_name}"
}
