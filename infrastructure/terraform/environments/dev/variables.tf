variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "octoeshop"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "swedencentral"
}

variable "alert_email" {
  description = "Alert notification email"
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "Address space for VNet"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "aks_subnet_prefix" {
  description = "Address prefix for AKS subnet"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "database_subnet_prefix" {
  description = "Address prefix for database subnet"
  type        = list(string)
  default     = ["10.0.2.0/24"]
}

variable "redis_subnet_prefix" {
  description = "Address prefix for Redis subnet"
  type        = list(string)
  default     = ["10.0.3.0/24"]
}

variable "kubernetes_version" {
  description = "Kubernetes version for AKS"
  type        = string
  default     = null
  nullable    = true
}

variable "aks_node_count" {
  description = "Number of AKS nodes"
  type        = number
  default     = 1
}

variable "aks_node_vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "acr_sku" {
  description = "ACR SKU"
  type        = string
  default     = "Basic"
}

variable "postgresql_sku" {
  description = "PostgreSQL SKU"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgresql_storage_mb" {
  description = "PostgreSQL storage in MB"
  type        = number
  default     = 32768
}

variable "redis_sku" {
  description = "Redis SKU"
  type        = string
  default     = "Basic"
}

variable "redis_family" {
  description = "Redis family"
  type        = string
  default     = "C"
}

variable "redis_capacity" {
  description = "Redis capacity"
  type        = number
  default     = 0
}

variable "servicebus_sku" {
  description = "Service Bus SKU"
  type        = string
  default     = "Basic"
}

# --------------------------------------------------------------------------- #
# Dev Codespaces OpenVPN Point-to-Site
#
# Provisions an Azure VPN Gateway with a P2S OpenVPN configuration so that a
# GitHub Codespace can tunnel into the dev VNet and reach the private
# PostgreSQL Flexible Servers. All variables below are no-ops while
# enable_dev_codespaces_openvpn = false. See docs/dev-codespaces-openvpn.md
# for end-to-end setup and a manual test flow that does not require CI/CD.
# --------------------------------------------------------------------------- #

variable "enable_dev_codespaces_openvpn" {
  description = "Master flag for the OpenVPN P2S codespaces tunnel. The Virtual Network Gateway it provisions is the most expensive resource in this environment (~USD 140/month for VpnGw1AZ) and takes 30-45 minutes to apply or destroy. Default false; flip on while you actively need the tunnel and back off when finished."
  type        = bool
  default     = false
}

variable "codespaces_vpn_gateway_subnet_prefix" {
  description = "CIDR for the GatewaySubnet inside the dev VNet. Must not overlap with AKS, database, or Redis subnets, and must be /29 or larger."
  type        = list(string)
  default     = ["10.0.255.0/27"]
}

variable "codespaces_vpn_client_address_pool" {
  description = "CIDR Azure assigns to connected P2S clients. Must not overlap with the dev VNet (10.0.0.0/16) or any peered network."
  type        = string
  default     = "172.16.201.0/24"
}

variable "codespaces_vpn_gateway_sku" {
  description = "Virtual Network Gateway SKU. Must support OpenVPN (Basic does not). Default VpnGw1AZ is the cheapest supported SKU; Azure deprecated non-AZ VPN Gateways in 2026 (NonAzSkusNotAllowedForVPNGateway) so only the *AZ variants are accepted now."
  type        = string
  default     = "VpnGw1AZ"
}

variable "codespaces_vpn_gateway_generation" {
  description = "Gateway hardware generation. Generation1 is the right value for VpnGw1AZ. Generation2 is only valid in combination with VpnGw2AZ or VpnGw3AZ."
  type        = string
  default     = "Generation1"
}

variable "codespaces_vpn_root_certificate_public_data" {
  description = "Base64 body of the trusted root certificate (PEM, with the -----BEGIN/END----- markers and line breaks stripped). Produced by scripts/generate-codespaces-vpn-cert.sh. Required when enable_dev_codespaces_openvpn = true."
  type        = string
  default     = ""
}

# --------------------------------------------------------------------------- #
# Azure DNS Private Resolver
#
# Provisions a Private DNS Resolver inbound endpoint inside the dev VNet so
# that GitHub Codespaces connected via the codespaces OpenVPN P2S tunnel can
# resolve VNet-private FQDNs (e.g. *.privatelink.postgres.database.azure.com)
# without the per-rebuild /etc/hosts workaround. The resolver IP is pushed
# to OpenVPN clients via scripts/build-codespaces-openvpn-config.sh, which
# injects a dhcp-option DNS directive into the generated profile.
#
# Replaces "Future improvements: Azure DNS Private Resolver" from
# docs/dev-codespaces-openvpn.md.
# --------------------------------------------------------------------------- #

variable "enable_dns_private_resolver" {
  description = "When true (and enable_dev_codespaces_openvpn = true), provisions an Azure DNS Private Resolver inbound endpoint inside the dev VNet. Adds ~USD 108/month on top of the VPN gateway, so default false; flip on alongside the VPN flag when you want codespaces to resolve VNet-private FQDNs natively without the /etc/hosts workaround. A check block in main.tf rejects enable_dns_private_resolver = true while enable_dev_codespaces_openvpn = false."
  type        = bool
  default     = false
}

variable "dns_private_resolver_subnet_prefix" {
  description = "CIDR for the dedicated DNS resolver inbound-endpoint subnet. Must be at least /28 and must not overlap with AKS, database, Redis, or GatewaySubnet ranges."
  type        = list(string)
  default     = ["10.0.4.0/28"]
}
