# DevOps Learning Platform: "Snapshot" mini photo-sharing app on AWS

Date: 2026-10-26
Status: Draft, awaiting approval

## 1. Intent and the why

The owner is a fullstack software engineer who wants to move their career toward DevOps / platform engineering. They have basic hands-on experience with AWS, Docker, Linux servers and CI/CD, and know Terraform and Kubernetes only in theory.

The project is a **learning vehicle**, not a product. The app is deliberately small; the point is the infrastructure and delivery pipeline around it, built the way big-tech companies build theirs, using as many AWS services and DevOps tools as make honest sense.

**Success** = the owner can show a public GitHub repo with an architecture diagram and walk an interviewer through the full path from `git push` to production, explaining *why* every piece exists and what would change in a real company. Breadth and understanding matter more than depth: the owner does not need to become an expert in any one tool, but must understand each one well enough to explain it and to know how to grow into the role.

## 2. Goals, non-goals, anti-goals

**Goals**
- A working mini photo-sharing social network ("Snapshot") built as four Go microservices + a React frontend.
- Every AWS resource created by Terraform; the whole environment can be created and destroyed with one command each.
- Containers on Kubernetes (EKS), deployed via GitOps (Argo CD), built and shipped by GitHub Actions.
- Event-driven communication between services (SNS → SQS) alongside synchronous HTTP calls.
- Observability: metrics, logs, and distributed tracing across all four services.
- Ansible used for its real-world purpose: configuring a plain server.
- A learning note per phase explaining the tool, why big tech uses it, how it's wired here, and interview talking points.

