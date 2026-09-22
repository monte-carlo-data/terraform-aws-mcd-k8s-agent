locals {
  mcd_agent_service_name    = "REMOTE_AGENT"
  mcd_agent_deployment_type = "TERRAFORM"

  region = data.aws_region.current.region

  default_tags = merge(var.custom_default_tags, {
    "mcd-agent-service-name"    = lower(local.mcd_agent_service_name)
    "mcd-agent-deployment-type" = lower(local.mcd_agent_deployment_type)
  })

  cluster_name             = var.cluster.name != null ? var.cluster.name : "mcd-agent-${random_id.mcd_agent_id.hex}"
  effective_cluster_name   = var.cluster.create ? module.eks[0].cluster_name : var.cluster.existing_cluster_name
  namespace                = var.agent.namespace
  service_account_name     = "mcd-agent-service-account"
  eso_namespace            = "external-secrets"
  eso_service_account_name = "external-secrets"

  mcd_agent_store_name        = "mcd-agent-store-${random_id.mcd_agent_id.hex}"
  mcd_agent_store_data_prefix = "mcd/"
  effective_bucket_name       = var.storage.create_bucket ? aws_s3_bucket.mcd_agent_store[0].id : var.storage.existing_bucket_name

  effective_vpc_id             = var.networking.create_vpc ? module.vpc[0].vpc_id : var.networking.existing_vpc_id
  effective_private_subnet_ids = var.networking.create_vpc ? module.vpc[0].private_subnets : var.networking.existing_private_subnet_ids
  effective_azs                = length(var.networking.availability_zones) > 0 ? var.networking.availability_zones : data.aws_availability_zones.available.names

  cluster_endpoint       = var.cluster.create ? module.eks[0].cluster_endpoint : data.aws_eks_cluster.existing[0].endpoint
  cluster_ca_certificate = base64decode(var.cluster.create ? module.eks[0].cluster_certificate_authority_data : data.aws_eks_cluster.existing[0].certificate_authority[0].data)

  use_oauth           = var.oauth_credentials != null || var.oauth_secret != null
  create_oauth_secret = var.oauth_credentials != null && (var.oauth_secret == null || var.oauth_secret.create)
  oauth_secret_name   = var.oauth_secret != null ? var.oauth_secret.name : "mcd/agent/oauth"

  # --- Identity (Pod Identity vs IRSA) ---

  use_irsa = var.identity.mode == "irsa"

  creating_agent_role = var.identity.existing_agent_role_arn == null
  agent_role_arn      = var.identity.existing_agent_role_arn != null ? var.identity.existing_agent_role_arn : aws_iam_role.agent[0].arn

  # Created only when the module installs its own ESO release: a pre-existing
  # operator already runs under identity.existing_eso_role_arn (required by
  # validation whenever one is reused), and the module's role would be unused
  # while colliding by name with the existing "<cluster>-eso-role".
  creating_eso_role      = var.helm.install_external_secrets_operator
  eso_role_arn           = one(aws_iam_role.eso_role[*].arn)
  effective_eso_role_arn = local.creating_eso_role ? local.eso_role_arn : var.identity.existing_eso_role_arn

  oidc_provider_arn = (
    var.identity.oidc_provider_arn != null ? var.identity.oidc_provider_arn :
    var.cluster.create ? module.eks[0].oidc_provider_arn :
    one(data.aws_iam_openid_connect_provider.existing[*].arn)
  )

  # Issuer host/path as used in the :sub / :aud condition keys; derived from
  # the ARN so the provider pair can never disagree. Falls back to a sentinel
  # when no provider is in play (pod_identity mode, or irsa with both roles
  # customer-supplied): irsa_trust_policy is eagerly evaluated in every
  # permutation, but in those it is never attached to any role.
  oidc_provider_id = try(split("oidc-provider/", local.oidc_provider_arn)[1], "no-oidc-provider")

  # Referenced only when use_irsa; in pod_identity mode the Federated principal
  # resolves to null but the policy is never attached to anything.
  irsa_trust_policy = {
    agent = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = local.oidc_provider_arn }
        Condition = {
          StringEquals = {
            "${local.oidc_provider_id}:sub" = "system:serviceaccount:${local.namespace}:${local.service_account_name}"
            "${local.oidc_provider_id}:aud" = ["sts.amazonaws.com"]
          }
        }
      }]
    })
    eso = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = local.oidc_provider_arn }
        Condition = {
          StringEquals = {
            "${local.oidc_provider_id}:sub" = "system:serviceaccount:${local.eso_namespace}:${local.eso_service_account_name}"
            "${local.oidc_provider_id}:aud" = ["sts.amazonaws.com"]
          }
        }
      }]
    })
  }
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {}
data "aws_region" "current" {}

data "aws_eks_cluster" "existing" {
  count = var.cluster.create ? 0 : 1
  name  = var.cluster.existing_cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = local.effective_cluster_name
}

