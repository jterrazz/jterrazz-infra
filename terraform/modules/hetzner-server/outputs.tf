output "id" {
  description = "Server ID"
  value       = hcloud_server.this.id
}

output "name" {
  description = "Server name"
  value       = hcloud_server.this.name
}

output "ipv4_address" {
  description = "Public IPv4 address"
  value       = hcloud_server.this.ipv4_address
}

output "ipv6_address" {
  description = "Public IPv6 address"
  value       = hcloud_server.this.ipv6_address
}

output "status" {
  description = "Server status"
  value       = hcloud_server.this.status
}
