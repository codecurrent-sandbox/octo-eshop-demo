locals {
  # Azure rejects zone-redundant Standard public IPs paired with non-AZ
  # gateway SKUs (and vice-versa) at apply time, deep into the 30-45 minute
  # provisioning window. We pick the right zoning automatically from the SKU.
  is_az_sku = endswith(var.gateway_sku, "AZ")

  # Generation2 is only meaningful for VpnGw2AZ and VpnGw3AZ (per Azure
  # SKU/generation matrix). Catch obvious mispairings at plan time.
  gen2_only_with_az_sku = var.gateway_generation == "Generation2" && !contains(["VpnGw2AZ", "VpnGw3AZ"], var.gateway_sku)
}

resource "azurerm_subnet" "gateway" {
  count = var.enabled ? 1 : 0

  name                 = "GatewaySubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.virtual_network_name
  address_prefixes     = var.gateway_subnet_prefix
}

resource "azurerm_public_ip" "gateway" {
  count = var.enabled ? 1 : 0

  name                = "${var.project_name}-${var.environment}-codespaces-vpn-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.is_az_sku ? ["1", "2", "3"] : null
  tags                = var.tags

  lifecycle {
    # Azure attaches a `FirstPartyUsage = /Unprivileged` ip_tag to public
    # IPs that back gateways behind the scenes (it shows up after creation,
    # never on the original config). Without this ignore, every subsequent
    # plan tries to remove the tag which forces a destroy/replace of the
    # PIP - and replacing the PIP changes the gateway's public IP, which
    # in turn invalidates every distributed OPENVPNCONFIG secret. Treat
    # ip_tags as Azure-owned so subsequent applies don't churn the PIP.
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_virtual_network_gateway" "main" {
  count = var.enabled ? 1 : 0

  name                = "${var.project_name}-${var.environment}-codespaces-vpn-gw"
  location            = var.location
  resource_group_name = var.resource_group_name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  active_active       = false
  bgp_enabled         = false
  sku                 = var.gateway_sku
  generation          = var.gateway_generation
  tags                = var.tags

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.gateway[0].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway[0].id
  }

  vpn_client_configuration {
    address_space        = [var.vpn_client_address_pool]
    vpn_client_protocols = ["OpenVPN"]
    vpn_auth_types       = ["Certificate"]

    root_certificate {
      name             = var.root_certificate_name
      public_cert_data = var.root_certificate_public_data
    }
  }

  # Catch the most expensive misconfiguration at plan-time, instead of
  # waiting 30+ minutes for Azure to reject the gateway creation.
  lifecycle {
    precondition {
      condition     = length(trimspace(var.root_certificate_public_data)) > 0
      error_message = "root_certificate_public_data must be provided when the codespaces_vpn module is enabled. Run scripts/generate-codespaces-vpn-cert.sh and pass the contents of azure-vpn-root-public.txt as TF_VAR_codespaces_vpn_root_certificate_public_data."
    }
    precondition {
      condition     = !local.gen2_only_with_az_sku
      error_message = "gateway_generation = \"Generation2\" is only valid for the *AZ SKUs (VpnGw2AZ/VpnGw3AZ). Use Generation1 for VpnGw1/VpnGw1AZ/VpnGw2/VpnGw3."
    }
  }
}
