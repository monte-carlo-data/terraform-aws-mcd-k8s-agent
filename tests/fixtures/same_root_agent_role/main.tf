# Test fixture: a caller that creates the agent's IAM role in the SAME root and
# passes its .arn to the module. The ARN is computed, so it is unknown at plan
# time; the module must still plan.

variable "create_agent_role" {
  type    = bool
  default = null
}

resource "aws_iam_role" "agent" {
  name               = "my-agent"
  assume_role_policy = "{}"
}

module "mcd_agent" {
  source = "../../.."

  backend_service_url = "https://api.montecarlodata.com"

  token_credentials = {
    mcd_id    = "test-id"
    mcd_token = "test-token"
  }

  cluster = {
    create                = false
    existing_cluster_name = "existing"
  }

  networking = {
    create_vpc                  = false
    existing_vpc_id             = "vpc-12345678"
    existing_private_subnet_ids = ["subnet-12345678"]
    create_vpc_endpoints        = false
    availability_zones          = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }

  identity = {
    mode                    = "irsa"
    create_agent_role       = var.create_agent_role
    existing_agent_role_arn = aws_iam_role.agent.arn
    existing_eso_role_arn   = "arn:aws:iam::123456789012:role/external-secrets"
  }

  storage = {
    create_bucket        = false
    existing_bucket_name = "my-bucket"
  }

  helm = {
    chart_version                     = "0.0.2"
    install_external_secrets_operator = false
  }
}
