#!/bin/bash
set -euo pipefail

###############################################################################
# Bootstrap Azure private networking for GitHub-hosted Actions runners.
#
# This creates the Azure-side network resources required before enabling a
# GitHub hosted compute network configuration:
#   1. GitHub.Network provider registration
#   2. Dedicated delegated subnet for GitHub-hosted runners
#   3. Private endpoint subnet
#   4. GitHub.Network/networkSettings resource
#   5. Private DNS zones and private endpoints for tfstate, Key Vault, and blob
#      storage data-plane access
#
# The GitHub-side hosted compute network and runner still need to be created by
# an organization/enterprise admin in GitHub settings using the GitHubId emitted
# by this script. If GitHub requires enterprise-level hosted compute networking,
# run this with --github-scope enterprise and the enterprise slug/databaseId.
###############################################################################

LOCATION="swedencentral"
RG_NAME="octoeshop-ci-network-rg"
VNET_NAME="octoeshop-ci-vnet"
RUNNER_SUBNET_NAME="github-runners-subnet"
PRIVATE_ENDPOINT_SUBNET_NAME="private-endpoints-subnet"
NETWORK_SETTINGS_NAME="octoeshop-github-actions-network"
ADDRESS_PREFIX="10.250.0.0/16"
RUNNER_SUBNET_PREFIX="10.250.1.0/24"
PRIVATE_ENDPOINT_SUBNET_PREFIX="10.250.2.0/24"
TFSTATE_RG="octoeshop-tfstate-rg"
TFSTATE_STORAGE_ACCOUNT="octoeshoptfstate"
GITHUB_SCOPE="org"
GITHUB_OWNER=""
GITHUB_DATABASE_ID=""
REPO=""
RUNNER_LABEL=""
SUBSCRIPTION=""
API_VERSION="2024-04-02"
ENVIRONMENTS=(dev staging production)

usage() {
  cat <<'USAGE'
Usage: scripts/bootstrap-github-actions-private-network.sh [options]

Options:
  --subscription <id>          Azure subscription ID (default: current az account)
  --repo <owner/repo>          GitHub repository for variables (default: detected)
  --github-scope <org|enterprise>
                               Scope used for GitHub hosted compute networking
                               (default: org)
  --github-owner <login|slug>  Organization login or enterprise slug
                               (default: repo owner for org scope)
  --github-database-id <id>    GitHub org/enterprise databaseId. If omitted for
                               org scope, the script fetches it with gh GraphQL.
  --runner-label <label>       Optional runner label to store in repo variables.
                               When supplied, also sets
                               INFRA_RUNNER_PRIVATE_NETWORK=true.
  --location <region>          Azure region for CI network resources
                               (default: swedencentral)
  --resource-group <name>      CI network resource group
                               (default: octoeshop-ci-network-rg)
  --vnet-name <name>           CI VNet name (default: octoeshop-ci-vnet)
  --address-prefix <cidr>      CI VNet address prefix (default: 10.250.0.0/16)
  --runner-subnet-prefix <cidr>
                               Delegated runner subnet CIDR
                               (default: 10.250.1.0/24)
  --private-endpoint-subnet-prefix <cidr>
                               Private endpoint subnet CIDR
                               (default: 10.250.2.0/24)

Examples:
  scripts/bootstrap-github-actions-private-network.sh \
    --github-owner codecurrent-sandbox

  scripts/bootstrap-github-actions-private-network.sh \
    --github-owner codecurrent-sandbox \
    --runner-label octoeshop-private-ubuntu

  scripts/bootstrap-github-actions-private-network.sh \
    --github-scope enterprise \
    --github-owner <enterprise-slug>
USAGE
  exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --github-scope) GITHUB_SCOPE="$2"; shift 2 ;;
    --github-owner) GITHUB_OWNER="$2"; shift 2 ;;
    --github-database-id) GITHUB_DATABASE_ID="$2"; shift 2 ;;
    --runner-label) RUNNER_LABEL="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --resource-group) RG_NAME="$2"; shift 2 ;;
    --vnet-name) VNET_NAME="$2"; shift 2 ;;
    --address-prefix) ADDRESS_PREFIX="$2"; shift 2 ;;
    --runner-subnet-prefix) RUNNER_SUBNET_PREFIX="$2"; shift 2 ;;
    --private-endpoint-subnet-prefix) PRIVATE_ENDPOINT_SUBNET_PREFIX="$2"; shift 2 ;;
    --help|-h) usage 0 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) not found."; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "GitHub CLI (gh) not found."; exit 1; }

