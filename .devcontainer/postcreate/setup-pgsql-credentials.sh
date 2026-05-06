#!/usr/bin/env bash
#
# Generate PostgreSQL VS Code extension profiles for the dev databases and,
# when DEV_DB_PASSWORDS_JSON is set, prepopulate their passwords.
#
# The database server FQDNs are read from Terraform outputs instead of being
# hardcoded in devcontainer.json. That keeps the Codespace configuration valid
# when the dev PostgreSQL servers are recreated with a new generated suffix.
#
# Inputs:
#   DEV_DB_PASSWORDS_JSON (optional Codespaces user secret) - JSON object
#       mapping PostgreSQL database name to its admin password, e.g.
#         {"userdb":"...","productdb":"...","orderdb":"..."}
#
# Outputs:
#   .vscode/settings.json - written with mode 0600. Contains
#       `pgsql.serverGroups` and `pgsql.connections`. Passwords are included
#       only when DEV_DB_PASSWORDS_JSON provides a value for that database.
#       The PostgreSQL extension moves saved passwords into VS Code
#       SecretStorage on activation.
#
# Idempotent: safe to run on every onCreate / postStart. Re-running after
# Terraform outputs or Codespaces secrets change refreshes the generated file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TERRAFORM_DIR="${REPO_ROOT}/infrastructure/terraform/environments/dev"
SETTINGS_DIR="${REPO_ROOT}/.vscode"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 not found; cannot generate pgsql settings."
    exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
    echo "⚠️  terraform not found; skipping pgsql profile generation."
    echo "    The PostgreSQL VS Code extension can be configured manually."
    exit 0
fi

mkdir -p "${SETTINGS_DIR}"

# Use umask 077 so new settings files are private from the start.
umask 077

python3 - "${TERRAFORM_DIR}" "${SETTINGS_FILE}" <<'PY'
"""Generate VS Code PostgreSQL extension settings from Terraform outputs."""
import json
import os
import pathlib
import subprocess
import sys

terraform_dir, settings_path = sys.argv[1], sys.argv[2]

DATABASES = [
    {
        "id": "octoeshop-dev-user-db",
        "profileName": "user-db (dev)",
        "database": "userdb",
        "fqdnOutput": "user_db_fqdn",
    },
    {
        "id": "octoeshop-dev-product-db",
        "profileName": "product-db (dev)",
        "database": "productdb",
        "fqdnOutput": "product_db_fqdn",
    },
    {
        "id": "octoeshop-dev-order-db",
        "profileName": "order-db (dev)",
        "database": "orderdb",
        "fqdnOutput": "order_db_fqdn",
    },
]


def terraform_output(name: str) -> str:
    result = subprocess.run(
        ["terraform", f"-chdir={terraform_dir}", "output", "-raw", name],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"terraform output -raw {name} failed: {detail}")
    value = result.stdout.strip()
    if not value:
        raise RuntimeError(f"terraform output -raw {name} returned an empty value")
    return value


try:
    fqdn_by_output = {db["fqdnOutput"]: terraform_output(db["fqdnOutput"]) for db in DATABASES}
except RuntimeError as exc:
    print("⚠️  Could not read Terraform database FQDN outputs; skipping pgsql profile generation.")
    print(f"    {exc}")
    print("    Run terraform init/login for the dev environment, then rerun this script if needed.")
    sys.exit(0)

raw_passwords = os.environ.get("DEV_DB_PASSWORDS_JSON", "")
if raw_passwords:
    try:
        pwd_map = json.loads(raw_passwords)
    except json.JSONDecodeError as exc:
        print(f"❌ DEV_DB_PASSWORDS_JSON is not valid JSON: {exc}.")
        sys.exit(1)
    if not isinstance(pwd_map, dict):
        print(
            "❌ DEV_DB_PASSWORDS_JSON must be a JSON object, got "
            f"{type(pwd_map).__name__}."
        )
        sys.exit(1)
else:
    pwd_map = {}
    print("ℹ️  DEV_DB_PASSWORDS_JSON not set; generating pgsql profiles without passwords.")

server_groups = [
    {
        "id": "octoeshop-dev",
        "name": "Octo E-Shop Dev (via VPN)",
        "color": "#0078D4",
        "description": (
            "Dev PostgreSQL Flexible Servers. Reachable only when the OpenVPN P2S "
            "tunnel is up. Passwords are prepopulated from the DEV_DB_PASSWORDS_JSON "
            "Codespaces user secret when set."
        ),
    }
]

filled = 0
connections = []
for db in DATABASES:
    conn = {
        "id": db["id"],
        "groupId": "octoeshop-dev",
        "profileName": db["profileName"],
        "server": fqdn_by_output[db["fqdnOutput"]],
        "port": "5432",
        "database": db["database"],
        "user": "pgadmin",
        "authenticationType": "SqlLogin",
        "sslmode": "require",
    }
    password = pwd_map.get(db["database"])
    if isinstance(password, str) and password:
        conn["password"] = password
        conn["savePassword"] = True
        filled += 1
    connections.append(conn)

out_path = pathlib.Path(settings_path)
if out_path.exists():
    try:
        settings = json.loads(out_path.read_text())
    except json.JSONDecodeError as exc:
        print(f"❌ Existing {out_path} is not valid JSON: {exc}.")
        sys.exit(1)
    if not isinstance(settings, dict):
        print(f"❌ Existing {out_path} must contain a JSON object.")
        sys.exit(1)
else:
    settings = {}

settings["pgsql.serverGroups"] = server_groups
settings["pgsql.connections"] = connections

out_path.write_text(json.dumps(settings, indent=2) + "\n")
os.chmod(out_path, 0o600)

print(
    f"✅ Wrote {out_path} with {len(connections)} Terraform-derived pgsql profile(s); "
    f"passwords filled for {filled}/{len(connections)}."
)
PY
