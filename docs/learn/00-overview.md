# 00 · Project overview

## What it is

Snapshot is a mini photo-sharing app (four Go services + React) whose real purpose is to practise the infrastructure and delivery pipeline used at big tech companies. See the design: `docs/superpowers/specs/2026-10-26-devops-learning-platform-design.md`.

```
services/      Go microservices (post-service first)
frontend/      React app (Vite)
infra/         Terraform: bootstrap (kept) and env (created/destroyed each session)
deploy/        Helm chart + values that Argo CD deploys
.github/       CI/CD pipelines
docs/learn/    these notes, one per topic
```

## Why big tech uses it

Every piece maps to something you'd meet at a large company: infrastructure as code, containers on Kubernetes, GitOps, CI with security scanning, event-driven services, and observability. The app is deliberately small so the attention goes to those.

## How it's wired here

Two Terraform layers:

- **bootstrap**: created once and kept (state bucket, ECR image registry, GitHub CI role). Costs pennies.
- **env**: everything else (network, EKS, database, load balancer, CloudFront). Created at the start of a study session and destroyed at the end, because it costs ~$0.25–0.35/hour while running.

Session routine: `make up` → study / build → `make down`.

## Probe results

2026-10-26: created a bare EKS control plane (`infra/probes/eks`) on the **Free account plan**. It reached `ACTIVE` after 13 minutes, then was destroyed (2.5 minutes). **Go: EKS is available on this account**, so the k3s fallback is not needed.

## Interview talking points

- "I split Terraform into a long-lived bootstrap layer and a disposable environment layer, so I could tear everything down nightly and keep costs near zero."
- "Before committing to EKS I ran a cheap probe, because account-level restrictions are cheaper to discover first than last."

## How to tear down

`make down` (built in Task 11) destroys the env layer. The probe directory is self-contained: `cd infra/probes/eks && terraform destroy`.
