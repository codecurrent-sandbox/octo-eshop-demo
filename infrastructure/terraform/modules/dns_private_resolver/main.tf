# Azure DNS Private Resolver (inbound endpoint only).
#
# Purpose: provide a VNet-internal DNS resolver IP that off-VNet clients
# (specifically: GitHub Codespaces connected via the codespaces_vpn P2S
# OpenVPN gateway) can target so that *.privatelink.postgres.database.azure.com
# - and any other VNet-linked private DNS zone - resolves correctly without
# the per-rebuild /etc/hosts workaround documented in
# docs/dev-codespaces-openvpn.md.
#
# This module intentionally does NOT touch the VNet's DNS servers field:
# changing VNet DNS would also affect AKS node bootstrap and other VNet-
# resident resources that have nothing to do with the codespaces use case.
# Instead, the resolver IP is pushed to OpenVPN clients via a
# dhcp-option DNS directive injected into the .ovpn profile by
# scripts/build-codespaces-openvpn-config.sh.
#
# Inbound endpoints are dedicated; they do not require an outbound endpoint
# or a forwarding ruleset for this use case (codespaces only need to resolve
# private DNS zones already linked to the VNet, which inbound resolution
# handles natively).

resource "azurerm_subnet" "dns_inbound" {
  count = var.enabled ? 1 : 0

  name                 = "${var.project_name}-${var.environment}-dns-inbound-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
  address_prefixes     = var.subnet_prefix

  delegation {
    name = "dns-resolver-delegation"

    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_resolver" "main" {
  count = var.enabled ? 1 : 0

  name                = "${var.project_name}-${var.environment}-dns-resolver"
  location            = var.location
  resource_group_name = var.resource_group_name
  virtual_network_id  = var.virtual_network_id
  tags                = var.tags
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "main" {
  count = var.enabled ? 1 : 0

  name                    = "${var.project_name}-${var.environment}-dns-resolver-inbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.main[0].id
  location                = var.location
  tags                    = var.tags

  ip_configurations {
    private_ip_allocation_method = "Dynamic"
    subnet_id                    = azurerm_subnet.dns_inbound[0].id
  }
}
