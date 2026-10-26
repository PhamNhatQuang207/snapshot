# Session commands, run from your laptop with your own AWS login.
#   make bootstrap   once: state bucket, ECR, GitHub CI role (kept forever, pennies/month)
#   make up          start a session: everything else (~25 min, ~$0.30/h while up)
#   make down        end a session: destroy everything, then check nothing billable is left
.PHONY: bootstrap up down verify-clean push

bootstrap:
	terraform -chdir=infra/bootstrap init -input=false
	terraform -chdir=infra/bootstrap apply

up:
	@scripts/up.sh

down:
	terraform -chdir=infra/env init -input=false >/dev/null
	terraform -chdir=infra/env destroy -auto-approve -input=false
	@scripts/verify-clean.sh

verify-clean:
	@scripts/verify-clean.sh

# Build and push a service image to ECR: make push SERVICE=post-service
push:
	@test -n "$(SERVICE)" || (echo "usage: make push SERVICE=<service>" && exit 1)
	@scripts/push-image.sh $(SERVICE)
