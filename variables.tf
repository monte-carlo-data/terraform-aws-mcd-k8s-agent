# --- AWS Configuration ---

variable "region" {
  description = "The AWS region to deploy resources into."
  type        = string
}

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
    compute_config = optional(object({
      enabled    = bool
      node_pools = list(string)
    }), { enabled = true, node_pools = ["general-purpose"] })
  })
  default = {}
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
  description = "MCD agent token credentials. Required when token_secret.create is true."
  type = object({
    mcd_id    = optional(string, null)
    mcd_token = optional(string, null)
  })
  sensitive = true
  default   = {}

  validation {
    condition     = !var.token_secret.create || (var.token_credentials.mcd_id != null && var.token_credentials.mcd_token != null)
    error_message = "Both mcd_id and mcd_token are required in token_credentials when token_secret.create is true."
  }
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
    replica_count = optional(number, 1)
  })
  default = {}
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
    enabled_logs_collector    = optional(bool, true)
    enabled_metrics_collector = optional(bool, true)
  })
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
  description = "Custom tags to apply to all resources. Merged with default Monte Carlo agent tags."
  type        = map(string)
  default     = {}
}
