# Monte Carlo Agent - AWS EKS Module

This module deploys the [Monte Carlo](https://www.montecarlodata.com/) containerized agent on AWS using EKS (Elastic Kubernetes Service).

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.3
- [AWS CLI](https://aws.amazon.com/cli/) with [authentication](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#authentication-and-configuration)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for cluster access
- A Monte Carlo account with agent credentials (mcd_id and mcd_token)

## Usage

> **Finding your `backend_service_url`:** Navigate to the [Account Information](https://getmontecarlo.com/account-info#agent-service) page in Monte Carlo. Under the **Agent Service** section, copy the **Public endpoint** (or **Private link endpoint** if using private link). Use this value for the `backend_service_url` variable in the examples below.

> **Finding the latest `chart_version`:** Check the available versions on [Docker Hub](https://hub.docker.com/r/montecarlodata/generic-agent-helm/tags).

For more complete configurations, see the [`examples`](./examples/) directory.

### Full deployment (new cluster)

```hcl
module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  region              = "us-east-1"
  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version = "0.0.2"
  }
}
```

### Existing VPC

```hcl
module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  region              = "us-east-1"
  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version = "0.0.2"
  }

  networking = {
    create_vpc                  = false
    existing_vpc_id             = "vpc-0123456789abcdef0"
    existing_private_subnet_ids = ["subnet-aaa111", "subnet-bbb222"]
  }
}
```

### Existing cluster

```hcl
module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  region              = "us-east-1"
  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version = "0.0.2"
  }

  cluster = {
    create                = false
    existing_cluster_name = "my-cluster"
  }

  networking = {
    create_vpc = false
  }
}
```

### Infrastructure only (manual Helm deployment)

```hcl
module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  region              = "us-east-1"
  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version = "0.0.2"
    deploy_agent  = false
  }
}

output "helm_values" {
  value     = module.mcd_agent.helm_values
  sensitive = true
}
```

## After Deployment

1. Update the agent token in AWS Secrets Manager:
   ```bash
   aws secretsmanager update-secret --secret-id mcd/agent/token \
     --secret-string '{"mcd_id":"YOUR_MCD_ID","mcd_token":"YOUR_MCD_TOKEN"}'
   ```

2. Configure kubectl access:
   ```bash
   aws eks update-kubeconfig --name <cluster_name> --region <region>
   ```

## Outputs

| Name | Description |
|------|-------------|
| cluster_endpoint | Endpoint for EKS control plane |
| cluster_name | EKS cluster name |
| storage_bucket_name | S3 bucket name for agent storage |
| pod_identity_role_arn | IAM role ARN for pod identity |
| eso_role_arn | IAM role ARN for External Secrets Operator |
| mcd_secrets_access_role_arn | IAM role ARN for ESO to access Secrets Manager |
| helm_values | Helm values for manual deployment (sensitive) |

## Releases and Development

This module follows [standard module structure](https://www.terraform.io/docs/modules/index.html). Run `terraform fmt` before committing.

CircleCI runs `make sanity-check` on every PR.

To release a new version, create and push a new tag: `git tag v0.0.1 && git push origin v0.0.1`

## License

See [LICENSE](LICENSE).

## Security

See [SECURITY](SECURITY.md).
