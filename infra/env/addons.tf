# Cluster add-ons: controllers that teach Kubernetes about AWS.
#   - AWS Load Balancer Controller: registers pod IPs with AWS load balancers (used from Task 8).
#   - External Secrets: copies secrets from AWS Secrets Manager into Kubernetes Secrets.
# Each gets its own IAM role through EKS Pod Identity: short-lived credentials, no access keys.

data "aws_caller_identity" "current" {}

# Terraform talks to the cluster's API with the same short-lived token kubectl uses.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

# --- AWS Load Balancer Controller ---------------------------------------------

module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name                            = "${var.name}-aws-lbc"
  attach_aws_lb_controller_policy = true # the controller's official IAM policy

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.2"
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName    = module.eks.cluster_name
    serviceAccount = { name = "aws-load-balancer-controller" }
    # Given explicitly: pods can't read them from instance metadata (EKS nodes limit IMDS to 1 hop).
    region = var.region
    vpcId  = module.vpc.vpc_id
  })]

  # Role must exist before the pods start, and on destroy the release goes first,
  # while the cluster and nodes are still there to uninstall it from.
  depends_on = [module.eks, module.lb_controller_pod_identity]
}

# --- External Secrets ---------------------------------------------------------

module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name                           = "${var.name}-external-secrets"
  attach_external_secrets_policy = true
  # Read access only to this project's secrets (snapshot/...), not every secret in the account.
  external_secrets_secrets_manager_arns = [
    "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name}/*"
  ]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.14.0"
  namespace        = "external-secrets"
  create_namespace = true

  values = [yamlencode({
    serviceAccount = { name = "external-secrets" }
  })]

  # The LB controller's webhook checks every new Kubernetes Service. Installing this chart
  # (which creates Services) before that webhook is ready fails, so install it second.
  depends_on = [module.eks, module.external_secrets_pod_identity, helm_release.lb_controller]
}