**Non-goals**
- Multiple environments (dev/staging/prod). One environment only; the docs explain how prod would differ.
- Production-grade high availability, multi-region, disaster recovery.
- A real custom domain (owner chose free: CloudFront's default `*.cloudfront.net` address).
- Deep expertise in any single tool.
- A polished UI or rich social features beyond the list in §4.

**Anti-goals** (failure even if it technically works)
- A surprise AWS bill, or resources left running after teardown.
- "Magic" the owner can't explain: copy-pasted config with no learning note behind it.
- App complexity crowding out the infrastructure work.
- Long-lived AWS access keys stored anywhere (laptop config excepted for the owner's own CLI use; never in the repo or CI).

## 3. Constraints

- **Budget:** AWS **Free account plan** with $200 of credits and a zero-spend budget alert. On the Free plan AWS does not charge beyond credits, but credits burn while resources run, so the design is built around **tear down after every study session**.
- **Deadline:** the Free plan ends on 2027-02-17 (confirmed via `aws freetier get-account-plan-state`) or when credits run out, whichever comes first. The account then closes and AWS resources are lost; the GitHub repo and Terraform code are what persist. Upgrading to the Paid plan keeps remaining credits but removes the no-charge safety net, so the default is to stay on the Free plan.
- **Service availability risk:** AWS docs say the Free plan has access to "select AWS services and features" and excludes services that "would rapidly consume" credits; the eligible list is not confirmed for EKS. The first AWS phase therefore starts with a cheap probe that creates (then destroys) a minimal EKS cluster. **Fallback if EKS is blocked:** k3s on EC2 instances provisioned by Terraform and configured by Ansible (Ansible's role grows; everything above Kubernetes stays the same).
- **Rough running cost** while the environment is up (my estimate, to be verified by the builder): EKS control plane ~$0.10/h, one NAT gateway ~$0.05/h, ALB ~$0.03/h, spot worker nodes ~$0.05/h, RDS + ElastiCache micro instances ~$0.04/h → roughly **$0.25–0.35/hour**. A 4-hour session ≈ $1–1.50. Credits should last the whole project if teardown is reliable.
- **Region:** `ap-southeast-1` (Singapore). *My call*, assuming the owner is in Southeast Asia; any region works.
- **Languages:** Go for all backend services and the Lambda; React for the frontend (owner's choice). Owner also wants to understand Go for microservices.
- **No domain:** public entry point is the CloudFront default domain, which provides HTTPS for free.
- **Repo:** single GitHub repo (monorepo), currently empty. Will be public as a portfolio piece; nothing secret is ever committed.

## 4. The app: Snapshot

What a user can do:
1. Sign up / log in, set a display name and avatar.
2. Post a photo with a caption.
3. Follow other users; view a home feed of posts from people they follow (newest first).
4. Like and comment on posts.
5. See notifications when someone likes, comments on, or follows them.

### Services

| Service | Owns | Data store | Talks to |
|---|---|---|---|
| **user-service** | Profiles, follow graph | RDS Postgres (`users` schema) | — (others call it) |
| **post-service** | Posts, likes, comments, upload URLs | RDS Postgres (`posts` schema), S3 for photos | Publishes events to SNS |
| **feed-service** | Each user's home feed | ElastiCache Redis (per-user feed list) | Consumes SQS; calls user-service over HTTP for follower lists |
| **notification-service** | Notification inbox | DynamoDB | Consumes SQS |
| **thumbnail Lambda** | Resized images | S3 | Triggered by S3 upload event |

- One RDS instance, separate schema per service (database-per-service in spirit, cheap in practice). The learning note explains the trade-off.
- **Photo upload:** frontend asks post-service for a presigned S3 URL, uploads directly to S3; S3 event triggers the Go Lambda which writes a thumbnail.
- **Events:** post-service (and user-service for follows) publish to an SNS topic (`post.created`, `post.liked`, `comment.created`, `user.followed`). SNS fans out to two SQS queues: one for feed-service, one for notification-service. Each queue has a dead-letter queue.
- **Feed strategy:** fan-out-on-write. On `post.created`, feed-service fetches the author's followers from user-service and pushes the post ID onto each follower's Redis list (capped length). Reads hydrate post details from post-service.
- **Auth:** Amazon Cognito user pool with the hosted UI; callback URL is the CloudFront domain. Each Go service validates the Cognito JWT itself.

## 5. AWS architecture

```
Browser ──HTTPS──> CloudFront (d123.cloudfront.net)
                     ├── /*         → S3 (React build, private, via OAC)
                     ├── /media/*   → S3 (photos + thumbnails, private, via OAC)
                     └── /api/*     → ALB (HTTP; only reachable from CloudFront prefix list)
                                        └── EKS (private subnets)
                                              user / post / feed / notification services
                                              Argo CD, observability stack
                                                ├── RDS Postgres (private)
                                                ├── ElastiCache Redis (private)
                                                ├── DynamoDB, SNS, SQS (via IAM)
                                                └── Secrets Manager (via External Secrets)
S3 upload event → Lambda (thumbnail)
Admin EC2 (public subnet, SSH from owner's IP only) ← configured by Ansible
```

AWS services used: VPC (public + private subnets across 2 AZs, one NAT gateway), EKS (managed node group on spot instances), ECR, ALB (via AWS Load Balancer Controller), CloudFront, S3, Lambda, RDS Postgres, ElastiCache Redis, DynamoDB, SNS, SQS, Cognito, Secrets Manager, IAM (EKS Pod Identity or IRSA, per-service roles), CloudWatch, EC2.

Note: CloudFront → ALB is plain HTTP because there's no domain to issue a certificate for. Acceptable for learning; the learning note explains that production would use a custom domain + ACM certificate end-to-end.

## 6. DevOps stack (my calls as defaults; owner accepted the list)

- **Terraform** for all AWS resources. Two layers:
  - `bootstrap` (created once, kept): S3 state bucket, ECR repositories, GitHub OIDC provider + CI role. Costs pennies per month.
  - `env` (created/destroyed every session): everything else. Remote state in S3 with native S3 locking.
  - Organized into modules (network, eks, data, edge, events, etc.); exact split left to builder.
- **Kubernetes (EKS)** with Helm charts per service (a shared chart or one per service: builder's call). Horizontal Pod Autoscaler on at least the hot read path (feed-service).
- **Argo CD** installed during `env` creation; watches the repo and syncs all apps (app-of-apps pattern). GitOps: the repo is the source of truth for what runs.
- **GitHub Actions**:
  - Per-service pipeline (path-filtered): lint, test, build image, Trivy vulnerability scan, push to ECR tagged with git SHA, then commit the new image tag to the deploy manifests → Argo CD rolls it out.
  - Terraform pipeline on PRs: `fmt`, `validate`, lint/security scan (e.g. tflint/checkov), `plan`.
  - AWS access via GitHub OIDC, no stored keys.
- **Ansible** configures the admin EC2 box: users and SSH keys, OS hardening, installs kubectl/helm/awscli/psql, configures kubeconfig. Runs from the owner's laptop. Learning note covers where Ansible fits in container-heavy companies (plain servers, golden images, network gear) and where it doesn't.
- **Observability**: kube-prometheus-stack (Prometheus + Grafana), Loki for logs, OpenTelemetry SDK in each Go service → OTel collector → Tempo for traces; Grafana as the single pane. CloudWatch for AWS-managed services (RDS, Lambda, SQS). At least one dashboard and one alert rule.
- **Secrets & permissions**: Secrets Manager holds the DB password etc.; External Secrets Operator syncs into Kubernetes. Each service gets its own IAM role with least-privilege access.
- **Teardown safety**: a single `make up` / `make down` (or equivalent). `make down` must remove Kubernetes-created AWS resources (ALB, etc.) before `terraform destroy`, then verify nothing billable is left (e.g. list remaining tagged resources). All resources tagged `project=snapshot`.

## 7. Phases

Each phase ends in a working, demoable state plus a learning note in `docs/learn/NN-<topic>.md` (what it is, why big tech uses it, how it's wired here, interview talking points, how to tear down).

0. **App locally**: four Go services + React, run via Docker Compose (Postgres, Redis; AWS-specific parts stubbed or pointed at real AWS: builder's call).
1. **Terraform foundations**: bootstrap layer, VPC, state.
2. **Managed data services**: RDS, ElastiCache, DynamoDB, S3, Cognito.
3. **Containers on EKS**: cluster, ECR, images, first deploy with plain manifests.
4. **Helm + Argo CD**: GitOps deployment.
5. **CI/CD**: GitHub Actions pipelines with OIDC.
6. **Event-driven**: SNS/SQS wiring, DLQs, thumbnail Lambda.
7. **Edge**: CloudFront in front of S3 and ALB.
8. **Observability**: metrics, logs, traces, dashboard, alert.
9. **Ansible**: admin EC2 box.
10. **Scaling & resilience demos**: load test, HPA scaling, killing pods, a poison message landing in the DLQ.
11. **Wrap-up**: architecture diagram, README walk-through script, "how prod would differ" note, a career roadmap note (what to learn next, certifications worth considering).

Phase order may be adjusted by the builder if dependencies demand it, as long as each phase stays demoable.

## 8. Working model and decisions

- **Who builds:** Claude builds the code and infrastructure; the owner runs the commands (`make up`, `make down`, `git push`), reads the learning note for each phase, and asks questions. Owner said: "No need to be too deep on practice, just explain enough for me to understand." Learning notes are written alongside each phase, not after.
- **Data is throwaway** *(my call)*: every `make down` wipes app data, Cognito users, and the CloudFront URL changes on each `make up`. A seed script runs at the end of `make up` to create demo users, follows, posts and photos so the app is demo-ready every time. Bring-up takes ~25–40 minutes, so interviews are served by recorded evidence (diagrams, screenshots, Grafana captures, optional screen recording), not live bring-up.
- **Order: thin slice first** *(my call, overrides strict §7 order)*: after Phase 0, get **one** service (post-service) all the way through Terraform → EKS → Helm/Argo CD → GitHub Actions → CloudFront early, so the full `git push` → production story works as soon as possible. Then add the remaining services, events, observability, Ansible and demos. If time runs short, cut in this order: resilience demos, Ansible, comments.
- **Timeline** *(my call; owner didn't give weekly hours)*: sized to finish in ~10–12 weeks at roughly 6–8 hours/week, leaving a month of buffer before the Free plan ends. The thin slice should be working by about week 4.
- **Cost honesty** *(my call)*: the observability stack likely needs larger nodes than the §3 estimate; the builder measures the real hourly cost after the first full bring-up and records it in the learning notes. Cheaper swaps (NAT instance, in-cluster Redis, slimmer observability) are documented as fallbacks, not built by default.

## 9. Diagrams

- Runtime architecture: `.archify/architecture-snapshot-20261026-101243/snapshot.html`
- Delivery flow (git push → production): `.archify/workflow-snapshot-delivery-20261026-101243/snapshot-delivery.html`

## 10. Left to the builder

- Go frameworks/libraries, project layout, API shapes, DB schemas.
- React tooling (e.g. Vite) and UI library; UI can be plain.
- Exact Terraform module boundaries and use of community modules (community EKS/VPC modules are fine if the learning note explains what they create).
- Pod Identity vs IRSA; Tempo vs Jaeger; exact Helm chart structure.
- Local-dev approach for AWS-specific features.
- Spot instance types and node count, sized so the observability stack fits.
