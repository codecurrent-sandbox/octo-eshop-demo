locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Team        = "Platform"
  }
}

resource "random_string" "global_suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = "${var.project_name}-${var.environment}-rg"
  location = var.location
  tags     = local.common_tags
}

module "networking" {
  source = "../../modules/networking"

  project_name           = var.project_name
  environment            = var.environment
  location               = var.location
  resource_group_name    = azurerm_resource_group.main.name
  vnet_address_space     = var.vnet_address_space
  aks_subnet_prefix      = var.aks_subnet_prefix
  database_subnet_prefix = var.database_subnet_prefix
  redis_subnet_prefix    = var.redis_subnet_prefix
  tags                   = local.common_tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  alert_email         = var.alert_email
  tags                = local.common_tags
}

module "acr" {
  source = "../../modules/acr"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.acr_sku
  tags                = local.common_tags
}

module "aks" {
  source = "../../modules/aks"

  project_name               = var.project_name
  environment                = var.environment
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  kubernetes_version         = var.kubernetes_version
  node_count                 = var.aks_node_count
  node_vm_size               = var.aks_node_vm_size
  vnet_subnet_id             = module.networking.aks_subnet_id
  acr_id                     = module.acr.acr_id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  tags                       = local.common_tags
}

module "postgresql_user" {
  source = "../../modules/postgresql"

  name                = "${var.project_name}-${var.environment}-user-db-${random_string.global_suffix.result}"
  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  delegated_subnet_id = module.networking.database_subnet_id
  private_dns_zone_id = module.networking.postgresql_private_dns_zone_id
  sku_name            = var.postgresql_sku
  storage_mb          = var.postgresql_storage_mb
  database_name       = "userdb"
  administrator_login = "pgadmin"
  tags                = local.common_tags
}

module "postgresql_product" {
  source = "../../modules/postgresql"

  name                = "${var.project_name}-${var.environment}-product-db-${random_string.global_suffix.result}"
  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  delegated_subnet_id = module.networking.database_subnet_id
  private_dns_zone_id = module.networking.postgresql_private_dns_zone_id
  sku_name            = var.postgresql_sku
  storage_mb          = var.postgresql_storage_mb
  database_name       = "productdb"
  administrator_login = "pgadmin"
  tags                = local.common_tags
}

module "postgresql_order" {
  source = "../../modules/postgresql"

  name                = "${var.project_name}-${var.environment}-order-db-${random_string.global_suffix.result}"
  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  delegated_subnet_id = module.networking.database_subnet_id
  private_dns_zone_id = module.networking.postgresql_private_dns_zone_id
  sku_name            = var.postgresql_sku
  storage_mb          = var.postgresql_storage_mb
  database_name       = "orderdb"
  administrator_login = "pgadmin"
  tags                = local.common_tags
}

module "redis" {
  source = "../../modules/redis"

  project_name                            = var.project_name
  environment                             = var.environment
  location                                = var.location
  resource_group_name                     = azurerm_resource_group.main.name
  sku_name                                = var.redis_sku
  family                                  = var.redis_family
  capacity                                = var.redis_capacity
  subnet_id                               = module.networking.redis_subnet_id
  active_directory_authentication_enabled = true
  tags                                    = local.common_tags
}

module "servicebus" {
  source = "../../modules/servicebus"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.servicebus_sku
  tags                = local.common_tags
}

module "storage" {
  source = "../../modules/storage"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

module "keyvault" {
  source = "../../modules/keyvault"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  aks_principal_id    = module.aks.kubelet_identity_object_id
  tags                = local.common_tags
}

resource "azurerm_key_vault_secret" "user_db_connection" {
  name         = "user-db-connection-string"
  value        = module.postgresql_user.connection_string
  key_vault_id = module.keyvault.key_vault_id
  depends_on   = [module.keyvault]
}

resource "azurerm_key_vault_secret" "product_db_connection" {
  name         = "product-db-connection-string"
  value        = module.postgresql_product.connection_string
  key_vault_id = module.keyvault.key_vault_id
  depends_on   = [module.keyvault]
}

resource "azurerm_key_vault_secret" "order_db_connection" {
  name         = "order-db-connection-string"
  value        = module.postgresql_order.connection_string
  key_vault_id = module.keyvault.key_vault_id
  depends_on   = [module.keyvault]
}

resource "azurerm_key_vault_secret" "redis_connection" {
  name         = "redis-connection-string"
  value        = module.redis.connection_string
  key_vault_id = module.keyvault.key_vault_id
  depends_on   = [module.keyvault]
}

resource "azurerm_key_vault_secret" "servicebus_connection" {
  name         = "servicebus-connection-string"
  value        = module.servicebus.primary_connection_string
  key_vault_id = module.keyvault.key_vault_id
  depends_on   = [module.keyvault]
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = true
}

resource "azurerm_key_vault_secret" "jwt_secret" {
  name         = "jwt-secret"
  value        = random_password.jwt_secret.result
  key_vault_id = module.keyvault.key_vault_id
  depends_on   = [module.keyvault]
}
