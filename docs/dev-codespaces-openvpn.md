# Dev Codespaces ↔ Azure Private PostgreSQL via OpenVPN P2S

> **Status:** Alternative approach implemented on `feature/dev-codespaces-openvpn`.
> See [Comparison to the hosted-compute approach](#comparison-to-the-hosted-compute-approach) below.

The dev PostgreSQL Flexible Servers are private-only
(`public_network_access_enabled = false`, attached to a delegated subnet on
the dev VNet). GitHub Codespaces cannot reach them over the public internet.

This guide covers an end-to-end **OpenVPN Point-to-Site** approach modelled
on Daniel Meixner's article
[Connecting Codespaces to Azure VNets via VPN](https://danielmeixner.github.io/Codespaces-VPN-Azure/)
and the canonical [`codespaces-contrib/codespaces-openvpn`](https://github.com/codespaces-contrib/codespaces-openvpn)
sample. It is intentionally testable end-to-end **without CI/CD** — provision
locally, paste a Codespaces secret, rebuild the codespace.

---

## Architecture

```
                    ┌───────────────────────────────┐
                    │      GitHub Codespace         │
                    │ (typescript-node:20 +         │
                    │  openvpn, NET_ADMIN cap,      │
                    │  /dev/net/tun)                │
                    │                               │
                    │  postStartCommand:            │
                    │  install-dev-tools.sh         │
                    │  └── openvpn --config         │
                    │      .ignore/openvpn.config   │
                    └──────────┬────────────────────┘
                               │ OpenVPN over TLS
                               │ (certificate auth)
                               ▼
              ┌──────────────────────────────────────┐
              │ Azure VPN Gateway (VpnGw1AZ, P2S)    │
              │   public IP: <gateway_public_ip>     │
              │   client pool: 172.16.201.0/24       │
              │   OpenVPN tunnel type, cert auth     │
              └──────────────┬───────────────────────┘
                             │ inside dev VNet
                             ▼
   ┌────────────────────────────────────────────────────────┐
   │ dev VNet 10.0.0.0/16                                  │
   │  ├─ aks-subnet      10.0.1.0/24                       │
   │  ├─ database-subnet 10.0.2.0/24  ← PostgreSQL Flex   │
   │  ├─ redis-subnet    10.0.3.0/24                       │
   │  └─ GatewaySubnet   10.0.255.0/27                     │
   │                                                        │
   │ db-nsg:                                                │
   │  100  Allow tcp/5432 from aks-subnet                  │
   │  110  Allow tcp/5432 from 172.16.201.0/24  ← new     │
   │  4096 Deny  *                                         │
   └────────────────────────────────────────────────────────┘
```

## Azure resources

All gated by `var.enable_dev_codespaces_openvpn` (default `false`).

| Resource (Terraform)                                                                | Purpose                                                                                                                                                                                                                                                   |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `azurerm_subnet.gateway` (`GatewaySubnet`, `10.0.255.0/27`)                         | Azure-mandated dedicated subnet for the gateway. Name must be exactly `GatewaySubnet`.                                                                                                                                                                    |
| `azurerm_public_ip.gateway` (Standard, Static; zonal only when SKU ends in `AZ`)    | Public endpoint for OpenVPN clients to reach. Zones are set automatically based on `gateway_sku`: regional for non-AZ SKUs, zone-redundant for `*AZ`. Since Azure deprecated non-AZ VPN Gateway SKUs in 2026, in practice this is always `["1","2","3"]`. |
| `azurerm_virtual_network_gateway.main` (`VpnGw1AZ`, `Generation1`, `RouteBased`)    | The P2S gateway. `vpn_client_configuration` enables OpenVPN tunnel type, certificate auth, address pool, and trusted root cert. Azure no longer accepts non-AZ SKUs (`NonAzSkusNotAllowedForVPNGateway`); only `VpnGw{1,2,3}AZ` are valid.                |
| `security_rule "AllowPostgreSQLFromAdditionalSources"` (inside `module.networking`) | Allow tcp/5432 from `172.16.201.0/24`. Priority `110`, between the AKS allow (100) and deny-all (4096). Managed inline alongside the existing DB NSG rules.                                                                                               |
| Outputs (`environments/dev`)                                                        | `codespaces_vpn_gateway_name`, `codespaces_vpn_gateway_public_ip`, `codespaces_vpn_client_address_pool`, `*_db_fqdn`, etc.                                                                                                                                |

The gateway is the dominant cost: **VpnGw1AZ is roughly USD 140 / month** at
the time of writing. Basic SKU does not support OpenVPN, and Azure deprecated
the non-AZ `VpnGw1/2/3` SKUs for new VPN Gateways in 2026, so `VpnGw1AZ` is
the floor. Provisioning takes **20–45 minutes** and so does destroy, so flip
`enable_dev_codespaces_openvpn` on/off deliberately.

## Files in this branch

| Path                                                                    | What it does                                                                             |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `.devcontainer/Dockerfile`                                              | Adds `openvpn`, `iproute2`, `openresolv` to the standard `typescript-node:20` image.     |
| `.devcontainer/devcontainer.json`                                       | Switches from inline `image:` to `build:`, adds `runArgs` for capabilities + TUN device. |
| `.devcontainer/postcreate/install-dev-tools.sh`                         | Reads `OPENVPNCONFIG` secret, writes `.ignore/openvpn.config`, starts OpenVPN.           |
| `.gitignore`                                                            | Adds `.ignore/` and `codespaces-vpn-secrets/` so private material never gets committed.  |
| `infrastructure/terraform/modules/codespaces_vpn/`                      | New module: GatewaySubnet, public IP, P2S OpenVPN gateway.                               |
| `infrastructure/terraform/modules/networking/outputs.tf`                | Exposes the database NSG name + VNet name needed by the new module / NSG rule.           |
| `infrastructure/terraform/environments/dev/{main,variables,outputs}.tf` | Wire up the module, variables, outputs.                                                  |
| `scripts/generate-codespaces-vpn-cert.sh`                               | Local helper: generates the root + client certs Azure expects.                           |
| `scripts/build-codespaces-openvpn-config.sh`                            | Local helper: pulls Azure's profile and splices in the client cert/key.                  |

---

## Prerequisites

- Azure subscription with rights to create a resource group, public IP, and
  Virtual Network Gateway in the dev region (`swedencentral`).
- `az` CLI signed in to the subscription (`az login`).
- `terraform >= 1.5.0` (matches the rest of the repo).
- `openssl`, `jq`, `unzip`, `curl`, `python3`. (`python3` is used by
  `scripts/build-codespaces-openvpn-config.sh` to splice the client cert/key
  into the OpenVPN profile because BSD `awk` on macOS does not accept
  multi-line `-v` variables.)
- A GitHub account that can:
  - Add a Codespaces **user** secret (`OPENVPNCONFIG`).
  - Create / rebuild a Codespace on this fork.

> **Heads-up: dev-environment data-plane drift.** Azure Policy on this
> subscription periodically resets `publicNetworkAccess` to `Disabled` on
> `octoeshopdevswkvhpxt5` (Key Vault) and `octoeshopdevar2lji` (blob storage)
> even though Terraform declares them `Enabled`. If `terraform plan` from
> your laptop fails reading KV secrets or storage containers, run
> `az keyvault update --name octoeshopdevswkvhpxt5 --public-network-access Enabled`
> and `az storage account update --name octoeshopdevar2lji --public-network-access Enabled`
> first; the apply will reconcile them as part of the run. The state-file
> storage account `octoeshoptfstate` is also locked down (`publicAccess=Disabled`);
> if you need to apply from a network without private connectivity, temporarily
> open it with `az storage account update --name octoeshoptfstate --public-network-access Enabled --default-action Deny` plus
> `az storage account network-rule add --account-name octoeshoptfstate --ip-address <your IP>`,
> and revert once the apply finishes.

## Manual local test flow (no CI/CD)

Everything below runs from your laptop / dev workstation. CI/CD is not
involved at any step.

### 1. Generate the certificates

```bash
./scripts/generate-codespaces-vpn-cert.sh
```

Produces `codespaces-vpn-secrets/`:

- `azure-vpn-root.{key,crt}` — root CA (`CA:TRUE`, `keyCertSign + cRLSign`).
- `azure-vpn-root-public.txt` — base64 body of the root cert with the
  `-----BEGIN/END-----` markers and line breaks stripped, ready to feed
  into `vpn_client_configuration.root_certificate.public_cert_data`.
- `azure-vpn-client.{key,crt,pem}` — client cert with `clientAuth` EKU,
  signed by the root.

The directory is `0700` and is git-ignored. **Treat the `.key` and `.pem`
files as secrets — they grant tunnel access.**

### 2. Apply Terraform with the gateway enabled

```bash
cd infrastructure/terraform/environments/dev

export TF_VAR_codespaces_vpn_root_certificate_public_data="$(cat ../../../codespaces-vpn-secrets/azure-vpn-root-public.txt)"
export TF_VAR_enable_dev_codespaces_openvpn=true

# Optional but strongly recommended: also stand up the Azure DNS Private
# Resolver inbound endpoint so codespaces can resolve VNet-private FQDNs
# (`*.privatelink.postgres.database.azure.com`, etc.) without the
# /etc/hosts workaround in step 6 below. Adds ~USD 108/month on top of
# the gateway. The resolver flag is rejected unless the VPN flag is also
# true (a `check` block in main.tf enforces this at plan time).
export TF_VAR_enable_dns_private_resolver=true

terraform init                # or `terraform init -reconfigure` if backend changes
terraform plan -out=tfplan    # confirm: GatewaySubnet, public IP, gateway, NSG rule,
                              # plus dns-inbound-subnet + DNS resolver + inbound endpoint
terraform apply tfplan        # 30-45 minutes (gateway dominates; resolver adds ~5 min)
```

When apply finishes you should have:

```bash
$ terraform output codespaces_vpn_gateway_name
"octoeshop-dev-codespaces-vpn-gw"

$ terraform output codespaces_vpn_gateway_public_ip
"<the gateway's public IP>"

# Only present when enable_dns_private_resolver = true:
$ terraform output dns_resolver_inbound_ip
"10.0.4.4"
```

### 3. Build the OpenVPN profile

```bash
cd "$(git rev-parse --show-toplevel)"
./scripts/build-codespaces-openvpn-config.sh > /tmp/vpnconfig.ovpn
```

The script:

1. Reads the gateway and resource group names from `terraform output`.
2. Calls `az network vnet-gateway vpn-client generate --processor-architecture Amd64`
   which returns a SAS URL.
3. Downloads the zip, extracts `OpenVPN/vpnconfig.ovpn`.
4. Replaces the `$CLIENTCERTIFICATE` and `$PRIVATEKEY` placeholders with
   the cert and key from `codespaces-vpn-secrets/azure-vpn-client.pem`.
5. Appends `disable-dco` so OpenVPN ≥ 2.6 (which the Debian 13-based
   devcontainer ships) does not negotiate Data Channel Offload —
   currently incompatible with Azure VPN Gateway per Microsoft's Linux
   OpenVPN guidance.
6. Prints the final profile to stdout.

### 4. Add the Codespaces secret

The secret name is **`OPENVPNCONFIG`** (no underscore — matching the
referenced article). Use a **user-level** secret (not repo-level) so that
the secret value is yours alone, then grant it to this repository:

Either via the GitHub web UI:

> Settings → Codespaces → Secrets → New secret  
> Name: `OPENVPNCONFIG`  
> Value: paste the contents of `/tmp/vpnconfig.ovpn`  
> Repository access: pick this repo

Or via `gh`:

```bash
gh secret set OPENVPNCONFIG \
    --user \
    --repos "$(gh repo view --json nameWithOwner -q .nameWithOwner)" \
    --body "$(cat /tmp/vpnconfig.ovpn)"
```

### 5. Rebuild the Codespace and verify

> **Important — rebuild, not restart.** Changes to `Dockerfile` or `runArgs`
> in `devcontainer.json` are not picked up by a plain restart. From the
> Codespaces command palette, choose **“Codespaces: Rebuild Container”**
> (full rebuild). For a fresh Codespace, just create a new one on the
> `feature/dev-codespaces-openvpn` branch.

After the rebuild, the `postStartCommand` calls `install-dev-tools.sh`,
which:

- Verifies `/dev/net/tun` exists in the container (preflight check).
- Writes `OPENVPNCONFIG` to `.ignore/openvpn.config` (mode `600`).
- Launches `openvpn` as a daemon, logs to `.ignore/openvpn.log`, and
  records the PID in `.ignore/openvpn.pid`.
- Polls the log for `Initialization Sequence Completed` for up to 20s.

Verify in the Codespace terminal:

```bash
# 1. Tunnel up?
sudo ip addr show tun0

# 2. Routes pointing into the dev VNet?
ip route | grep 10.0

# 3. DNS smoke test (only meaningful with enable_dns_private_resolver = true).
#    /etc/resolv.conf should now point at the resolver's inbound endpoint IP
#    (10.0.4.x), and a private FQDN should resolve to a 10.0.2.x address.
cat /etc/resolv.conf
nslookup "$(terraform -chdir=infrastructure/terraform/environments/dev output -raw user_db_fqdn)"

# 4. TCP probe — the simplest "is the route alive?" test. The PostgreSQL
#    Flexible Server's private IP is in 10.0.2.0/24. Both `nc` and
#    `pg_isready` ship in the devcontainer image.
USER_DB_FQDN="$(terraform -chdir=infrastructure/terraform/environments/dev output -raw user_db_fqdn)"
nc -vz "$USER_DB_FQDN" 5432
pg_isready -h "$USER_DB_FQDN" -p 5432
```

### 6. Connect with `psql`

How DNS resolves inside the codespace depends on whether the **Azure DNS
Private Resolver** is enabled (step 2):

- **Resolver enabled (recommended).** The build script injected
  `dhcp-option DNS <resolver-ip>` into the OpenVPN profile.
  `update-resolv-conf` rewrites `/etc/resolv.conf` for the duration of
  the tunnel, and `*.privatelink.postgres.database.azure.com` resolves
  natively via the VNet's linked private DNS zones. Skip ahead to the
  `psql` snippet below — no `/etc/hosts` editing needed.
- **Resolver disabled.** P2S clients sit outside the VNet, so Azure's
  link-local DNS (`168.63.129.16`) does not resolve
  `*.postgres.database.azure.com` for them. Use the `/etc/hosts`
  workaround in **6a** as a one-shot fallback.

> **Where each command runs.** Anything that uses `az` or `terraform`
> against Azure runs on the **operator's laptop** (operators have
> Reader/Contributor RBAC; codespaces do not, by design). Anything that
> uses `psql`, `nc`, or `nslookup` against private IPs runs **inside the
> codespace** (which has the tunnel). The split is called out per block
> below.

**Pull the FQDN you'll connect to (operator laptop _or_ codespace — both
work, since `terraform output` only reads state):**

```bash
USER_DB_FQDN="$(terraform -chdir=infrastructure/terraform/environments/dev \
    output -raw user_db_fqdn)"
```

**Connect with `psql` (codespace, resolver enabled):**

```bash
# DNS resolves through the Azure DNS Private Resolver because the OpenVPN
# profile pushed it as the codespace's only resolver. No /etc/hosts entries.
PGPASSWORD="$(az keyvault secret show \
    --vault-name "$(terraform -chdir=infrastructure/terraform/environments/dev output -raw key_vault_name)" \
    --name user-db-connection-string -o tsv --query value | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')" \
psql "host=$USER_DB_FQDN port=5432 dbname=userdb user=pgadmin sslmode=require"
```

#### 6a. `/etc/hosts` fallback (resolver disabled)

Run from the **operator laptop** to look up the private IPs (no VPN needed
for the lookup itself):

```bash
USER_DB_NAME="$(basename "$USER_DB_FQDN" .postgres.database.azure.com)"
DNS_ZONE="$(terraform -chdir=infrastructure/terraform/environments/dev \
    output -raw postgresql_private_dns_zone_name)"
RG="$(terraform -chdir=infrastructure/terraform/environments/dev \
    output -raw resource_group_name)"

USER_DB_IP="$(az network private-dns record-set a show \
    --resource-group "$RG" \
    --zone-name "$DNS_ZONE" \
    --name "$USER_DB_NAME" \
    --query 'aRecords[0].ipv4Address' -o tsv)"

echo "USER_DB_IP=$USER_DB_IP"
```

Then **inside the codespace**:

```bash
echo "$USER_DB_IP $USER_DB_FQDN" | sudo tee -a /etc/hosts
PGPASSWORD="$(az keyvault secret show \
    --vault-name "$(terraform -chdir=infrastructure/terraform/environments/dev output -raw key_vault_name)" \
    --name user-db-connection-string -o tsv --query value | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')" \
psql "host=$USER_DB_FQDN port=5432 dbname=userdb user=pgadmin sslmode=require"
```

The `/etc/hosts` line is wiped on every codespace rebuild — the resolver
flow is the durable answer.

### 6b. Connect with the official Microsoft PostgreSQL VS Code extension

The devcontainer ships
[`ms-ossdata.vscode-pgsql`](https://marketplace.visualstudio.com/items?itemName=ms-ossdata.vscode-pgsql)
("PostgreSQL for Visual Studio Code") pre-installed and pre-configured. When
the codespace comes up you'll see an elephant icon in the Activity Bar with
three connections under the **Octo E-Shop Dev (via VPN)** group:

| Profile            | Server                                                      | Database    | User      |
| ------------------ | ----------------------------------------------------------- | ----------- | --------- |
| `user-db (dev)`    | `octoeshop-dev-user-db-qyqw.postgres.database.azure.com`    | `userdb`    | `pgadmin` |
| `product-db (dev)` | `octoeshop-dev-product-db-qyqw.postgres.database.azure.com` | `productdb` | `pgadmin` |
| `order-db (dev)`   | `octoeshop-dev-order-db-qyqw.postgres.database.azure.com`   | `orderdb`   | `pgadmin` |

All three use `sslmode=require` and SQL-login auth (the dev servers don't
have Entra auth enabled). On first connect the extension prompts for the
password and remembers it in VS Code's SecretStorage for the codespace's
lifetime.

**Two prerequisites for the connect to succeed:**

1. **The OpenVPN tunnel must be up** (see [step 5](#5-rebuild-the-codespace-and-verify)) — without it the connections will time out at the TCP layer because tcp/5432 to the database subnet is only allowed from the VPN client pool.
2. **The FQDN must resolve to the private IP.** With `enable_dns_private_resolver = true` (see [step 2](#2-apply-terraform-with-the-gateway-enabled)) the Azure DNS Private Resolver handles this automatically — no per-codespace setup. With the resolver disabled, fall back to the `/etc/hosts` workaround in [step 6a](#6a-etchosts-fallback-resolver-disabled): add a line per FQDN (`10.0.2.X octoeshop-dev-{user,product,order}-db-qyqw.postgres.database.azure.com`). The `/etc/hosts` entries are wiped on rebuild.

Where to get the password: any of the three `*-db-connection-string` secrets in Key Vault `octoeshopdevswkvhpxt5`, or `terraform output` in the dev environment.

> If the FQDNs above don't match what `terraform output user_db_fqdn`
> (etc) returns, the dev servers were re-created with new random suffixes;
> update `pgsql.connections` in `.devcontainer/devcontainer.json` to match
> and rebuild the Codespace.

### 7. Tear down when done

`VpnGw1AZ` bills hourly. Tear it down as soon as you finish testing:

```bash
cd infrastructure/terraform/environments/dev
unset TF_VAR_enable_dev_codespaces_openvpn
terraform apply
```

(or set the var back to `false`). This destroys the gateway, public IP,
GatewaySubnet, and NSG rule. The rest of the dev environment is unchanged.

---

## Security model

Read this section before enabling the gateway.

- **The gateway has a public IP by design.** Authentication is
  certificate-based (Azure rejects connections without a client cert
  signed by the registered root).
- **Cert auth is not MFA.** Whoever holds `azure-vpn-client.pem` has
  network-level access to the dev VNet. Treat it like an SSH key.
- **Use a Codespaces _user_ secret, not a repository secret.** Repository
  secrets are visible to anyone who can create a Codespace on the repo;
  user secrets are only available to the user who created them, even
  when granted to a repo.
- **Per-user client certs.** For more than one developer, generate one
  client cert per user and put each user's `.pem` in their own
  `codespaces-vpn-secrets/`. The same root cert authenticates all of them
  and the gateway tracks each tunnel separately.
- **Revocation.** Compromised client certs are revoked by adding their
  thumbprint to `vpn_client_configuration.revoked_certificate` blocks.
  Compromised root means re-issuing all client certs and re-applying.
- **PostgreSQL is still TLS.** The NSG rule only opens tcp/5432 from
  `172.16.201.0/24`. Connections still require the PostgreSQL admin
  password from Key Vault.
- **`.ignore/` and `codespaces-vpn-secrets/` are git-ignored.** Do not
  weaken those rules and do not remove the `umask 077` / `chmod 600`
  guards in the scripts.
- **Logs.** `.ignore/openvpn.log` may contain endpoint / route
  information. Don't paste it into public issues unredacted.

## Comparison to the hosted-compute approach

There is a sibling branch `feature/dev-codespaces-vpn` implementing a
different solution: GitHub-managed
[hosted-compute private networking](https://docs.github.com/en/enterprise-cloud@latest/admin/configuring-settings/configuring-private-networking-for-hosted-compute-products/about-azure-private-networking-for-github-hosted-runners-in-your-enterprise)
via `GitHub.Network/networkSettings`.

| Dimension             | OpenVPN P2S (this branch)                                                                                                                                                                                                       | Hosted-compute private networking (sibling)                                                                        |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Today's status        | Works in any GitHub plan that allows `runArgs` capability flags.                                                                                                                                                                | Works for hosted Actions runners now; **Codespaces** integration is a private preview not enabled on this account. |
| Egress public IP      | A new Azure public IP attached to the VPN Gateway.                                                                                                                                                                              | None — traffic egresses to Azure across GitHub-managed peering.                                                    |
| Codespace changes     | Custom Dockerfile, `--cap-add=NET_ADMIN`, `/dev/net/tun`, openvpn client.                                                                                                                                                       | None inside the Codespace; networking happens before user code runs.                                               |
| Recurring Azure cost  | ~USD 140 / month for VpnGw1AZ (cheapest SKU that supports OpenVPN; Azure deprecated non-AZ SKUs in 2026).                                                                                                                       | Just the delegated subnet + NSG; no gateway.                                                                       |
| Provisioning time     | 30–45 min apply, 30–45 min destroy.                                                                                                                                                                                             | Minutes.                                                                                                           |
| Auth                  | Self-signed root + per-user client cert.                                                                                                                                                                                        | Managed by GitHub via the org/enterprise network configuration.                                                    |
| DNS for private FQDNs | Optional `enable_dns_private_resolver` flag stands up an Azure DNS Private Resolver inbound endpoint and pushes it to OpenVPN clients via `dhcp-option DNS`. Adds ~USD 108/month. Without it, operator side-loads `/etc/hosts`. | Same — needs Azure-side DNS strategy.                                                                              |
| Client OS support     | Anywhere with OpenVPN ≥ 2.4 (with `disable-dco` for ≥ 2.6).                                                                                                                                                                     | Only GitHub-hosted compute.                                                                                        |

Pick the OpenVPN approach when you need a tunnel **today** and are willing
to pay the gateway cost. Pick hosted-compute private networking when your
account is in the Codespaces preview and you want zero per-codespace setup.

---

## Troubleshooting

| Symptom                                                                                                | Likely cause                                                                                                                                                         | Fix                                                                                                                                                                                                                                                    |
| ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `❌ /dev/net/tun is not present in the container.`                                                     | Codespace was restarted but not rebuilt after `runArgs` change.                                                                                                      | Run **Codespaces: Rebuild Container** or open a new Codespace.                                                                                                                                                                                         |
| `TUNSETIFF: Operation not permitted`                                                                   | NET_ADMIN capability not granted.                                                                                                                                    | Confirm `runArgs` includes `--cap-add=NET_ADMIN` and rebuild. Verify with `capsh --print`.                                                                                                                                                             |
| `OpenVPN ROUTE: failed to parse/resolve`, or tunnel up but `nc` to private IP times out.               | Stale routes from a previous run.                                                                                                                                    | `sudo pkill openvpn` then re-run `bash .devcontainer/postcreate/install-dev-tools.sh`.                                                                                                                                                                 |
| `OpenVPN data channel offload not available with kernel: …`                                            | Running OpenVPN ≥ 2.6 without `disable-dco`. The `build-codespaces-openvpn-config.sh` script appends it for you, so this only appears if you hand-built the profile. | Append `disable-dco` to your `vpnconfig.ovpn` and update the secret.                                                                                                                                                                                   |
| `Initialization Sequence Completed` never logged.                                                      | Cert mismatch (client cert not signed by registered root) or the gateway is still provisioning.                                                                      | `terraform output codespaces_vpn_gateway_name` and check `az network vnet-gateway show -g <RG> -n <name> --query provisioningState`. Re-run cert + config build if needed.                                                                             |
| `psql` fails with `server certificate verification failed`.                                            | Connecting to the FQDN with `sslmode=verify-full` while bypassing public DNS via `/etc/hosts`.                                                                       | Use `sslmode=require`, or enable `enable_dns_private_resolver = true` and reach the FQDN through the VNet resolver.                                                                                                                                    |
| `psql`/`nc` fails with `Name or service not known` for a `*-db-qyqw.postgres.database.azure.com` FQDN. | `enable_dns_private_resolver = false` (or the OpenVPN profile was generated before the resolver was applied) — the codespace has no resolver for the private zone.   | Either (a) set `enable_dns_private_resolver = true`, re-run `scripts/build-codespaces-openvpn-config.sh`, update the `OPENVPNCONFIG` secret, and rebuild the codespace, or (b) use the [/etc/hosts fallback](#6a-etchosts-fallback-resolver-disabled). |

The OpenVPN log lives at `.ignore/openvpn.log`. The PID lives at
`.ignore/openvpn.pid`. Stop the tunnel with
`sudo kill $(cat .ignore/openvpn.pid)`.

## Future improvements

- **Per-user client certs in a Key Vault.** Today the operator distributes `azure-vpn-client.pem` directly. A small wrapper around `az keyvault secret set/get` would centralise rotation.
- **Wire `enable_dev_codespaces_openvpn` and `enable_dns_private_resolver` into `terraform-deploy.yml`** once the manual flow has bedded in. This branch deliberately leaves CI/CD untouched.
- **`pg_hba.conf`-equivalent IP allow-list** at the database firewall layer for defence in depth (currently only NSG-gated).
- **Split-DNS via systemd-resolved** so only `*.privatelink.postgres.database.azure.com` (and other VNet-linked private zones) routes through the resolver, while public lookups continue to use the codespace's default DNS. The current implementation replaces `/etc/resolv.conf` for the duration of the tunnel, which means **all** DNS — including unrelated public lookups — flows through the Azure resolver. That's a small DNS-leak/observability concern, not a security flaw, but split-DNS is the cleaner long-term answer.

---

## References

- Daniel Meixner, _Connecting Codespaces to Azure VNets via VPN_ — https://danielmeixner.github.io/Codespaces-VPN-Azure/
- `codespaces-contrib/codespaces-openvpn` — https://github.com/codespaces-contrib/codespaces-openvpn
- Azure VPN Gateway P2S OpenVPN docs — https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-howto-openvpn-clients
- Codespaces — Connecting to a private network — https://docs.github.com/en/codespaces/developing-in-codespaces/connecting-to-a-private-network
