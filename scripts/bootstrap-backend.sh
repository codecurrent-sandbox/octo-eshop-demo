#!/bin/bash
set -euo pipefail

###############################################################################
# Bootstrap script for Octo E-Shop infrastructure
#
# This is the ONE manual step required to go from zero to fully automated.
# It creates:
#   1. Terraform state backend (Resource Group + Storage Account + Container)
#   2. Azure app registration / service principal with OIDC federation
#   3. GitHub Actions secrets (AZURE_CLIENT_ID, AZURE_TENANT_ID,
#      AZURE_SUBSCRIPTION_ID)
#
# Prerequisites:
#   - Azure CLI (az) installed and logged in
#   - GitHub CLI (gh) installed and authenticated
#   - Owner or Contributor + User Access Administrator on the Azure subscription
#
# Usage:
#   ./scripts/bootstrap-backend.sh [--subscription <id>] [--repo <owner/repo>]
###############################################################################

LOCATION="eastus"
RG_NAME="octoeshop-tfstate-rg"
STORAGE_ACCOUNT="octoeshoptfstate"
CONTAINER_NAME="tfstate"
SP_NAME="octoeshop-github-actions"
GITHUB_OIDC_ISSUER="https://token.actions.githubusercontent.com"
GITHUB_OIDC_AUDIENCE="api://AzureADTokenExchange"
ENVIRONMENTS=(dev staging production)

SUBSCRIPTION=""
REPO=""

usage() {
  echo "Usage: $0 [--subscription <id>] [--repo <owner/repo>]"
  echo ""
  echo "Options:"
  echo "  --subscription  Azure subscription ID (default: current az account)"
  echo "  --repo          GitHub repository (default: detected from git remote)"
  exit 1
}

ensure_role_assignment() {
  local assignee_object_id="$1"
  local principal_type="$2"
  local role="$3"
  local scope="$4"
  local label="$5"
  local existing

  existing=$(az role assignment list \
    --assignee "$assignee_object_id" \
    --scope "$scope" \
    --query "[?roleDefinitionName=='$role'] | length(@)" \
    -o tsv 2>/dev/null || true)

  if [[ -z "$existing" || "$existing" == "0" ]]; then
    az role assignment create \
      --assignee-object-id "$assignee_object_id" \
      --assignee-principal-type "$principal_type" \
      --role "$role" \
      --scope "$scope" \
      --output none
    echo "  ✅ RBAC: $label"
  else
    echo "  ✅ RBAC: $label (already assigned)"
  fi
}

ensure_federated_credential() {
  local name="$1"
  local subject="$2"
  local existing_subject
  local existing_name_for_subject
  local parameters

  existing_subject=$(az ad app federated-credential list \
    --id "$CLIENT_ID" \
    --query "[?name=='$name'].subject | [0]" \
    -o tsv 2>/dev/null || true)

  if [[ "$existing_subject" == "$subject" ]]; then
    echo "  ✅ OIDC: $name (already configured)"
    return
  fi

  if [[ -n "$existing_subject" && "$existing_subject" != "None" ]]; then
    az ad app federated-credential delete \
      --id "$CLIENT_ID" \
      --federated-credential-id "$name" \
      --output none
  fi

  existing_name_for_subject=$(az ad app federated-credential list \
    --id "$CLIENT_ID" \
    --query "[?subject=='$subject'].name | [0]" \
    -o tsv 2>/dev/null || true)

  if [[ -n "$existing_name_for_subject" && "$existing_name_for_subject" != "None" ]]; then
    echo "  ✅ OIDC: $name (already configured as $existing_name_for_subject)"
    return
  fi

  parameters=$(jq -nc \
    --arg name "$name" \
    --arg issuer "$GITHUB_OIDC_ISSUER" \
    --arg subject "$subject" \
    --arg audience "$GITHUB_OIDC_AUDIENCE" \
    '{name: $name, issuer: $issuer, subject: $subject, audiences: [$audience]}')

  az ad app federated-credential create \
    --id "$CLIENT_ID" \
    --parameters "$parameters" \
    --output none
  echo "  ✅ OIDC: $name"
}

create_tfstate_container() {
  local err_file
  err_file=$(mktemp)

  for attempt in {1..12}; do
    if az storage container create \
      --name "$CONTAINER_NAME" \
      --account-name "$STORAGE_ACCOUNT" \
      --auth-mode login \
      --output none 2>"$err_file"; then
      rm -f "$err_file"
      echo "  ✅ Container: $CONTAINER_NAME"
      return
    fi

    if [[ "$attempt" == "12" ]]; then
      echo "❌ Could not create or access container '$CONTAINER_NAME' with Azure AD auth."
      cat "$err_file"
      rm -f "$err_file"
      exit 1
    fi

    sleep 5
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --help|-h) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# --- Preflight checks -------------------------------------------------------

echo "=== Preflight Checks ==="

command -v az  >/dev/null 2>&1 || { echo "❌ Azure CLI (az) not found. Install: https://aka.ms/install-azure-cli"; exit 1; }
command -v gh  >/dev/null 2>&1 || { echo "❌ GitHub CLI (gh) not found. Install: https://cli.github.com"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "❌ jq not found. Install: https://jqlang.github.io/jq/download/"; exit 1; }

az account show >/dev/null 2>&1 || { echo "❌ Not logged into Azure. Run: az login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ Not logged into GitHub. Run: gh auth login"; exit 1; }

if [[ -z "$SUBSCRIPTION" ]]; then
  SUBSCRIPTION=$(az account show --query id -o tsv)
