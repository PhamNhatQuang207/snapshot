# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repo. Human-facing overview: `README.md`.

## What this project is

A learning project. The owner is a fullstack engineer learning DevOps. Snapshot (a mini Instagram: Go microservices + React) exists to practise Terraform, EKS, GitOps, CI/CD and AWS. Breadth and understanding matter more than depth.

- Design spec (binding): `docs/superpowers/specs/2026-10-26-devops-learning-platform-design.md`
- Current plan: `docs/superpowers/plans/2026-10-26-milestone-1-thin-slice.md`
- Progress ledger: `.superpowers/sdd/2026-10-26-milestone-1-thin-slice/progress.md` (git-ignored)

## How to work with the owner

- **One step at a time.** Say what you're about to do and why, in plain language (analogies welcome), do only that step, show the result, then pause for questions. Never batch many actions silently.
- Avoid unexplained jargon.
- After each plan task, write or update a note in `docs/learn/NN-topic.md` with the headings: What it is / Why big tech uses it / How it's wired here / Interview talking points / How to tear down.

## Hard rules

- **GitHub:** push only to the personal account repo `PhamNhatQuang207/snapshot`, never the work account. The local branch name differs from the remote, so push with `git push origin HEAD:main`.
- **Commit identity:** repo-local `PhamNhatQuang207 <156569397+PhamNhatQuang207@users.noreply.github.com>`.
- **No long-lived AWS keys** in the repo or CI. CI uses GitHub OIDC → `snapshot-github-actions` role.
- **AWS Free plan** (credits expire 2027-02-17):
  - Only free-tier-eligible instance types launch (`c7i-flex.large`, `m7i-flex.large`, `t3.micro/small`, `t4g.micro/small`…). A `--dry-run` pass does not prove a type is allowed.
  - Never create AWS Organizations or Control Tower: that upgrades the account to the Paid plan.
  - Confirm with the owner before anything that could cost real money rather than credits.
- **Cost:** `infra/env` costs ~$0.26/h. Ask before `terraform apply`. Destroy it at the end of every session, then verify nothing billable remains (EKS, NAT gateways, EIPs, EC2, load balancers, EBS volumes).
- Ask before any destructive or outward-facing action (destroy, push, publish).

## Layout and commands

```
services/post-service/   Go 1.27, stdlib net/http, slog, pgx/v5; distroless image
frontend/                React 19 + Vite + TS + Vitest; Node 24 (.nvmrc)
infra/bootstrap/         kept: S3 state bucket, ECR, GitHub OIDC role
infra/env/               disposable: VPC + EKS (RDS, ALB, CloudFront next)
docker-compose.yml       local Postgres (host port 5433) + post-service (8080)
```

| Task | Command |
|---|---|
| Go tests | `cd services/post-service && go test ./...` |
| Go integration test | `POSTS_TEST_DATABASE_URL='postgres://app:local@localhost:5433/snapshot?sslmode=disable' go test ./internal/posts/ -run Postgres` |
| Frontend tests | `cd frontend && npm test` |
| Local stack | `docker compose up --build` |
| Terraform checks | `terraform fmt -check && terraform validate && tflint` (inside the layer dir) |
| Kube access | `aws eks update-kubeconfig --name snapshot --region ap-southeast-1` |

## Conventions

- TDD: write the failing test first, watch it fail, then implement.
- Go: small `internal/` packages, interfaces at the consumer, `/healthz` (liveness) vs `/readyz` (readiness), graceful shutdown on SIGTERM.
- APIs: REST/JSON for the browser (port 8080); gRPC between services (port 9090, internal only, contracts in `proto/` via buf). gRPC starts in Milestone 2.
- Images: `linux/amd64` for AWS. The Dockerfile cross-compiles with `--platform=$BUILDPLATFORM` and `GOARCH=$TARGETARCH`.
- Terraform: pin module versions (`terraform-aws-modules/vpc ~> 6.7`, `eks ~> 21.29`), S3 backend with `use_lockfile`, short comments explaining *why*.
- Keep teardown clean: no resources that survive `destroy` and collide on the next `apply` (e.g. no custom KMS key or control-plane log group).
