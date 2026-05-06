variable "project_name" {
  description = "Project short name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "vnet_address_space" {
  description = "Virtual network address spaces"
  type        = list(string)
}

variable "aks_subnet_prefix" {
  description = "AKS subnet CIDR"
  type        = list(string)
}

variable "database_subnet_prefix" {
  description = "Database subnet CIDR"
  type        = list(string)
}

variable "redis_subnet_prefix" {
  description = "Redis subnet CIDR"
  type        = list(string)
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}

variable "database_additional_allow_postgres_source_cidrs" {
  description = "Additional source CIDRs allowed inbound to the database NSG on TCP/5432, beyond the AKS subnet. Empty list (the default) keeps the NSG identical to its previous shape. Used by environments that need to grant connectivity from extra ranges, e.g. the Codespaces VPN client address pool. The rule is still managed inline by this module so that we never mix inline and standalone NSG rules on one NSG."
  type        = list(string)
  default     = []
}
