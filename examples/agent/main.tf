provider "aws" {
  region = "us-east-1"
}

module "mcd_on_prem_agent" {
  source = "../../"

  region              = "us-east-1"
  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version = "0.0.2"
  }
}

output "cluster_endpoint" {
  value = module.mcd_on_prem_agent.cluster_endpoint
}

output "cluster_name" {
  value = module.mcd_on_prem_agent.cluster_name
}

output "storage_bucket_name" {
  value = module.mcd_on_prem_agent.storage_bucket_name
}

output "pod_identity_role_arn" {
  value = module.mcd_on_prem_agent.pod_identity_role_arn
}
