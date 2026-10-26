# Network: one VPC across two availability zones.
# Public subnets hold internet-facing things (load balancer, NAT gateway).
# Private subnets hold everything else (EKS nodes and pods, RDS); they reach the
# internet only outbound, through the NAT gateway.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.name
  cidr = "10.20.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.20.0.0/19", "10.20.32.0/19"]    # large: every EKS pod gets a VPC IP
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24"] # small: load balancer + NAT only

  enable_nat_gateway = true
  single_nat_gateway = true # one NAT (~$0.06/h) instead of one per AZ; trades AZ resilience for cost

  # Where Kubernetes may place load balancers (internet-facing vs internal).
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}
