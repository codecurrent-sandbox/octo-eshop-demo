#!/usr/bin/env bash
#
# Builds the OpenVPN profile that the Codespace will use to connect to the dev
# Azure VPN Gateway and prints it to stdout. The output is meant to be saved
# verbatim into the OPENVPNCONFIG GitHub Codespaces user secret.
#
# Flow:
#   1. terraform output -raw resource_group_name / codespaces_vpn_gateway_name
#      to find the gateway provisioned by Terraform.
#   2. `az network vnet-gateway vpn-client generate` returns a URL to a zip
#      that contains the gateway-specific OpenVPN profile template. Download
#      and extract it.
#   3. Replace the $CLIENTCERTIFICATE and $PRIVATEKEY placeholders in
#      OpenVPN/vpnconfig.ovpn with the client cert/key from
#      codespaces-vpn-secrets/azure-vpn-client.pem.
#   4. Append `disable-dco` to work around an Azure P2S incompatibility with
#      OpenVPN >= 2.6 Data Channel Offload mode (Microsoft's official Linux
#      OpenVPN guidance, current at time of writing).
#   5. If the dns_private_resolver module is enabled (terraform output
#      `dns_resolver_inbound_ip` is non-null), inject a DNS push directive
#      pointing at the resolver's inbound endpoint and wire OpenVPN's
#      update-resolv-conf hook so resolved DNS lasts only for the tunnel.
#   6. Print the final profile to stdout.
#
# Pre-requisites:
#   * `az` (Azure CLI) logged in to the dev subscription.
#   * `terraform`, `jq`, `unzip`, `curl`.
#   * scripts/generate-codespaces-vpn-cert.sh has been run.
#   * `terraform apply` of environments/dev with
#     enable_dev_codespaces_openvpn = true has completed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${REPO_ROOT}/infrastructure/terraform/environments/dev"
SECRETS_DIR="${REPO_ROOT}/codespaces-vpn-secrets"
CLIENT_PEM="${SECRETS_DIR}/azure-vpn-client.pem"

for cmd in az terraform jq unzip curl openssl python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Required command '$cmd' is not on PATH." >&2
        exit 1
    fi
done

if [[ ! -s "${CLIENT_PEM}" ]]; then
    echo "❌ ${CLIENT_PEM} is missing or empty." >&2
    echo "   Run scripts/generate-codespaces-vpn-cert.sh first." >&2
    exit 1
fi

cd "${TERRAFORM_DIR}"

# Pull the names that identify the gateway from terraform state. tf must
# already have been applied with enable_dev_codespaces_openvpn = true.
RG_NAME="$(terraform output -raw resource_group_name 2>/dev/null)"
GW_NAME="$(terraform output -raw codespaces_vpn_gateway_name 2>/dev/null || true)"
GW_PUBLIC_IP="$(terraform output -raw codespaces_vpn_gateway_public_ip 2>/dev/null || true)"

if [[ -z "${GW_NAME}" || "${GW_NAME}" == "null" ]]; then
    echo "❌ codespaces_vpn_gateway_name is null in terraform state." >&2
    echo "   Did you set enable_dev_codespaces_openvpn = true and apply?" >&2
    exit 1
fi

echo "🌐 Resource group:       ${RG_NAME}" >&2
echo "🌐 VPN gateway:          ${GW_NAME}" >&2
echo "🌐 Gateway public IP:    ${GW_PUBLIC_IP:-<unknown>}" >&2

# `az network vnet-gateway vpn-client generate` returns the URL of a zip
# that the caller must download separately. Capture it as raw text.
echo "🌐 Requesting OpenVPN profile from Azure (this may take ~1 minute)..." >&2
ZIP_URL="$(az network vnet-gateway vpn-client generate \
    --resource-group "${RG_NAME}" \
    --name "${GW_NAME}" \
    --processor-architecture Amd64 \
    -o tsv)"

if [[ -z "${ZIP_URL}" ]]; then
    echo "❌ az returned an empty URL for the vpn-client zip." >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

curl -fsSL "${ZIP_URL}" -o "${WORKDIR}/vpnclient.zip"
# unzip exits 1 for non-fatal warnings (macOS unzip surfaces a backslash-path
# warning on the Azure-generated zip even though extraction succeeds). Treat
# only exit codes >=2 as real errors.
unzip_status=0
unzip -q "${WORKDIR}/vpnclient.zip" -d "${WORKDIR}/vpnclient" || unzip_status=$?
if (( unzip_status >= 2 )); then
    echo "❌ unzip failed with exit code ${unzip_status}." >&2
    exit "${unzip_status}"
fi

OVPN_TEMPLATE="${WORKDIR}/vpnclient/OpenVPN/vpnconfig.ovpn"
if [[ ! -s "${OVPN_TEMPLATE}" ]]; then
    echo "❌ Could not find OpenVPN/vpnconfig.ovpn inside the downloaded zip." >&2
    echo "   Files extracted:" >&2
    find "${WORKDIR}/vpnclient" -maxdepth 3 -type f >&2
    exit 1
fi

