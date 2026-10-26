# Snapshot

A mini photo-sharing app (Go microservices + React) built to learn the DevOps stack used at big tech companies: Terraform, Kubernetes (EKS), GitOps, CI/CD, and AWS.

The app is deliberately small. The interesting part is everything around it: how it is built, shipped, run, and torn down.

## Status

Milestone 1 (thin slice: one service end to end on AWS) is complete.

| | Task |
|---|---|
| ✅ | 1. Tooling check and EKS availability probe |
| ✅ | 2. post-service HTTP API |
| ✅ | 3. Postgres store, container, local compose |
| ✅ | 4. Minimal React frontend |
| ✅ | 5. GitHub repo and Terraform bootstrap layer |
| ✅ | 6. Network (VPC) and Kubernetes cluster (EKS) |
| ✅ | 7. Database (RDS), secrets, cluster add-ons |
| ✅ | 8. Load balancer, CloudFront, web bucket |
| ✅ | 9. Helm chart and Argo CD |
| ✅ | 10. CI/CD pipelines (GitHub Actions) |
| ✅ | 11. One-command `make up` / `make down`, seed data, teardown check |

Later milestones: user, feed and notification services with gRPC between them, photo uploads to S3, SNS/SQS events, observability, Ansible. See the design doc.

## How it runs on AWS

```
Browser ──HTTPS──> CloudFront ─┬─ /*      → S3 web bucket (React build, private)
                               └─ /api/*  → ALB (CloudFront-only) → post-service pods (EKS) → RDS Postgres
                                                                    ↑ DB URL from Secrets Manager via External Secrets
git push → GitHub Actions (test, Trivy scan, image → ECR, bump tag in Git) → Argo CD syncs the cluster from Git
```

Diagrams (open in a browser): [architecture](.archify/architecture-snapshot-20261026-101243/snapshot.html) · [delivery flow](.archify/workflow-snapshot-delivery-20261026-101243/snapshot-delivery.html)

## Session routine

Prerequisites: AWS CLI logged in, Terraform ≥ 1.10, kubectl, Helm, Docker, Go 1.27, Node 24 (nvm), jq.

```bash
make bootstrap   # once: state bucket, ECR, GitHub CI role (kept)
make up          # start a session: ~25 min, prints https://dxxxx.cloudfront.net with 5 demo posts
make down        # end a session: destroy everything, then verify nothing billable is left
make verify-clean
```

The env costs about $0.30/hour while up (from credits). Always `make down` when you stop. See [note 08](docs/learn/08-session-routine.md) and [note 09](docs/learn/09-teardown.md).

## Repository layout

```
services/post-service/   Go microservice: create and list posts (Postgres)
frontend/                React + Vite + TypeScript page
infra/bootstrap/         Terraform, created once and kept: state bucket, ECR, GitHub OIDC role
infra/env/               Terraform, created and destroyed each session: VPC, EKS, RDS, add-ons, ALB, CloudFront, Argo CD
deploy/charts/service/   Shared Helm chart for every Go service
deploy/values/           Per-service values (CI bumps image.tag here; Argo CD deploys it)
deploy/platform/         Cluster-wide objects (ClusterSecretStore), synced by Argo CD
scripts/                 up.sh, seed.sh, verify-clean.sh, push-image.sh, deploy-frontend.sh
.github/workflows/       CI/CD: post-service, frontend, terraform
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
- The `env` layer costs about $0.30/hour while running: `make up` at the start of a session, **`make down` at the end**. `terraform -chdir=infra/env output cloudfront_domain` prints the app's URL (it changes every `make up`).

`infra/bootstrap` stays up permanently and costs pennies. Never commit Terraform plan or state files: they contain secrets.

## Releasing

- **Automatic:** push to `main`. GitHub Actions tests and scans the change; for post-service it pushes the image to ECR and commits the new tag to `deploy/values/post-service.yaml`, and Argo CD rolls it out. The frontend is uploaded to S3. When the env is down, the image and tag are still recorded and get deployed on the next `apply`.
- **Manual image:** `make push SERVICE=post-service` builds and pushes an image tagged with the current commit.
- AWS access from CI uses GitHub OIDC (no stored keys), limited to `main` of this repo.
- **Argo CD UI:** `kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443`, user `admin`, password from `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.

## Learning notes

- [00 · Project overview](docs/learn/00-overview.md)
- [01 · Go microservice and containers](docs/learn/01-go-microservice-and-containers.md)
- [02 · Terraform basics and state](docs/learn/02-terraform-basics-and-state.md)
- [03 · VPC and EKS](docs/learn/03-vpc-and-eks.md)
- [04 · RDS, secrets and cluster add-ons](docs/learn/04-rds-secrets-and-addons.md)
- [05 · CloudFront, ALB and the web bucket](docs/learn/05-edge-cloudfront-alb.md)
- [06 · Helm and Argo CD](docs/learn/06-helm-and-argocd.md)
- [07 · CI/CD with GitHub Actions](docs/learn/07-ci-cd-github-actions.md)
- [08 · Session routine](docs/learn/08-session-routine.md)
- [09 · Teardown](docs/learn/09-teardown.md)

Design: [`docs/superpowers/specs/2026-10-26-devops-learning-platform-design.md`](docs/superpowers/specs/2026-10-26-devops-learning-platform-design.md) ·
Plan: [`docs/superpowers/plans/2026-10-26-milestone-1-thin-slice.md`](docs/superpowers/plans/2026-10-26-milestone-1-thin-slice.md)