az account show >/dev/null 2>&1 || { echo "Not logged into Azure. Run: az login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged into GitHub. Run: gh auth login"; exit 1; }

if [[ -z "$SUBSCRIPTION" ]]; then
  SUBSCRIPTION=$(az account show --query id -o tsv)
fi

if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
fi

if [[ -z "$GITHUB_OWNER" && "$GITHUB_SCOPE" == "org" && -n "$REPO" ]]; then
  GITHUB_OWNER="${REPO%%/*}"
fi

if [[ -z "$GITHUB_OWNER" ]]; then
  echo "GitHub owner is required. Pass --github-owner <org-login|enterprise-slug>."
  exit 1
fi

az account set --subscription "$SUBSCRIPTION"

resolve_github_database_id() {
  if [[ -n "$GITHUB_DATABASE_ID" ]]; then
    printf '%s\n' "$GITHUB_DATABASE_ID"
    return
  fi

  if [[ "$GITHUB_SCOPE" == "org" ]]; then
    local org_query
    # shellcheck disable=SC2016
    org_query='query($login: String!) { organization(login: $login) { databaseId } }'

    gh api graphql \
      -f login="$GITHUB_OWNER" \
      -f query="$org_query" \
      --jq '.data.organization.databaseId'
    return
  fi

  if [[ "$GITHUB_SCOPE" == "enterprise" ]]; then
    local enterprise_query
    # shellcheck disable=SC2016
    enterprise_query='query($slug: String!) { enterprise(slug: $slug) { databaseId } }'

    gh api graphql \
      -f slug="$GITHUB_OWNER" \
      -f query="$enterprise_query" \
      --jq '.data.enterprise.databaseId'
    return
  fi

  echo "Unsupported GitHub scope: $GITHUB_SCOPE" >&2
  exit 1
}

wait_for_provider_registration() {
  local state

  for _ in {1..30}; do
    state=$(az provider show --namespace GitHub.Network --query registrationState -o tsv 2>/dev/null || true)
    if [[ "$state" == "Registered" ]]; then
      return 0
    fi
    sleep 5
  done

  echo "GitHub.Network provider registration did not complete." >&2
  return 1
}

ensure_subnet() {
  local subnet_name="$1"
  local prefix="$2"

  if az network vnet subnet show \
    --resource-group "$RG_NAME" \
    --vnet-name "$VNET_NAME" \
    --name "$subnet_name" \
    --output none 2>/dev/null; then
    return
  fi

  az network vnet subnet create \
    --resource-group "$RG_NAME" \
    --vnet-name "$VNET_NAME" \
    --name "$subnet_name" \
    --address-prefixes "$prefix" \
    --output none
}

ensure_private_dns_zone() {
  local zone="$1"

  if ! az network private-dns zone show \
    --resource-group "$RG_NAME" \
    --name "$zone" \
    --output none 2>/dev/null; then
    az network private-dns zone create \
      --resource-group "$RG_NAME" \
      --name "$zone" \
      --output none
  fi

  if ! az network private-dns link vnet show \
    --resource-group "$RG_NAME" \
    --zone-name "$zone" \
    --name "${VNET_NAME}-${zone}-link" \
    --output none 2>/dev/null; then
    az network private-dns link vnet create \
      --resource-group "$RG_NAME" \
      --zone-name "$zone" \
      --name "${VNET_NAME}-${zone}-link" \
      --virtual-network "$VNET_ID" \
      --registration-enabled false \
      --output none
  fi
}

safe_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-64
}

ensure_private_endpoint() {
  local endpoint_name="$1"
  local target_id="$2"
  local group_id="$3"
  local dns_zone="$4"
  local existing_dns_zone_group_id
  local dns_zone_id

  endpoint_name=$(safe_name "$endpoint_name")
  dns_zone_id=$(az network private-dns zone show \
    --resource-group "$RG_NAME" \
    --name "$dns_zone" \
    --query id \
    -o tsv)

  if ! az network private-endpoint show \
    --resource-group "$RG_NAME" \
    --name "$endpoint_name" \
    --output none 2>/dev/null; then
    az network private-endpoint create \
      --resource-group "$RG_NAME" \
      --name "$endpoint_name" \
      --location "$LOCATION" \
      --vnet-name "$VNET_NAME" \
      --subnet "$PRIVATE_ENDPOINT_SUBNET_NAME" \
      --private-connection-resource-id "$target_id" \
      --group-ids "$group_id" \
      --connection-name "${endpoint_name}-conn" \
      --output none
  fi

  existing_dns_zone_group_id=$(az network private-endpoint dns-zone-group show \
    --resource-group "$RG_NAME" \
    --endpoint-name "$endpoint_name" \
    --name default \
    --query id \
    -o tsv 2>/dev/null || true)

  if [[ -z "$existing_dns_zone_group_id" ]]; then
    az network private-endpoint dns-zone-group create \
      --resource-group "$RG_NAME" \
      --endpoint-name "$endpoint_name" \
      --name default \
      --private-dns-zone "$dns_zone_id" \
      --zone-name "$dns_zone" \
      --output none
  fi
}

