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
# (kubectl config set can't address exec fields, so edit the file with yq; args stay intact.)
user="$(kubectl config view --minify -o jsonpath='{.users[0].name}')"
kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
kubeconfig="${kubeconfig%%:*}"
U="$user" B="$(command -v aws)" yq -i '(.users[] | select(.name == strenv(U)) | .user.exec.command) = strenv(B)' "$kubeconfig"

echo "==> 3/6 waiting for Argo CD to deploy post-service (max 10 min)"
kubectl -n argocd wait application/post-service --for=jsonpath='{.status.health.status}'=Healthy --timeout=10m >/dev/null

echo "==> 4/6 waiting for the API through CloudFront"
api_up=0
for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "https://$domain/api/posts")" = 200 ]; then api_up=1; break; fi
  sleep 5
done
if [ "$api_up" -ne 1 ]; then
  echo "API not answering at https://$domain/api/posts after 5 min; check: kubectl -n snapshot get pods" >&2
  exit 1
fi

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
if [ "$(curl -s "https://$domain/api/posts" | jq '.posts | length')" -eq 0 ]; then
  scripts/seed.sh "https://$domain"
else
  echo "posts already exist (re-run of make up), skipping seed"
fi

elapsed=$((SECONDS - start))
echo "Snapshot is up: https://$domain  (took $((elapsed / 60))m$((elapsed % 60))s)"
