# 08 · The session routine: `make up` / `make down`

## What it is

The whole environment is created at the start of a study session and destroyed at the end, with one command each. Run them from your laptop with your own AWS login.

```bash
make up      # ~25 min: infrastructure + app + website + demo posts, prints the URL
make down    # ~15 min: destroy everything, then verify nothing billable is left
```

`make up` (`scripts/up.sh`) runs six steps:

1. `terraform apply` on `infra/env`: network, EKS, RDS, add-ons, ALB, CloudFront, Argo CD.
2. `aws eks update-kubeconfig`, then points kubeconfig at the absolute path of `aws`, so Headlamp works when opened from the Dock.
3. Waits until Argo CD reports post-service `Healthy`. Argo CD deploys whatever image tag Git says is latest.
4. Waits until `https://<cloudfront>/api/posts` answers 200.
5. `scripts/deploy-frontend.sh`: builds the React app with Node 24, uploads it to the new bucket, invalidates the CloudFront cache.
6. `scripts/seed.sh`: creates 5 demo posts, then prints `Snapshot is up: https://dxxxx.cloudfront.net (took Xm Ys)`.

`make down` runs `terraform destroy`, then `scripts/verify-clean.sh`.

## Why big tech uses it

Companies don't destroy production nightly, but they do the same thing for **ephemeral environments**: a full copy of the stack per pull request or per test run, created from code and thrown away afterwards. It only works if creation and teardown are fully automated and repeatable. If you can't recreate an environment from scratch, you don't really know what's in it.

## How it's wired here

- **One-time setup** (already done): `make bootstrap` creates the state bucket, ECR and the GitHub CI role. They stay up permanently for a few cents a month.
- **Cost while up**: about **$0.30/h**, all from credits. Roughly:
  - EKS control plane $0.10
  - NAT gateway ~$0.06
  - 2 spot nodes ~$0.06
  - ALB ~$0.03
  - RDS `db.t3.micro` ~$0.03
  - plus small items

  Measured on 2026-10-26: about **$1.50** for ~4.5 hours of building and testing (Cost Explorer shows the exact figure the next day).
- **Data is throwaway**: the database, the website bucket and the CloudFront URL are new every `make up`. The seed script makes the app look lived-in again. The *app version* is not lost: it lives in Git (`deploy/values/post-service.yaml`).
- **If `make down` fails halfway**: run `make down` again. Terraform resumes and destroys only what's left. Then run `make verify-clean`. If something is still listed, see note 09.
- **If `make up` fails halfway**: run `make up` again. Terraform creates only what's missing (we saw this with the tainted node group and the reserved DB name).
- **Status**: `make down` + `verify-clean` verified on 2026-10-26. The first one-command `make up` from scratch is still to be run by the owner. Record its time here: `____`.

## Interview talking points

- "My whole environment is code: one command builds it in about 25 minutes, one command destroys it and verifies nothing billable is left."
- "Teardown is verified against the AWS API, not assumed from Terraform's output."
- "It's the same idea as ephemeral preview environments per pull request."

## How to tear down

`make down`. If it reports `LEFT: ...`, rerun `make down`; if it still reports leftovers, follow note 09.
