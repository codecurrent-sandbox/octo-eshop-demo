#!/usr/bin/env bash
#
# Prepopulate the password field on every `pgsql.connections` entry the
# Microsoft PostgreSQL VS Code extension (ms-ossdata.vscode-pgsql) sees in
# this codespace, so it does not prompt for a password every time the user
# clicks a connection.
#
# Why a separate file is needed:
#   * Server, port, database and user are baked into devcontainer.json under
#     `customizations.vscode.settings.pgsql.connections`. Adding `password`
#     there would commit the dev DB credentials to the repo - not acceptable.
#   * The extension does support a `password` field (verified against the
#     ms-ossdata.vscode-pgsql 1.21.x configuration schema), so all we need is
#     a way to inject that field per-codespace, from a per-user secret.
#   * VS Code merges workspace settings (`.vscode/settings.json`) on top of
#     the devcontainer-injected machine settings. For array keys like
#     `pgsql.connections` it is a *replace*, not a merge - so we copy the
#     entire connections array into `.vscode/settings.json` and add the
#     `password` value on top. `.vscode/` is already git-ignored.
#
# Inputs:
#   DEV_DB_PASSWORDS_JSON (Codespaces user secret) - JSON object mapping
#       PostgreSQL database name to the admin password, e.g.
#         {"userdb":"...","productdb":"...","orderdb":"..."}
#       Database names match the `database` field of each entry in
#       `customizations.vscode.settings.pgsql.connections` inside
#       .devcontainer/devcontainer.json. Connections whose database is not
#       present in the map are written without a password (the extension
#       falls back to its existing prompt). If the secret itself is unset
#       the script logs a notice and exits 0 - the user keeps the manual
#       prompt flow.
#
# Outputs:
#   .vscode/settings.json - written with mode 0600. Holds the cloned
#       `pgsql.connections` array with `password` filled in per database.
#       Git-ignored via the existing `.vscode/` rule in .gitignore.
#
# Idempotent: safe to run on every postStart. Re-running with the same
# secret produces the same file. Re-running after the secret changes
# silently picks up the new values.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVCONTAINER_JSON="${REPO_ROOT}/.devcontainer/devcontainer.json"
SETTINGS_DIR="${REPO_ROOT}/.vscode"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

if [[ -z "${DEV_DB_PASSWORDS_JSON:-}" ]]; then
    echo "ℹ️  DEV_DB_PASSWORDS_JSON secret not set; skipping pgsql password injection."
    echo "    The PostgreSQL VS Code extension will keep prompting for the password"
    echo "    on first connect. To prepopulate it, add a Codespaces user secret"
    echo "    named DEV_DB_PASSWORDS_JSON containing JSON like"
    echo '      {"userdb":"...","productdb":"...","orderdb":"..."}'
    echo "    See docs/dev-codespaces-openvpn.md."
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 not found; cannot patch .vscode/settings.json."
    exit 1
fi

if [[ ! -r "${DEVCONTAINER_JSON}" ]]; then
    echo "❌ Cannot read ${DEVCONTAINER_JSON}; aborting pgsql password injection."
    exit 1
fi

mkdir -p "${SETTINGS_DIR}"

# Use umask 077 so the python heredoc creates the file with mode 0600 from
# the start (no transient world-readable window between write and chmod).
umask 077

# Pass file paths as positional args so the heredoc body can stay on the
# 'PY' literal heredoc form (no shell interpolation inside the script).
python3 - "${DEVCONTAINER_JSON}" "${SETTINGS_FILE}" <<'PY'
"""Materialize .vscode/settings.json with prepopulated pgsql passwords.

Reads `pgsql.connections` out of devcontainer.json (which is JSON-with-
Comments), fills in the `password` field per database name from the
DEV_DB_PASSWORDS_JSON env var, and writes the result to
.vscode/settings.json.
"""
import json
import os
import pathlib
import sys

devcontainer_path, settings_path = sys.argv[1], sys.argv[2]


def strip_jsonc(src: str) -> str:
    """Strip // line comments and /* ... */ block comments from JSON-with-
    Comments, while preserving slashes and stars inside string literals.

    A naive regex breaks when a string contains '//' (e.g. a URL); walk the
    text char-by-char so string state is tracked precisely.
    """
    out = []
    i, n = 0, len(src)
    in_string = False
    while i < n:
        ch = src[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        # Line comment.
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        # Block comment.
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


raw = pathlib.Path(devcontainer_path).read_text()
dc = json.loads(strip_jsonc(raw))

connections = (
    dc.get("customizations", {})
    .get("vscode", {})
    .get("settings", {})
    .get("pgsql.connections", [])
)
if not connections:
    print(
        "⚠️  No pgsql.connections found in devcontainer.json; nothing to do."
    )
    sys.exit(0)

try:
    pwd_map = json.loads(os.environ["DEV_DB_PASSWORDS_JSON"])
except json.JSONDecodeError as e:
    print(
        f"❌ DEV_DB_PASSWORDS_JSON is not valid JSON: {e}. "
        "Expected an object like {\"userdb\":\"...\"}."
    )
    sys.exit(1)
if not isinstance(pwd_map, dict):
    print(
        "❌ DEV_DB_PASSWORDS_JSON must be a JSON object, got "
        f"{type(pwd_map).__name__}."
    )
    sys.exit(1)

filled = 0
out_connections = []
for conn in connections:
    conn = dict(conn)  # Shallow copy so we don't mutate the loaded JSON.
    db = conn.get("database")
    if db in pwd_map:
        conn["password"] = pwd_map[db]
        # `emptyPasswordInput: true` tells the extension the user wants no
        # password at all; drop it once we provide one.
        conn.pop("emptyPasswordInput", None)
        filled += 1
    out_connections.append(conn)

out_path = pathlib.Path(settings_path)
out_path.write_text(
    json.dumps({"pgsql.connections": out_connections}, indent=2) + "\n"
)
# Defence in depth - the umask above already makes new files 0600, but
# re-running over an existing world-readable file would not narrow it.
os.chmod(out_path, 0o600)

print(
    f"✅ Wrote {out_path} with passwords filled in for {filled}/{len(connections)} pgsql connection(s)."
)
PY
