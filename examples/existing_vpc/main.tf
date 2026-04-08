module "mcd_on_prem_agent" {
  source = "../../"

  region              = "us-east-1"
  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version = "0.0.2"
  }

  # Create a new EKS cluster in an existing VPC
  networking = {
    create_vpc                  = false
    existing_vpc_id             = "vpc-0123456789abcdef0"
    existing_private_subnet_ids = ["subnet-aaa111", "subnet-bbb222"]
    # Set to false if your VPC already has these service endpoints
    # create_vpc_endpoints = false
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
