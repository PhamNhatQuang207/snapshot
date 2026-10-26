# Milestone 1: Thin Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Go service (post-service) and a minimal React page run on AWS behind a free HTTPS CloudFront URL, deployed by `git push` → GitHub Actions → ECR → Argo CD → EKS, with every AWS resource in Terraform and one-command `make up` / `make down`.

**Architecture:** Two Terraform layers: `infra/bootstrap` (kept: state bucket, ECR, GitHub OIDC role) and `infra/env` (destroyed every session: VPC, EKS, RDS, ALB, CloudFront, cluster add-ons). Terraform owns the ALB and target group; the AWS Load Balancer Controller only binds pods to that target group (`TargetGroupBinding`), so CloudFront knows its origin at apply time and `terraform destroy` leaves no orphaned load balancers. Argo CD deploys a shared Helm chart; env-specific values (target group ARN) are injected by Terraform into the Argo CD Application, while the image tag lives in Git and is bumped by CI.

**Tech Stack:** Go (stdlib `net/http`, `log/slog`, `pgx/v5`), React + Vite + TypeScript + Vitest, Docker (multi-arch build, amd64 in AWS), Terraform (+ `terraform-aws-modules/vpc`, `terraform-aws-modules/eks`), EKS on x86 spot nodes, Helm, Argo CD, External Secrets Operator, AWS Load Balancer Controller, GitHub Actions (OIDC), Trivy, tflint, checkov.

**Spec:** `docs/superpowers/specs/2026-10-26-devops-learning-platform-design.md`

**Later milestones (separate plans, written after this one ships):**
- M2 Users & photos: Cognito auth, user-service, presigned S3 uploads, thumbnail Lambda, seed users/follows/photos.
- M3 Event-driven: SNS/SQS + DLQs, feed-service (ElastiCache Redis, fan-out on write), notification-service (DynamoDB), likes/comments, HPA.
- M4 Observability: kube-prometheus-stack, Loki, OpenTelemetry → Tempo, dashboard + alert, CloudWatch.
- M5 Ansible admin EC2 box.
- M6 Resilience demos (load test, pod kill, poison message → DLQ) and wrap-up (diagram, README walk-through, "how prod would differ", career roadmap).

## Global Constraints

