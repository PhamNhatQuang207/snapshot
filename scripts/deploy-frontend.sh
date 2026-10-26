#!/usr/bin/env bash
# Test, build and publish the React app: S3 upload + CloudFront cache invalidation.
# Bucket and distribution change on every `make up`, so they are read from SSM at run time.
set -euo pipefail

param() { aws ssm get-parameter --name "/snapshot/$1" --query Parameter.Value --output text 2>/dev/null || true; }
bucket="$(param web_bucket)"
distribution="$(param cloudfront_distribution_id)"
if [ -z "$bucket" ] || [ -z "$distribution" ]; then
  echo "env is down, skipping frontend deploy"
  exit 0
fi

cd "$(dirname "$0")/../frontend"
npm ci
npm test
npm run build

# --delete removes files from old builds; hashed asset names mean old and new builds don't collide.
aws s3 sync dist "s3://$bucket" --delete
# Tell CloudFront to drop its cached copies so visitors get the new index.html right away.
aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/*" --query Invalidation.Id --output text
