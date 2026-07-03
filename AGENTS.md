# AGENTS.md — Octo E-Shop

Canonical, tool-agnostic guide for AI agents and human contributors working in this
repository. It is the single source of truth for project structure, commands, conventions,
code style, and the development workflow. (`/.github/copilot-instructions.md` points here.)

## Project Overview

Bicycle e-commerce platform using microservices architecture deployed on Azure AKS.

**Status:** Phase 1 complete - project structure and tooling set up.

## Technology Stack

- **Backend:** Node.js/TypeScript with Express
- **Frontend:** React with Vite and Tailwind CSS
- **Databases:** PostgreSQL (per-service) + Redis (cart)
- **ORM:** Prisma
- **Infrastructure:** Terraform on Azure (AKS, ACR, Key Vault)
- **Kubernetes:** Helm charts (one per microservice)
- **CI/CD:** GitHub Actions

## Project Structure

```
octo-eshop-demo/
├── services/               # Microservices (npm workspaces)
│   ├── frontend/           # React SPA
│   ├── user-service/       # Authentication & profiles
│   ├── product-service/    # Bicycle catalog
│   ├── cart-service/       # Shopping cart (Redis)
│   ├── order-service/      # Order lifecycle
│   └── payment-service/    # Mock payment gateway
├── shared/                 # Shared packages (npm workspaces)
│   ├── types/              # @octo-eshop/types - shared TypeScript types
│   └── utils/              # @octo-eshop/utils - shared utilities
├── .devcontainer/          # GitHub Codespaces / devcontainer config
├── infrastructure/         # Terraform configs
├── kubernetes/             # K8s manifests
├── scripts/                # Utility scripts
└── plan/                   # Implementation plans
```

## Service Structure (template for backend services)

```
services/{service-name}/
├── src/
│   ├── controllers/    # HTTP handlers
│   ├── services/       # Business logic
│   ├── repositories/   # Data access
│   ├── middleware/     # Auth, validation, logging
│   ├── routes/         # Express routes
│   └── utils/          # Helpers
├── tests/
├── prisma/             # Schema and migrations (PostgreSQL services)
├── tsconfig.json       # Extends ../../tsconfig.base.json
├── Dockerfile
└── package.json
```

## Build & Run Commands

```bash
# Install all dependencies (monorepo with npm workspaces)
npm install

# Build all services
npm run build

# Run all tests
npm test

# Run tests for a single service
npm test --workspace=services/user-service

# Run a single test file
npm test --workspace=services/user-service -- src/services/userService.test.ts

# Lint all code
npm run lint

# Start local development (all services via Docker Compose)
docker-compose up -d

# Run database migrations
docker-compose exec user-service npx prisma migrate deploy

# Seed product data
docker-compose exec product-service npx prisma db seed
```

## Codespaces / Devcontainer

The `.devcontainer/` provides a ready-to-code environment with all tools and extensions pre-installed (Node 20, Docker, GitHub CLI, kubectl, Helm, Terraform, Azure CLI). Databases are not auto-started — use `docker-compose up -d` when needed.

## Terraform Commands

```bash
cd infrastructure/terraform/environments/dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Helm Deployment

```bash
# Deploy single service
helm upgrade --install user-service ./helm/charts/user-service \
  --namespace octo-eshop-dev \
  -f ./helm/charts/user-service/values-dev.yaml

# Deploy all services with Helmfile
cd helm && helmfile -e dev sync
```

## Key Conventions

### API Response Format

All endpoints return consistent JSON:

```typescript
{
  success: boolean;
  data?: T;
  error?: { code: string; message: string; };
  meta?: { page: number; limit: number; total: number; };
}
```

### Service Communication

- Synchronous: HTTP via internal Kubernetes DNS (`http://user-service`)
- Asynchronous: Azure Service Bus for events (order.created, order.paid, etc.)

### Authentication

- JWT access tokens (15min) + refresh tokens (7 days)
- Middleware validates tokens and attaches `req.user`
- Inter-service calls use `X-Service-Auth` header

### Database Per Service

Each service owns its database - no shared schemas. Use API calls for cross-service data.

### Environment Configuration

- ConfigMaps for non-sensitive config
- External Secrets Operator syncs Azure Key Vault → K8s Secrets

## Code Style & Tooling

- **TypeScript:** Strict mode enabled via `tsconfig.base.json`
- **Linting:** ESLint with @typescript-eslint
- **Formatting:** Prettier (single quotes, trailing commas, 100 char width)
- **Git Hooks:** Husky + lint-staged runs ESLint and Prettier on commit

## Development Workflow

Follow this flow for every change (agent or human):

1. **Branch.** Create a feature branch off `main`, one per unit of work — e.g.
   `feature/phase-02-user-service`, `fix/cart-redis-ttl`. Do not commit directly to `main`.
2. **Implement.** Make the change, keeping it scoped and matching the conventions and code
   style above. Build and run the relevant tests locally.
3. **Independent code review (multi-model).** Run `/review` with **three agents in parallel —
   Claude Opus, Gemini, and Codex** — as _independent_ reviewers. Compare their feedback
   side by side: agreement across models is high-signal, divergence is worth a closer look.
   The cross-model review is deliberate — each model tends to catch a different class of
   issues.
4. **Fix.** Address the issues surfaced by the review before opening the PR.
5. **Open a PR into `main`.** Make sure CI is green. Note the pipeline **gates tests behind
   lint** — `Build & Test` has `needs: lint`, and `Lint & Format` runs `prettier --check .`,
   so a single unformatted file fails lint and skips every test job. Run
   `npx prettier --write` on the files you touched (or the whole tree) before pushing.

> The automated **demo** pipeline (changelog scout → Copilot coding agent → auto-review) is a
> separate, trigger-based system documented in [`docs/agentic-workflows.md`](docs/agentic-workflows.md).
> The steps above are the workflow for normal feature development.

## Custom Agents & Skills

Specialized helpers live under `.github/`. Prefer them over ad-hoc work when a task matches
their domain:

- **`.github/agents/`** — custom agents:
  - **BDD Specialist** (`bdd-specialist.agent.md`) — Gherkin features + Playwright automation
    with full coverage matrices.
  - **GitHub Actions Expert** (`github-actions-expert.agent.md`) — secure CI/CD workflows,
    action pinning, OIDC authentication, least-privilege permissions, supply-chain safety.
  - **Azure Terraform Infrastructure Planning** (`terraform-azure-planning.agent.md`) —
    implementation planning for Azure Terraform IaC.
- **`.github/skills/`** — reusable skills: `azure-resource-visualizer`,
  `excalidraw-diagram-generator`.

## Implementation Plans

Detailed implementation docs in `plan/`:

- `plan.md` - Main overview and architecture
- `phase-01-project-setup.md` through `phase-10-documentation-polish.md` - Step-by-step guides with code examples
