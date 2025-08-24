# Jterrazz Infrastructure - Terraform Outputs
# Expose important information for Ansible and external use

output "server_id" {
  description = "Hetzner server ID"
  value       = hcloud_server.main.id
}

output "server_ipv4" {
  description = "Server IPv4 address"
  value       = hcloud_server.main.ipv4_address
}

output "server_ipv6" {
  description = "Server IPv6 address"
  value       = hcloud_server.main.ipv6_address
}

output "floating_ip" {
  description = "Floating IP address (if enabled)"
  value       = var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : null
}

output "public_ip" {
  description = "Public IP address (floating or server IP)"
  value       = var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address
}

output "domain_fqdn" {
  description = "Full domain name"
  value       = var.domain_name != "" ? "${var.subdomain}.${var.domain_name}" : null
}

# Ansible inventory generation
output "ansible_inventory" {
  description = "Ansible inventory configuration"
  value = templatefile("${path.module}/ansible-inventory.tpl", {
    server_ip   = var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address
    domain_name = var.domain_name != "" ? "${var.subdomain}.${var.domain_name}" : "localhost"
    environment = var.environment
  })
}

# Connection information
output "ssh_connection" {
  description = "SSH connection command"
  value       = "ssh root@${var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address}"
}

output "kubernetes_endpoint" {
  description = "Kubernetes API endpoint (after k3s installation)"
  value       = "https://${var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address}:6443"
}

# Summary output
output "deployment_summary" {
  description = "Deployment summary"
  value = {
    server_ip      = var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address
    server_type    = var.server_type
    server_location = var.server_location
    domain         = var.domain_name != "" ? "${var.subdomain}.${var.domain_name}" : null
    ssh_command    = "ssh root@${var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address}"
    next_steps     = [
      "1. Run: ansible-playbook -i inventory.yml playbooks/site.yml",
      "2. Access services at: https://${var.domain_name != "" ? "${var.subdomain}.${var.domain_name}" : hcloud_server.main.ipv4_address}",
      "3. Get kubeconfig: scp root@${var.enable_floating_ip ? hcloud_floating_ip.main[0].ip_address : hcloud_server.main.ipv4_address}:/etc/rancher/k3s/k3s.yaml ~/.kube/config"
    ]
  }
}