# IRSA on an existing cluster: look up the cluster's IAM OIDC identity provider
# by issuer URL. Plan fails when none exists — the cluster must have IRSA
# enabled before mode = "irsa" can be used. Skipped when no IRSA role is
# created (both roles customer-supplied), so no lookup permissions are needed.
data "aws_iam_openid_connect_provider" "existing" {
  count = (
    !var.cluster.create && local.use_irsa && var.identity.oidc_provider_arn == null &&
    (local.creating_agent_role || local.creating_eso_role)
  ) ? 1 : 0
  url = data.aws_eks_cluster.existing[0].identity[0].oidc[0].issuer
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
  tags = local.default_tags

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
  tags               = local.default_tags

  # Left unset by default so AWS applies its own default (EXTENDED). Opting in
  # to STANDARD means AWS force upgrades the cluster once standard support ends
  # rather than moving it to paid extended support.
  upgrade_policy = var.cluster.upgrade_policy == null ? null : {
    support_type = var.cluster.upgrade_policy
  }

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # Pod Identity agent is only needed for the default identity mode; in irsa
  # mode the service-account annotations are the whole mechanism.
  addons = local.use_irsa ? {} : {
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
  tags   = local.default_tags
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
# IAM - Agent Role (Pod Identity or IRSA)
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

resource "aws_iam_role" "agent" {
  # Skipped when the customer supplies their own agent role: the module's role
  # would be unused, and their role must carry the agent's permissions itself.
  count = local.creating_agent_role ? 1 : 0

  name = local.use_irsa ? "${local.effective_cluster_name}-irsa" : "${local.effective_cluster_name}-pod-identity"

  assume_role_policy = local.use_irsa ? local.irsa_trust_policy.agent : data.aws_iam_policy_document.assume_role.json
  tags               = local.default_tags
}

# Indexed target: the pre-rename resource had no count, this one does, so the
# unkeyed address would land on a no-key instance that no longer exists in
# config (destroy + recreate instead of a move).
moved {
  from = aws_iam_role.pod_identity
  to   = aws_iam_role.agent[0]
}

resource "aws_eks_pod_identity_association" "agent_association" {
  count = local.use_irsa ? 0 : 1

  cluster_name    = local.effective_cluster_name
  namespace       = local.namespace
  service_account = local.service_account_name
  role_arn        = local.agent_role_arn
  tags            = local.default_tags
}

resource "aws_iam_role_policy" "mcd_agent_service_s3_policy" {
  # Skipped when the customer supplies their own role: the S3 permissions are
  # part of the documented policy that role must already carry.
  count = local.creating_agent_role ? 1 : 0

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
  role = aws_iam_role.agent[0].id
}

# -----------------------------------------------------------------------------
# IAM - ESO Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eso_role" {
  count = local.creating_eso_role ? 1 : 0

  name = "${local.effective_cluster_name}-eso-role"

  # In irsa mode this role is bound by the service-account annotation on the
  # module-installed ESO release; with a pre-existing ESO it is not created at
  # all and identity.existing_eso_role_arn takes over instead (see above).
  assume_role_policy = local.use_irsa ? local.irsa_trust_policy.eso : data.aws_iam_policy_document.assume_role.json
  tags               = local.default_tags
}

resource "aws_eks_pod_identity_association" "eso_association" {
  # Created only for the module-installed ESO in pod_identity mode: in irsa
  # mode the annotation binds ESO instead, and a pre-existing operator must
  # keep whatever identity it already uses — this association would rebind the
  # shared external-secrets service account away from it.
  count = local.use_irsa || !local.creating_eso_role ? 0 : 1

  cluster_name    = local.effective_cluster_name
  namespace       = local.eso_namespace
  service_account = local.eso_service_account_name
  role_arn        = local.eso_role_arn
  tags            = local.default_tags
}

# A supplied ESO role needs no modification: this trust policy names it
# directly, and a same-account sts:AssumeRole requires no identity-side grant
# on the target role.
data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type = "AWS"
      # compact: either ARN is null depending on which ESO is in play.
      identifiers = compact([local.eso_role_arn, var.identity.existing_eso_role_arn])
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
  tags               = local.default_tags

  lifecycle {
    precondition {
      condition     = var.oauth_credentials == null || (var.token_credentials.mcd_id == null && var.token_credentials.mcd_token == null)
      error_message = "Only one of oauth_credentials or token_credentials should be set, not both."
    }
    precondition {
      condition     = var.oauth_credentials != null || !var.token_secret.create || (var.token_credentials.mcd_id != null && var.token_credentials.mcd_token != null)
      error_message = "Both mcd_id and mcd_token are required in token_credentials when token_secret.create is true and oauth_credentials is not set."
    }
  }
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
          local.use_oauth ? [] : (
            var.token_secret.create ? [
              aws_secretsmanager_secret.mcd_agent_token[0].arn
              ] : [
              "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:${var.token_secret.name}*"
            ]
          ),
          local.use_oauth ? (
            local.create_oauth_secret ? [
              aws_secretsmanager_secret.mcd_agent_oauth[0].arn
              ] : [
              "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:${local.oauth_secret_name}*"
            ]
          ) : [],
          [for s in var.integration_secrets :
            "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:${s.remote_ref_key}*"
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
  count                          = !local.use_oauth && var.token_secret.create ? 1 : 0
  name                           = var.token_secret.name
  force_overwrite_replica_secret = true
  tags                           = local.default_tags
}

resource "aws_secretsmanager_secret_version" "mcd_agent_token_version" {
  count     = !local.use_oauth && var.token_secret.create ? 1 : 0
  secret_id = aws_secretsmanager_secret.mcd_agent_token[0].id
  secret_string = jsonencode({
    "mcd_id"    = var.token_credentials.mcd_id != null ? var.token_credentials.mcd_id : ""
    "mcd_token" = var.token_credentials.mcd_token != null ? var.token_credentials.mcd_token : ""
  })
}

resource "aws_secretsmanager_secret" "mcd_agent_oauth" {
  count                          = local.create_oauth_secret ? 1 : 0
  name                           = local.oauth_secret_name
  force_overwrite_replica_secret = true
  tags                           = local.default_tags
}

resource "aws_secretsmanager_secret_version" "mcd_agent_oauth_version" {
  count     = local.create_oauth_secret ? 1 : 0
  secret_id = aws_secretsmanager_secret.mcd_agent_oauth[0].id
  secret_string = jsonencode({
    "client_id"     = var.oauth_credentials.client_id
    "client_secret" = var.oauth_credentials.client_secret
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
  namespace        = local.eso_namespace
  create_namespace = true

  values = local.use_irsa ? [
    yamlencode({
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = local.eso_role_arn
        }
      }
    })
  ] : []

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
  # Optional container tuning. Each key is omitted from the rendered values
  # entirely when its variable is unset, so the chart's own defaults apply.
  agent_container_tuning = merge(
    var.agent.ops_runner_thread_count == null ? {} : {
      opsRunnerThreadCount = tostring(var.agent.ops_runner_thread_count)
    },
    var.agent.resources == null ? {} : {
      resources = var.agent.resources
    },
  )

  # Rendered only when agent.autoscaling is supplied, so deployments that don't
  # use it are unaffected.
  agent_autoscaling_values = var.agent.autoscaling == null ? {} : {
    autoscaling = {
      enabled                           = var.agent.autoscaling.enabled
      minReplicas                       = var.agent.autoscaling.min_replicas
      maxReplicas                       = var.agent.autoscaling.max_replicas
      targetCPUUtilizationPercentage    = var.agent.autoscaling.target_cpu_utilization_percentage
      targetMemoryUtilizationPercentage = var.agent.autoscaling.target_memory_utilization_percentage
    }
  }

  auth_helm_values = local.use_oauth ? {
    oauthSecret = {
      remoteRef = {
        key = local.oauth_secret_name
      }
    }
    } : {
    tokenSecret = {
      remoteRef = {
        key = var.token_secret.name
      }
    }
  }

  # In irsa mode the eks.amazonaws.com/role-arn annotation is the whole
  # identity mechanism. Re-applied after custom_values in helm_values with a
  # nested merge so a caller's own serviceAccount settings survive without
  # dropping the annotation.
  aws_identity_helm_values = local.use_irsa ? {
    serviceAccount = merge(
      try(var.custom_values.serviceAccount, {}),
      {
        annotations = merge(
          try(var.custom_values.serviceAccount.annotations, {}),
          { "eks.amazonaws.com/role-arn" = local.agent_role_arn }
        )
      }
    )
  } : {}

  base_helm_values = merge(
    {
      namespace    = local.namespace
      replicaCount = var.agent.replica_count

      image = {
        repository = split(":", var.agent.image)[0]
        pullPolicy = var.agent.pull_policy
        tag        = length(split(":", var.agent.image)) > 1 ? split(":", var.agent.image)[1] : "latest-generic"
      }

      container = merge(
        {
          backendServiceUrl = var.backend_service_url
          storageBucketName = local.effective_bucket_name
          storageType       = "S3"
        },
        local.agent_container_tuning,
      )

      secretStore = {
        provider = {
          aws = {
            role    = aws_iam_role.mcd_secrets_access_role.arn
            region  = local.region
            service = "SecretsManager"
          }
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

      logShipping      = var.helm.log_shipping
      metricsCollector = { enabled = var.helm.enabled_metrics_collector }
    },
    local.agent_autoscaling_values,
    local.auth_helm_values
  )

  # Merge custom_values over base, then re-apply typed module fields
  # so the module-managed values always win
  helm_values = merge(local.base_helm_values, var.custom_values, {
    logShipping = var.helm.log_shipping
    metricsCollector = merge(
      try(var.custom_values.metricsCollector, {}),
      { enabled = var.helm.enabled_metrics_collector }
    )
  }, local.aws_identity_helm_values)

  helm_values_yaml = yamlencode(local.helm_values)
}
