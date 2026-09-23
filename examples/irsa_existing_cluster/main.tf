provider "aws" {
  region = "us-east-1"
}

module "mcd_on_prem_agent" {
  source = "../../"

  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version                     = "0.0.2"
    install_external_secrets_operator = false
  }

  # Use an existing EKS cluster — and no VPC of our own: the agent runs in
  # the cluster's existing VPC, so creating one here would be dead weight.
  cluster = {
    create                = false
    existing_cluster_name = "my-existing-cluster"
  }
  networking = {
    create_vpc = false
  }

  # IRSA instead of EKS Pod Identity, reusing the cluster's existing
  # External Secrets Operator role.
  identity = {
    mode                  = "irsa"
    existing_eso_role_arn = "arn:aws:iam::123456789012:role/external-secrets"
    # To bring your own agent role, also set existing_agent_role_arn and
    # storage.existing_bucket_name. If that role is created in this same
    # configuration, also set create_agent_role = false.
  }
}

output "storage_bucket_name" {
  value = module.mcd_on_prem_agent.storage_bucket_name
}

output "helm_values" {
  value     = module.mcd_on_prem_agent.helm_values
  sensitive = true
}