fi

if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
  if [[ -z "$REPO" ]]; then
    echo "❌ Could not detect GitHub repo. Pass --repo owner/name"
    exit 1
  fi
fi

TENANT_ID=$(az account show --query tenantId -o tsv)

echo "  Subscription: $SUBSCRIPTION"
echo "  Tenant:       $TENANT_ID"
echo "  GitHub Repo:  $REPO"
echo ""

# --- 1. Terraform State Backend ---------------------------------------------

echo "=== 1/3 Creating Terraform State Backend ==="

az account set --subscription "$SUBSCRIPTION"

az group create \
  --name "$RG_NAME" \
  --location "$LOCATION" \
  --output none 2>/dev/null && echo "  ✅ Resource group: $RG_NAME"

az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --public-network-access Enabled \
  --default-action Allow \
  --bypass AzureServices \
  --min-tls-version TLS1_2 \
  --output none 2>/dev/null && echo "  ✅ Storage account: $STORAGE_ACCOUNT"

az storage account update \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG_NAME" \
  --allow-shared-key-access false \
  --public-network-access Enabled \
  --default-action Allow \
  --bypass AzureServices \
  --output none
echo "  ✅ Storage account access: public endpoint enabled for GitHub-hosted Actions; auth restricted to Entra ID/RBAC"

STORAGE_ID=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RG_NAME" --query id -o tsv)

# Assign Storage Blob Data Contributor to current user for AAD auth
CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -n "$CURRENT_USER_OID" ]]; then
  ensure_role_assignment \
    "$CURRENT_USER_OID" \
    User \
    "Storage Blob Data Contributor" \
    "$STORAGE_ID" \
    "current user → Storage Blob Data Contributor"
fi

create_tfstate_container

# --- 2. GitHub Actions OIDC app ---------------------------------------------

echo ""
echo "=== 2/3 Configuring GitHub Actions OIDC ==="

CLIENT_ID=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]]; then
  echo "  ℹ️  App registration '$SP_NAME' already exists (clientId: $CLIENT_ID)"
else
  echo "  Creating app registration: $SP_NAME"
  CLIENT_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
  echo "  ✅ App registration created: $CLIENT_ID"
fi

SP_OID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "$SP_OID" || "$SP_OID" == "null" ]]; then
  az ad sp create --id "$CLIENT_ID" --output none
  for attempt in {1..12}; do
    SP_OID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv 2>/dev/null || true)
    if [[ -n "$SP_OID" && "$SP_OID" != "null" ]]; then
      break
    fi
    sleep 5
  done
fi

if [[ -z "$SP_OID" || "$SP_OID" == "null" ]]; then
  echo "❌ Could not resolve service principal for app registration '$SP_NAME'."
  exit 1
fi

SUBSCRIPTION_SCOPE="/subscriptions/$SUBSCRIPTION"

ensure_role_assignment \
  "$SP_OID" \
  ServicePrincipal \
  Contributor \
  "$SUBSCRIPTION_SCOPE" \
  "SP → Contributor"

ensure_role_assignment \
  "$SP_OID" \
  ServicePrincipal \
  "Key Vault Secrets Officer" \
  "$SUBSCRIPTION_SCOPE" \
  "SP → Key Vault Secrets Officer"

ensure_role_assignment \
  "$SP_OID" \
  ServicePrincipal \
  "Storage Blob Data Contributor" \
  "$SUBSCRIPTION_SCOPE" \
  "SP → Storage Blob Data Contributor"

ensure_role_assignment \
  "$SP_OID" \
  ServicePrincipal \
  "Storage Blob Data Contributor" \
  "$STORAGE_ID" \
  "SP → Storage Blob Data Contributor"

# Assign Role Based Access Control Administrator (scoped, with conditions)
# This is narrower than User Access Administrator — it can only manage role
# assignments, not role definitions, and can be further restricted with conditions.
ensure_role_assignment \
  "$SP_OID" \
  ServicePrincipal \
  "Role Based Access Control Administrator" \
  "$SUBSCRIPTION_SCOPE" \
  "SP → Role Based Access Control Administrator"

ensure_federated_credential "repo-main" "repo:${REPO}:ref:refs/heads/main"
ensure_federated_credential "repo-pull-request" "repo:${REPO}:pull_request"
for ENV in "${ENVIRONMENTS[@]}"; do
  ensure_federated_credential "repo-env-${ENV}" "repo:${REPO}:environment:${ENV}"
done

# --- 3. GitHub Secrets -------------------------------------------------------

echo ""
echo "=== 3/3 Setting GitHub Secrets ==="

printf '%s' "$CLIENT_ID" | gh secret set AZURE_CLIENT_ID --repo "$REPO"
echo "  ✅ AZURE_CLIENT_ID"

printf '%s' "$TENANT_ID" | gh secret set AZURE_TENANT_ID --repo "$REPO"
echo "  ✅ AZURE_TENANT_ID"

printf '%s' "$SUBSCRIPTION" | gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPO"
echo "  ✅ AZURE_SUBSCRIPTION_ID"

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Next steps:"
echo "  1. Run the Infrastructure workflow to create Azure resources:"
echo "     gh workflow run infrastructure.yml -f environment=dev -f action=apply --repo $REPO"
echo "  2. The workflow will automatically sync secrets and set up cluster add-ons."
echo "  3. Then trigger a build to deploy services:"
echo "     gh workflow run build-push.yml --repo $REPO"
