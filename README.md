# Snapshot

A mini photo-sharing app (Go microservices + React) built to learn the DevOps stack used at big tech companies: Terraform, Kubernetes (EKS), GitOps, CI/CD, and AWS.

The app is deliberately small. The interesting part is everything around it: how it is built, shipped, run, and torn down.

## Status

Milestone 1 (thin slice: one service end to end on AWS) is in progress.

| | Task |
|---|---|
| ✅ | 1. Tooling check and EKS availability probe |
| ✅ | 2. post-service HTTP API |
| ✅ | 3. Postgres store, container, local compose |
| ✅ | 4. Minimal React frontend |
| ✅ | 5. GitHub repo and Terraform bootstrap layer |
| ✅ | 6. Network (VPC) and Kubernetes cluster (EKS) |
| ⏭ | 7. Database (RDS), secrets, cluster add-ons |
| | 8. Load balancer, CloudFront, web bucket |
| | 9. Helm chart and Argo CD |
| | 10. CI/CD pipelines |
| | 11. One-command `make up` / `make down` |

## Repository layout

```
services/post-service/   Go microservice: create and list posts (Postgres)
frontend/                React + Vite + TypeScript page
infra/bootstrap/         Terraform, created once and kept: state bucket, ECR, GitHub OIDC role
infra/env/               Terraform, created and destroyed each session: VPC, EKS (more coming)
infra/probes/eks/        Throwaway probe that proved EKS works on this account
docs/learn/              Learning notes, one per topic
docs/superpowers/        Design spec and implementation plan
.archify/                Architecture and delivery-flow diagrams (open the .html files)
```

## Run locally

Requirements: Docker, Go 1.27, Node 24 (`nvm use` in `frontend/`).

```bash
# API + Postgres (Postgres is published on host port 5433)
docker compose up --build

# Frontend dev server (proxies /api to localhost:8080)
cd frontend && npm install && npm run dev
```

Open the URL Vite prints and create a post.

## Tests

```bash
# Go unit tests
cd services/post-service && go test ./...

# Go integration test against the compose Postgres
docker compose up -d postgres
cd services/post-service && \
  POSTS_TEST_DATABASE_URL='postgres://app:local@localhost:5433/snapshot?sslmode=disable' \
  go test ./internal/posts/ -run Postgres -v

# Frontend
cd frontend && npm test
```

## AWS

Region `ap-southeast-1`. The account is on the AWS **Free plan** with promotional credits, so:

- Only free-tier-eligible EC2 types launch. EKS nodes are `c7i-flex.large` / `m7i-flex.large` spot.
- The `env` layer costs about $0.26/hour while running. Create it at the start of a session and **destroy it at the end**:

```bash
cd infra/env
terraform init
terraform apply      # ~16 min
aws eks update-kubeconfig --name snapshot --region ap-southeast-1
# ... work ...
terraform destroy    # ~10-15 min
```

`infra/bootstrap` stays up permanently and costs pennies.

## Learning notes

- [00 · Project overview](docs/learn/00-overview.md)
- [01 · Go microservice and containers](docs/learn/01-go-microservice-and-containers.md)
- [02 · Terraform basics and state](docs/learn/02-terraform-basics-and-state.md)
- [03 · VPC and EKS](docs/learn/03-vpc-and-eks.md)

Design: [`docs/superpowers/specs/2026-10-26-devops-learning-platform-design.md`](docs/superpowers/specs/2026-10-26-devops-learning-platform-design.md) ·
Plan: [`docs/superpowers/plans/2026-10-26-milestone-1-thin-slice.md`](docs/superpowers/plans/2026-10-26-milestone-1-thin-slice.md)
