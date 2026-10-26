# EKS: AWS runs the Kubernetes control plane (API server, scheduler, etcd);
# we run the worker nodes, a managed node group of spot instances in private subnets.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.name
  kubernetes_version = "1.37" # newest in standard support; extended support costs 6x

  # Public API endpoint so kubectl works from a laptop; access still requires IAM auth.
  # Production would restrict endpoint_public_access_cidrs or use a private endpoint + VPN.
  endpoint_public_access = true

  # Who can use the cluster is managed by EKS access entries (IAM), not the old aws-auth ConfigMap.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true # the IAM user running terraform (Quang) becomes cluster admin

  # Teardown hygiene: no control-plane log group and no custom KMS key, so a destroy/create
  # cycle never collides with leftovers. Secrets are still encrypted with the AWS-managed key.
  enabled_log_types           = []
  create_cloudwatch_log_group = false
  create_kms_key              = false
  encryption_config           = null

  addons = {
    vpc-cni                = { before_compute = true } # pod networking: every pod gets a VPC IP; must exist before nodes join
    eks-pod-identity-agent = { before_compute = true } # lets pods assume IAM roles without access keys
    kube-proxy             = {}                        # routes Service IPs to pods on each node
    coredns                = {}                        # in-cluster DNS (post-service.snapshot.svc.cluster.local)
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      ami_type = "AL2023_x86_64_STANDARD" # EKS-optimized Amazon Linux 2023 on x86
      # The Free account plan only launches free-tier-eligible types (t3.medium was refused).
      # c7i-flex.large = 2 vCPU / 4 GiB / 29 pods; m7i-flex.large (8 GiB) is the spot fallback pool.
      instance_types = ["c7i-flex.large", "m7i-flex.large"]
      capacity_type  = "SPOT" # spare capacity, up to ~70% cheaper, can be reclaimed with 2 min notice

      min_size     = 2
      desired_size = 2
      max_size     = 3
    }
  }
}