- Region `ap-southeast-1`. All resources tagged `project=snapshot` plus `layer=bootstrap` or `layer=env` (via provider `default_tags`).
- AWS account is on the **Free account plan**, ending 2027-02-17. Never create AWS Organizations, Control Tower, or anything else that auto-upgrades the plan to Paid.
- No long-lived AWS keys in the repo or in GitHub; CI uses GitHub OIDC. The owner's own CLI profile on their laptop is the only exception.
- Terraform `>= 1.10` (S3 backend with `use_lockfile = true`, no DynamoDB lock table). AWS provider `>= 6.0`. Pin module/chart versions to the latest stable release at implementation time; check current docs before writing provider/module/chart arguments.
- CPU architecture in AWS is **x86_64** (owner's choice): spot nodes `c7i-flex.large` + `m7i-flex.large` (Free plan only launches free-tier-eligible types), `db.t3.micro`, images pushed as `linux/amd64`. The Dockerfile cross-compiles via `$TARGETARCH`, so local builds on Apple Silicon stay native arm64. CI runs on `ubuntu-24.04` (x86).
- Repeatable teardown: every `env` resource must survive an `up → down → up` cycle with the same names: Secrets Manager `recovery_window_in_days = 0`; S3 `force_destroy = true` on env buckets; RDS `skip_final_snapshot = true`, `deletion_protection = false`; EKS control-plane logging off and module-managed KMS key off (`create_kms_key = false`, no `encryption_config`).
- One NAT gateway (`single_nat_gateway = true`). Two AZs.
- Every task that introduces a tool also writes or extends its learning note in `docs/learn/NN-<topic>.md` with exactly these headings: `## What it is`, `## Why big tech uses it`, `## How it's wired here`, `## Interview talking points`, `## How to tear down`. Notes are written for a fullstack engineer who knows the theory only.
- post-service HTTP contract: port from `PORT` (default `8080`); `GET /healthz`, `GET /readyz`, `GET /api/posts`, `POST /api/posts`. JSON errors are `{"error": "<message>"}`.
- Caption length: 1–2200 characters (counted in Unicode runes).

## Review Focus

1. **Second `make up` after `make down`** must succeed with no name collisions (secrets in recovery window, leftover log groups, KMS aliases, non-empty buckets). Pinned in Task 11's full-cycle verification.
2. **`make down` leaves nothing billable** (EKS, NAT gateway, Elastic IPs, load balancers, RDS, EC2). Pinned by `scripts/verify-clean.sh` in Task 11.
3. **Database briefly unavailable**: `/healthz` must keep returning 200 (so Kubernetes doesn't restart the pod) while `/readyz` returns 503 (so traffic stops). Pinned in Task 2's tests.
4. **Bad client input** (empty or oversized caption, malformed JSON, wrong method) must return 4xx, never 500. Pinned in Task 2's tests.
5. **Rolling update mid-request**: SIGTERM must let in-flight requests finish. Pinned in Task 2's `httpserver` test. **CloudFront must not cache or rewrite `/api/*`**: a newly created post appears in the next list call, and API 404s stay JSON 404s. Pinned in Task 8's verification.

---

## File Structure

```
Makefile                                  make bootstrap | up | down | verify-clean | push
docker-compose.yml                        local Postgres + post-service
.gitignore
services/post-service/
  go.mod
  cmd/server/main.go                      wiring: env, store, migrate, handler, Run
  internal/posts/post.go                  Post type, Store interface, validation
  internal/posts/handler.go               HTTP handlers (NewHandler)
  internal/posts/handler_test.go
  internal/posts/fake_store_test.go       in-memory Store for handler tests
  internal/posts/postgres.go              PostgresStore + Migrate
  internal/posts/schema.sql               embedded migration
  internal/posts/postgres_test.go         integration test (skips without DB)
  internal/httpserver/run.go              Run with graceful shutdown
  internal/httpserver/run_test.go
  Dockerfile
frontend/                                 Vite React TS app
  src/App.tsx, src/api.ts, src/App.test.tsx
infra/probes/eks/main.tf                  throwaway EKS availability probe
infra/bootstrap/{versions,main,variables,outputs}.tf
infra/env/
  versions.tf  providers.tf  variables.tf  outputs.tf
  network.tf   eks.tf        data.tf       edge.tf
  addons.tf    params.tf
deploy/charts/service/                    shared Helm chart for all Go services
  Chart.yaml values.yaml templates/{deployment,service,serviceaccount,targetgroupbinding,externalsecret}.yaml
deploy/values/post-service.yaml           image.repository, image.tag (CI bumps tag)
deploy/platform/cluster-secret-store.yaml
scripts/{push-image,deploy-frontend,seed,verify-clean}.sh
.github/workflows/{post-service,frontend,terraform}.yml
docs/learn/00-overview.md … 09-teardown.md
```

---

### Task 1: Tooling check and EKS availability probe

Fail fast: confirm the Free plan can create an EKS cluster before building anything that depends on it.

**Files:**
- Create: `infra/probes/eks/main.tf`, `.gitignore`, `docs/learn/00-overview.md`

**Interfaces:**
- Produces: a go/no-go result recorded in `docs/learn/00-overview.md` under `## Probe results`.

- [ ] **Step 1: Owner prerequisites.** Already done: the default AWS CLI profile is IAM user `Quang` (group `admin` with `AdministratorAccess`, region `ap-southeast-1`), not root. Still to do (owner, in the console): enable MFA on user `Quang`. Install the missing tools: `brew install hashicorp/tap/terraform helm go yq tflint` (kubectl, Docker on arm64, Node 20, `gh` already present).

- [ ] **Step 2: Verify the toolchain**

Run: `aws sts get-caller-identity && terraform version && kubectl version --client && helm version && go version && node --version && yq --version && tflint --version`
Expected: the `arn:aws:iam::<account>:user/Quang` ARN, and every tool prints a version (Terraform ≥ 1.10).

- [ ] **Step 3: Write `.gitignore`** covering `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfplan`, `node_modules/`, `dist/`, `.env`, `.archify/**/visual-check*/`, `.archify/**/review-*/`, `.archify/**/*.json` except `candidate.json`.

- [ ] **Step 4: Write `infra/probes/eks/main.tf`.** Local state. It contains a cluster IAM role with `AmazonEKSClusterPolicy`, data sources for the default VPC and its subnets in two AZs, and one `aws_eks_cluster` named `snapshot-probe` with no node groups and no add-ons. Use provider `default_tags` `project=snapshot`, `layer=probe`.

- [ ] **Step 5: Run the probe**

Run: `cd infra/probes/eks && terraform init && terraform apply -auto-approve`
Expected: `aws_eks_cluster.this: Creation complete` (about 10 minutes). A failure mentioning the account plan, a subscription, or `AccessDenied` on `eks:CreateCluster` means **no-go**.

- [ ] **Step 6: Destroy the probe and confirm**

Run: `terraform destroy -auto-approve && aws eks list-clusters`
Expected: `"clusters": []`.

- [ ] **Step 7: Record the result and decide.** Write the go/no-go in `docs/learn/00-overview.md` (`## Probe results`), along with a short overview note: the project map, the two Terraform layers, and the session routine (`make up` → study → `make down`). **On no-go, stop executing this plan.** Report back so the plan can be revised to the k3s-on-EC2 fallback in spec §3.

- [ ] **Step 8: Commit**

```bash
git add .gitignore infra/probes docs/learn/00-overview.md
git commit -m "chore: add EKS availability probe and project overview"
```

---

### Task 2: post-service HTTP API (in-memory tested)

**Files:**
- Create: `services/post-service/go.mod` (module `github.com/<owner>/snapshot/services/post-service`), `internal/posts/post.go`, `internal/posts/handler.go`, `internal/posts/handler_test.go`, `internal/posts/fake_store_test.go`, `internal/httpserver/run.go`, `internal/httpserver/run_test.go`

**Interfaces:**
- Produces:
  ```go
  // package posts
  type Post struct {
      ID        string    `json:"id"`
      Caption   string    `json:"caption"`
      CreatedAt time.Time `json:"created_at"`
  }
  type Store interface {
      Ping(ctx context.Context) error
      Create(ctx context.Context, caption string) (Post, error)
      ListRecent(ctx context.Context, limit int) ([]Post, error) // newest first
  }
  const MaxCaptionRunes = 2200
  const ListLimit = 50
  func ValidateCaption(caption string) error // trims space; errors: "caption is required", "caption must be at most 2200 characters"
  func NewHandler(store Store, logger *slog.Logger) http.Handler

  // package httpserver
  func Run(ctx context.Context, srv *http.Server, shutdownTimeout time.Duration) error
  ```

- [ ] **Step 1: Write the failing handler tests** in `handler_test.go`, using an in-memory `fakeStore` from `fake_store_test.go` (fields `posts []Post`, `pingErr error`, `createErr error`).

```go
func TestHealthz_Returns200EvenWhenStoreDown(t *testing.T)        // pingErr set → GET /healthz 200 {"status":"ok"}
func TestReadyz_Returns503WhenStoreUnavailable(t *testing.T)      // pingErr set → 503 {"error":"database unavailable"}
func TestReadyz_Returns200WhenStoreOK(t *testing.T)               // 200 {"status":"ready"}
func TestCreatePost_Returns201WithPost(t *testing.T)              // POST {"caption":"hello"} → 201, caption=="hello", id!=""
func TestCreatePost_RejectsEmptyCaption(t *testing.T)             // {"caption":"   "} → 400 {"error":"caption is required"}
func TestCreatePost_RejectsCaptionOver2200Runes(t *testing.T)     // strings.Repeat("é", 2201) → 400 {"error":"caption must be at most 2200 characters"}
func TestCreatePost_Accepts2200Runes(t *testing.T)                // strings.Repeat("é", 2200) → 201
func TestCreatePost_RejectsMalformedJSON(t *testing.T)            // body "{" → 400 {"error":"invalid JSON body"}
func TestCreatePost_Returns500JSONOnStoreError(t *testing.T)      // createErr set → 500 {"error":"internal error"}, error logged
func TestListPosts_NewestFirst(t *testing.T)                      // two posts → GET /api/posts → 200 {"posts":[newer, older]}
func TestPosts_WrongMethodReturns405(t *testing.T)                // DELETE /api/posts → 405
```

All responses set `Content-Type: application/json`. Request bodies are capped with `http.MaxBytesReader` at 16 KiB (an oversized body → 400 `invalid JSON body`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd services/post-service && go test ./...`
Expected: FAIL (undefined: `NewHandler`, `Post`, …).

- [ ] **Step 3: Implement `post.go` and `handler.go`.** Use `http.ServeMux` method patterns (`"GET /api/posts"`, `"POST /api/posts"`, `"GET /healthz"`, `"GET /readyz"`), which return 405 automatically. Log each store error with `slog` at error level along with the request path.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/posts/...`
Expected: PASS.

- [ ] **Step 5: Write the failing graceful-shutdown test** in `run_test.go`:

```go
func TestRun_DrainsInFlightRequestOnCancel(t *testing.T)
// handler sleeps 300ms then writes "done"; start Run on 127.0.0.1:0 listener-backed server,
// fire request, cancel ctx after 50ms; assert response body == "done" and Run returns nil.
func TestRun_ReturnsErrorWhenShutdownTimesOut(t *testing.T)
// handler sleeps 2s; shutdownTimeout 100ms; cancel → Run returns non-nil error.
```

- [ ] **Step 6: Run to verify it fails, then implement `Run`.** `Run` calls `ListenAndServe` in a goroutine. On `ctx.Done()` it calls `srv.Shutdown` with a `shutdownTimeout` context. `http.ErrServerClosed` is not an error. Expose a seam for the test to use its own listener (e.g., an unexported `serve(ctx, srv, ln, timeout)` that `Run` wraps).

Run: `go test ./internal/httpserver/...`
Expected: FAIL before implementing, PASS after.

- [ ] **Step 7: Commit**

```bash
git add services/post-service
git commit -m "feat(post-service): HTTP API with validation, health probes, graceful shutdown"
```

---

### Task 3: Postgres store, server wiring, container, local compose

**Files:**
- Create: `internal/posts/postgres.go`, `internal/posts/schema.sql`, `internal/posts/postgres_test.go`, `cmd/server/main.go`, `services/post-service/Dockerfile`, `docker-compose.yml`, `docs/learn/01-go-microservice-and-containers.md`

**Interfaces:**
- Consumes: `posts.Store`, `posts.NewHandler`, `httpserver.Run` (Task 2).
- Produces:
  ```go
  func NewPostgresStore(ctx context.Context, databaseURL string) (*PostgresStore, error) // pgxpool
  func (s *PostgresStore) Migrate(ctx context.Context) error                           // runs embedded schema.sql
  func (s *PostgresStore) Close()
  ```
  Container contract: listens on `8080`, needs env `DATABASE_URL`, runs as non-root, multi-arch Dockerfile (`linux/amd64` for AWS, native arm64 locally).

- [ ] **Step 1: Write `schema.sql`** (idempotent):

```sql
CREATE SCHEMA IF NOT EXISTS posts;
CREATE TABLE IF NOT EXISTS posts.posts (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  caption    text NOT NULL CHECK (char_length(caption) BETWEEN 1 AND 2200),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS posts_created_at_idx ON posts.posts (created_at DESC);
```

- [ ] **Step 2: Write the failing integration test** `TestPostgresStore_CreateListAndMigrateTwice`. It skips unless `POSTS_TEST_DATABASE_URL` is set. It runs `Migrate` twice (idempotent), creates `"first"` then `"second"`, asserts `ListRecent(ctx, 50)` returns `second, first`, and asserts `Ping` returns nil.

- [ ] **Step 3: Write `docker-compose.yml`** with `postgres:17` (db `snapshot`, user `app`, password `local`, port `5432`, healthcheck `pg_isready`) and `post-service` built from `services/post-service`, `DATABASE_URL=postgres://app:local@postgres:5432/snapshot?sslmode=disable`, port `8080:8080`, `depends_on: condition: service_healthy`.

- [ ] **Step 4: Run the test to verify it fails**

Run: `docker compose up -d postgres && cd services/post-service && POSTS_TEST_DATABASE_URL=postgres://app:local@localhost:5432/snapshot?sslmode=disable go test ./internal/posts/ -run Postgres -v`
Expected: FAIL (undefined: `NewPostgresStore`).

- [ ] **Step 5: Implement `postgres.go`** (embed `schema.sql` with `//go:embed`). Then implement `main.go`: JSON `slog` logger to stdout; `DATABASE_URL` is required (if missing, log an error and exit 1); `PORT` defaults to `8080`; run `Migrate` at startup (on failure, exit 1, and Kubernetes restarts the pod with backoff); `signal.NotifyContext` for SIGTERM/SIGINT; `httpserver.Run(ctx, srv, 20*time.Second)`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: same command as Step 4, then `go test ./... && go vet ./...`
Expected: PASS, no vet findings.

- [ ] **Step 7: Write the Dockerfile.** It is multi-stage: build with the official `golang` image (`CGO_ENABLED=0 GOOS=linux`), `FROM --platform=$BUILDPLATFORM` + `GOARCH=$TARGETARCH` cross-compile, run on `gcr.io/distroless/static-debian12:nonroot`, `USER nonroot`, `EXPOSE 8080`.

- [ ] **Step 8: Verify end to end locally**

Run: `docker compose up -d --build && curl -s -XPOST localhost:8080/api/posts -d '{"caption":"hello"}' && curl -s localhost:8080/api/posts && docker compose stop post-service && docker compose logs post-service | tail -3`
Expected: a 201 body with an `id`, a list containing `hello`, and logs showing a clean shutdown (no panic).

- [ ] **Step 9: Write `docs/learn/01-go-microservice-and-containers.md`** covering the Go service layout, why liveness and readiness differ, graceful shutdown during rolling updates, distroless/non-root images, and multi-arch builds.

- [ ] **Step 10: Commit**

```bash
git add services/post-service docker-compose.yml docs/learn/01-*.md
git commit -m "feat(post-service): Postgres store, container image, local compose"
```

---

### Task 4: Minimal React frontend

**Files:**
- Create: `frontend/` (Vite React TS scaffold), `frontend/src/api.ts`, `frontend/src/App.tsx`, `frontend/src/App.test.tsx`, `frontend/vite.config.ts`

**Interfaces:**
- Consumes: post-service HTTP contract (Global Constraints).
- Produces: `frontend/dist/` static build served from the S3 web bucket. All API calls use relative `/api/...` paths (same origin through CloudFront; in dev, Vite proxies `/api` → `http://localhost:8080`).
  ```ts
  export type Post = { id: string; caption: string; created_at: string };
  export async function listPosts(): Promise<Post[]>;
  export async function createPost(caption: string): Promise<Post>; // throws Error(message from {"error"})
  ```

- [ ] **Step 1: Scaffold and add test deps.** Run `npm create vite@latest frontend -- --template react-ts`, then install `vitest`, `@testing-library/react`, `@testing-library/user-event`, and `jsdom`, and add `"test": "vitest run"`.

- [ ] **Step 2: Write the failing tests** in `App.test.tsx` (mock `fetch` with `vi.fn`):

```tsx
test("renders posts returned by the API, newest first")
// GET /api/posts → {"posts":[{caption:"newer"},{caption:"older"}]} → both texts visible in that order
test("shows the API error message when creating a post fails")
// POST → 400 {"error":"caption is required"} → text "caption is required" visible
test("prepends the created post after a successful submit")
```

- [ ] **Step 3: Run to verify failure**

Run: `cd frontend && npm test`
Expected: FAIL.

- [ ] **Step 4: Implement `api.ts` and `App.tsx`** (title "Snapshot", a caption textarea, a Post button, and a list of captions with relative timestamps). Plain CSS, no UI library.

- [ ] **Step 5: Run the tests and build**

Run: `npm test && npm run build`
Expected: 3 tests PASS; `dist/index.html` exists.

- [ ] **Step 6: Manual check against compose.** Run `npm run dev` with compose up, create a post in the browser, and confirm it appears.

- [ ] **Step 7: Commit**

```bash
git add frontend
git commit -m "feat(frontend): minimal Snapshot page listing and creating posts"
```

---

### Task 5: GitHub repo and Terraform bootstrap layer

**Files:**
- Create: `infra/bootstrap/versions.tf`, `main.tf`, `variables.tf`, `outputs.tf`, `docs/learn/02-terraform-basics-and-state.md`

**Interfaces:**
- Produces (outputs):
  - `state_bucket` = `snapshot-tfstate-<account_id>` (versioned, SSE, all public access blocked)
  - `ecr_repository_urls` = map of name → URL for `var.ecr_repositories` (default `["post-service"]`); `image_tag_mutability = "IMMUTABLE"`, scan on push, lifecycle keeps the last 10 images
  - `github_actions_role_arn`: role `snapshot-github-actions`, trusted by the GitHub OIDC provider for `repo:${var.github_repo}:ref:refs/heads/main` only. Permissions: ECR push/pull on the snapshot repos, `ecr:GetAuthorizationToken`, `s3:ListBucket/PutObject/DeleteObject` on `arn:aws:s3:::snapshot-web-*`, `cloudfront:CreateInvalidation`, `ssm:GetParameter` on `/snapshot/*`
- Variables: `github_repo` (e.g. `quangphamnhat-kwang/snapshot`), `ecr_repositories`.

- [ ] **Step 1: Owner creates a public GitHub repo** and adds it as `origin` (`gh repo create <owner>/snapshot --public --source . --push`). Nothing secret has been committed (verify with `git log -p | grep -iE "aws_secret|password=" || true` → no matches other than the local compose password `local`).

- [ ] **Step 2: Write the bootstrap Terraform** (local backend at first, provider `default_tags` `project=snapshot`, `layer=bootstrap`).

- [ ] **Step 3: Validate**

Run: `cd infra/bootstrap && terraform init && terraform fmt -check && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Apply**

Run: `terraform apply -var github_repo=<owner>/snapshot`
Expected: the plan shows only bootstrap resources; apply completes and prints the three outputs.

- [ ] **Step 5: Move bootstrap state into the bucket.** Add `backend "s3" { bucket = "<state_bucket>", key = "bootstrap/terraform.tfstate", region = "ap-southeast-1", use_lockfile = true }` and run `terraform init -migrate-state`.

Run: `aws s3 ls s3://snapshot-tfstate-<account_id>/bootstrap/`
Expected: `terraform.tfstate` is listed.

- [ ] **Step 6: Write `docs/learn/02-terraform-basics-and-state.md`** covering providers/resources/modules, plan vs apply, what state is and why it lives in S3 with locking, why bootstrap is separate, and OIDC vs access keys.

- [ ] **Step 7: Commit**

```bash
git add infra/bootstrap docs/learn/02-*.md
git commit -m "feat(infra): bootstrap layer with state bucket, ECR, GitHub OIDC role"
```

---

### Task 6: env layer, network and EKS cluster

**Files:**
- Create: `infra/env/versions.tf`, `providers.tf`, `variables.tf`, `network.tf`, `eks.tf`, `outputs.tf`, `docs/learn/03-vpc-and-eks.md`

**Interfaces:**
- Consumes: `state_bucket` (Task 5) as the backend bucket, key `env/terraform.tfstate`.
- Produces: outputs `cluster_name` (= `snapshot`), `vpc_id`, `private_subnet_ids`, `node_security_group_id`, `cluster_endpoint`. `kubernetes` and `helm` providers are configured from the EKS module outputs with `exec` auth (`aws eks get-token`), so later tasks add Helm releases in the same layer.

- [ ] **Step 1: Write `network.tf`** using `terraform-aws-modules/vpc`: CIDR `10.20.0.0/16`, 2 AZs, public and private subnets, `enable_nat_gateway = true`, `single_nat_gateway = true`, and subnet tags `kubernetes.io/role/elb=1` (public) and `kubernetes.io/role/internal-elb=1` (private).

- [ ] **Step 2: Write `eks.tf`** using `terraform-aws-modules/eks`:
  - cluster `snapshot`, latest version in EKS standard support (check `aws eks describe-cluster-versions`)
  - public endpoint, `authentication_mode = "API"`, `enable_cluster_creator_admin_permissions = true`
  - add-ons: `vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent`
  - control-plane logging disabled, `create_kms_key = false`, no `encryption_config`
  - one managed node group: `capacity_type = "SPOT"`, `ami_type = "AL2023_x86_64_STANDARD"`, instance types `["c7i-flex.large", "m7i-flex.large"]` (Free plan only launches free-tier-eligible types; t3.medium was refused), min 2, desired 2, max 3, nodes in private subnets

- [ ] **Step 3: Validate**

Run: `cd infra/env && terraform init && terraform fmt -check && terraform validate && tflint --init && tflint`
Expected: valid; no tflint errors.

- [ ] **Step 4: Apply and connect**

Run: `terraform apply && aws eks update-kubeconfig --name snapshot --region ap-southeast-1 && kubectl get nodes -o wide`
Expected: 2 nodes `Ready`, arch `amd64` (check with `kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type`).

- [ ] **Step 5: Destroy to confirm the layer tears down cleanly** (the full repeatable cycle comes in Task 11).

Run: `terraform destroy && aws eks list-clusters && aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'`
Expected: `"clusters": []` and `[]`.

- [ ] **Step 6: Write `docs/learn/03-vpc-and-eks.md`** covering public vs private subnets, NAT and its cost, the control plane vs nodes, spot instances, Pod Identity, and why the endpoint is public with IAM auth (and what prod would do instead).

- [ ] **Step 7: Commit**

```bash
git add infra/env docs/learn/03-*.md
git commit -m "feat(infra): env layer with VPC and EKS on x86 spot nodes"
```

---

### Task 7: Database, secrets and cluster add-ons

**Files:**
- Create: `infra/env/data.tf`, `infra/env/addons.tf`, `deploy/platform/cluster-secret-store.yaml`, `docs/learn/04-rds-secrets-and-addons.md`
- Modify: `infra/env/outputs.tf`

**Interfaces:**
- Consumes: VPC, EKS outputs (Task 6).
- Produces:
  - RDS Postgres 17 `db.t3.micro`, db `snapshot`, user `app`, 20 GB gp3, private subnets, SG allowing 5432 only from `node_security_group_id`, `skip_final_snapshot = true`, `deletion_protection = false`, `backup_retention_period = 0`.
  - Secrets Manager secret `snapshot/post-service/db`, JSON `{"DATABASE_URL":"postgres://app:<random>@<endpoint>:5432/snapshot?sslmode=require"}`, password from `random_password` (no special characters that break URLs), `recovery_window_in_days = 0`.
  - Helm releases in namespace `kube-system` / `external-secrets`: `aws-load-balancer-controller` (Pod Identity role with the controller's official IAM policy) and `external-secrets` (Pod Identity role allowing `secretsmanager:GetSecretValue`/`DescribeSecret` on `arn:aws:secretsmanager:ap-southeast-1:<acct>:secret:snapshot/*`).
  - `deploy/platform/cluster-secret-store.yaml`: `ClusterSecretStore` named `aws-secrets-manager`, provider `aws`, service `SecretsManager`, region `ap-southeast-1` (auth comes from the controller's Pod Identity). Applied by Argo CD in Task 9.
  - Output `rds_endpoint`.

- [ ] **Step 1: Write `data.tf` and `addons.tf`.**

- [ ] **Step 2: Validate and apply**

Run: `terraform fmt -check && terraform validate && terraform apply`
Expected: apply completes. `kubectl -n kube-system get deploy aws-load-balancer-controller` and `kubectl -n external-secrets get deploy` both show `READY` with all replicas available.

- [ ] **Step 3: Verify the secret shape without printing it**

Run: `aws secretsmanager get-secret-value --secret-id snapshot/post-service/db --query SecretString --output text | jq -r 'keys[]'`
Expected: `DATABASE_URL`.

- [ ] **Step 4: Write `docs/learn/04-rds-secrets-and-addons.md`** covering managed databases, why secrets stay out of Git and out of Terraform output, how External Secrets syncs secrets into Kubernetes, what a cluster add-on/controller is, and how Pod Identity gives a pod AWS permissions.

- [ ] **Step 5: Commit**

```bash
git add infra/env deploy/platform docs/learn/04-*.md
git commit -m "feat(infra): RDS, Secrets Manager, LB controller and External Secrets"
```

---

### Task 8: Edge: ALB, target group, CloudFront, web bucket

**Files:**
- Create: `infra/env/edge.tf`, `infra/env/params.tf`, `docs/learn/05-edge-cloudfront-alb.md`
- Modify: `infra/env/outputs.tf`

**Interfaces:**
- Consumes: VPC public subnets, `node_security_group_id` (Task 6).
- Produces:
  - ALB `snapshot-alb` (public subnets). SG ingress 80 only from the managed prefix list `com.amazonaws.global.cloudfront.origin-facing`. HTTP:80 listener with default action fixed-response 404 `{"error":"not found"}` (content type `application/json`). Rule path pattern `/api/posts*` → target group.
  - Target group `snapshot-post-service`: `target_type = "ip"`, port 8080, health check `/readyz`, `deregistration_delay = 15`.
  - Node SG ingress 8080 from the ALB SG.
  - S3 bucket `snapshot-web-<account_id>` (private, `force_destroy = true`) with an OAC.
  - CloudFront distribution (comment `snapshot`, `PriceClass_200`, default certificate, viewer protocol `redirect-to-https`):
    - default behavior → S3 origin with the managed `CachingOptimized` policy, plus a **CloudFront Function** (viewer-request) that rewrites paths without a file extension to `/index.html` (SPA routing). **Do not use distribution-level custom error responses**, because they would turn API 404s into `index.html`.
    - `/api/*` behavior → ALB origin (`http-only`), all methods, managed `CachingDisabled` cache policy and `AllViewerExceptHostHeader` origin request policy.
  - SSM parameters `/snapshot/web_bucket`, `/snapshot/cloudfront_distribution_id`, `/snapshot/cloudfront_domain`.
  - Outputs `cloudfront_domain`, `cloudfront_distribution_id`, `web_bucket`, `post_service_target_group_arn`.

- [ ] **Step 1: Write `edge.tf` and `params.tf`.**

- [ ] **Step 2: Validate and apply**

Run: `terraform fmt -check && terraform validate && terraform apply && terraform output cloudfront_domain`
Expected: a `dxxxx.cloudfront.net` domain.

- [ ] **Step 3: Verify the edge behavior** (no pods yet):

Run: `D=$(terraform output -raw cloudfront_domain); curl -s -o /dev/null -w "%{http_code}\n" http://$D/; curl -s https://$D/api/nope; curl -s -o /dev/null -w "%{http_code}\n" https://$D/api/posts; curl -s -o /dev/null -w "%{http_code}\n" http://$(aws elbv2 describe-load-balancers --names snapshot-alb --query 'LoadBalancers[0].DNSName' --output text)/api/posts --max-time 5`
Expected: `301` (redirect to HTTPS); `{"error":"not found"}` (a JSON 404 from the ALB, **not** HTML); `503` (target group has no healthy targets yet); the last call times out (`000`) because the ALB rejects direct traffic that doesn't come through CloudFront.

- [ ] **Step 4: Write `docs/learn/05-edge-cloudfront-alb.md`** covering CDNs, origins and behaviors, OAC, why `/api/*` isn't cached, why the ALB only accepts CloudFront traffic, why there's HTTP between CloudFront and the ALB here and what prod does instead (custom domain + ACM), and why Terraform owns the ALB rather than an Ingress.

- [ ] **Step 5: Commit**

```bash
git add infra/env docs/learn/05-*.md
git commit -m "feat(infra): CloudFront edge with S3 web origin and ALB API origin"
```

---

### Task 9: Helm chart and Argo CD GitOps deploy

**Files:**
- Create: `deploy/charts/service/Chart.yaml`, `values.yaml`, `templates/deployment.yaml`, `templates/service.yaml`, `templates/serviceaccount.yaml`, `templates/targetgroupbinding.yaml`, `templates/externalsecret.yaml`, `deploy/values/post-service.yaml`, `scripts/push-image.sh`, `docs/learn/06-helm-and-argocd.md`
- Modify: `infra/env/addons.tf` (Argo CD + Applications), `Makefile` (target `push`)

**Interfaces:**
- Consumes: `post_service_target_group_arn` (Task 8), `ClusterSecretStore aws-secrets-manager` (Task 7), ECR URL (Task 5).
- Produces:
  - Chart values contract (used by every later service):
    ```yaml
    image: { repository: "", tag: "" }
    containerPort: 8080
    replicas: 2
    targetGroupARN: ""            # injected by Terraform via the Argo CD Application
    secretEnv: { remoteKey: "", targetSecretName: "" }   # ExternalSecret → envFrom
    resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { memory: 128Mi } }
    probes: { liveness: /healthz, readiness: /readyz }
    ```
    The Deployment uses `envFrom` with the synced secret, `securityContext.runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `terminationGracePeriodSeconds: 30`, and rolling update `maxUnavailable: 0`, `maxSurge: 1`. The ExternalSecret has `refreshInterval: 1h` and `dataFrom.extract.key = secretEnv.remoteKey`.
  - `deploy/values/post-service.yaml`: `image.repository: <ecr url>/post-service`, `image.tag: <sha>`, `secretEnv.remoteKey: snapshot/post-service/db`, `secretEnv.targetSecretName: post-service-db`. **CI edits only `image.tag`.**
  - Terraform `helm_release` `argo-cd` (namespace `argocd`) and `helm_release` `argocd-apps` defining two Applications, both with automated sync (`prune`, `selfHeal`) and the finalizer `resources-finalizer.argocd.argoproj.io`:
    - `platform`: path `deploy/platform`
    - `post-service`: path `deploy/charts/service`, value file `../../values/post-service.yaml`, Helm parameter `targetGroupARN = <tg arn>`, namespace `snapshot` (CreateNamespace)
  - Variable `github_repo_url` (the public HTTPS URL).
  - `scripts/push-image.sh <service>`: ECR login, `docker build --platform linux/amd64`, tag with `git rev-parse --short=12 HEAD`, push, print the tag. Exposed as `make push SERVICE=post-service`.

- [ ] **Step 1: Write the chart, then lint and render it**

Run: `helm lint deploy/charts/service -f deploy/values/post-service.yaml --set targetGroupARN=arn:test && helm template t deploy/charts/service -f deploy/values/post-service.yaml --set targetGroupARN=arn:test | grep -E "kind: (Deployment|Service|ServiceAccount|TargetGroupBinding|ExternalSecret)"`
Expected: lint passes; all five kinds are rendered.

- [ ] **Step 2: Push the first image and set its tag**

Run: `make push SERVICE=post-service`, then put the printed tag in `deploy/values/post-service.yaml`, commit, and push to `main`.
Expected: `aws ecr describe-images --repository-name post-service` lists the tag.

- [ ] **Step 3: Add Argo CD to Terraform and apply**

Run: `terraform apply && kubectl -n argocd get applications`
Expected: `platform` and `post-service` both `Synced` / `Healthy` within ~3 minutes.

- [ ] **Step 4: Verify the full path through CloudFront**

Run: `D=$(terraform -chdir=infra/env output -raw cloudfront_domain); curl -s -XPOST https://$D/api/posts -H 'content-type: application/json' -d '{"caption":"from the cloud"}'; curl -s https://$D/api/posts`
Expected: a 201 body with an `id`; the list call immediately includes `from the cloud` (proving `/api/*` is not cached).

- [ ] **Step 5: Verify GitOps self-heal**

Run: `kubectl -n snapshot scale deploy post-service --replicas=0 && sleep 60 && kubectl -n snapshot get deploy post-service`
Expected: back to `2/2` (Argo CD reverted the manual change).

- [ ] **Step 6: Write `docs/learn/06-helm-and-argocd.md`** covering Helm charts vs plain manifests, one shared chart for many services, GitOps pull vs CI push, app-of-apps, self-heal, rollback via `git revert`, how to open the Argo CD UI (`kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443` plus the initial admin secret), and TargetGroupBinding.

- [ ] **Step 7: Commit**

```bash
git add deploy scripts/push-image.sh infra/env Makefile docs/learn/06-*.md
git commit -m "feat(deploy): shared Helm chart and Argo CD GitOps for post-service"
```

---

### Task 10: CI/CD pipelines

**Files:**
- Create: `.github/workflows/post-service.yml`, `.github/workflows/frontend.yml`, `.github/workflows/terraform.yml`, `scripts/deploy-frontend.sh`, `docs/learn/07-ci-cd-github-actions.md`

**Interfaces:**
- Consumes: `github_actions_role_arn` (Task 5, stored as the repo variable `AWS_ROLE_ARN`, not a secret), SSM params (Task 8), `deploy/values/post-service.yaml` (Task 9).
- Produces:
  - `post-service.yml`: triggers on `pull_request` and `push` to `main` with `paths: services/post-service/**`; `runs-on: ubuntu-24.04`.
    - Job `test` (PRs and main): `go vet ./...`, `go test ./...`, build the image tagged with the 12-char SHA, Trivy scan of the local image (`severity: HIGH,CRITICAL`, `ignore-unfixed: true`, `exit-code: 1`).
    - Job `release` (main only, needs `test`, `permissions: id-token: write, contents: write`): rebuild the same tag → OIDC login → push to ECR → `yq -i '.image.tag = "<sha>"' deploy/values/post-service.yaml` → commit as `github-actions[bot]` with message `deploy(post-service): <sha>` → push. The `paths` filter means this commit does not retrigger the workflow.
  - `scripts/deploy-frontend.sh`: reads `/snapshot/web_bucket` and `/snapshot/cloudfront_distribution_id` from SSM. If a parameter is missing, it prints `env is down, skipping frontend deploy` and exits 0. Otherwise it runs `npm ci && npm test && npm run build`, `aws s3 sync dist s3://$BUCKET --delete`, and creates a CloudFront invalidation for `/*`.
  - `frontend.yml`: `paths: frontend/**`. On PRs it runs `npm ci && npm test && npm run build`; on main it runs OIDC login and then `scripts/deploy-frontend.sh`.
  - `terraform.yml`: `paths: infra/**`, PRs and main, **no AWS credentials**. For each of `infra/bootstrap` and `infra/env` it runs `terraform fmt -check -recursive`, `terraform init -backend=false`, `terraform validate`, `tflint`, and `checkov -d infra --quiet --compact` (soft-fail for findings documented in the learning note, so the owner can see and discuss them).

- [ ] **Step 1: Write the workflows and the script.** Set the repo variable: `gh variable set AWS_ROLE_ARN --body <arn>`.

- [ ] **Step 2: Verify the PR path.** Open a PR that changes a log message in post-service.
Expected: `test` passes; `release` is skipped; `terraform.yml` does not run.

- [ ] **Step 3: Verify the main path (env up).** Merge the PR.
Expected: `release` goes green; a `deploy(post-service): <sha>` commit appears on main; within ~3 minutes `kubectl -n snapshot get deploy post-service -o jsonpath='{.spec.template.spec.containers[0].image}'` ends with that SHA; `curl https://$D/api/posts` keeps answering throughout (watch it with `while true; do curl -s -o /dev/null -w "%{http_code} " https://$D/api/posts; sleep 1; done`, which should show only `200`s).

- [ ] **Step 4: Verify the security gate.** On a branch, change the Dockerfile's final stage to an old base image with known critical CVEs (e.g. an old `debian` release) and open a PR.
Expected: the `test` job fails at the Trivy step listing CRITICAL CVEs; `release` never runs, so nothing is pushed. Close the PR without merging.

- [ ] **Step 5: Write `docs/learn/07-ci-cd-github-actions.md`** covering the CI vs CD split, OIDC trust, image tags as git SHAs, vulnerability scanning, why the PR Terraform pipeline has no credentials here, and what `terraform plan` in PRs looks like at a company.

- [ ] **Step 6: Commit**

```bash
git add .github scripts/deploy-frontend.sh docs/learn/07-*.md
git commit -m "ci: post-service release pipeline, frontend deploy, Terraform checks"
```

---

### Task 11: One-command up/down, seed, verify-clean, full-cycle proof

**Files:**
- Create: `Makefile` targets `bootstrap`, `up`, `down`, `verify-clean`; `scripts/seed.sh`, `scripts/verify-clean.sh`, `docs/learn/08-session-routine.md`, `docs/learn/09-teardown.md`, `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `make up`: `terraform -chdir=infra/env apply -auto-approve -var github_repo_url=...` → `aws eks update-kubeconfig` → wait until `kubectl -n argocd get application post-service` is `Healthy` (timeout 10 min) → `scripts/deploy-frontend.sh` → `scripts/seed.sh https://$D` → print `Snapshot is up: https://$D` and the elapsed time.
  - `scripts/seed.sh <base_url>`: POSTs 5 fixed demo captions; exits non-zero on any non-201.
  - `make down`: `terraform -chdir=infra/env destroy -auto-approve` → `scripts/verify-clean.sh`.
  - `scripts/verify-clean.sh`: in `ap-southeast-1`, checks that each of these is empty and exits 1 listing anything found: `aws eks list-clusters`; NAT gateways in state `available`/`pending`; Elastic IPs; load balancers named `snapshot-*`; RDS instances whose identifier starts with `snapshot`; EC2 instances in state `running`/`pending` tagged `project=snapshot`; CloudFront distributions with comment `snapshot` (global). Prints `clean: nothing billable left` on success.
  - `README.md`: what Snapshot is, both archify diagrams, prerequisites, `make bootstrap` once, the session routine, and links to `docs/learn/`.

- [ ] **Step 1: Write `verify-clean.sh` and test it against a live env** (env currently up from earlier tasks).

Run: `scripts/verify-clean.sh; echo "exit=$?"`
Expected: lists the cluster, NAT gateway, ALB, RDS and CloudFront distribution; `exit=1`.

- [ ] **Step 2: Write the Makefile targets and `seed.sh`.**

- [ ] **Step 3: Full-cycle proof (Review Focus 1 and 2).** Run, in order:

Run: `make down && make up && make down`
Expected: the first `make down` ends with `clean: nothing billable left`; `make up` ends with `Snapshot is up: https://…` and the page shows the 5 seeded posts; the second `make down` again ends with `clean: nothing billable left`. No errors about existing secrets, log groups, KMS aliases, or non-empty buckets. Record the elapsed `make up` time and the cost of the cycle (Cost Explorer next day) in `docs/learn/08-session-routine.md`.

- [ ] **Step 4: Write `docs/learn/08-session-routine.md`** (start/stop a session, what it costs per hour measured, what to do if `make down` fails halfway: rerun it, then `verify-clean`) and `docs/learn/09-teardown.md` (why teardown order matters, Argo CD finalizers, why Terraform owns the ALB, and the resources that commonly get orphaned and how to find them).

- [ ] **Step 5: Commit**

```bash
git add Makefile scripts README.md docs/learn/08-*.md docs/learn/09-*.md
git commit -m "feat: one-command up/down with seed data and teardown verification"
```

---

## Self-review notes

- Spec coverage for M1: §4 post-service (subset: captions; photos/likes/comments → M2/M3), §5 edge/EKS/RDS/Secrets Manager, §6 Terraform two layers, EKS/Helm/Argo CD, GitHub Actions + Trivy + OIDC, Terraform PR checks, teardown safety, §7 phases 0–5 and 7 for one service, §8 thin slice, seed, measured cost, §3 EKS probe and fallback gate. Deferred by design to later plans: Cognito, other services, SNS/SQS/Lambda, ElastiCache, DynamoDB, HPA, observability, Ansible, resilience demos, wrap-up.
- Decision not in the spec, made here: Terraform-owned ALB + `TargetGroupBinding` instead of an Ingress-created ALB (stable CloudFront origin and clean destroy); SPA routing via a CloudFront Function instead of custom error responses; x86 nodes with a cross-compiling multi-arch Dockerfile; CI Terraform checks run without AWS credentials.
