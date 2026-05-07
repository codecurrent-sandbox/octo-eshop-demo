# CI/CD Pipeline Documentation

> Complete guide to the Octo E-Shop continuous integration, delivery, and infrastructure workflows.

## Table of Contents

- [Overview](#overview)
- [Architecture Diagram](#architecture-diagram)
- [Workflow Inventory](#workflow-inventory)
- [Pipeline Flows](#pipeline-flows)
  - [CI Pipeline](#1-ci-pipeline)
  - [Build & Deploy Pipeline](#2-build--deploy-pipeline)
  - [Infrastructure Pipeline](#3-infrastructure-pipeline)
  - [Rollback Pipeline](#4-rollback-pipeline)
- [Environment Strategy](#environment-strategy)
- [Secrets Management](#secrets-management)
- [Deployment Details](#deployment-details)
- [Operational Runbook](#operational-runbook)

---

## Overview

The Octo E-Shop uses **GitHub Actions** for CI/CD with a progressive deployment model across three environments. The platform consists of 6 microservices deployed to **Azure Kubernetes Service (AKS)** via **Helm charts**, with infrastructure provisioned by **Terraform**.

```
Code Push → CI Validation → Build & Push Images → Deploy Dev → Deploy Staging → Deploy Production
                                                      ↑              ↑               ↑
                                                   automatic    approval gate    approval gate
```

---

## Architecture Diagram

```mermaid
graph TB
    subgraph "GitHub"
        DEV[Developer Push/PR]
        CI[CI Pipeline<br/>ci.yml]
        BP[Build & Push<br/>build-push.yml]
        DEPLOY[Deploy Workflow<br/>deploy.yml]
        INFRA[Infrastructure<br/>infrastructure.yml]
        TFD[Terraform Deploy<br/>terraform-deploy.yml]
        RB[Rollback<br/>rollback.yml]
    end

    subgraph "Azure Container Registry"
        ACR_DEV[Dev ACR<br/>octoeshopdev*.azurecr.io]
        ACR_STG[Staging ACR<br/>octoeshopstaging*.azurecr.io]
        ACR_PRD[Production ACR<br/>octoeshopprod*.azurecr.io]
    end

    subgraph "Azure Kubernetes Service"
        AKS_DEV[Dev AKS<br/>octo-eshop-dev]
        AKS_STG[Staging AKS<br/>octo-eshop-staging]
        AKS_PRD[Production AKS<br/>octo-eshop-production]
    end

    DEV -->|push/PR| CI
    DEV -->|push to main/develop| BP
    DEV -->|terraform changes| INFRA

    BP -->|images| ACR_DEV
    BP -->|calls| DEPLOY

    DEPLOY -->|helm install| AKS_DEV
    DEPLOY -->|helm install| AKS_STG
    DEPLOY -->|helm install| AKS_PRD

    INFRA -->|calls| TFD
    TFD -->|provisions| AKS_DEV
    TFD -->|provisions| AKS_STG
    TFD -->|provisions| AKS_PRD

    RB -->|helm rollback| AKS_DEV
    RB -->|helm rollback| AKS_STG
    RB -->|helm rollback| AKS_PRD

    style CI fill:#4CAF50,color:white
    style BP fill:#2196F3,color:white
    style DEPLOY fill:#FF9800,color:white
    style INFRA fill:#9C27B0,color:white
    style RB fill:#F44336,color:white
```

---

## Workflow Inventory

| Workflow                  | File                   | Type         | Trigger                          |
| ------------------------- | ---------------------- | ------------ | -------------------------------- |
| **CI Pipeline**           | `ci.yml`               | Standalone   | Push, PR                         |
| **Build & Push Images**   | `build-push.yml`       | Orchestrator | Push (service changes), manual   |
| **Deploy to Environment** | `deploy.yml`           | Reusable     | Called by build-push, manual     |
| **Infrastructure**        | `infrastructure.yml`   | Orchestrator | Push (terraform changes), manual |
| **Terraform Deploy**      | `terraform-deploy.yml` | Reusable     | Called by infrastructure         |
| **Cluster Setup**         | `cluster-setup.yml`    | Reusable     | Called by infrastructure (apply) |
| **Rollback**              | `rollback.yml`         | Standalone   | Manual only                      |

### Workflow Call Graph

```mermaid
graph LR
    subgraph "Orchestrators"
        BP[build-push.yml]
        INF[infrastructure.yml]
    end

    subgraph "Reusable Workflows"
        DEP[deploy.yml]
        TFD[terraform-deploy.yml]
        CSU[cluster-setup.yml]
    end

    BP -->|workflow_call| DEP
    INF -->|workflow_call| TFD
    INF -->|workflow_call<br/>after apply| CSU

    BP -.->|workflow_dispatch| BP
    INF -.->|workflow_dispatch| INF
    DEP -.->|workflow_dispatch| DEP

    style DEP fill:#FF9800,color:white
    style TFD fill:#9C27B0,color:white
    style CSU fill:#00BCD4,color:white
```

---

## Pipeline Flows

### 1. CI Pipeline

**File:** `.github/workflows/ci.yml`
**Purpose:** Validates code quality, runs tests, and checks infrastructure definitions.

```mermaid
graph TD
    A[Push to main/develop/feature/**<br/>or PR to main/develop] --> B[Lint & Format Check]
    B --> C[Build TypeScript]
    C --> D[Run Unit Tests]
    D --> E{Is PR?}
    E -->|Yes| F[Docker Build Test]
    E -->|No| G[Skip Docker Build]
    F --> H[Terraform Validate]
    G --> H
    H --> I[Helm Lint]
    I --> J[Security Scan]

    style A fill:#E3F2FD
    style J fill:#C8E6C9
```

**Triggers:**

- `push` to `main`, `develop`, `feature/**` branches
- `pull_request` to `main`, `develop`

**What it validates:**

- ESLint + Prettier formatting
- TypeScript compilation (all services)
- Unit tests with PostgreSQL + Redis service containers
- Docker image builds (PR only)
- Terraform `validate` and `fmt`
- Helm chart linting
- Security scanning

---

### 2. Build & Deploy Pipeline

**File:** `.github/workflows/build-push.yml` → calls `deploy.yml`
**Purpose:** Builds Docker images for changed services and progressively deploys through environments.

```mermaid
graph TD
    A[Push to main/develop<br/>services/** or shared/** changed] --> B[Detect Changes]
    B --> C{Any service<br/>changed?}
    C -->|No| END[Skip]
    C -->|Yes| D[Build Matrix]

    D --> E1[Build user-service]
    D --> E2[Build product-service]
    D --> E3[Build cart-service]
    D --> E4[Build order-service]
    D --> E5[Build payment-service]
    D --> E6[Build frontend]

    E1 & E2 & E3 & E4 & E5 & E6 --> F[Push to ACR]
    F --> G[Trivy Vulnerability Scan]
    G --> H[Upload SARIF Results]

    H --> I[🟢 Deploy to Dev<br/>automatic]
    I --> J{Branch = main?}
    J -->|No| END2[Stop]
    J -->|Yes| K[🟡 Deploy to Staging<br/>requires approval]
    K --> L[🔴 Deploy to Production<br/>requires approval]

    style I fill:#4CAF50,color:white
    style K fill:#FF9800,color:white
    style L fill:#F44336,color:white
    style END fill:#9E9E9E,color:white
    style END2 fill:#9E9E9E,color:white
```

**Triggers:**

- `push` to `main` or `develop` with changes in `services/**`, `shared/**`, or the workflow itself
- `workflow_dispatch` with option to build all services

**Smart Change Detection:**
The pipeline uses [dorny/paths-filter](https://github.com/dorny/paths-filter) to detect which services changed. Only modified services are rebuilt. If `shared/**` changes, **all services** are rebuilt.

**Image Tagging Strategy:**

The image tag is resolved once in a dedicated `resolve-tag` job _before_ the build matrix runs, ensuring all services use the same consistent tag.

| Branch              | Tags                                      |
| ------------------- | ----------------------------------------- |
| `main`              | `latest`, `<commit-sha-short>`            |
| `develop` / feature | `<branch>-<commit-sha-short>`, `<branch>` |

> **Note:** Deployments always use the `<commit-sha-short>` tag (not `latest`) to ensure traceability.

**Manual Dispatch:**
Can be triggered manually with `build_all: true` to force-build all 6 services regardless of changes.

#### Deploy Sub-Workflow

**File:** `.github/workflows/deploy.yml`

Each environment deployment follows the same steps:

```mermaid
graph TD
    A[Start Deploy] --> B[Azure Login]
    B --> C[Get AKS Credentials]
    C --> D[Create Namespace<br/>octo-eshop-ENV]
    D --> E[Deploy Network Policies<br/>via Helm]
    E --> F[Deploy All Services<br/>via Helm]
    F --> G[Create K8s Secrets<br/>via kubectl]
    G --> H[Restart Deployments<br/>pick up secrets]
    H --> I[Wait for Rollouts]
    I --> J[Verify: pods, services,<br/>helm releases]
    J --> K[Smoke Tests]

    style A fill:#E3F2FD
    style K fill:#C8E6C9
```

**Services deployed (in order):**

1. `network-policies` (Helm chart for K8s NetworkPolicy resources)
2. `user-service`
3. `product-service`
4. `cart-service`
5. `order-service`
6. `payment-service`
7. `frontend`

**Secret injection strategy:**
Secrets are injected via `kubectl create secret` (not Helm `--set`) to avoid shell escaping issues with connection strings containing special characters. After secrets are created, deployments are restarted to pick them up.

---

### 3. Infrastructure Pipeline

**File:** `.github/workflows/infrastructure.yml` → calls `terraform-deploy.yml`
**Purpose:** Provisions and manages Azure infrastructure via Terraform.

```mermaid
graph TD
    A{Trigger Type?}

    A -->|Push to main<br/>terraform changes| B[Progressive Deploy]
    B --> C1[Plan Dev]
    C1 --> D1[Apply Dev]
    D1 --> C2[Plan Staging]
    C2 --> D2[Apply Staging]
    D2 --> C3[Plan Production]
    C3 --> D3[Apply Production]

    A -->|Manual Dispatch| E[Select Environment<br/>& Action]
    E --> F{Action?}
    F -->|plan| G[Terraform Plan<br/>review only]
    F -->|apply| H[Terraform Apply<br/>makes changes]
    H --> I[Cluster Setup<br/>ESO + ingress-nginx]

    style B fill:#E3F2FD
    style D1 fill:#4CAF50,color:white
    style D2 fill:#FF9800,color:white
    style D3 fill:#F44336,color:white
    style G fill:#FFF9C4
    style H fill:#FFCDD2
```

**Triggers:**

- `push` to `main` with changes in `infrastructure/terraform/**` → **progressive deploy** through all 3 environments (plan + apply for each, sequentially: dev → staging → production). A failure in any environment stops the pipeline.
- `workflow_dispatch` → select environment (dev/staging/production) and action (plan/apply)

#### Terraform Deploy Sub-Workflow

**File:** `.github/workflows/terraform-deploy.yml`

```mermaid
graph TD
    A[Start] --> B[Checkout Code]
    B --> C[Azure Login<br/>via OIDC]
    C --> D[Setup Terraform ≥1.5]
    D --> E[Set ARM Environment Variables<br/>OIDC + ARM_USE_OIDC=true]
    E --> F[terraform init<br/>remote backend in Azure Storage]
    F --> G[terraform plan -out=tfplan]
    G --> H{Action = apply?}
    H -->|Yes| I[terraform apply -auto-approve tfplan]
    I --> J[Sync Secrets to GitHub<br/>Terraform outputs + Key Vault → gh secret set]
    J --> K[Cluster Setup<br/>ESO + ingress-nginx + ClusterSecretStore]
    H -->|No| L[Stop after plan]

    style I fill:#FFCDD2
    style J fill:#CE93D8
    style K fill:#80DEEA
    style L fill:#C8E6C9
```

**Authentication:**

The workflow uses **OIDC (OpenID Connect)** federated credentials — no secrets to rotate. GitHub Actions exchanges a short-lived OIDC token with Azure AD to authenticate. This is configured via:

- Azure AD app registration: `octoeshop-github-actions`
- Federated credentials for: `main` branch, pull requests, and `dev`/`staging`/`production` environments
- GitHub secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- Terraform uses `ARM_USE_OIDC=true` for both provider and backend authentication

**Post-Apply Automation:**

After `terraform apply`, two additional steps run automatically:

1. **Secrets Sync** — reads Terraform outputs and Key Vault secrets, then sets them as GitHub Actions environment secrets via `gh secret set`. Requires a `GH_TOKEN` secret (GitHub PAT with `repo` scope).

2. **Cluster Setup** (`cluster-setup.yml`) — configures AKS cluster-level dependencies:
   - Installs **ingress-nginx** controller via Helm
   - Installs **External Secrets Operator** (ESO) via Helm
   - Creates a **managed identity** with federated credentials for workload identity
   - Creates a **ClusterSecretStore** CRD pointing to Azure Key Vault

**Terraform State Backend:**
Each environment stores state in the shared Azure Storage Account:

- Container: `tfstate`
- Keys: `dev.terraform.tfstate`, `staging.terraform.tfstate`, `production.terraform.tfstate`
- Authentication: OIDC via Azure AD (no shared keys)
- Network: The Terraform backend, environment Key Vaults, and environment
  storage accounts are kept with public network access disabled after each run.
  Because the current workflow uses GitHub-hosted runners, `terraform-deploy.yml`
  temporarily enables public network access for the targeted environment before
  `terraform init/plan/apply`, then restores public access to disabled and
  firewall defaults to deny in an `always()` cleanup step.
  Access is still restricted by Entra ID/RBAC, shared keys are disabled, and
  anonymous blob access is disabled. If these resources move behind private
  endpoints, the Terraform workflow must also move to a private/self-hosted
  runner with network access to those endpoints.

**Optional dev Codespaces private access:**

The dev Terraform environment can provision a Point-to-Site OpenVPN gateway and
Azure DNS Private Resolver for Codespaces access to private PostgreSQL. These
resources are off by default, but the workflow reads repository settings so an
intentional enablement is preserved across later pipeline runs instead of being
reversed by the next apply:

- `ENABLE_DEV_CODESPACES_OPENVPN` repository variable
- `ENABLE_DNS_PRIVATE_RESOLVER` repository variable
- `CODESPACES_VPN_ROOT_CERTIFICATE_PUBLIC_DATA` repository secret

Do not enable the VPN only with local `TF_VAR_*` exports unless the matching
GitHub settings are updated before the next infrastructure run.

**Terraform Provider:**

- `hashicorp/azurerm` version `~> 4.0` (migrated from v3 in April 2026 for AKS preview API retirement)
- `resource_provider_registrations = "none"` (RPs managed externally)
- AKS uses `monitor_metrics {}` + `azurerm_monitor_diagnostic_setting` for observability

**Resources provisioned per environment:**

| Resource                         | Module                   |
| -------------------------------- | ------------------------ |
| Resource Group                   | `azurerm_resource_group` |
| Virtual Network + Subnets + NSGs | `modules/networking`     |
| AKS Cluster                      | `modules/aks`            |
| AKS Diagnostics                  | `modules/aks`            |
| Container Registry               | `modules/acr`            |
| PostgreSQL Flexible Server (×3)  | `modules/postgresql`     |
| Redis Cache                      | `modules/redis`          |
| Service Bus Namespace            | `modules/servicebus`     |
| Key Vault + Secrets              | `modules/keyvault`       |
| Storage Account                  | `modules/storage`        |
| Log Analytics + App Insights     | `modules/monitoring`     |

---

### 4. Rollback Pipeline

**File:** `.github/workflows/rollback.yml`
**Purpose:** Emergency rollback of Helm releases to a previous revision.

```mermaid
graph TD
    A[Manual Dispatch] --> B[Select Environment]
    B --> C[Select Service<br/>or 'all']
    C --> D{Revision<br/>specified?}
    D -->|Yes| E[Rollback to<br/>specific revision]
    D -->|No| F[Rollback to<br/>previous revision]
    E --> G[Verify Pods & Releases]
    F --> G

    style A fill:#FFCDD2
    style G fill:#C8E6C9
```

**Inputs:**

- `environment`: dev / staging / production
- `service`: specific service name or `all` (rolls back all 6)
- `revision`: optional Helm revision number (defaults to previous)

---

## Environment Strategy

```mermaid
graph LR
    DEV[🟢 Dev<br/>Auto-deploy] -->|approval gate| STG[🟡 Staging<br/>Manual approval]
    STG -->|approval gate| PRD[🔴 Production<br/>Manual approval]

    style DEV fill:#4CAF50,color:white
    style STG fill:#FF9800,color:white
    style PRD fill:#F44336,color:white
```

| Property               | Dev                      | Staging                  | Production                          |
| ---------------------- | ------------------------ | ------------------------ | ----------------------------------- |
| **Namespace**          | `octo-eshop-dev`         | `octo-eshop-staging`     | `octo-eshop-production`             |
| **Approval**           | None                     | Required (reviewer)      | Required (reviewer) + branch policy |
| **Branch restriction** | Any                      | `main` only              | `main` only                         |
| **Auto-deploy**        | ✅ Yes                   | ❌ No                    | ❌ No                               |
| **AKS nodes**          | 1 × Standard_D2s_v3      | 2 × Standard_D2s_v3      | 3 × Standard_D4s_v3                 |
| **PostgreSQL SKU**     | B_Standard_B1ms          | B_Standard_B1ms          | GP_Standard_D4s_v3                  |
| **Redis**              | Basic/C0                 | Basic/C0                 | Premium/P1                          |
| **ACR SKU**            | Basic                    | Standard                 | Premium                             |
| **Frontend access**    | LoadBalancer (public IP) | LoadBalancer (public IP) | LoadBalancer (public IP)            |

---

## Secrets Management

### Repository-Level Secrets

| Secret                                        | Description                                                              | Used By       |
| --------------------------------------------- | ------------------------------------------------------------------------ | ------------- |
| `AZURE_CLIENT_ID`                             | Azure AD app registration client ID (OIDC authentication)                | All workflows |
| `AZURE_TENANT_ID`                             | Azure AD tenant ID                                                       | All workflows |
| `AZURE_SUBSCRIPTION_ID`                       | Azure subscription ID                                                    | All workflows |
| `ACR_LOGIN_SERVER`                            | ACR login URL (shared across environments)                               | Build & Push  |
| `ACR_USERNAME`                                | ACR admin username                                                       | Build & Push  |
| `ACR_PASSWORD`                                | ACR admin password                                                       | Build & Push  |
| `GH_TOKEN`                                    | GitHub PAT with `repo` scope (for automated secrets sync)                | Terraform     |
| `CODESPACES_VPN_ROOT_CERTIFICATE_PUBLIC_DATA` | Public root certificate body for the optional dev Codespaces VPN gateway | Terraform     |

> **Note:** Authentication uses OIDC federated credentials (no client secrets). The Azure AD app registration `octoeshop-github-actions` has federated credentials configured for the `main` branch, pull requests, and all three GitHub environments (dev, staging, production).

### Repository-Level Variables

| Variable                        | Description                                             | Used By   |
| ------------------------------- | ------------------------------------------------------- | --------- |
| `ENABLE_DEV_CODESPACES_OPENVPN` | Set to `true` to keep the optional dev OpenVPN gateway  | Terraform |
| `ENABLE_DNS_PRIVATE_RESOLVER`   | Set to `true` to keep the optional dev private resolver | Terraform |

### Environment-Scoped Secrets

Each GitHub Environment (dev, staging, production) has its own set of secrets. These are **automatically synced** from Azure Key Vault after `terraform apply`:

| Secret                         | Description                                      |
| ------------------------------ | ------------------------------------------------ |
| `AKS_RESOURCE_GROUP`           | Azure resource group for AKS                     |
| `AKS_CLUSTER_NAME`             | AKS cluster name                                 |
| `USER_DATABASE_URL`            | PostgreSQL connection string for user-service    |
| `PRODUCT_DATABASE_URL`         | PostgreSQL connection string for product-service |
| `ORDER_DATABASE_URL`           | PostgreSQL connection string for order-service   |
| `REDIS_URL`                    | Redis connection string (`rediss://...`)         |
| `SERVICEBUS_CONNECTION_STRING` | Azure Service Bus connection string              |
| `JWT_SECRET`                   | JWT signing secret                               |

### How secrets flow to services

```mermaid
graph LR
    TF[Terraform Apply] -->|stores secrets| AKV[Azure Key Vault]
    TF -->|outputs| SYNC[Secrets Sync Step]
    AKV -->|read by| SYNC
    SYNC -->|gh secret set| GHS[GitHub Environment<br/>Secrets]
    GHS -->|deploy.yml| K8S[K8s Secrets<br/>kubectl create secret]
    K8S -->|mounted as env vars| POD[Service Pods]

    AKV -.->|ExternalSecret CRD| ESO[External Secrets<br/>Operator]
    ESO -.->|creates| K8S

    style TF fill:#9C27B0,color:white
    style AKV fill:#7B1FA2,color:white
    style SYNC fill:#CE93D8,color:white
    style GHS fill:#1565C0,color:white
    style K8S fill:#2E7D32,color:white
    style ESO fill:#00BCD4,color:white
```

> **Note:** Production uses External Secrets Operator (ESO) with Azure Workload Identity to sync secrets directly from Key Vault to Kubernetes, bypassing GitHub secrets for sensitive values.

---

## Deployment Details

### Helm Charts

Each microservice has its own Helm chart with per-environment value overrides:

```
helm/charts/
├── cart-service/
│   ├── values.yaml              # Base defaults
│   ├── values-dev.yaml          # Dev overrides
│   ├── values-staging.yaml      # Staging overrides
│   └── values-production.yaml   # Production overrides
├── frontend/
├── network-policies/
├── order-service/
├── payment-service/
├── product-service/
└── user-service/
```

The deploy workflow applies values in this order:

```bash
helm upgrade --install <service> ./helm/charts/<service> \
  --namespace octo-eshop-<env> \
  -f values.yaml \
  -f values-<env>.yaml \
  --set image.tag=<tag> \
  --set image.repository=<acr>/<service>
```

### Network Policies

The `network-policies` chart is deployed **first** in every environment. It defines Kubernetes NetworkPolicy resources that restrict pod-to-pod communication and egress to database subnets.

---

## Operational Runbook

### Bootstrap from scratch

To recreate the entire platform from zero:

```bash
# 1. One-time bootstrap: Terraform backend + GitHub Actions OIDC secrets
./scripts/bootstrap-backend.sh --subscription <sub-id> --repo <owner/repo>

# 2. Provision infrastructure (creates AKS, databases, Key Vault, etc.)
#    This also syncs secrets to GitHub and installs cluster add-ons
gh workflow run infrastructure.yml -f environment=dev -f action=apply

# 3. Build and deploy all services
gh workflow run build-push.yml -f build_all=true
```

### Deploy a single service manually

```bash
# Trigger build-push for all services
gh workflow run build-push.yml -f build_all=true

# Or deploy to a specific environment directly
gh workflow run deploy.yml -f environment=dev -f image_tag=latest
```

### Provision infrastructure

```bash
# Plan first (safe - no changes applied)
gh workflow run infrastructure.yml -f environment=staging -f action=plan

# Apply after reviewing plan output
gh workflow run infrastructure.yml -f environment=staging -f action=apply
```

### Emergency rollback

```bash
# Rollback all services in staging to previous revision
gh workflow run rollback.yml -f environment=staging -f service=all

# Rollback specific service to specific revision
gh workflow run rollback.yml -f environment=production -f service=user-service -f revision=3
```

### Check deployment status

```bash
# List recent workflow runs
gh run list --limit 10

# Watch a specific run
gh run watch <run-id>

# View logs for failed jobs
gh run view <run-id> --log-failed
```

### End-to-End Flow: Feature to Production

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant GH as GitHub
    participant CI as CI Pipeline
    participant Build as Build & Push
    participant DevEnv as Dev Environment
    participant Stg as Staging
    participant Prod as Production

    Dev->>GH: Create feature branch
    Dev->>GH: Push code changes
    GH->>CI: Trigger CI (lint, test, build)
    CI-->>GH: ✅ All checks pass

    Dev->>GH: Open PR to main
    GH->>CI: Trigger CI (+ Docker build test)
    CI-->>GH: ✅ PR checks pass

    Dev->>GH: Merge PR to main
    GH->>Build: Trigger Build & Push
    Build->>Build: Detect changed services
    Build->>Build: Build & push images to ACR
    Build->>Build: Trivy security scan

    Build->>DevEnv: Deploy to Dev (automatic)
    DevEnv-->>Build: ✅ Healthy

    Build->>Stg: Request staging deployment
    Note over Stg: ⏸️ Waiting for approval
    Dev->>Stg: Approve deployment
    Stg-->>Build: ✅ Healthy

    Build->>Prod: Request production deployment
    Note over Prod: ⏸️ Waiting for approval
    Dev->>Prod: Approve deployment
    Prod-->>Build: ✅ Deployed to production
```
