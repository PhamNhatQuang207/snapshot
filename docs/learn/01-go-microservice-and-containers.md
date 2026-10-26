# 01 · A Go microservice and its container

## What it is

`services/post-service` is one small Go program with one job: store and list posts. It is a **microservice** because it owns its own data (the `posts` schema), exposes it only through an HTTP API, and can be built, deployed and scaled without touching any other service.

```
cmd/server/main.go          wiring: read env vars, connect DB, run migrations, start HTTP server
internal/posts/post.go      the Post type, the Store interface, caption rules
internal/posts/handler.go   HTTP endpoints → Store calls → JSON
internal/posts/postgres.go  the real Store (Postgres via pgx)
internal/httpserver/run.go  start the server; on SIGTERM stop accepting and drain requests
Dockerfile                  multi-stage build → ~20 MB distroless image
```

Go's `internal/` folder means "only this module can import this", which keeps each service's guts private.

## Why big tech uses it

- **Go** compiles to one static binary with no runtime to install, starts in milliseconds, and uses little memory. That's why Kubernetes, Docker, Terraform and Prometheus are written in it.
- **Containers** make "works on my machine" the same as "works in production": the image *is* the deployable artifact, identical on your laptop, in CI, and on EKS.
- **Small, separately deployable services** let many teams ship independently. The cost is more moving parts. You'll feel that cost in later milestones, and being able to explain it is part of the interview answer.

## How it's wired here

**Configuration comes from environment variables** (`DATABASE_URL`, `PORT`), never from files baked into the image. The same image runs locally (Docker Compose sets `DATABASE_URL` to the local Postgres) and on EKS (a Kubernetes Secret will set it to RDS). This is the [12-factor](https://12factor.net/config) rule.

**Two health endpoints, on purpose:**

| Endpoint | Kubernetes probe | Question it answers | If it fails |
|---|---|---|---|
| `/healthz` | liveness | Is the process alive? | Kubernetes **restarts** the pod |
| `/readyz` | readiness | Can it serve traffic right now (DB reachable)? | Kubernetes **stops sending traffic**, no restart |

If `/healthz` checked the database, a 30-second RDS blip would make Kubernetes restart every pod at once, which turns a small problem into an outage. A unit test (`TestHealthz_Returns200EvenWhenStoreDown`) pins this.

**Graceful shutdown.** During a rolling update, Kubernetes sends each old pod `SIGTERM`. `httpserver.Run` then stops accepting new connections and waits up to 20 s for in-flight requests to finish. Without it, every deploy would drop a few requests. `TestRun_DrainsInFlightRequestOnCancel` proves it.

**Migrations on startup.** `schema.sql` is compiled into the binary (`//go:embed`) and runs every time the service starts. Every statement is `IF NOT EXISTS`, so running it twice, or from two pods at once, is harmless (*idempotent*). If the database is unreachable at startup the process exits, and Kubernetes restarts it with growing delays (`CrashLoopBackOff`) until the DB is up.

**The image.**
- *Multi-stage build:* compile in `golang:1.27-alpine` (~300 MB), then copy only the binary into `distroless/static:nonroot` (~2 MB, no shell, no package manager).
- *Non-root:* the process can't modify the container's system files even if compromised.
- *arm64:* built for Graviton (AWS's ARM CPUs, ~20% cheaper), the same architecture as an Apple Silicon Mac.

**Tests.** Handler tests use an in-memory `fakeStore`, so they run in milliseconds. The Postgres test runs against the real database from Docker Compose:
```bash
docker compose up -d postgres
cd services/post-service
POSTS_TEST_DATABASE_URL='postgres://app:local@localhost:5433/snapshot?sslmode=disable' go test ./...
```

## Interview talking points

- "Liveness and readiness are different questions. Liveness never checks dependencies, otherwise a database blip triggers a restart storm."
- "Services handle SIGTERM and drain in-flight requests, so rolling deploys have zero errors."
- "Config comes from env vars, so one immutable image is promoted through every environment."
- "Images are multi-stage, distroless and non-root: small attack surface, fewer CVEs for the scanner to flag."
- "Migrations are idempotent and run at startup. At larger scale I'd move them to a separate Kubernetes Job or a tool like Atlas or golang-migrate, so schema changes are reviewed and run exactly once."

## How to tear down

Local only: `docker compose down` stops the containers; `docker compose down -v` also deletes the local database data.
