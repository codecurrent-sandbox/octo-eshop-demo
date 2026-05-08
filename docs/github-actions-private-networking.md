# GitHub Actions private networking

This project can run Azure-facing GitHub Actions jobs on GitHub-hosted runners
attached to an Azure VNet. This removes the need to temporarily enable public
network access on the Terraform state backend, Key Vaults, or storage accounts.

## Why this is needed

OIDC and RBAC authenticate the workflow identity, but they do not provide network
reachability. When an Azure resource has `publicNetworkAccess=Disabled`, a public
GitHub-hosted runner cannot reach its data plane even with the correct token. A
VNet-attached runner reaches the resource through private endpoints and private
DNS while still using short-lived OIDC credentials for authorization.

## Azure bootstrap

Run the bootstrap script from a workstation that has Azure and GitHub admin
permissions. If hosted compute networking is enabled at the organization level,
bind the Azure `networkSettings` resource to the organization:

```bash
scripts/bootstrap-github-actions-private-network.sh \
  --github-owner codecurrent-sandbox
```

If GitHub shows hosted compute networking only at the enterprise level, bind the
Azure `networkSettings` resource to the enterprise instead:

```bash
gh auth refresh -h github.com -s read:enterprise

scripts/bootstrap-github-actions-private-network.sh \
  --github-scope enterprise \
  --github-owner <enterprise-slug>
```

If the CLI token cannot get `read:enterprise`, an enterprise owner can look up
the enterprise database ID and pass it directly:

```bash
scripts/bootstrap-github-actions-private-network.sh \
  --github-scope enterprise \
  --github-owner <enterprise-slug> \
  --github-database-id <enterprise-database-id>
```

If you already bootstrapped with the organization ID and GitHub reports "The
private network is registered to another enterprise or organization", rerun the
enterprise command above. The script detects the existing org-bound
`networkSettings` resource, recreates it for the enterprise database ID, and
prints a new `GitHubId` for the Enterprise UI.

The script creates:

- `octoeshop-ci-network-rg`
- `octoeshop-ci-vnet`
- `github-runners-subnet`, delegated to `GitHub.Network/networkSettings`
- `private-endpoints-subnet`
- `GitHub.Network/networkSettings` for the selected GitHub organization or
  enterprise
- Private DNS zones for `privatelink.blob.core.windows.net` and
  `privatelink.vaultcore.azure.net`
- Private endpoints for the tfstate storage account and existing environment
  Key Vault/blob storage accounts

If the script cannot infer the GitHub organization or enterprise database ID,
pass it explicitly:

```bash
scripts/bootstrap-github-actions-private-network.sh \
  --github-scope org \
  --github-owner codecurrent-sandbox \
  --github-database-id <database-id>
```

The script prints the `GitHubId` from the Azure `networkSettings` resource. Use
that value when creating the hosted compute network configuration in GitHub.

## GitHub configuration

An organization or enterprise admin must complete the GitHub-side setup. Use the
Enterprise settings page when GitHub says hosted compute networking is managed at
enterprise level.

1. Go to the organization or enterprise hosted compute networking settings.
2. Create an Azure private network configuration using the `GitHubId` printed by
   the bootstrap script. If the form asks for Azure details, use:
   - Resource name: `octoeshop-github-actions-network`
   - Azure subscription ID: `d9a8811a-4d89-4ba0-bf6e-e9fee0524cae`
   - Resource group: `octoeshop-ci-network-rg`
   - Region: `swedencentral`
   - Virtual network: `octoeshop-ci-vnet`
   - Subnet: `github-runners-subnet`
3. Create a Linux larger runner or runner group that uses that network
   configuration.
4. Allow this repository to use the runner or runner group.
5. Set repository variables:

```bash
gh variable set INFRA_RUNNER_LABEL --repo codecurrent-sandbox/octo-eshop-demo --body '<runner-label>'
gh variable set INFRA_RUNNER_PRIVATE_NETWORK --repo codecurrent-sandbox/octo-eshop-demo --body 'true'
```

You can set both variables automatically when rerunning the bootstrap script if
the runner label is already known:

```bash
scripts/bootstrap-github-actions-private-network.sh \
  --github-owner codecurrent-sandbox \
  --runner-label '<runner-label>'
```

## Workflow behavior

When `INFRA_RUNNER_PRIVATE_NETWORK=true`, Azure-facing workflows run on
`INFRA_RUNNER_LABEL` and do not toggle public network access. The Terraform
workflow fails fast if the runner cannot reach:

- the `octoeshoptfstate` blob container
- environment Key Vault secret data plane
- environment blob storage data plane

When `INFRA_RUNNER_PRIVATE_NETWORK` is unset or not `true`, the workflow keeps
the previous public GitHub-hosted runner fallback. That fallback temporarily
opens public network access, waits until the tfstate data plane is reachable,
then restores public access to disabled/default deny in cleanup.

## Cutover validation

1. Run the bootstrap script.
2. Configure the GitHub hosted compute network and runner.
3. Set `INFRA_RUNNER_LABEL` and `INFRA_RUNNER_PRIVATE_NETWORK=true`.
4. Run the Infrastructure workflow for `dev` with `action=plan`.
5. If the private data-plane preflight passes, run `dev` with `action=apply`.
6. Repeat for `staging` and `production`.
7. Remove the public-runner fallback once all environments have passed on the
   private runner path.

If new Key Vaults or storage accounts are created outside the existing
environments, rerun the bootstrap script so it creates the matching private
endpoints in the CI network.
