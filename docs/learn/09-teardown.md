# 09 · Teardown: why order matters and what gets orphaned

## What it is

Destroying a cloud environment is harder than creating it. Resources depend on each other, and some are created **outside** Terraform (by Kubernetes controllers), so Terraform doesn't know to delete them. Anything left behind can keep billing, and can block the *next* `terraform apply` from reusing the same names.

## Why big tech uses it

Orphaned resources are one of the most common sources of surprise cloud bills: forgotten load balancers, detached disks, unused Elastic IPs, old snapshots. Companies run "janitor" jobs and tag policies (`project=…`, `owner=…`) to find them. Our `verify-clean.sh` is a tiny version of that.

## How it's wired here

**Teardown order (Terraform works it out from dependencies):**

1. `argocd-apps` release. The Applications carry the `resources-finalizer.argocd.argoproj.io` finalizer, so Argo CD first deletes what it deployed: pods, Service, TargetGroupBinding (the LB controller deregisters pod IPs), ExternalSecret.
2. Argo CD, External Secrets and the LB controller releases. They depend on the cluster, so they go while it still exists.
3. CloudFront, ALB, target group, web bucket (`force_destroy = true`), SSM parameters.
4. RDS (`skip_final_snapshot = true`), the secret (`recovery_window_in_days = 0`), the node group, the EKS cluster.
5. NAT gateway and its Elastic IP, subnets, then the VPC.

**Design choices that make teardown clean:**

| Choice | Prevents |
|---|---|
| Terraform owns the ALB (`TargetGroupBinding`, not an Ingress) | An ALB created by Kubernetes, unknown to Terraform, blocking VPC deletion |
| Secret `recovery_window_in_days = 0` | "Secret is scheduled for deletion" error on the next apply |
| `skip_final_snapshot`, no backups | Snapshots piling up and billing after every session |
| No EKS control-plane log group, no custom KMS key | "Already exists" log group / KMS alias errors on the next apply |
| `force_destroy` on the web bucket | "Bucket not empty" errors |
| No PersistentVolumes in the cluster (yet) | Detached EBS disks left behind (they survive a cluster deletion) |

**Real incident (2026-10-26): the first destroy hung.** Terraform uninstalled External Secrets *at the same time* as it deleted the Argo CD apps. Argo CD then tried to delete the `ExternalSecret`, but that object carries a finalizer that only the External Secrets controller can remove, and the controller was already gone. So the ExternalSecret could never be deleted, the Application never finished deleting, and `helm uninstall argocd-apps` waited forever. The `TargetGroupBinding` (LB controller finalizer) also stayed stuck.
- **Fix in code:** `helm_release.argocd_apps` now `depends_on` the External Secrets and LB controller releases. Terraform destroys in reverse dependency order, so the apps are deleted while the controllers that own their finalizers are still running.
- **Recovery by hand:** `kubectl patch <object> --type=merge -p '{"metadata":{"finalizers":null}}'` on the stuck objects, then rerun the destroy. Removing a finalizer skips the controller's cleanup, so only do it when that cleanup no longer matters (here the cluster itself was being deleted).

**`scripts/verify-clean.sh`** asks the AWS API directly for: EKS clusters, NAT gateways, Elastic IPs, load balancers named `snapshot*`, RDS instances `snapshot*`, running EC2 instances tagged `project=snapshot`, unattached EBS volumes, and CloudFront distributions with comment `snapshot`. Mid-destroy on 2026-10-26 it listed the cluster, the ALB, RDS, CloudFront and the Elastic IPs (exit 1). After the destroy it printed `clean: nothing billable left`.

**Finding orphans by hand:**

```bash
# Everything still tagged with the project (any service, any region in the call):
aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=snapshot --query 'ResourceTagMappingList[].ResourceARN'
# Load balancers created by the LB controller would carry this tag:
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'
aws elbv2 describe-tags --resource-arns <arn>   # look for elbv2.k8s.aws/cluster
# Detached disks:
aws ec2 describe-volumes --filters Name=status,Values=available
```

If Terraform's destroy is stuck on the VPC, something else still has a network interface in it: `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>` shows what.

## Interview talking points

- "Teardown order matters: in-cluster controllers must clean up their cloud resources before the cluster disappears, so the Argo CD Applications use the resources finalizer."
- "I kept every AWS resource Terraform-owned. Controllers only *bind* to them, so `terraform destroy` never leaves orphans."
- "I verify teardown against the AWS API, including classic orphans like detached EBS volumes and unattached Elastic IPs."

## How to tear down

This note *is* the teardown guide: `make down`, then follow the hand checks above if `verify-clean` lists anything.
