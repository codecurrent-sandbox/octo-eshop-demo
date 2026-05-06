output "enabled" {
  description = "Reflects the input flag so consumers can gate downstream behavior off the same value."
  value       = var.enabled
}

output "resolver_id" {
  description = "Resource ID of the Private DNS Resolver, or null when the module is disabled."
  value       = try(azurerm_private_dns_resolver.main[0].id, null)
}

output "inbound_endpoint_id" {
  description = "Resource ID of the Private DNS Resolver inbound endpoint, or null when the module is disabled."
  value       = try(azurerm_private_dns_resolver_inbound_endpoint.main[0].id, null)
}

output "inbound_endpoint_ip" {
  description = "Private IP of the inbound endpoint inside the VNet, or null when the module is disabled. scripts/build-codespaces-openvpn-config.sh consumes this value via terraform output and injects it into the OpenVPN profile as a dhcp-option DNS directive."
  value       = try(azurerm_private_dns_resolver_inbound_endpoint.main[0].ip_configurations[0].private_ip_address, null)
}

output "subnet_id" {
  description = "Resource ID of the inbound-endpoint subnet, or null when the module is disabled."
  value       = try(azurerm_subnet.dns_inbound[0].id, null)
}