# Pull the cert and key out of the combined PEM file so we can splice them
# into the .ovpn template. -outform PEM keeps Azure-friendly formatting.
CLIENT_CERT_BLOCK="$(openssl x509 -in "${CLIENT_PEM}" -outform PEM)"
CLIENT_KEY_BLOCK="$(openssl rsa -in "${CLIENT_PEM}" -outform PEM 2>/dev/null \
    || openssl pkey -in "${CLIENT_PEM}" -outform PEM)"

if [[ -z "${CLIENT_CERT_BLOCK}" || -z "${CLIENT_KEY_BLOCK}" ]]; then
    echo "❌ Failed to extract client cert/key from ${CLIENT_PEM}." >&2
    exit 1
fi

# Splice cert + key into the .ovpn template. Done in Python instead of awk/sed
# because BSD awk on macOS rejects multi-line -v variables; python3 is
# available on both macOS (xcode-select) and the Debian-based devcontainer.
CERT_FILE="${WORKDIR}/cert.pem"
KEY_FILE="${WORKDIR}/key.pem"
printf '%s' "${CLIENT_CERT_BLOCK}" >"${CERT_FILE}"
printf '%s' "${CLIENT_KEY_BLOCK}" >"${KEY_FILE}"

FINAL_OVPN="$(python3 - "${OVPN_TEMPLATE}" "${CERT_FILE}" "${KEY_FILE}" <<'PY'
import sys
template_path, cert_path, key_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(template_path) as f:
    text = f.read()
with open(cert_path) as f:
    cert = f.read()
with open(key_path) as f:
    key = f.read()
text = text.replace("$CLIENTCERTIFICATE", cert).replace("$PRIVATEKEY", key)
sys.stdout.write(text)
PY
)"

# Defensive check: if Azure ever changes placeholder names, fail loudly
# rather than silently emit a broken profile.
# shellcheck disable=SC2016
if grep -qE '\$CLIENTCERTIFICATE|\$PRIVATEKEY' <<< "${FINAL_OVPN}"; then
    echo "❌ Placeholder substitution failed. Inspect ${OVPN_TEMPLATE}." >&2
    exit 1
fi

# Append disable-dco so OpenVPN >= 2.6 (the Debian 13-shipped version) does
# not negotiate Data Channel Offload, which currently does not interoperate
# with Azure VPN Gateway.
FINAL_OVPN="${FINAL_OVPN}"$'\n'"disable-dco"$'\n'

# Optional: inject the Azure DNS Private Resolver IP (when the resolver
# module is enabled in environments/dev). Without this, codespaces fall
# back to the /etc/hosts workaround documented in
# docs/dev-codespaces-openvpn.md to resolve VNet-private FQDNs.
#
# `terraform output -raw` prints the literal string "null" when an output
# resolves to null, so treat both empty and "null" as "resolver disabled".
DNS_RESOLVER_IP="$(terraform output -raw dns_resolver_inbound_ip 2>/dev/null || true)"
if [[ -n "${DNS_RESOLVER_IP}" && "${DNS_RESOLVER_IP}" != "null" ]]; then
    echo "🌐 DNS Private Resolver IP: ${DNS_RESOLVER_IP}" >&2

    # Strip any DNS push directives Azure already shipped in the template
    # (current Azure profiles include none, but a future change must not
    # silently end up *first* in resolv.conf and shadow our resolver - the
    # libc resolver does not retry on NXDOMAIN, so a stale 168.63.129.16
    # ahead of our resolver would break private-zone resolution outright).
    FINAL_OVPN="$(printf '%s' "${FINAL_OVPN}" \
        | sed -E '/^[[:space:]]*dhcp-option[[:space:]]+DNS[[:space:]]+/d')"

    # script-security 2 is required for OpenVPN to execute the bundled
    # /etc/openvpn/update-resolv-conf hook, which uses /sbin/resolvconf
    # (provided by the openresolv package in the devcontainer image) to
    # write our resolver into /etc/resolv.conf for the duration of the
    # tunnel. The down hook reverts it. install-dev-tools.sh validates
    # both binaries exist before starting the daemon.
    FINAL_OVPN="${FINAL_OVPN}"$'\n'"# Pushed by scripts/build-codespaces-openvpn-config.sh (DNS Private Resolver enabled)."$'\n'
    FINAL_OVPN="${FINAL_OVPN}"$'\n'"dhcp-option DNS ${DNS_RESOLVER_IP}"$'\n'
    FINAL_OVPN="${FINAL_OVPN}script-security 2"$'\n'
    FINAL_OVPN="${FINAL_OVPN}up /etc/openvpn/update-resolv-conf"$'\n'
    FINAL_OVPN="${FINAL_OVPN}down /etc/openvpn/update-resolv-conf"$'\n'
else
    echo "🌐 DNS Private Resolver: not enabled (set enable_dns_private_resolver = true to use)" >&2
fi

printf '%s' "${FINAL_OVPN}"

echo >&2
echo "✅ OpenVPN profile written to stdout." >&2
echo "   Pipe to a file or copy directly into the OPENVPNCONFIG Codespaces user secret:" >&2
echo "     gh secret set OPENVPNCONFIG --user --body \"\$(scripts/build-codespaces-openvpn-config.sh)\"" >&2
echo "   …then rebuild the codespace." >&2
