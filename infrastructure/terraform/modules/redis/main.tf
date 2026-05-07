resource "random_string" "suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  cache_name = substr(join("", regexall("[a-z0-9-]", lower("${var.project_name}-${var.environment}-redis-${random_string.suffix.result}"))), 0, 63)
}

resource "azurerm_redis_cache" "main" {
  name                               = local.cache_name
  location                           = var.location
  resource_group_name                = var.resource_group_name
  capacity                           = var.capacity
  family                             = var.family
  sku_name                           = var.sku_name
  access_keys_authentication_enabled = var.access_keys_authentication_enabled

  non_ssl_port_enabled = false
  minimum_tls_version  = "1.2"
  subnet_id            = var.sku_name == "Premium" ? var.subnet_id : null

  redis_configuration {
    active_directory_authentication_enabled = var.active_directory_authentication_enabled
    authentication_enabled                  = true
  }

  tags = var.tags
}
