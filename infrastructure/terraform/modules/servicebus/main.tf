resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  namespace_name = substr(join("", regexall("[a-z0-9-]", lower("${var.project_name}-${var.environment}-sb-${random_string.suffix.result}"))), 0, 50)
}

resource "azurerm_servicebus_namespace" "main" {
  name                          = local.namespace_name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  sku                           = var.sku
  local_auth_enabled            = true
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_servicebus_queue" "order_created" {
  name         = "order-created"
  namespace_id = azurerm_servicebus_namespace.main.id
}

resource "azurerm_servicebus_queue" "order_paid" {
  name         = "order-paid"
  namespace_id = azurerm_servicebus_namespace.main.id
}

resource "azurerm_servicebus_namespace_authorization_rule" "apps" {
  name         = "app-policy"
  namespace_id = azurerm_servicebus_namespace.main.id

  listen = true
  send   = true
  manage = false
}
