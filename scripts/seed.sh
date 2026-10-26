#!/usr/bin/env bash
# Create demo posts so a fresh environment isn't empty (data is wiped on every `make down`).
# Usage: scripts/seed.sh https://dxxxx.cloudfront.net
set -euo pipefail

base="${1:?usage: $0 <base_url>}"
captions=(
  "Sunrise over the Saigon river"
  "First deploy through Argo CD"
  "Coffee, code, Kubernetes"
  "Terraform plan: 0 to destroy"
  "Hello from EKS in Singapore"
)

for caption in "${captions[@]}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/api/posts" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg c "$caption" '{caption: $c}')")"
  if [ "$code" != 201 ]; then
    echo "seed failed: \"$caption\" -> HTTP $code" >&2
    exit 1
  fi
done
echo "seeded ${#captions[@]} posts"
