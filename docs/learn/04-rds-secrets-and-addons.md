# 04 · Database (RDS), secrets and cluster add-ons

## What it is

**RDS**: a managed database. AWS runs the server, disk, OS patches, minor-version upgrades, backups (if enabled) and failover (if Multi-AZ). We only connect and use Postgres. Ours: Postgres 17 on `db.t3.micro`, 20 GB gp3, in the private subnets (`infra/env/data.tf`).

**Secrets Manager**: AWS's password vault. It holds one secret, `snapshot/post-service/db`, with a single field, `DATABASE_URL` (the full connection string).

**Cluster add-ons / controllers**: programs running inside Kubernetes that keep checking "what was asked for, and does it exist?" and fix the difference (like the building manager who reads your note and arranges the parking spot). We install two with Helm (`infra/env/addons.tf`):

| Add-on | Job | Analogy |
|---|---|---|
| **AWS Load Balancer Controller** | Keeps an AWS load balancer's list of pod IPs up to date as pods come and go | Receptionist who knows which staff are at their desks |
| **External Secrets** | Copies a secret from Secrets Manager into a Kubernetes Secret, and refreshes it | Courier who fetches the key from the bank vault into the staff locker |

**Helm**: the package manager for Kubernetes (like `npm install` for cluster software). A chart is a versioned install package; a release is one installed copy.

**EKS Pod Identity**: how a pod gets AWS permissions without access keys. Each add-on has its own IAM role; an *association* links "service account X in namespace Y of this cluster" to that role. The `eks-pod-identity-agent` on each node hands the pod short-lived credentials. Like a staff badge that only opens certain doors and expires every hour.

## Why big tech uses it

- **Managed databases**: running Postgres yourself (patching, disks, failover, backups) is a full-time job. Most teams rent it.
- **Secrets never in Git**: Git history is forever and widely copied. Secrets live in a vault, access is logged, and rotating a password doesn't need a code change.
- **Controllers bridge Kubernetes and the cloud**: apps declare what they need ("this Service needs a load balancer", "this pod needs that secret"), and controllers do the cloud work.
- **No long-lived keys**: an access key in a pod can be stolen and used from anywhere until someone notices. Pod Identity credentials expire within hours, and each role can do only one job (least privilege).

## How it's wired here

```
External Secrets pod ──(Pod Identity role: read snapshot/* only)──> Secrets Manager
        │ creates
        ▼
Kubernetes Secret "DATABASE_URL" ──env──> post-service pod ──TCP 5432, TLS──> RDS (private subnet)
                                                         (allowed: RDS firewall accepts only the EKS node security group)
```

- **Password**: `random_password` (letters and digits only, so it is URL-safe). Nobody types it and it never appears in Git. **It does land in Terraform state**, so the state bucket is private, encrypted and versioned. Production options that keep it out of state: RDS-managed master passwords (`manage_master_user_password`), or Terraform write-only arguments.
- **`ClusterSecretStore`** (`deploy/platform/cluster-secret-store.yaml`) says "the vault is Secrets Manager in ap-southeast-1". It contains no credentials: auth comes from the controller's Pod Identity role. An **`ExternalSecret`** (added with the app in Task 9) says "copy `snapshot/post-service/db` into a Kubernetes Secret".
- **Proof run on 2026-10-26**: a throwaway pod used the synced secret to run `psql` and got back `snapshotdb | app | 10.20.18.5 | 17.9 | ssl=t`. That's a private IP, over TLS, through the security-group rule.
- **Lessons learned while applying:**
  1. `snapshot` is a **reserved database name** in RDS Postgres, so the database is `snapshotdb` (local Docker keeps `snapshot`). Like the Free-plan instance types, `terraform validate` can't know AWS's own rules; only the real API call does.
  2. **Install order matters.** The LB controller adds a *webhook*: every new Kubernetes Service is sent to it for checking. External Secrets was installed in parallel, its Services hit the webhook before the controller's pods were ready, and the install failed. Fix: `depends_on = [helm_release.lb_controller]`, plus `helm uninstall` of the failed release so Terraform could retry.
  3. `psql` doesn't read `DATABASE_URL` by itself; it is passed explicitly (`psql "$DATABASE_URL"`). Our Go service reads it explicitly too.
- **Lab vs production settings:**

| Setting | Lab | Production |
|---|---|---|
| Backups (`backup_retention_period`) | 0 | 7–35 days, point-in-time restore |
| Final snapshot on delete | skipped | always |
| `deletion_protection` | off | on |
| Multi-AZ standby | off | on |
| Secret recovery window | 0 days (instant delete, so the name is reusable next session) | 7–30 days |

## Interview talking points

- "The database sits in private subnets, and its security group only accepts the EKS node security group on 5432. Connections use TLS (`sslmode=require`)."
- "Secrets are in Secrets Manager. External Secrets Operator syncs them into Kubernetes, so Git only holds a pointer, never the value."
- "Controllers get AWS permissions through EKS Pod Identity: per-controller IAM roles, short-lived credentials, no access keys. The secrets controller can only read `snapshot/*`."
- "I disabled backups in my lab because the data was disposable. In production I'd enable PITR, deletion protection, Multi-AZ, and test restores regularly."
- "I hit a webhook ordering race between two Helm charts and fixed it with an explicit dependency. Admission webhooks can block unrelated installs while they're not ready."

## How to tear down

Part of the env layer: `cd infra/env && terraform destroy` (later `make down`). Terraform uninstalls the Helm releases first (they depend on the cluster), then deletes the database without a snapshot and the secret without a recovery window, so the next `apply` can reuse every name.
