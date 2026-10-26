#!/usr/bin/env bash
# Bring up a whole study session: infrastructure, app, website, demo data.
set -euo pipefail
cd "$(dirname "$0")/.."
start=$SECONDS
region=ap-southeast-1

echo "==> 1/6 terraform apply (network, EKS, RDS, add-ons, ALB, CloudFront, Argo CD) ~20 min"
terraform -chdir=infra/env init -input=false >/dev/null
terraform -chdir=infra/env apply -auto-approve -input=false
domain="$(terraform -chdir=infra/env output -raw cloudfront_domain)"

echo "==> 2/6 kubeconfig"
aws eks update-kubeconfig --name snapshot --region "$region" >/dev/null
# GUI apps (Headlamp) don't get the shell's PATH, so point kubeconfig at the absolute aws binary.
user="$(kubectl config view --minify -o jsonpath='{.users[0].name}')"
kubectl config set "users.${user}.exec.command" "$(command -v aws)" >/dev/null

echo "==> 3/6 waiting for Argo CD to deploy post-service (max 10 min)"
kubectl -n argocd wait application/post-service --for=jsonpath='{.status.health.status}'=Healthy --timeout=10m >/dev/null

echo "==> 4/6 waiting for the API through CloudFront"
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "https://$domain/api/posts")" = 200 ] && break
  sleep 5
done

echo "==> 5/6 website (build, upload to S3, invalidate CloudFront)"
if [ -s "$HOME/.nvm/nvm.sh" ]; then # use the Node version pinned in frontend/.nvmrc
  set +u
  # shellcheck disable=SC1091
  source "$HOME/.nvm/nvm.sh"
  nvm use "$(cat frontend/.nvmrc)" >/dev/null
  set -u
fi
scripts/deploy-frontend.sh >/dev/null

echo "==> 6/6 demo data"
scripts/seed.sh "https://$domain"

elapsed=$((SECONDS - start))
echo "Snapshot is up: https://$domain  (took $((elapsed / 60))m$((elapsed % 60))s)"
