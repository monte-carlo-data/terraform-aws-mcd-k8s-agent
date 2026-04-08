locals {
  mcd_agent_service_name    = "REMOTE_AGENT"
  mcd_agent_deployment_type = "TERRAFORM"

  cluster_name           = var.cluster.name != null ? var.cluster.name : "mcd-agent-${random_id.mcd_agent_id.hex}"
  effective_cluster_name = var.cluster.create ? module.eks[0].cluster_name : var.cluster.existing_cluster_name
  namespace              = var.agent.namespace
  service_account_name   = "mcd-agent-service-account"

  mcd_agent_store_name        = "mcd-agent-store-${random_id.mcd_agent_id.hex}"
  mcd_agent_store_data_prefix = "mcd/"
  effective_bucket_name       = var.storage.create_bucket ? aws_s3_bucket.mcd_agent_store[0].id : var.storage.existing_bucket_name

  effective_vpc_id             = var.networking.create_vpc ? module.vpc[0].vpc_id : var.networking.existing_vpc_id
  effective_private_subnet_ids = var.networking.create_vpc ? module.vpc[0].private_subnets : var.networking.existing_private_subnet_ids
  effective_azs                = length(var.networking.availability_zones) > 0 ? var.networking.availability_zones : data.aws_availability_zones.available.names

  cluster_endpoint       = var.cluster.create ? module.eks[0].cluster_endpoint : data.aws_eks_cluster.existing[0].endpoint
  cluster_ca_certificate = base64decode(var.cluster.create ? module.eks[0].cluster_certificate_authority_data : data.aws_eks_cluster.existing[0].certificate_authority[0].data)
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {}

data "aws_eks_cluster" "existing" {
  count = var.cluster.create ? 0 : 1
  name  = var.cluster.existing_cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = local.effective_cluster_name
}

# -----------------------------------------------------------------------------
# Random ID
# -----------------------------------------------------------------------------

resource "random_id" "mcd_agent_id" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# VPC (conditional)
# -----------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"
  count   = var.networking.create_vpc ? 1 : 0

  name = "${local.cluster_name}-vpc"
  cidr = var.networking.vpc_cidr
  azs  = local.effective_azs

  private_subnets = var.networking.private_subnet_cidrs
  public_subnets  = var.networking.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# -----------------------------------------------------------------------------
# EKS Cluster (conditional)
# -----------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.10.1"
  count   = var.cluster.create ? 1 : 0

  name               = local.cluster_name
  kubernetes_version = var.cluster.kubernetes_version

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  compute_config = var.cluster.compute_config

  vpc_id     = local.effective_vpc_id
  subnet_ids = local.effective_private_subnet_ids
}

# -----------------------------------------------------------------------------
# S3 Storage (conditional)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "mcd_agent_store" {
  count  = var.storage.create_bucket ? 1 : 0
  bucket = local.mcd_agent_store_name
}

resource "aws_s3_bucket_lifecycle_configuration" "mcd_agent_store_lifecycle" {
  count  = var.storage.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.mcd_agent_store[0].id

  rule {
    id = "${local.mcd_agent_store_name}-obj-expiration"
    expiration {
      days = 90
    }
    filter {
      prefix = local.mcd_agent_store_data_prefix
    }
    status = "Enabled"
  }

  rule {
    id = "${local.mcd_agent_store_name}-tmp-expiration"
    expiration {
      days = 2
    }
    filter {
      prefix = "${local.mcd_agent_store_data_prefix}tmp"
    }
    status = "Enabled"
  }

  rule {
    id = "${local.mcd_agent_store_name}-response-expiration"
    expiration {
      days = 1
    }
    filter {
      prefix = "${local.mcd_agent_store_data_prefix}responses"
    }
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "mcd_agent_store_block_public_access" {
  count                   = var.storage.create_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.mcd_agent_store[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mcd_agent_store_encryption" {
  count  = var.storage.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.mcd_agent_store[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "mcd_agent_store_ssl_policy" {
  count  = var.storage.create_bucket && var.storage.create_bucket_policy ? 1 : 0
  bucket = aws_s3_bucket.mcd_agent_store[0].id

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "DenyActionsWithoutSSL",
        "Effect" : "Deny",
        "Principal" : {
          "AWS" : "*"
        },
        "Action" : "*",
        "Resource" : [
          aws_s3_bucket.mcd_agent_store[0].arn,
          "${aws_s3_bucket.mcd_agent_store[0].arn}/*"
        ],
        "Condition" : {
          "Bool" : {
            "aws:SecureTransport" : "false"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM - Pod Identity Role
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}

resource "aws_iam_role" "pod_identity" {
  name               = "${local.effective_cluster_name}-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_eks_pod_identity_association" "agent_association" {
  cluster_name    = local.effective_cluster_name
  namespace       = local.namespace
  service_account = local.service_account_name
  role_arn        = aws_iam_role.pod_identity.arn
}

resource "aws_iam_role_policy" "mcd_agent_service_s3_policy" {
  name = "s3_policy"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action" : [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketPolicyStatus",
          "s3:GetBucketAcl"
        ],
        "Resource" : var.storage.create_bucket ? [
          aws_s3_bucket.mcd_agent_store[0].arn,
          "${aws_s3_bucket.mcd_agent_store[0].arn}/*"
          ] : [
          "arn:${data.aws_partition.current.partition}:s3:::${var.storage.existing_bucket_name}",
          "arn:${data.aws_partition.current.partition}:s3:::${var.storage.existing_bucket_name}/*"
        ],
        "Effect" : "Allow"
      }
    ]
  })
  role = aws_iam_role.pod_identity.id
}

# -----------------------------------------------------------------------------
# IAM - ESO Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eso_role" {
  name               = "${local.effective_cluster_name}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_eks_pod_identity_association" "eso_association" {
  cluster_name    = local.effective_cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso_role.arn
}

data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.eso_role.arn]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}

resource "aws_iam_role" "mcd_secrets_access_role" {
  name               = "${local.effective_cluster_name}-mcd-agent-secrets-access"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json
}

resource "aws_iam_role_policy" "mcd_agent_token_secret_access" {
  name = "mcd_agent_token_secret_access"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action" : [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ],
        "Resource" : concat(
          var.token_secret.create ? [
            aws_secretsmanager_secret.mcd_agent_token[0].arn
            ] : [
            "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.token_secret.name}*"
          ],
          [for s in var.integration_secrets :
            "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${s.remote_ref_key}*"
          ]
        ),
        "Effect" : "Allow"
      },
      {
        "Action" : [
          "secretsmanager:ListSecrets"
        ],
        "Resource" : "*",
        "Effect" : "Allow"
      }
    ]
  })
  role = aws_iam_role.mcd_secrets_access_role.id
}

