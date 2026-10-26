# 03 · The network (VPC) and the Kubernetes cluster (EKS)

## What it is

**VPC**: your own private network inside AWS. Ours (`infra/env/network.tf`):

```
VPC 10.20.0.0/16
├── AZ a: public 10.20.101.0/24   private 10.20.0.0/19
├── AZ b: public 10.20.102.0/24   private 10.20.32.0/19
├── Internet gateway: front door (public subnets ↔ internet, both directions)
└── NAT gateway (in public-a): one-way door (private subnets → internet only)
```

A subnet is "public" or "private" only because of its **route table**: public sends `0.0.0.0/0` to the internet gateway; private sends it to the NAT gateway.

**EKS**: managed Kubernetes. A cluster has two halves. Think of a restaurant:

| Restaurant | Kubernetes | Who runs it |
|---|---|---|
| Manager's office: takes orders, assigns cooks, replaces missing ones | **Control plane**: API server, etcd (the cluster's database), scheduler, controller-manager | **AWS**, in AWS's own account. You pay $0.10/h and never see the machines. |
| Cooks | **Worker nodes**: EC2 machines running your containers | **You**: a managed node group in `infra/env/eks.tf` |
| Ordering at the front desk | **kubectl** (and later Argo CD) | Talks only to the control plane's API endpoint |

## Why big tech uses it

- **One API for running anything.** You declare *what* should run ("2 copies of post-service"); Kubernetes decides *where*, and keeps it that way.
- **Self-healing.** Controllers continuously compare desired state to actual state and fix differences. Crashes, lost nodes and bad manual edits get corrected without anyone being paged.
- **Managed control plane.** Running etcd and API servers highly available is hard. EKS, GKE and AKS do it for you.
- **Private by default.** Nodes and databases live in private subnets with no inbound route from the internet.

## How it's wired here

**Network decisions**

- **2 availability zones** (separate data centers). EKS and RDS require at least two, and one AZ failing doesn't take everything down.
- **Big private subnets** (8,192 IPs each), because with the VPC CNI *every pod gets a real VPC IP*. Public subnets only need room for the load balancer and the NAT.
- **One NAT gateway**, not one per AZ. It saves about $0.06/h but means AZ b's private subnet depends on AZ a. A deliberate cost-vs-resilience trade-off.
- AWS reserves **5 IPs per subnet**, which is why a /19 shows 8,187 free.

**Cluster decisions** (`infra/env/eks.tf`)

- **Kubernetes 1.37**, the newest in *standard* support. Versions in extended support cost 6× more for the control plane.
- **Access through IAM.** `enable_cluster_creator_admin_permissions` gave IAM user `Quang` an EKS *access entry* with cluster-admin. `kubectl` has no password: each call runs `aws eks get-token` for a 15-minute token.
- **Add-ons:**
  - `vpc-cni`: pod IPs
  - `eks-pod-identity-agent`: AWS permissions for pods
  - `kube-proxy`: Service routing
  - `coredns`: in-cluster DNS
  - The first two install *before* nodes (`before_compute`), or nodes boot without networking.
- **Teardown hygiene:** no control-plane log group and no custom KMS key (`create_kms_key = false`, `encryption_config = null`). Secrets are still encrypted with the AWS-managed key, and nothing is left behind to collide with on the next `apply`.
- **Nodes:** 2 × **spot** instances, types `c7i-flex.large` + `m7i-flex.large` (x86, Amazon Linux 2023), one per AZ.
  - **Lesson learned:** the AWS **Free account plan only launches free-tier-eligible instance types.** `t3.medium` passed an `ec2 run-instances --dry-run` but the real launch failed with *"The specified instance type is not eligible for Free Tier."* A dry run checks permissions, not every account-plan rule.
  - Listing two spot types lets AWS use whichever pool has capacity. It picked one of each.

**What a "blank" cluster already runs** (`kubectl get pods -n kube-system`)

| Kind | Meaning | Examples |
|---|---|---|
| **DaemonSet** | exactly one pod on *every* node | `aws-node` (vpc-cni), `kube-proxy`, `eks-pod-identity-agent` |
| **Deployment** | N copies, placed anywhere | `coredns` (2 copies, spread one per node) |

DaemonSet pods share the node's IP; normal pods get their own VPC IP (e.g. coredns at `10.20.40.76`).

**Seeing the control plane** (you can't log into it, but you can see evidence of it)

- `aws eks describe-cluster`: its endpoint, version and status.
- Network interfaces named "Amazon EKS snapshot" in *our* private subnets, owned by AWS's account (`502263855264`): the control plane's doors into our VPC.
- `kubectl get --raw='/readyz?verbose'` reports `etcd ok`.
- `kubectl get leases -n kube-system` shows `kube-scheduler` and `kube-controller-manager` leaders on AWS machines (172.16.x.x), even though no such pods exist on our nodes.

**Self-healing demo.** Deleting a coredns pod: within ~2 s a replacement was `Running`, and the Deployment never dropped below 2/2 ready.

**Tools to look at a cluster**

- `kubectl`: the CLI.
- **k9s**: a terminal UI.
- **Headlamp**: a desktop GUI. Start it from a terminal with `headlamp` (alias in `~/.zshrc`) so it can find the `aws` CLI. Opened from the Dock it can't, and asks for a token.
- AWS console: **VPC → Resource map** (network diagram) and **EKS → Resources** (log in as IAM user `Quang`).

**Partial applies.** The first apply failed at the node group; that resource was marked **tainted**. Fixing the instance type and re-running `apply` replaced only the tainted node group and created the two add-ons that never got reached. Terraform resumes from wherever it stopped.

## Interview talking points

- "Nodes and data stores sit in private subnets; only the load balancer is public. Outbound traffic goes through NAT."
- "I ran one NAT gateway to save cost and know the trade-off: production uses one per AZ."
- "EKS access is IAM-based via access entries, not the legacy aws-auth ConfigMap. No static kubeconfig credentials."
- "Spot nodes across multiple instance types and AZs cut cost by up to ~70%. Kubernetes reschedules pods if a node is reclaimed."
- "I pin to a Kubernetes version in standard support; extended support multiplies control-plane cost."
- "Kubernetes is a set of reconciliation loops. The control plane holds desired state in etcd, and controllers converge reality toward it."

## How to tear down

```bash
cd infra/env && terraform destroy     # ~10–15 min, 51 resources (later: make down)
```

Then confirm nothing billable remains: no EKS clusters, NAT gateways, Elastic IPs, running EC2 instances or load balancers (`scripts/verify-clean.sh` in Task 11 automates this). Recreate with `terraform apply` (~16 min).
