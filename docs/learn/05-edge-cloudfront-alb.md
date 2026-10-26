# 05 · The front door: CloudFront, ALB and the web bucket

## What it is

```
Browser ──HTTPS──> CloudFront (d1kflejc0h3wvx.cloudfront.net; changes every `make up`)
                     ├── /*       → S3 web bucket (React build; private, read only by CloudFront via OAC)
                     └── /api/*   → ALB (HTTP, accepts only CloudFront's IPs)
                                     └── target group (pod IPs) → post-service pods :8080 → RDS
```

- **CDN (CloudFront)**: AWS's worldwide network of servers. It keeps copies of files close to visitors, provides free HTTPS on `*.cloudfront.net`, and is the single public entry point.
- **Origin**: where CloudFront fetches from when it has no copy. We have two: the S3 bucket and the ALB.
- **Behavior**: a path rule ("`/api/*` goes to the ALB, with these cache settings"). The default behavior catches everything else.
- **OAC (Origin Access Control)**: CloudFront signs its requests to S3; the bucket policy accepts only *this* distribution. The bucket itself stays fully private.
- **CloudFront Function**: a tiny piece of JavaScript running at the edge on every request. Ours rewrites `/profile/quang` (no file extension) to `/index.html`, so React's router can show the page.
- **ALB (Application Load Balancer)**: spreads API requests across healthy pods, checking `/readyz` on each.
- **Target group**: the list of pod IPs the ALB sends traffic to. Terraform creates it empty; the LB controller fills it with pod IPs in Task 9.

## Why big tech uses it

- **One entry point** gives one place for HTTPS, caching, DDoS protection (AWS Shield, on by default), and later a web application firewall (WAF).
- **Static files from a CDN** are fast and almost free to serve; no servers needed for the website itself.
- **Private origins**: the bucket and the ALB refuse anyone who doesn't come through CloudFront, so nobody can bypass the front door's protections.
- **Health-checked load balancing** means a broken pod stops getting traffic within seconds, with no human involved.

## How it's wired here

Files: `infra/env/edge.tf`, `infra/env/params.tf`.

- **Two behaviors:**
  - Default (website): `CachingOptimized` policy, GET/HEAD only, gzip/brotli compression, SPA-rewrite function.
  - `/api/*`: `CachingDisabled` (a new post must show up on the next request), all HTTP methods, `AllViewerExceptHostHeader` (forward headers, cookies and query strings, but not `Host`, which must be the ALB's own name).
- **Why SPA routing is a function, not a "custom error page"**: a distribution-wide "404 → index.html" rule would also turn API 404s into an HTML page, breaking API clients. The function runs only on the website behavior.
- **ALB lockdown**: its security group allows port 80 only from the AWS-managed prefix list `com.amazonaws.global.cloudfront.origin-facing` (CloudFront's IP ranges). Nodes accept 8080 only from the ALB's security group.
- **ALB listener**: unknown paths get a fixed JSON 404 `{"error":"not found"}`; `/api/posts` and `/api/posts/*` go to the post-service target group (`target_type = ip`, health check `/readyz`, 15 s drain instead of the default 300 s).
- **Terraform owns the ALB, not a Kubernetes Ingress.** With an Ingress, the LB controller creates the ALB itself, and Terraform doesn't know it exists. At `terraform destroy` that ALB blocks deleting the VPC, a classic teardown failure. Here Terraform creates the ALB and target group, and the controller only registers pod IPs (via a `TargetGroupBinding`, Task 9).
- **SSM parameters** `/snapshot/web_bucket`, `/snapshot/cloudfront_distribution_id`, `/snapshot/cloudfront_domain`: CI reads these to publish the website, because they change on every `make up`.
- **The honest shortcut**: CloudFront → ALB is plain HTTP, because an HTTPS certificate requires owning a domain. Production: a custom domain, an ACM certificate on the ALB, and `https-only` to the origin (plus a secret header or VPC origin so only CloudFront can call it).

**Verified on 2026-10-26** (no pods yet):

| Request | Result | Meaning |
|---|---|---|
| `http://<cf>/` | 301 | redirected to HTTPS |
| `https://<cf>/api/nope` | `{"error":"not found"}` | API 404 stays JSON |
| `https://<cf>/api/posts` | 503 | route works, no healthy pods yet |
| ALB directly | timeout | only CloudFront may connect |
| `https://<cf>/` and `/profile/quang` | 200, `<title>Snapshot</title>` | website + SPA routing |
| `/assets/nope.js` | 403 | real missing files aren't rewritten |
| S3 bucket URL directly | 403 | bucket is private |

## Interview talking points

- "CloudFront is the only public entry point. S3 is private behind OAC, and the ALB only accepts CloudFront's managed prefix list."
- "Static assets are cached at the edge. The API behavior has caching disabled and forwards all viewer headers except Host."
- "I used a CloudFront Function for SPA routing instead of custom error responses, which would have rewritten API 404s into HTML."
- "Terraform owns the ALB and target group. The LB controller only binds pod IPs with a TargetGroupBinding, so teardown never leaves orphaned load balancers blocking VPC deletion."
- "In production I'd add a custom domain with ACM end-to-end TLS, AWS WAF, and access logs."

## How to tear down

Part of the env layer: `terraform destroy` (later `make down`). The web bucket has `force_destroy = true`, so it is deleted even with the build inside. CloudFront takes the longest (a few minutes to disable and delete).
