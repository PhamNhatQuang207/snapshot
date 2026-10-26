#!/usr/bin/env bash
# Build a service image for AWS (linux/amd64) and push it to ECR, tagged with the git commit.
# Usage: scripts/push-image.sh <service>   (prints the tag on the last line)
set -euo pipefail

service="${1:?usage: $0 <service>}"
region="ap-southeast-1"
account="$(aws sts get-caller-identity --query Account --output text)"
registry="${account}.dkr.ecr.${region}.amazonaws.com"
tag="$(git rev-parse --short=12 HEAD)"

if [ -n "$(git status --porcelain -- "services/${service}")" ]; then
  echo "services/${service} has uncommitted changes; commit first so the tag matches the code" >&2
  exit 1
fi

# Short-lived (12h) Docker login token from ECR; no stored registry password.
aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry" >/dev/null

docker build --platform linux/amd64 -t "${registry}/${service}:${tag}" "services/${service}" >&2
docker push "${registry}/${service}:${tag}" >&2
echo "$tag"
