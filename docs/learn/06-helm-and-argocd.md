# 06 · Helm and Argo CD (GitOps)

## What it is

**Helm chart**: Kubernetes YAML written once as *templates with blanks*. A values file fills in the blanks. Plain manifests mean copying five near-identical files per service; a chart means one recipe and a small "ingredients" file per service.

```
deploy/charts/service/           one shared chart for every Go service
├── values.yaml                  defaults (2 replicas, probes, resources)
└── templates/
    ├── deployment.yaml          run N copies of the container
    ├── service.yaml             stable in-cluster name in front of the pods
    ├── serviceaccount.yaml      the pod's identity (for Pod Identity later)
    ├── externalsecret.yaml      "copy snapshot/post-service/db from the vault"
    └── targetgroupbinding.yaml  "keep these pod IPs registered in the ALB target group"
deploy/values/post-service.yaml  image repo + tag, which secret to use (CI edits only the tag)
```

**Argo CD**: a GitOps controller running inside the cluster. It watches the Git repo and makes the cluster match it, continuously. Git is the blueprint; Argo CD is the site foreman who checks every few minutes that the building matches.

**Application**: Argo CD's unit of work: "this Git path, rendered this way, goes into this namespace". We have two:
- `platform` → `deploy/platform` (the `ClusterSecretStore`)
- `post-service` → the shared chart + `deploy/values/post-service.yaml` + the target group ARN

## Why big tech uses it

- **Pull, not push.** With push-style CD, a CI server holds admin credentials to every cluster. With GitOps, the cluster pulls from Git, and CI only needs to write to Git.
- **Git is the audit log.** Who changed what, when, and why is a commit. Rollback is `git revert`.
- **Drift correction.** Manual `kubectl` edits are undone automatically (`selfHeal`), and things deleted from Git are deleted from the cluster (`prune`).
- **One chart, many services** keeps every service's safety settings (probes, limits, security) consistent.

## How it's wired here

- **Who owns what:**
  - Terraform installs Argo CD and declares the two Applications (`infra/env/addons.tf`, charts `argo-cd` 10.11.3 and `argocd-apps` 2.0.7). Terraform also injects the one value only it knows: the ALB target group ARN.
  - **Everything inside the apps changes only through Git.**
- **Release flow today (CI automates it in Task 10):**
  1. `make push SERVICE=post-service`: builds a linux/amd64 image and pushes it to ECR, tagged with the git commit (`62f448784a33`). The image is 4.8 MB, a static Go binary on distroless.
  2. Put the tag in `deploy/values/post-service.yaml`, commit, push.
  3. Argo CD sees the commit (polls every ~3 min, or on refresh) and rolls it out.
- **Safety settings in the chart:**
  - Rolling update `maxUnavailable: 0`, `maxSurge: 1`.
  - Liveness `/healthz` (restart if dead) vs readiness `/readyz` (stop traffic if the DB is down).
  - Non-root, read-only root filesystem, no privilege escalation, all Linux capabilities dropped.
  - Memory limit, no CPU limit.
- **TargetGroupBinding**: the LB controller registers the Service's pod IPs into the Terraform-owned target group. Kubernetes never creates or deletes the ALB.
- **Readiness gate**: the `snapshot` namespace carries `elbv2.k8s.aws/pod-readiness-gate-inject=enabled`, so a new pod only counts as Ready once the **ALB** reports it healthy. Gates are injected only into pods created after the TargetGroupBinding exists, so the very first pods had none.
- **Lessons learned:**
  1. **`runAsNonRoot` needs a numeric user.** The Dockerfile said `USER nonroot` (a name), and Kubernetes can't verify a name isn't root, so it refuses to start the pod. Fixed with `USER 65532:65532`.
  2. **Zero-downtime deploys need a pause before shutdown.** On pod deletion, Kubernetes sends SIGTERM *and* starts ALB deregistration at the same time. The app stopped accepting connections while the ALB was still sending to it: 2 failed requests out of 306 during a rollout. Fix: a `preStop` 10 s sleep (Kubernetes' built-in sleep action, since the distroless image has no `sleep` binary). Results:

     | Run | Errors |
     |---|---|
     | Before the fix | 2 / 306 |
     | After the fix, run 1 | 2 / 304 |
     | After the fix, run 2 | 0 / ~500 |

     Better, but not yet proven perfect. ALB deregistration sometimes takes longer than 10 s to propagate; the next step is a 15–20 s pause with a longer grace period.
- **Verified on 2026-10-26:**
  - Both Applications `Synced/Healthy`.
  - `POST https://<cf>/api/posts` → 201, and the next GET lists it immediately (no API caching).
  - An empty caption → 400 JSON.
  - `kubectl scale --replicas=0` was reverted to 2/2 by Argo CD in 12 s.

**Opening the Argo CD UI:**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443
# open https://localhost:8080 (accept the self-signed cert), user: admin
```

## Interview talking points

- "I used one shared Helm chart for all Go services. Each service is a small values file, so probes, limits and security settings stay consistent."
- "Deployment is GitOps with Argo CD: the cluster pulls desired state from Git, CI never holds cluster credentials, and rollback is a `git revert`."
- "Auto-sync with prune and self-heal: I scaled a deployment to zero by hand and Argo CD restored it in about 12 seconds."
- "Terraform owns the ALB; the app only binds pod IPs to it with a TargetGroupBinding, plus readiness gates so a pod isn't Ready until the ALB sees it healthy."
- "I measured errors during rolling updates and fixed the SIGTERM/deregistration race with a preStop delay."

## How to tear down

Part of the env layer (`terraform destroy`, later `make down`). Terraform removes the `argocd-apps` release first. The Applications carry the `resources-finalizer`, so Argo CD deletes what it deployed (pods, TargetGroupBinding, ExternalSecret) before Argo CD itself is uninstalled. Then the rest of the cluster goes.
