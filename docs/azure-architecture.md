# Azure Architecture

> Infrastructure and deployment architecture for the Octo E-Shop platform on Microsoft Azure.

![Azure Architecture](diagrams/azure-architecture.png)

## Overview

The Octo E-Shop platform runs on **Azure Kubernetes Service (AKS)** with a full suite of managed Azure services. Infrastructure is provisioned via **Terraform** and deployed across three environments: dev, staging, and production.

## Azure Services

| Service                                        | Purpose                                                 |
| ---------------------------------------------- | ------------------------------------------------------- |
| **Azure Kubernetes Service (AKS)**             | Container orchestration for all microservices           |
| **Azure Container Registry (ACR)**             | Private Docker image registry                           |
| **Azure Database for PostgreSQL**              | Managed databases for user, product, and order services |
| **Azure Cache for Redis**                      | Session and cart data store                             |
| **Azure Service Bus**                          | Asynchronous messaging between services                 |
| **Azure Key Vault**                            | Secrets and certificate management                      |
| **Azure Storage Account**                      | Terraform state backend and static assets               |
| **Azure Log Analytics & Application Insights** | Monitoring, logging, and diagnostics                    |
| **Network Security Groups (NSG)**              | Network-level access control                            |
| **Azure Load Balancer**                        | Public ingress for the frontend                         |

## Network Architecture

Each environment is deployed into its own **Virtual Network (VNet)** with dedicated subnets:

| Subnet          | Dev           | Staging        | Production     | Purpose                                 |
| --------------- | ------------- | -------------- | -------------- | --------------------------------------- |
| AKS Subnet      | `10.0.1.0/24` | `10.10.1.0/24` | `10.20.1.0/24` | Kubernetes node pool                    |
| Database Subnet | `10.0.2.0/24` | `10.10.2.0/24` | `10.20.2.0/24` | PostgreSQL flexible servers (delegated) |
| Redis Subnet    | `10.0.3.0/24` | `10.10.3.0/24` | `10.20.3.0/24` | Azure Cache for Redis                   |

**Network Policies** (Kubernetes-level) restrict pod-to-pod communication and egress to database subnets. **NSG rules** control network-level access at the Azure layer.

## Environment Sizing

| Resource   | Dev                 | Staging             | Production                             |
| ---------- | ------------------- | ------------------- | -------------------------------------- |
| AKS Nodes  | 1 × Standard_D2s_v3 | 2 × Standard_D2s_v3 | 3 × Standard_D4s_v3                    |
| PostgreSQL | B_Standard_B1ms     | B_Standard_B1ms     | GP_Standard_D4s_v3 (Zone Redundant HA) |
| Redis      | Basic/C0            | Basic/C0            | Premium/P1                             |
| ACR        | Basic               | Standard            | Premium                                |

## Infrastructure as Code

All infrastructure is managed with **Terraform** using a modular structure:

```
infrastructure/terraform/
├── modules/
│   ├── aks/            # Kubernetes cluster
│   ├── acr/            # Container registry
│   ├── postgresql/     # Database servers
│   ├── redis/          # Cache instances
│   ├── networking/     # VNet, subnets, NSGs
│   ├── keyvault/       # Secrets management
│   ├── servicebus/     # Message bus
│   ├── storage/        # Storage accounts
│   └── monitoring/     # Log Analytics + App Insights
└── environments/
    ├── dev/
    ├── staging/
    └── production/
```

State is stored remotely in **Azure Storage** with Azure AD authentication.

### Bootstrap

The Terraform state backend and Azure service principal are created by a one-time bootstrap script:

```bash
./scripts/bootstrap-backend.sh --subscription <sub-id> --repo <owner/repo>
```

This creates the `octoeshop-tfstate-rg` resource group, storage account, and blob container, and sets the `AZURE_CREDENTIALS` secret in GitHub.

### Provisioning

```bash
# Plan changes (safe — no modifications)
gh workflow run infrastructure.yml -f environment=dev -f action=plan

# Apply after reviewing
gh workflow run infrastructure.yml -f environment=dev -f action=apply
```

## Cluster Add-Ons

After Terraform provisions the AKS cluster, the `cluster-setup.yml` workflow automatically installs:

| Component                       | Purpose                                                   |
| ------------------------------- | --------------------------------------------------------- |
| **ingress-nginx**               | Kubernetes Ingress controller for HTTP routing            |
| **External Secrets Operator**   | Syncs secrets from Azure Key Vault to Kubernetes secrets  |
| **ClusterSecretStore**          | Connects ESO to Azure Key Vault via workload identity     |
| **Managed Identity + Fed Cred** | Enables passwordless authentication from ESO to Key Vault |

## Deployment Flow

Services are deployed to AKS via **Helm charts** through the CI/CD pipeline:

1. Code merged to `main` triggers build
2. Docker images pushed to ACR
3. Helm upgrade/install to AKS namespaces
4. Kubernetes secrets injected via `kubectl`
5. Rolling update with health checks

See [CI/CD Pipeline Documentation](cicd-pipeline.md) for full details.

## Security

- **Secrets**: Stored in Azure Key Vault, automatically synced to GitHub Environment secrets after `terraform apply`, injected as Kubernetes secrets at deploy time. Production uses External Secrets Operator with workload identity for direct Key Vault → K8s sync.
- **Network**: NSG rules + Kubernetes NetworkPolicies restrict traffic. Each environment uses isolated VNet CIDRs.
- **Registry**: ACR credentials automatically synced to GitHub secrets
- **Authentication**: Azure service principal with Role Based Access Control Administrator (not User Access Administrator). AKS uses workload identity for passwordless access to Key Vault.
- **Scanning**: Trivy container vulnerability scanning in CI pipeline
- **Bootstrap**: One-time `bootstrap-backend.sh` script is the only manual step; all subsequent operations are automated via GitHub Actions
