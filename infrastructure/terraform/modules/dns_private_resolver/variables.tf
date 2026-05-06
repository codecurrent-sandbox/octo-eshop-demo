variable "enabled" {
  description = "When true, provisions the dedicated inbound-resolver subnet, the Private DNS Resolver, and an inbound endpoint. The inbound endpoint bills at roughly USD 108/month at the time of writing (in addition to the codespaces_vpn gateway), so this defaults to false. Flip to true alongside enable_dev_codespaces_openvpn when you want codespaces to resolve VNet-private FQDNs without the /etc/hosts workaround."
  type        = bool
  default     = false
}

variable "project_name" {
  description = "Project short name."
  type        = string
}

variable "environment" {
  description = "Environment name (dev/staging/production)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that will own the resolver and the inbound endpoint subnet."
  type        = string
}

variable "virtual_network_id" {
  description = "Resource ID of the existing VNet to link the resolver to. Must be in the same region as var.location."
  type        = string
}

variable "virtual_network_name" {
  description = "Name of the existing VNet that the inbound-endpoint subnet should be added to."
  type        = string
}

variable "subnet_prefix" {
  description = "CIDR for the inbound-endpoint subnet. Azure requires at least /28 for a DNS resolver subnet, and the subnet must be dedicated (delegated to Microsoft.Network/dnsResolvers, no other resources can use it)."
  type        = list(string)
  default     = ["10.0.4.0/28"]

  validation {
    condition     = length(var.subnet_prefix) == 1
    error_message = "Provide exactly one CIDR for the DNS resolver inbound subnet."
  }
}

variable "tags" {
  description = "Resource tags."
  type        = map(string)
  default     = {}
}
