# 07 · CI/CD with GitHub Actions

## What it is

- **CI (Continuous Integration)**: every change is automatically checked (build, tests, linters, security scans) before anyone trusts it.
- **CD (Continuous Delivery)**: every change that passes on `main` is automatically shipped.
- **GitHub Actions**: GitHub's built-in automation. A *workflow* (`.github/workflows/*.yml`) runs *jobs* on fresh virtual machines (`ubuntu-24.04`) when something happens (a pull request, a push).

Our three workflows:

| Workflow | Runs when | Pull request | Push to `main` |
|---|---|---|---|
| `post-service.yml` | `services/post-service/**` changes | `test`: vet, tests, build image, **Trivy** scan | `test`, then `release`: image → ECR, bot commits `deploy(post-service): <sha>` |
| `frontend.yml` | `frontend/**` changes | test + build | test, build, S3 upload, CloudFront invalidation (skipped if env is down) |
| `terraform.yml` | `infra/**` changes | fmt, validate, tflint, checkov | same |

## Why big tech uses it

- **Fast, consistent feedback**: every change gets the same checks, so nobody has to remember to run them.
- **Small, frequent releases** are less risky than big rare ones, and easy to trace back (every image tag is a commit).
- **Security gates in the pipeline** ("shift left") block known vulnerabilities before they reach production, not after.
- **No humans with production keys** for routine releases: the pipeline and GitOps do it, and everything is logged.

## How it's wired here

**The CI/CD split with GitOps:**

```
git push ──> GitHub Actions: test → scan → image to ECR → commit new tag to deploy/values/post-service.yaml
                                                                   │  (CI never touches the cluster)
                                                                   ▼
                                                   Argo CD (in the cluster) sees the commit → rolling update
```

- **OIDC instead of AWS keys.** Each run gets a signed ID token from GitHub. AWS checks it against the role's trust policy and returns credentials that last about an hour. The trust policy only accepts `main` of this repo, written in GitHub's **immutable subject** form:

  ```
  repo:PhamNhatQuang207@156569397/snapshot@1433890568:ref:refs/heads/main
  ```

  The numbers are permanent owner and repo IDs, so a deleted or renamed repo can't be re-created by someone else to inherit the access. *Found the hard way:* the first login failed because the rule used the old name-only form. CloudTrail showed the exact subject GitHub sent.
- **Least privilege for CI**: the role can push to ECR, write to the web bucket, invalidate CloudFront and read `/snapshot/*` SSM parameters. Nothing else, so it can't create or destroy infrastructure.
- **The repo variable** `AWS_ROLE_ARN` is a variable, not a secret: a role ARN alone grants nothing.
- **Image tags are git SHAs** (first 12 characters). From any running pod you can find the exact code. ECR tags are immutable, so a tag can never be overwritten with different code.
- **Trivy** scans the built image for known CVEs and fails on fixable HIGH/CRITICAL ones (`ignore-unfixed: true` avoids blocking on problems nobody can fix yet).
  - **Real catch on day one**: 2 HIGH CVEs in `golang.org/x/text` v0.29.0, an indirect dependency via the Postgres driver. Fixed by upgrading to v0.43.0.
  - **Deliberate test**: a PR with a `debian:10.0` base → 62 findings (15 CRITICAL), `release` skipped, nothing pushed, PR closed.
- **Supply-chain hygiene**: every third-party action is pinned to a full commit SHA (with the version in a comment), because tags can be moved by an attacker who compromises an action's repo.
- **`concurrency`** on release/deploy jobs: two quick merges can't race each other's tag bumps.
- **The bot's commit doesn't loop**: commits made with the workflow's `GITHUB_TOKEN` don't trigger new workflow runs (and the tag file isn't in post-service's `paths` filter anyway).
- **Env down?** Tests, scans, ECR pushes and tag bumps still work, because ECR lives in the always-on bootstrap layer. The frontend deploy prints `env is down, skipping frontend deploy`. Only a *missing* SSM parameter counts as "down": other errors (expired credentials, denied permission) fail the job instead of silently skipping. The next `make up` deploys whatever Git says is latest.
- **Terraform in CI has no AWS credentials**: it only checks formatting, validity, lint (tflint) and security misconfigurations (checkov, soft-fail). Expected checkov findings are deliberate lab trade-offs: no RDS backups or Multi-AZ, no ALB access logs, HTTP from CloudFront to the ALB, public EKS endpoint, no WAF.

**Verified on 2026-10-26:**

| Check | Result |
|---|---|
| PR #1 (Go log change) | `test` ✅, `release` skipped, frontend/terraform didn't run |
| Merge of PR #1 | release ✅ → bot commit `deploy(post-service): 9a16dc53cd20` → Argo CD rollout, **278/278 requests 200** throughout |
| First automated release | 306/306 requests 200 |
| PR #2 (vulnerable base image) | blocked by Trivy, never released |

**How a company runs Terraform in CI** (not done here): a PR that changes infrastructure triggers `terraform plan`, and the plan is posted as a PR comment. A reviewer approves. Merging runs `terraform apply` with a powerful but tightly guarded role (often only from a protected branch, with manual approval). Tools: Atlantis, HCP Terraform, Spacelift. We run `make up/down` from the laptop instead, because the environment is created and destroyed daily, costs money per hour, and CI would need near-admin rights.

## Interview talking points

- "CI builds, tests and scans; CD is GitOps. The pipeline only commits the new image tag, and Argo CD pulls it into the cluster, so CI never holds cluster credentials."
- "GitHub Actions authenticates to AWS with OIDC: no stored keys, hour-long credentials, and a trust policy pinned to main of one repo using GitHub's immutable subject."
- "Trivy gates releases on fixable HIGH/CRITICAL CVEs. It caught a real one in an indirect Go dependency on day one."
- "Third-party actions are pinned to commit SHAs to defend against tag hijacking."
- "Image tags are git SHAs and ECR tags are immutable, so every running pod maps to an exact commit."
- "In a team I'd run terraform plan on PRs and apply on merge with Atlantis or HCP Terraform."

## How to tear down

Nothing to tear down: workflows cost nothing and simply skip deploys when the env is down. To pause CI entirely: GitHub → Actions → disable a workflow. ECR keeps the last 10 images (lifecycle rule); the CI role and OIDC provider live in `infra/bootstrap`.
