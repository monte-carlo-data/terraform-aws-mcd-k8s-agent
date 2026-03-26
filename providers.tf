provider "aws" {
  region = var.region

  default_tags {
    tags = merge(var.custom_default_tags, {
      "mcd-agent-service-name"    = lower(local.mcd_agent_service_name)
      "mcd-agent-deployment-type" = lower(local.mcd_agent_deployment_type)
    })
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca_certificate
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca_certificate
  token                  = data.aws_eks_cluster_auth.cluster.token
}
