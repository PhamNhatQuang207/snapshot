# Stage 1: compile a static arm64 binary with the full Go toolchain.
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o /out/post-service ./cmd/server

# Stage 2: ship only the binary on a minimal, shell-less, non-root base.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/post-service /post-service
USER nonroot
EXPOSE 8080
ENTRYPOINT ["/post-service"]
