#!/usr/bin/env bash
#
# Generate PostgreSQL VS Code extension profiles for the dev databases and,
# when DEV_DB_PASSWORDS_JSON is set, prepopulate their passwords.
#
# The database server FQDNs are resolved at runtime instead of being hardcoded
# in devcontainer.json. That keeps the Codespace configuration valid when the
# dev PostgreSQL servers are recreated with a new generated suffix.
#
# Inputs:
#   DEV_DB_FQDNS_JSON (optional Codespaces user secret) - JSON object
#       mapping PostgreSQL database names or Terraform output names to FQDNs,
#       e.g. {"userdb":"...postgres.database.azure.com"}.
#   DEV_DB_PASSWORDS_JSON (optional Codespaces user secret) - JSON object
#       mapping PostgreSQL database name to its admin password, e.g.
#         {"userdb":"...","productdb":"...","orderdb":"..."}
#
# Outputs:
#   .vscode/settings.json - written with mode 0600. Contains
#       `pgsql.serverGroups` and `pgsql.connections`. Database FQDNs are
#       resolved from DEV_DB_FQDNS_JSON, Terraform outputs, Azure resource
#       metadata, or recent successful infrastructure workflow logs. Passwords
#       are included only when DEV_DB_PASSWORDS_JSON provides a value for that
#       database. The PostgreSQL extension moves saved passwords into VS Code
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

mkdir -p "${SETTINGS_DIR}"

# Use umask 077 so new settings files are private from the start.
umask 077

python3 - "${TERRAFORM_DIR}" "${SETTINGS_FILE}" <<'PY'
"""Generate VS Code PostgreSQL extension settings for the dev databases."""
import json
import os
import pathlib
import re
import subprocess
import sys
from typing import Dict, Iterable, List, Optional, Tuple

terraform_dir, settings_path = sys.argv[1], sys.argv[2]
terraform_path = pathlib.Path(terraform_dir)
tfvars_path = terraform_path / "terraform.tfvars"

DATABASES = [
    {
        "id": "octoeshop-dev-user-db",
        "profileName": "user-db (dev)",
        "database": "userdb",
        "service": "user",
        "fqdnOutput": "user_db_fqdn",
    },
    {
        "id": "octoeshop-dev-product-db",
        "profileName": "product-db (dev)",
        "database": "productdb",
        "service": "product",
        "fqdnOutput": "product_db_fqdn",
    },
    {
        "id": "octoeshop-dev-order-db",
        "profileName": "order-db (dev)",
        "database": "orderdb",
        "service": "order",
        "fqdnOutput": "order_db_fqdn",
    },
]


def as_text(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def run_command(command: List[str], timeout: int = 60) -> Optional[subprocess.CompletedProcess]:
    try:
        return subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return None
    except subprocess.TimeoutExpired as exc:
        return subprocess.CompletedProcess(
            command,
            124,
            stdout=as_text(exc.stdout),
            stderr=as_text(exc.stderr) or "command timed out",
        )


def normalize_fqdn(value: object) -> str:
    fqdn = as_text(value).strip().rstrip(".")
    if not fqdn:
        return ""
    if "." not in fqdn and re.fullmatch(r"[a-z0-9-]+", fqdn, flags=re.IGNORECASE):
        fqdn = f"{fqdn}.postgres.database.azure.com"
    return fqdn


def read_tfvar(name: str, default: str) -> str:
    try:
        content = tfvars_path.read_text()
    except OSError:
        return default
    match = re.search(rf'^\s*{re.escape(name)}\s*=\s*"([^"]+)"', content, flags=re.MULTILINE)
    return match.group(1) if match else default


PROJECT_NAME = read_tfvar("project_name", "octoeshop")
ENVIRONMENT = read_tfvar("environment", "dev")
RESOURCE_GROUP_NAME = f"{PROJECT_NAME}-{ENVIRONMENT}-rg"
POSTGRES_FQDN_SUFFIX = ".postgres.database.azure.com"

source_notes: List[str] = []
source_errors: List[str] = []


def command_output(result: subprocess.CompletedProcess) -> str:
    return "\n".join(
        part for part in [as_text(result.stderr).strip(), as_text(result.stdout).strip()] if part
    ).strip()


def summarize_error(error: str) -> str:
    for line in error.splitlines():
        cleaned = re.sub(r"^[╷╵│\s]+", "", line).strip()
        if cleaned:
            return cleaned
    return "unknown error"


def expected_server_prefix(db: Dict[str, str]) -> str:
    return f"{PROJECT_NAME}-{ENVIRONMENT}-{db['service']}-db-".lower()


def validate_expected_fqdn(db: Dict[str, str], value: object, source_name: str) -> str:
    fqdn = normalize_fqdn(value).lower()
    if not fqdn:
        return ""

    prefix = expected_server_prefix(db)
    if not (fqdn.startswith(prefix) and fqdn.endswith(POSTGRES_FQDN_SUFFIX)):
        source_errors.append(
            f"{source_name} ignored {db['database']} host; expected "
            f"{prefix}*{POSTGRES_FQDN_SUFFIX}"
        )
        return ""
    return fqdn


def fqdn_map_from_env() -> Dict[str, str]:
    raw = os.environ.get("DEV_DB_FQDNS_JSON", "")
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"❌ DEV_DB_FQDNS_JSON is not valid JSON: {exc}.")
        sys.exit(1)
    if not isinstance(parsed, dict):
        print(
            "❌ DEV_DB_FQDNS_JSON must be a JSON object, got "
            f"{type(parsed).__name__}."
        )
        sys.exit(1)

    values: Dict[str, str] = {}
    for db in DATABASES:
        keys: Iterable[str] = (
            db["fqdnOutput"],
            db["database"],
            db["service"],
            db["id"],
            db["profileName"],
        )
        for key in keys:
            if key in parsed:
                fqdn = validate_expected_fqdn(db, parsed[key], "DEV_DB_FQDNS_JSON")
                if fqdn:
                    values[db["fqdnOutput"]] = fqdn
                    break
    return values


