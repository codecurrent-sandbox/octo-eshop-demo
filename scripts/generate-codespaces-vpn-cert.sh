#!/usr/bin/env bash
#
# Generates the certificate material needed by the dev codespaces OpenVPN
# P2S Virtual Network Gateway:
#
#   * A self-signed root CA (CA:TRUE, keyCertSign + cRLSign)
#   * A client cert signed by that root with clientAuth EKU
#   * `azure-vpn-root-public.txt` - base64 body of the root certificate, with
#     -----BEGIN/END----- markers and line breaks stripped, suitable for the
#     `codespaces_vpn_root_certificate_public_data` Terraform variable / the
#     `vpn_client_configuration.root_certificate.public_cert_data` provider
#     argument.
#   * `azure-vpn-client.pem` - concatenated client certificate + private key,
#     consumed by scripts/build-codespaces-openvpn-config.sh.
#
# All output goes to ./codespaces-vpn-secrets/ at the repo root, which is
# git-ignored. Re-running the script regenerates everything.
#
# IMPORTANT: azure-vpn-root.key and azure-vpn-client.pem contain private keys.
# Treat them as secrets. Do not check them in or share them.

set -euo pipefail
# Make every file we create unreadable to others by default; we still chmod
# 600 explicitly below, but this closes the brief world-readable window
# between `openssl genrsa -out` and the chmod.
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/codespaces-vpn-secrets"
COMMON_NAME_ROOT="${CODESPACES_VPN_ROOT_CN:-OctoEshop Codespaces VPN Root}"
COMMON_NAME_CLIENT="${CODESPACES_VPN_CLIENT_CN:-octoeshop-codespaces-client}"
DAYS_ROOT="${CODESPACES_VPN_ROOT_DAYS:-3650}"
DAYS_CLIENT="${CODESPACES_VPN_CLIENT_DAYS:-365}"

if ! command -v openssl >/dev/null 2>&1; then
    echo "❌ openssl is required but not found on PATH." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"
cd "${OUT_DIR}"

ROOT_KEY="azure-vpn-root.key"
ROOT_CRT="azure-vpn-root.crt"
ROOT_PUBLIC_TXT="azure-vpn-root-public.txt"
CLIENT_KEY="azure-vpn-client.key"
CLIENT_CSR="azure-vpn-client.csr"
CLIENT_CRT="azure-vpn-client.crt"
CLIENT_PEM="azure-vpn-client.pem"

ROOT_EXT_FILE="$(mktemp)"
CLIENT_EXT_FILE="$(mktemp)"
trap 'rm -f "${ROOT_EXT_FILE}" "${CLIENT_EXT_FILE}"' EXIT

cat > "${ROOT_EXT_FILE}" <<'EOF'
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage         = critical, digitalSignature, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat > "${CLIENT_EXT_FILE}" <<'EOF'
[v3_client]
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

echo "🔧 Generating root CA (${COMMON_NAME_ROOT}, ${DAYS_ROOT} days)"
openssl genrsa -out "${ROOT_KEY}" 4096 2>/dev/null
chmod 600 "${ROOT_KEY}"
openssl req -x509 -new -nodes \
    -key "${ROOT_KEY}" \
    -sha256 \
    -days "${DAYS_ROOT}" \
    -out "${ROOT_CRT}" \
    -subj "/CN=${COMMON_NAME_ROOT}" \
    -extensions v3_ca \
    -config <(cat /etc/ssl/openssl.cnf "${ROOT_EXT_FILE}" 2>/dev/null || cat "${ROOT_EXT_FILE}") \
    2>/dev/null

echo "🔧 Generating client cert (${COMMON_NAME_CLIENT}, ${DAYS_CLIENT} days)"
openssl genrsa -out "${CLIENT_KEY}" 4096 2>/dev/null
chmod 600 "${CLIENT_KEY}"
openssl req -new \
    -key "${CLIENT_KEY}" \
    -out "${CLIENT_CSR}" \
    -subj "/CN=${COMMON_NAME_CLIENT}" \
    2>/dev/null

openssl x509 -req \
    -in "${CLIENT_CSR}" \
    -CA "${ROOT_CRT}" \
    -CAkey "${ROOT_KEY}" \
    -CAcreateserial \
    -out "${CLIENT_CRT}" \
    -days "${DAYS_CLIENT}" \
    -sha256 \
    -extfile "${CLIENT_EXT_FILE}" \
    -extensions v3_client \
    2>/dev/null

# Concatenate cert + key into the file build-codespaces-openvpn-config.sh
# and other tooling consumes.
cat "${CLIENT_CRT}" "${CLIENT_KEY}" > "${CLIENT_PEM}"
chmod 600 "${CLIENT_PEM}"

# `public_cert_data` for the Azure VPN Gateway is the PEM body only, with
# the BEGIN/END markers removed and all line breaks stripped.
awk 'NR>1 && !/-----END CERTIFICATE-----/' "${ROOT_CRT}" \
    | tr -d '\n\r' \
    > "${ROOT_PUBLIC_TXT}"

if [[ ! -s "${ROOT_PUBLIC_TXT}" ]]; then
    echo "❌ Failed to extract base64 body from ${ROOT_CRT}; aborting." >&2
    exit 1
fi

echo
echo "✅ Done. Generated files in ${OUT_DIR}:"
echo "   - ${ROOT_KEY}            (PRIVATE root key, do not share)"
echo "   - ${ROOT_CRT}            (root certificate)"
echo "   - ${ROOT_PUBLIC_TXT}     (root cert base64 body for Terraform)"
echo "   - ${CLIENT_KEY}          (PRIVATE client key, do not share)"
echo "   - ${CLIENT_CRT}          (client certificate)"
echo "   - ${CLIENT_PEM}          (client cert + key, used by build script)"
echo
echo "Next:"
echo "   1. Set the Terraform variable:"
echo "      export TF_VAR_codespaces_vpn_root_certificate_public_data=\"\$(cat ${OUT_DIR}/${ROOT_PUBLIC_TXT})\""
echo "      export TF_VAR_enable_dev_codespaces_openvpn=true"
echo "   2. cd infrastructure/terraform/environments/dev && terraform apply"
echo "      (gateway provisioning takes 30-45 minutes)"
echo "   3. After apply succeeds, run scripts/build-codespaces-openvpn-config.sh"
