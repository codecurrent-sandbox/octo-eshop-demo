output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_cluster_id" {
  value = module.aks.cluster_id
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "acr_name" {
  value = module.acr.acr_name
}

output "key_vault_name" {
  value = module.keyvault.key_vault_name
}

output "key_vault_uri" {
  value = module.keyvault.key_vault_uri
}

output "log_analytics_workspace_id" {
  value = module.monitoring.log_analytics_workspace_id
}

output "application_insights_connection_string" {
  value     = module.monitoring.application_insights_connection_string
  sensitive = true
}

output "kube_config_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${module.aks.cluster_name}"
}

# --------------------------------------------------------------------------- #
# Dev Codespaces OpenVPN P2S outputs
#
# These are null while enable_dev_codespaces_openvpn = false, populated once
# the gateway has finished provisioning. scripts/build-codespaces-openvpn-config.sh
# consumes codespaces_vpn_gateway_name and resource_group_name to fetch the
# gateway's generated OpenVPN profile.
# --------------------------------------------------------------------------- #

output "codespaces_vpn_enabled" {
  value = module.codespaces_vpn.enabled
}

output "codespaces_vpn_gateway_name" {
  value = module.codespaces_vpn.gateway_name
}

output "codespaces_vpn_gateway_public_ip" {
  value = module.codespaces_vpn.gateway_public_ip
}

output "codespaces_vpn_client_address_pool" {
  value = module.codespaces_vpn.vpn_client_address_pool
}

output "postgresql_private_dns_zone_name" {
  value = module.networking.postgresql_private_dns_zone_name
}

output "user_db_fqdn" {
  value = module.postgresql_user.server_fqdn
}

output "product_db_fqdn" {
  value = module.postgresql_product.server_fqdn
}

output "order_db_fqdn" {
  value = module.postgresql_order.server_fqdn
}

# --------------------------------------------------------------------------- #
# Azure DNS Private Resolver outputs
#
# Null while the resolver is disabled (enable_dns_private_resolver = false
# and/or enable_dev_codespaces_openvpn = false). When enabled,
# scripts/build-codespaces-openvpn-config.sh reads dns_resolver_inbound_ip
# and injects it into the OpenVPN profile as a `dhcp-option DNS <ip>` line
# so connected codespaces resolve VNet-private FQDNs through the resolver.
# --------------------------------------------------------------------------- #

output "dns_resolver_enabled" {
  value = module.dns_private_resolver.enabled
}

output "dns_resolver_inbound_ip" {
  description = "Private IP of the DNS Private Resolver inbound endpoint, or null when disabled. Consumed by scripts/build-codespaces-openvpn-config.sh."
  value       = module.dns_private_resolver.inbound_endpoint_ip
}