DATABASE_ID=$(resolve_github_database_id)
if [[ -z "$DATABASE_ID" || "$DATABASE_ID" == "null" ]]; then
  echo "Could not resolve GitHub databaseId for $GITHUB_SCOPE '$GITHUB_OWNER'."
  exit 1
fi

echo "=== Azure private networking for GitHub-hosted runners ==="
echo "Subscription:  $SUBSCRIPTION"
echo "Location:      $LOCATION"
echo "Resource group: $RG_NAME"
echo "GitHub scope:  $GITHUB_SCOPE/$GITHUB_OWNER (databaseId: $DATABASE_ID)"
echo ""

echo "Registering GitHub.Network provider..."
az provider register --namespace GitHub.Network --output none
wait_for_provider_registration

echo "Creating CI network resource group and VNet..."
az group create --name "$RG_NAME" --location "$LOCATION" --output none

if ! az network vnet show --resource-group "$RG_NAME" --name "$VNET_NAME" --output none 2>/dev/null; then
  az network vnet create \
    --resource-group "$RG_NAME" \
    --name "$VNET_NAME" \
    --location "$LOCATION" \
    --address-prefixes "$ADDRESS_PREFIX" \
    --subnet-name "$RUNNER_SUBNET_NAME" \
    --subnet-prefixes "$RUNNER_SUBNET_PREFIX" \
    --output none
fi

ensure_subnet "$RUNNER_SUBNET_NAME" "$RUNNER_SUBNET_PREFIX"
ensure_subnet "$PRIVATE_ENDPOINT_SUBNET_NAME" "$PRIVATE_ENDPOINT_SUBNET_PREFIX"

echo "Delegating runner subnet to GitHub.Network/networkSettings..."
az network vnet subnet update \
  --resource-group "$RG_NAME" \
  --vnet-name "$VNET_NAME" \
  --name "$RUNNER_SUBNET_NAME" \
  --delegations GitHub.Network/networkSettings \
  --output none

az network vnet subnet update \
  --resource-group "$RG_NAME" \
  --vnet-name "$VNET_NAME" \
  --name "$PRIVATE_ENDPOINT_SUBNET_NAME" \
  --private-endpoint-network-policies Disabled \
  --output none

VNET_ID=$(az network vnet show --resource-group "$RG_NAME" --name "$VNET_NAME" --query id -o tsv)
RUNNER_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG_NAME" \
  --vnet-name "$VNET_NAME" \
  --name "$RUNNER_SUBNET_NAME" \
  --query id \
  -o tsv)

echo "Creating GitHub.Network/networkSettings resource..."
NETWORK_SETTINGS_BODY=$(printf '{"location":"%s","properties":{"subnetId":"%s","businessId":"%s"}}' \
  "$LOCATION" \
  "$RUNNER_SUBNET_ID" \
  "$DATABASE_ID")
EXISTING_NETWORK_SETTINGS_BUSINESS_ID=$(az resource show \
  --resource-group "$RG_NAME" \
  --name "$NETWORK_SETTINGS_NAME" \
  --resource-type GitHub.Network/networkSettings \
  --api-version "$API_VERSION" \
  --query properties.businessId \
  -o tsv 2>/dev/null || true)