# -----------------------------------------------------------------------------
# Secrets Manager (conditional)
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "mcd_agent_token" {
  count                          = var.token_secret.create ? 1 : 0
  name                           = var.token_secret.name
  force_overwrite_replica_secret = true
}

resource "aws_secretsmanager_secret_version" "mcd_agent_token_version" {
  count     = var.token_secret.create ? 1 : 0
  secret_id = aws_secretsmanager_secret.mcd_agent_token[0].id
  secret_string = jsonencode({
    "mcd_id"    = var.token_credentials.mcd_id != null ? var.token_credentials.mcd_id : ""
    "mcd_token" = var.token_credentials.mcd_token != null ? var.token_credentials.mcd_token : ""
  })
}

# -----------------------------------------------------------------------------
# Helm - External Secrets Operator (conditional)
# -----------------------------------------------------------------------------

resource "helm_release" "external_secrets" {
  count            = var.helm.install_external_secrets_operator ? 1 : 0
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# Helm - Agent (conditional)
# -----------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "mcd_agent" {
  count = var.helm.deploy_agent ? 1 : 0

  metadata {
    name = local.namespace

    labels = {
      "app.kubernetes.io/managed-by" = "Helm"
    }

    annotations = {
      "meta.helm.sh/release-name"      = "mcd-agent"
      "meta.helm.sh/release-namespace" = local.namespace
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "mcd_agent" {
  count            = var.helm.deploy_agent ? 1 : 0
  name             = "mcd-agent"
  repository       = var.helm.chart_repository
  chart            = var.helm.chart_name
  version          = var.helm.chart_version
  namespace        = local.namespace
  create_namespace = false

  values = [local.helm_values_yaml]

  depends_on = [
    module.eks,
    helm_release.external_secrets,
    kubernetes_namespace_v1.mcd_agent
  ]
}

locals {
  base_helm_values = {
    namespace    = local.namespace
    replicaCount = var.agent.replica_count

    image = {
      repository = split(":", var.agent.image)[0]
      pullPolicy = "IfNotPresent"
      tag        = length(split(":", var.agent.image)) > 1 ? split(":", var.agent.image)[1] : "latest-generic"
    }

    container = {
      backendServiceUrl = var.backend_service_url
      storageBucketName = local.effective_bucket_name
      storageType       = "S3"
    }

    secretStore = {
      provider = {
        aws = {
          role    = aws_iam_role.mcd_secrets_access_role.arn
          region  = var.region
          service = "SecretsManager"
        }
      }
    }

    tokenSecret = {
      remoteRef = {
        key = var.token_secret.name
      }
    }

    integrationsSecrets = {
      data = [for s in var.integration_secrets : {
        secretKey = s.secret_key
        remoteRef = {
          key = s.remote_ref_key
        }
      }]
    }

    logsCollector    = { enabled = var.helm.enabled_logs_collector }
    metricsCollector = { enabled = var.helm.enabled_metrics_collector }
  }

  # Merge custom_values over base, then re-apply collector merges
  # so the typed boolean toggles always win
  helm_values = merge(local.base_helm_values, var.custom_values, {
    logsCollector = merge(
      try(var.custom_values.logsCollector, {}),
      { enabled = var.helm.enabled_logs_collector }
    )
    metricsCollector = merge(
      try(var.custom_values.metricsCollector, {}),
      { enabled = var.helm.enabled_metrics_collector }
    )
  })

  helm_values_yaml = yamlencode(local.helm_values)
}
