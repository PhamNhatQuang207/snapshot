# 02 · Terraform basics, state, and the bootstrap layer

## What it is

Terraform turns text files (`.tf`) into real cloud resources. You describe the *end result* you want ("a private S3 bucket with versioning"), and Terraform works out the API calls to get there. This is called **declarative infrastructure as code (IaC)**.

Vocabulary:

| Term | Meaning | Example here |
|---|---|---|
| **provider** | plugin that talks to one platform's API | `hashicorp/aws` |
| **resource** | something Terraform creates and owns | `aws_s3_bucket.tfstate` |
| **data source** | something that already exists; read-only lookup | `data.aws_caller_identity.current` |
| **variable / output** | inputs and results of a configuration | `github_repo` in, `state_bucket` out |
| **module** | a reusable bundle of resources | VPC and EKS modules in Task 6 |
| **state** | Terraform's record of what it created and their real IDs | `bootstrap/terraform.tfstate` in S3 |

The everyday loop:

```bash
terraform init      # download providers, connect to the state backend
terraform plan      # show what WOULD change: + create, ~ update, - destroy. Changes nothing.
terraform apply     # make the changes (asks for confirmation unless given a saved plan)
terraform destroy   # delete everything this configuration created
```

## Why big tech uses it

- **Review:** infrastructure changes go through pull requests like code. Reviewers read the `plan` output before anything is applied.
- **Repeatability:** the same code builds an identical environment every time. That's how you can destroy everything nightly and rebuild it in the morning.
- **Inventory:** the code *is* the documentation of what exists. No clicking around the console wondering who created what.
- **Multi-cloud tooling:** the same workflow works for AWS, GCP, Cloudflare, GitHub, Datadog and others. That's why Terraform is the default IaC tool in most job descriptions, alongside its open-source fork OpenTofu.

## How it's wired here

**Two layers, two lifetimes.**

- `infra/bootstrap`: created once, kept forever. It holds things that are cheap at rest and that the other layer depends on:
  - S3 bucket `snapshot-tfstate-<account>`: versioned, encrypted, public access blocked. Holds state for both layers.
  - ECR repository `post-service`: the private Docker registry. Tags are **immutable** (a git SHA always means one build), and only the last 10 images are kept.
  - GitHub OIDC provider + role `snapshot-github-actions` (see below).
- `infra/env` (next tasks): the network, EKS, database and edge. It's destroyed at the end of every session.

**Why state matters.** State maps your code (`aws_s3_bucket.tfstate`) to the real thing (`snapshot-tfstate-668302078083`). Lose it and Terraform thinks nothing exists: the next `apply` tries to create duplicates, and `destroy` can't clean up. So state lives in S3 with:

- **versioning**, so a corrupted write can be rolled back
- **encryption**, because state can contain sensitive values
- **locking** (`use_lockfile = true`): while an apply runs, a `.tflock` object exists, and a second apply refuses to start. Older setups used a DynamoDB table for this; Terraform 1.10+ can lock with S3 alone.

**The chicken-and-egg problem.** The bootstrap layer creates the bucket that should hold its own state. So it was applied first with local state, then a `backend "s3"` block was added and `terraform init -migrate-state` copied the state up. Proof it worked: `terraform plan` said *"No changes. Your infrastructure matches the configuration."*

**OIDC instead of access keys.** GitHub Actions never gets an AWS key. Instead:

1. The workflow asks GitHub for a short-lived signed token that says "repo `PhamNhatQuang207/snapshot`, branch `main`".
2. AWS checks the signature against the trusted OIDC provider, and checks the role's conditions: `aud = sts.amazonaws.com` and `sub = repo:PhamNhatQuang207/snapshot:ref:refs/heads/main`.
3. AWS returns temporary credentials (about 1 hour).

Nothing secret is stored in GitHub, so nothing can leak, and PRs, forks and other branches can't assume the role at all.

**Least privilege.** The role can push to ECR, upload to `snapshot-web-*` buckets, invalidate CloudFront and read `/snapshot/*` parameters. It can't touch RDS, IAM or EKS. If CI were compromised, the damage would be limited to deploying.

**Dependency graph.** Terraform reads references between resources (e.g. the role policy uses `aws_iam_role.github_actions.id`) and orders creation automatically. Independent resources are created in parallel; that's why 9 resources took about 3 seconds.

## Interview talking points

- "Remote state in S3 with versioning, encryption and locking. I'd never keep state on a laptop or in Git."
- "I separate a long-lived bootstrap layer from disposable environments, which also avoids the chicken-and-egg problem of the state bucket."
- "CI authenticates to AWS with OIDC federation, scoped to one repo and branch. No long-lived keys anywhere."
- "Every change goes plan → review → apply. In a team I'd have CI post the plan on the PR and apply only after merge."
- "`.terraform.lock.hcl` is committed so everyone uses identical provider versions."

## How to tear down

Normally you don't: bootstrap is meant to stay (cost well under $1/month). To remove it completely at the end of the project:

```bash
aws s3 rm s3://snapshot-tfstate-668302078083 --recursive   # versioned bucket: also delete old versions in the console
cd infra/bootstrap && terraform destroy
```

Destroy `infra/env` first, since its state lives in this bucket.