def terraform_output_once() -> Tuple[Dict[str, str], List[str]]:
    values: Dict[str, str] = {}
    errors: List[str] = []
    for db in DATABASES:
        name = db["fqdnOutput"]
        result = run_command(
            ["terraform", f"-chdir={terraform_dir}", "output", "-no-color", "-raw", name],
            timeout=60,
        )
        if result is None:
            errors.append("terraform is not installed")
            break
        if result.returncode == 0:
            fqdn = normalize_fqdn(result.stdout)
            if fqdn:
                validated = validate_expected_fqdn(db, fqdn, "Terraform output")
                if validated:
                    values[name] = validated
                else:
                    errors.append(f"terraform output -raw {name} returned an unexpected host")
            else:
                errors.append(f"terraform output -raw {name} returned an empty value")
        else:
            detail = command_output(result) or "unknown error"
            errors.append(f"terraform output -raw {name} failed:\n{detail}")
    return values, errors


def fqdn_map_from_terraform() -> Dict[str, str]:
    values, errors = terraform_output_once()
    if len(values) == len(DATABASES):
        return values

    needs_init = any("Backend initialization required" in err for err in errors)
    if needs_init:
        init = run_command(
            ["terraform", f"-chdir={terraform_dir}", "init", "-input=false", "-no-color"],
            timeout=120,
        )
        if init is not None and init.returncode == 0:
            values, errors = terraform_output_once()
            if len(values) == len(DATABASES):
                return values
        elif init is not None:
            detail = command_output(init) or "unknown error"
            errors.append(f"terraform init failed: {summarize_error(detail)}")
        else:
            errors.append("terraform init failed: terraform is not installed")

    if errors:
        source_errors.append("Terraform outputs unavailable; " + summarize_error(errors[0]))
    return values


def fqdn_map_from_azure_resources() -> Dict[str, str]:
    result = run_command(
        [
            "az",
            "resource",
            "list",
            "--resource-group",
            RESOURCE_GROUP_NAME,
            "--resource-type",
            "Microsoft.DBforPostgreSQL/flexibleServers",
            "--query",
            "[].{name:name,fqdn:properties.fullyQualifiedDomainName}",
            "-o",
            "json",
        ],
        timeout=60,
    )
    if result is None:
        source_errors.append("Azure resource query unavailable; az is not installed")
        return {}
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        source_errors.append(
            "Azure resource query unavailable; "
            f"{detail[-1] if detail else 'az resource list failed'}"
        )
        return {}
    try:
        resources = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        source_errors.append("Azure resource query returned invalid JSON")
        return {}

    values: Dict[str, str] = {}
    for db in DATABASES:
        prefix = f"{PROJECT_NAME}-{ENVIRONMENT}-{db['service']}-db-".lower()
        for resource in resources:
            name = normalize_fqdn(resource.get("name", "")).lower()
            if not name.startswith(prefix):
                continue
            fqdn = normalize_fqdn(resource.get("fqdn")) or normalize_fqdn(name)
            validated = validate_expected_fqdn(db, fqdn, "Azure resource metadata")
            if validated:
                values[db["fqdnOutput"]] = validated
                break
    return values


