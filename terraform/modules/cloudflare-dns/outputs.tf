output "fqdn" {
  description = "Fully qualified domain name"
  value       = cloudflare_record.main.hostname
}

output "record_id" {
  description = "DNS record ID"
  value       = cloudflare_record.main.id
}

output "wildcard_fqdn" {
  description = "Wildcard FQDN"
  value       = var.create_wildcard ? cloudflare_record.wildcard[0].hostname : null
}
