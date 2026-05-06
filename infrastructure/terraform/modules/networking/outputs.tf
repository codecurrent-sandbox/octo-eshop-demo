output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "database_subnet_id" {
  value = azurerm_subnet.database.id
}

output "database_nsg_id" {
  value = azurerm_network_security_group.database.id
}

output "database_nsg_name" {
  value = azurerm_network_security_group.database.name
}

output "redis_subnet_id" {
  value = azurerm_subnet.redis.id
}

output "postgresql_private_dns_zone_id" {
  value = azurerm_private_dns_zone.postgresql.id
}

output "postgresql_private_dns_zone_name" {
  value = azurerm_private_dns_zone.postgresql.name
}
