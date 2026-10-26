#!/usr/bin/env bash
# After `make down`: ask AWS directly whether anything billable from the env layer is left.
# Exits 1 and lists what it found; prints "clean: nothing billable left" otherwise.
set -euo pipefail

export AWS_REGION=ap-southeast-1
found=0

check() { # check <label> <aws command...>: runs the query; any AWS error aborts (never "clean" by mistake)
  local label="$1" items
  shift
  if ! items="$("$@")"; then
    echo "ERROR: could not check $label (credentials or permissions?)" >&2
    exit 2
  fi
  if [ -n "${items// /}" ] && [ "$items" != "None" ]; then
    echo "LEFT: $label: $items"
    found=1
  fi
}

check "EKS clusters" aws eks list-clusters --query 'clusters' --output text
check "NAT gateways" aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text
check "Elastic IPs" aws ec2 describe-addresses --query 'Addresses[].PublicIp' --output text
check "Load balancers" aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'snapshot')].LoadBalancerName" --output text
check "RDS instances" aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier, 'snapshot')].DBInstanceIdentifier" --output text
check "EC2 instances" aws ec2 describe-instances --filters Name=tag:project,Values=snapshot Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].InstanceId' --output text
# Detached disks keep billing; Kubernetes volumes are a classic orphan after a cluster is deleted.
check "Unattached EBS volumes" aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
check "CloudFront distributions" aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='snapshot'].Id" --output text

if [ "$found" -eq 0 ]; then
  echo "clean: nothing billable left"
fi
exit "$found"