def gh_repo_args() -> List[str]:
    repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if repo:
        return ["--repo", repo]
    result = run_command(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
    if result is not None and result.returncode == 0 and result.stdout.strip():
        return ["--repo", result.stdout.strip()]
    return []


def gh_default_branch(repo_args: List[str]) -> str:
    result = run_command(
        ["gh", "repo", "view", *repo_args, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"]
    )
    if result is not None and result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    return os.environ.get("GITHUB_REF_NAME", "main").strip() or "main"


def fqdn_map_from_github_actions_logs() -> Dict[str, str]:
    repo_args = gh_repo_args()
    branch = gh_default_branch(repo_args)
    result = run_command(
        [
            "gh",
            "run",
            "list",
            *repo_args,
            "--workflow",
            "infrastructure.yml",
            "--branch",
            branch,
            "--status",
            "success",
            "--limit",
            "10",
            "--json",
            "databaseId,createdAt",
        ],
        timeout=60,
    )
    if result is None:
        source_errors.append("GitHub Actions log fallback unavailable; gh is not installed")
        return {}
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        source_errors.append(
            "GitHub Actions log fallback unavailable; "
            f"{detail[-1] if detail else 'gh run list failed'}"
        )
        return {}
    try:
        runs = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        source_errors.append("GitHub Actions log fallback returned invalid run JSON")
        return {}

    for run in runs:
        run_id = str(run.get("databaseId", "")).strip()
        if not run_id:
            continue
        log = run_command(["gh", "run", "view", run_id, *repo_args, "--log"], timeout=120)
        if log is None or log.returncode != 0:
            continue
        values: Dict[str, str] = {}
        body = log.stdout or ""
        for db in DATABASES:
            prefix = f"{PROJECT_NAME}-{ENVIRONMENT}-{db['service']}-db-"
            pattern = re.compile(
                rf"\b({re.escape(prefix)}[a-z0-9]+)(?:\.postgres\.database\.azure\.com)?\b",
                flags=re.IGNORECASE,
            )
            matches = pattern.findall(body)
            if matches:
                fqdn = validate_expected_fqdn(db, matches[-1], "GitHub Actions logs")
                if fqdn:
                    values[db["fqdnOutput"]] = fqdn
        if len(values) == len(DATABASES):
            return values
    source_errors.append("GitHub Actions log fallback found no complete dev database FQDN set")
    return {}


resolved_fqdns: Dict[str, str] = {}
for source_name, source_func in [
    ("DEV_DB_FQDNS_JSON", fqdn_map_from_env),
    ("Terraform outputs", fqdn_map_from_terraform),
    ("Azure resource metadata", fqdn_map_from_azure_resources),
    ("GitHub Actions logs", fqdn_map_from_github_actions_logs),
]:
    source_values = source_func()
    if not source_values:
        continue

    missing_from_source = [
        db["fqdnOutput"] for db in DATABASES if not source_values.get(db["fqdnOutput"])
    ]
    if missing_from_source:
        source_errors.append(
            f"{source_name} incomplete; missing {', '.join(missing_from_source)}"
        )
        continue

    resolved_fqdns = {db["fqdnOutput"]: source_values[db["fqdnOutput"]] for db in DATABASES}
    source_notes.append(source_name)
    break

missing = [db["fqdnOutput"] for db in DATABASES if db["fqdnOutput"] not in resolved_fqdns]
if missing:
    print("⚠️  Could not resolve all dev database FQDNs; skipping pgsql profile generation.")
    print(f"    Missing: {', '.join(missing)}")
    for detail in source_errors[-4:]:
        print(f"    - {detail}")
    print(
        "    Set a complete DEV_DB_FQDNS_JSON value, sign in to Azure and initialize "
        "Terraform, or ensure a successful infrastructure.yml run is available."
    )
    sys.exit(0)

fqdn_by_output = resolved_fqdns
print("ℹ️  Resolved pgsql profile hostnames from: " + ", ".join(source_notes) + ".")

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
    f"✅ Wrote {out_path} with {len(connections)} dev pgsql profile(s); "
    f"passwords filled for {filled}/{len(connections)}."
)
PY
