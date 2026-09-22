# --- Monte Carlo Configuration ---

variable "backend_service_url" {
  description = "The Monte Carlo backend service URL. Obtain this from Monte Carlo -> Account information -> Agent Service -> Public endpoint (or Private link endpoint if using PrivateLink)."
  type        = string
}

# --- Cluster Configuration ---

variable "cluster" {
  description = "EKS cluster configuration."
  type = object({
    create                = optional(bool, true)
    name                  = optional(string, null)
    existing_cluster_name = optional(string, null)
    kubernetes_version    = optional(string, "1.35")
    upgrade_policy        = optional(string, null)
    compute_config = optional(object({
      enabled    = bool
      node_pools = list(string)
    }), { enabled = true, node_pools = ["general-purpose"] })
  })
  default = {}

  validation {
    condition = (
      var.cluster.upgrade_policy == null ||
      contains(["STANDARD", "EXTENDED"], coalesce(var.cluster.upgrade_policy, "STANDARD"))
    )
    error_message = "cluster.upgrade_policy must be either \"STANDARD\" or \"EXTENDED\"."
  }
}

# --- Networking ---

variable "networking" {
  description = "VPC and networking configuration."
  type = object({
    create_vpc                  = optional(bool, true)
    create_vpc_endpoints        = optional(bool, true)
    vpc_cidr                    = optional(string, "10.18.0.0/16")
    availability_zones          = optional(list(string), [])
    private_subnet_cidrs        = optional(list(string), ["10.18.1.0/24", "10.18.2.0/24", "10.18.3.0/24"])
    public_subnet_cidrs         = optional(list(string), ["10.18.4.0/24", "10.18.5.0/24", "10.18.6.0/24"])
    existing_vpc_id             = optional(string, null)
    existing_private_subnet_ids = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = length(var.networking.availability_zones) == 0 || length(var.networking.availability_zones) >= 2
    error_message = "At least two availability zones are required when specified."
  }
}

# --- Storage ---

variable "storage" {
  description = "S3 storage configuration."
  type = object({
    create_bucket        = optional(bool, true)
    existing_bucket_name = optional(string, null)
    create_bucket_policy = optional(bool, true)
  })
  default = {}
}

# --- Secrets ---

variable "token_secret" {
  description = "Token secret store configuration."
  type = object({
    create = optional(bool, true)
    name   = optional(string, "mcd/agent/token")
  })
  default = {}
}

variable "token_credentials" {
  description = "MCD agent token credentials. Required when token_secret.create is true and oauth_credentials is not set."
  type = object({
    mcd_id    = optional(string, null)
    mcd_token = optional(string, null)
  })
  sensitive = true
  default   = {}
}

variable "oauth_credentials" {
  description = "OAuth client credentials for agent authentication. If provided, the module creates a secret in AWS Secrets Manager and configures the Helm chart to use OAuth instead of key/token. Only one of oauth_credentials or token_credentials should be set."
  type = object({
    client_id     = string
    client_secret = string
  })
  default   = null
  sensitive = true
}

variable "oauth_secret" {
  description = "OAuth secret store configuration. Only needed to customize the secret name or to reference a pre-existing secret (create = false). When null and oauth_credentials is set, the module creates a secret with the default name."
  type = object({
    create = optional(bool, true)
    name   = optional(string, "mcd/agent/oauth")
  })
  default = null
}

variable "integration_secrets" {
  description = "Integration secrets to sync from the cloud secret store."
  type = list(object({
    secret_key     = string
    remote_ref_key = string
  }))
  default = []
}

# --- Agent Configuration ---

variable "agent" {
  description = "Agent container configuration."
  type = object({
    namespace     = optional(string, "mcd-agent")
    image         = optional(string, "montecarlodata/agent:latest-generic")
    pull_policy   = optional(string, "Always")
    replica_count = optional(number, 2)

    # Concurrent operations a single replica processes. Chart default is 18.
    ops_runner_thread_count = optional(number, null)

    # Pod resource requests/limits, e.g.
    #   { requests = { cpu = "500m", memory = "512Mi" }, limits = { cpu = "2" } }
    # At least requests must be set when autoscaling is enabled.
    resources = optional(map(map(string)), null)

    # Horizontal Pod Autoscaler. Supplying this object enables autoscaling
    # unless enabled is explicitly set to false. When enabled, replica_count
    # is ignored and the HPA manages the replica count.
    autoscaling = optional(object({
      enabled                              = optional(bool, true)
      min_replicas                         = optional(number, 2)
      max_replicas                         = optional(number, 5)
      target_cpu_utilization_percentage    = optional(number, 70)
      target_memory_utilization_percentage = optional(number, null)
    }), null)
  })
  default = {}

  validation {
    # try() rather than a null guard on the left of ||: Terraform 1.9 evaluates
    # both operands, so keys(null) errors before the guard can take effect. A
    # genuinely bad key set still makes length() non-zero and fails validation.
    condition     = try(length(setsubtract(keys(var.agent.resources), ["requests", "limits"])) == 0, true)
    error_message = "agent.resources may only contain \"requests\" and \"limits\" keys."
  }

  validation {
    condition     = try(var.agent.autoscaling.enabled, false) == false || try(var.agent.resources["requests"], null) != null
    error_message = "agent.resources.requests must be set when agent.autoscaling is enabled — the HorizontalPodAutoscaler uses requests as its utilization baseline."
  }

  validation {
    condition     = try(var.agent.autoscaling.min_replicas <= var.agent.autoscaling.max_replicas, true)
    error_message = "agent.autoscaling.min_replicas must be less than or equal to agent.autoscaling.max_replicas."
  }
}

# --- Helm Deployment ---

variable "helm" {
  description = "Helm deployment configuration."
  type = object({
    deploy_agent                      = optional(bool, true)
    install_external_secrets_operator = optional(bool, true)
    chart_repository                  = optional(string, "oci://registry-1.docker.io/montecarlodata")
    chart_name                        = optional(string, "generic-agent-helm")
    # Find the latest version at https://hub.docker.com/r/montecarlodata/generic-agent-helm/tags
    chart_version             = string
    log_shipping              = optional(string, "in-process")
    enabled_metrics_collector = optional(bool, true)
  })

  validation {
    condition     = contains(["in-process", "fluentd", "none"], var.helm.log_shipping)
    error_message = "helm.log_shipping must be one of: in-process, fluentd, none."
  }
}

# --- Identity ---

variable "identity" {
  description = <<-EOT
    How the agent's pods authenticate to AWS.

    mode: "pod_identity" (default) requires the eks-pod-identity-agent add-on on the cluster;
    "irsa" binds service accounts by annotation through the cluster's OIDC provider. The two
    must never be mixed on one service account. See "Identity: IRSA instead of EKS Pod
    Identity" in the README for the existing-role and OIDC-provider options.
  EOT
  type = object({
    mode                    = optional(string, "pod_identity")
    oidc_provider_arn       = optional(string, null)
    existing_eso_role_arn   = optional(string, null)
    existing_agent_role_arn = optional(string, null)
  })
  default = {}

  validation {
    condition     = contains(["pod_identity", "irsa"], var.identity.mode)
    error_message = "identity.mode must be either \"pod_identity\" or \"irsa\"."
  }

  validation {
    condition = (
      var.helm.install_external_secrets_operator ||
      !var.helm.deploy_agent ||
      var.identity.existing_eso_role_arn != null
    )
    error_message = "identity.existing_eso_role_arn is required when an existing External Secrets Operator is reused (helm.install_external_secrets_operator = false) while the agent is deployed: in irsa mode the agent's SecretStore has no identity to read its token secret through, and in pod_identity mode the module's Pod Identity association would rebind the shared external-secrets service account away from the identity the existing operator already uses."
  }

  validation {
    condition     = var.identity.existing_eso_role_arn == null || can(regex("^arn:[^:]*:iam::[0-9]{12}:role/", var.identity.existing_eso_role_arn))
    error_message = "identity.existing_eso_role_arn must be an IAM role ARN of the form arn:aws:iam::<account-id>:role/<name>."
  }

  validation {
    condition     = var.identity.existing_agent_role_arn == null || can(regex("^arn:[^:]*:iam::[0-9]{12}:role/", var.identity.existing_agent_role_arn))
    error_message = "identity.existing_agent_role_arn must be an IAM role ARN of the form arn:aws:iam::<account-id>:role/<name>."
  }

  validation {
    condition     = var.identity.oidc_provider_arn == null || can(regex("^arn:[^:]*:iam::[0-9]{12}:oidc-provider/", var.identity.oidc_provider_arn))
    error_message = "identity.oidc_provider_arn must be an IAM OIDC provider ARN of the form arn:aws:iam::<account-id>:oidc-provider/<host-path>."
  }

  validation {
    condition     = var.identity.existing_eso_role_arn == null || !var.helm.install_external_secrets_operator
    error_message = "identity.existing_eso_role_arn may only be set when helm.install_external_secrets_operator is false (reusing a pre-existing External Secrets Operator)."
  }

  validation {
    condition     = var.identity.existing_agent_role_arn == null || var.storage.existing_bucket_name != null
    error_message = "identity.existing_agent_role_arn requires storage.existing_bucket_name: the module-created bucket's name embeds a random ID that is unknowable before apply, so a pre-authored role cannot be scoped to it."
  }

  validation {
    condition     = var.identity.mode == "irsa" || var.identity.oidc_provider_arn == null
    error_message = "identity.oidc_provider_arn is only used in irsa mode and must be null when mode = \"pod_identity\"."
  }
}

variable "custom_values" {
  description = "Custom Helm values to merge with module-generated values. Accepts any map matching the chart's values.yaml schema."
  type        = any
  default     = {}
}

variable "private_link" {
  description = "AWS PrivateLink configuration for connecting to the Monte Carlo backend via a VPC endpoint. When set, creates an interface VPC endpoint, security group, and Route53 private hosted zone. The region and VPCE service name can be obtained from Monte Carlo -> Account information -> Agent Service -> AWS PrivateLink."
  type = object({
    vpce_service_name = string
    region            = string
  })
  default = null
}

variable "custom_default_tags" {
  description = "Custom tags to apply to all resources. Merged with default Monte Carlo agent tags (mcd-agent-service-name, mcd-agent-deployment-type)."
  type        = map(string)
  default     = {}
}
