output "gateway_id" {
  description = "Resource ID of the Virtual Network Gateway, or null when the module is disabled."
  value       = try(azurerm_virtual_network_gateway.main[0].id, null)
}

output "gateway_name" {
  description = "Name of the Virtual Network Gateway, or null when the module is disabled."
  value       = try(azurerm_virtual_network_gateway.main[0].name, null)
}

output "gateway_public_ip" {
  description = "Public IP of the gateway, or null when the module is disabled."
  value       = try(azurerm_public_ip.gateway[0].ip_address, null)
}

output "vpn_client_address_pool" {
  description = "P2S client CIDR that NSG rules should allow inbound."
  value       = var.vpn_client_address_pool
}

output "enabled" {
  description = "Reflects the input flag so consumers can gate downstream resources off the same value."
  value       = var.enabled
}