EXISTING_NETWORK_SETTINGS_SUBNET_ID=$(az resource show \
  --resource-group "$RG_NAME" \
  --name "$NETWORK_SETTINGS_NAME" \
  --resource-type GitHub.Network/networkSettings \
  --api-version "$API_VERSION" \
  --query properties.subnetId \
  -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_NETWORK_SETTINGS_BUSINESS_ID" && \
  ( "$EXISTING_NETWORK_SETTINGS_BUSINESS_ID" != "$DATABASE_ID" || "$EXISTING_NETWORK_SETTINGS_SUBNET_ID" != "$RUNNER_SUBNET_ID" ) ]]; then
  echo "Existing network settings resource points to a different GitHub owner or subnet; recreating it..."
  echo "  current businessId: ${EXISTING_NETWORK_SETTINGS_BUSINESS_ID:-<none>}"
  echo "  desired businessId: $DATABASE_ID"
  echo "  current subnetId:   ${EXISTING_NETWORK_SETTINGS_SUBNET_ID:-<none>}"
  echo "  desired subnetId:   $RUNNER_SUBNET_ID"
  az resource delete \
    --resource-group "$RG_NAME" \
    --name "$NETWORK_SETTINGS_NAME" \
    --resource-type GitHub.Network/networkSettings \
    --api-version "$API_VERSION"
fi

if ! az resource show \
  --resource-group "$RG_NAME" \
  --name "$NETWORK_SETTINGS_NAME" \
  --resource-type GitHub.Network/networkSettings \
  --api-version "$API_VERSION" \
  --output none 2>/dev/null; then
  az resource create \
    --resource-group "$RG_NAME" \
    --name "$NETWORK_SETTINGS_NAME" \
    --resource-type GitHub.Network/networkSettings \
    --properties "$NETWORK_SETTINGS_BODY" \
    --is-full-object \
    --api-version "$API_VERSION" \
    --output none
fi

GITHUB_NETWORK_ID=$(az resource show \
  --resource-group "$RG_NAME" \
  --name "$NETWORK_SETTINGS_NAME" \
  --resource-type GitHub.Network/networkSettings \
  --api-version "$API_VERSION" \
  --query tags.GitHubId \
  -o tsv)

echo "Creating private DNS zones..."
ensure_private_dns_zone "privatelink.blob.core.windows.net"
ensure_private_dns_zone "privatelink.vaultcore.azure.net"

echo "Creating tfstate private endpoint..."
TFSTATE_ID=$(az storage account show \
  --resource-group "$TFSTATE_RG" \
  --name "$TFSTATE_STORAGE_ACCOUNT" \
  --query id \
  -o tsv)
ensure_private_endpoint "pe-${TFSTATE_STORAGE_ACCOUNT}-blob" "$TFSTATE_ID" "blob" "privatelink.blob.core.windows.net"

echo "Creating environment private endpoints for existing Key Vaults and Storage accounts..."
for ENV in "${ENVIRONMENTS[@]}"; do
  ENV_RG="octoeshop-${ENV}-rg"

  if ! az group show --name "$ENV_RG" --output none 2>/dev/null; then
    echo "Skipping $ENV_RG; resource group does not exist yet."
    continue
  fi

  for vault in $(az keyvault list --resource-group "$ENV_RG" --query '[].name' -o tsv); do
    VAULT_ID=$(az keyvault show --name "$vault" --query id -o tsv)
    ensure_private_endpoint "pe-${vault}-vault" "$VAULT_ID" "vault" "privatelink.vaultcore.azure.net"
  done

  for account in $(az storage account list --resource-group "$ENV_RG" --query '[].name' -o tsv); do
    ACCOUNT_ID=$(az storage account show --resource-group "$ENV_RG" --name "$account" --query id -o tsv)
    ensure_private_endpoint "pe-${account}-blob" "$ACCOUNT_ID" "blob" "privatelink.blob.core.windows.net"
  done
done

if [[ -n "$RUNNER_LABEL" ]]; then
  if [[ -z "$REPO" ]]; then
    echo "Cannot set GitHub variables without a repo. Pass --repo owner/name."
    exit 1
  fi

  gh variable set INFRA_RUNNER_LABEL --body "$RUNNER_LABEL" --repo "$REPO"
  gh variable set INFRA_RUNNER_PRIVATE_NETWORK --body "true" --repo "$REPO"
fi

echo ""
echo "=== Bootstrap complete ==="
echo "GitHub network settings resource: $NETWORK_SETTINGS_NAME"
echo "GitHub network ID: ${GITHUB_NETWORK_ID:-<not returned yet>}"
echo ""
echo "Next steps:"
echo "  1. In GitHub organization/enterprise settings, create a hosted compute network"
echo "     configuration using the GitHub network ID above."
echo "  2. Create a Linux larger runner or runner group that uses that network."
echo "  3. Set repository variables:"
echo "       INFRA_RUNNER_LABEL=<runner-label>"
echo "       INFRA_RUNNER_PRIVATE_NETWORK=true"
echo "  4. Run the Infrastructure workflow with action=plan for dev and verify the"
echo "     private data-plane preflight passes before applying."
