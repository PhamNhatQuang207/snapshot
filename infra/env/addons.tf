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

# --- Argo CD (GitOps) ---------------------------------------------------------
# Argo CD runs in the cluster, watches the Git repo, and makes the cluster match it.
# Terraform installs Argo CD and declares *which* apps to watch; what runs inside
# those apps (image tags, replicas...) is changed only through Git.

resource "helm_release" "argo_cd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.3"
  namespace        = "argocd"
  create_namespace = true

  # Trimmed for small nodes: no SSO (dex), no notifications, no ApplicationSets.
  values = [yamlencode({
    dex            = { enabled = false }
    notifications  = { enabled = false }
    applicationSet = { replicas = 0 }
  })]

  depends_on = [module.eks, helm_release.lb_controller]
}

locals {
  argocd_app_defaults = {
    namespace  = "argocd"
    project    = "default"
    finalizers = ["resources-finalizer.argocd.argoproj.io"] # deleting the app deletes what it deployed
    syncPolicy = {
      automated   = { prune = true, selfHeal = true } # remove what left Git; undo manual edits
      syncOptions = ["CreateNamespace=true"]
    }
  }
}

resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.7"
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      # Cluster-wide platform objects (e.g. the ClusterSecretStore).
      platform = merge(local.argocd_app_defaults, {
        source      = { repoURL = var.github_repo_url, targetRevision = "main", path = "deploy/platform" }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
      })

      # post-service = shared chart + its values file + the target group ARN only Terraform knows.
      post-service = merge(local.argocd_app_defaults, {
        source = {
          repoURL        = var.github_repo_url
          targetRevision = "main"
          path           = "deploy/charts/service"
          helm = {
            releaseName = "post-service"
            valueFiles  = ["../../values/post-service.yaml"]
            parameters  = [{ name = "targetGroupARN", value = aws_lb_target_group.post_service.arn }]
          }
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "snapshot" }
        syncPolicy = merge(local.argocd_app_defaults.syncPolicy, {
          # A new pod only counts as ready once the ALB sees it healthy, so rolling updates never drop traffic.
          managedNamespaceMetadata = { labels = { "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled" } }
        })
      })
    }
  })]

  depends_on = [helm_release.argo_cd]
}
