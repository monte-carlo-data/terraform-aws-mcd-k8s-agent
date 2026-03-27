module "mcd_on_prem_agent" {
  source = "../../"

  region              = "us-east-1"
  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version = "0.0.2"
  }

  # Use an existing EKS cluster
  cluster = {
    create                = false
    existing_cluster_name = "my-existing-cluster"
  }

  # Use existing VPC/subnets
  networking = {
    create_vpc = false
  }
}

output "storage_bucket_name" {
  value = module.mcd_on_prem_agent.storage_bucket_name
}

output "helm_values" {
  value     = module.mcd_on_prem_agent.helm_values
  sensitive = true
}
