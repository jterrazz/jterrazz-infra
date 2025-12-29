/**
 * Output Values
 */

output "server_ip" {
  description = "Server public IPv4 address"
  value       = module.server.ipv4_address
}

output "server_ipv6" {
  description = "Server public IPv6 address"
  value       = module.server.ipv6_address
}

output "ssh_command" {
  description = "SSH connection command"
  value       = "ssh root@${module.server.ipv4_address}"
}

output "domain" {
  description = "Domain name (if DNS configured)"
  value       = var.cloudflare_zone_id != "" ? module.dns[0].fqdn : null
}

output "kubernetes_api" {
  description = "Kubernetes API endpoint (after k3s installation)"
  value       = "https://${module.server.ipv4_address}:6443"
}

output "ansible_host" {
  description = "Host entry for Ansible inventory"
  value = {
    name     = module.server.name
    ip       = module.server.ipv4_address
    ssh_user = "root"
  }
}
