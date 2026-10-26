# Session commands. More targets (up, down, verify-clean) arrive in Task 11.
.PHONY: push

# Build and push a service image to ECR: make push SERVICE=post-service
push:
	@test -n "$(SERVICE)" || (echo "usage: make push SERVICE=<service>" && exit 1)
	@scripts/push-image.sh $(SERVICE)
