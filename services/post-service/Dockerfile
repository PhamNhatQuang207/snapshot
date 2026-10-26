# Stage 1: compile a static binary with the full Go toolchain.
# The build stage runs on the builder's own CPU ($BUILDPLATFORM) and Go cross-compiles
# for the requested target ($TARGETARCH): arm64 for local runs on Apple Silicon,
# amd64 for the x86 EKS nodes (`docker build --platform linux/amd64`). No emulation.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/post-service ./cmd/server

# Stage 2: ship only the binary on a minimal, shell-less, non-root base.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/post-service /post-service
# Numeric UID (distroless "nonroot") so Kubernetes runAsNonRoot can verify it is not root.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/post-service"]
