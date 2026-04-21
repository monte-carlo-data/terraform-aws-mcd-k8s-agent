# Monte Carlo Agent - AWS EKS Module

This module deploys the [Monte Carlo](https://www.montecarlodata.com/) containerized agent on AWS using EKS (Elastic Kubernetes Service).

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.9
- [AWS CLI](https://aws.amazon.com/cli/) with [authentication](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#authentication-and-configuration)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for cluster access
- A Monte Carlo account with agent credentials (mcd_id and mcd_token)
- **(PrivateLink only)** Before deploying with `private_link` enabled, contact Monte Carlo support to request that your AWS account be allowed for PrivateLink. You must wait for Monte Carlo to confirm the account has been allowed before proceeding with deployment.

## Provider Configuration

This module does **not** configure the `aws` provider — the calling root module must do so. At minimum, the provider must set the target region:

```hcl
provider "aws" {
  region = "us-east-1"
}
```

The module applies Monte Carlo agent tags (`mcd-agent-service-name`, `mcd-agent-deployment-type`) to all resources it creates. To add your own tags alongside these, use the `custom_default_tags` variable — there is no need to set `default_tags` on the provider for this module's resources.

The `helm` and `kubernetes` providers are configured inside this module because they depend on the cluster's kubeconfig, which is only available after the cluster is created or read. This is a [known compromise](https://developer.hashicorp.com/terraform/language/modules/develop/providers) for modules that deploy Kubernetes resources.

## Usage

> **Finding your `backend_service_url`:** Navigate to the [Account Information](https://getmontecarlo.com/account-info#agent-service) page in Monte Carlo. Under the **Agent Service** section, copy the **Public endpoint** (or **Private link endpoint** if using private link). Use this value for the `backend_service_url` variable in the examples below.

> **Finding the latest `chart_version`:** Check the available versions on [Docker Hub](https://hub.docker.com/r/montecarlodata/generic-agent-helm/tags).

For more complete configurations, see the [`examples`](./examples/) directory.

### Agent token secret

You must configure the agent token secret using one of two options:

**Option 1 — Provide credentials (recommended):** The module creates and populates the secret in AWS Secrets Manager.

```hcl
token_credentials = {
  mcd_id    = "your-mcd-id"
  mcd_token = "your-mcd-token"
}
```

**Option 2 — Use a pre-existing secret:** Point the module to an existing secret in AWS Secrets Manager by name. The secret must be in the same region as the module deployment. The secret value must be a JSON object with the following format:

```json
{
  "mcd_id": "YOUR_MCD_ID",
  "mcd_token": "YOUR_MCD_TOKEN"
}
```

```hcl
token_secret = {
  create = false
  name   = "my-existing-secret-name"
}
```

All examples below require the `aws` provider configured as described in [Provider Configuration](#provider-configuration).

### Full deployment (new cluster)

```hcl
provider "aws" {
  region = "us-east-1"
}

module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  backend_service_url = "<backend_service_url>"

  token_credentials = {
    mcd_id    = var.mcd_id
    mcd_token = var.mcd_token
  }

  helm = {
    chart_version = "0.0.2"
  }
}
```

### Existing VPC

```hcl
provider "aws" {
  region = "us-east-1"
}

module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version = "0.0.2"
  }

  networking = {
    create_vpc                  = false
    existing_vpc_id             = "vpc-0123456789abcdef0"
    existing_private_subnet_ids = ["subnet-aaa111", "subnet-bbb222"]
    # Set to false if your VPC already has these service endpoints
    # create_vpc_endpoints = false
  }
}
```

> **Note:** The existing VPC must have DNS hostnames enabled (`enable_dns_hostnames = true`) for VPC Interface endpoints. If your VPC already has VPC endpoints for S3, Secrets Manager, STS, and EC2, set `create_vpc_endpoints = false` to avoid conflicts.

### Existing cluster

```hcl
provider "aws" {
  region = "us-east-1"
}

module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

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
provider "aws" {
  region = "us-east-1"
}

module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

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

### AWS PrivateLink (optional)

To route traffic to the Monte Carlo backend over AWS PrivateLink instead of the public internet, add the `private_link` block. The region and VPCE service name can be obtained from Monte Carlo -> Account information -> Agent Service -> AWS PrivateLink. When using PrivateLink, `backend_service_url` must use the private link endpoint (it must contain `.privatelink.`).

```hcl
provider "aws" {
  region = "us-east-1"
}

module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  backend_service_url = "https://artemis.privatelink.getmontecarlo.com"

  token_credentials = {
    mcd_id    = var.mcd_id
    mcd_token = var.mcd_token
  }

  helm = {
    chart_version = "0.0.2"
  }

  private_link = {
    vpce_service_name = "<vpce_service_name>"
    region            = "us-east-1"
  }
}
```

This creates an interface VPC endpoint, a security group allowing HTTPS from the VPC CIDR, and a Route53 private hosted zone with an alias record pointing to the endpoint. See [Prerequisites](#prerequisites) for the required allowlisting step and [Approve PrivateLink connection](#approve-privatelink-connection-optional) for post-deployment steps.

## After Deployment

Configure kubectl access:
```bash
aws eks update-kubeconfig --name <cluster_name> --region <region>
```

### Approve PrivateLink connection (optional)

If you configured `private_link`, the VPC endpoint connection requires approval from Monte Carlo. After deployment, contact Monte Carlo support and share the following output values:

```bash
terraform output vpce_id
terraform output vpce_dns_entry
```

The agent will not be able to communicate with the Monte Carlo backend until the connection is approved. Once approved, restart the agent services:

```bash
kubectl rollout restart deployment mcd-agent-deployment -n mcd-agent
kubectl rollout restart daemonset logs-collector metrics-collector -n mcd-agent
```

Then run the [reachability test](#reachability-test) to confirm connectivity.

## Troubleshooting

### Checking agent logs

Verify the agent pod is running and check its logs:

```bash
kubectl get pods -n mcd-agent
kubectl logs -n mcd-agent -l app=mcd-agent --tail=30
```

### Reachability test

Run the reachability test to confirm the agent can communicate with the Monte Carlo platform:

```bash
kubectl exec -n mcd-agent deploy/mcd-agent-deployment -- \
  curl -s -X POST localhost:8080/api/v1/test/reachability
```

### Rotating the agent token

1. Update the secret in AWS Secrets Manager:
   ```bash
   aws secretsmanager update-secret --secret-id mcd/agent/token \
     --secret-string '{"mcd_id":"NEW_MCD_ID","mcd_token":"NEW_MCD_TOKEN"}'
   ```

2. Force sync the Kubernetes secret from ESO:
   ```bash
   kubectl annotate externalsecret -n mcd-agent --all \
     force-sync=$(date +%s) --overwrite
   ```

3. Restart the agent services:
   ```bash
   kubectl rollout restart deployment mcd-agent-deployment -n mcd-agent
   kubectl rollout restart daemonset logs-collector metrics-collector -n mcd-agent
   ```

## Outputs

| Name                       | Description                                          |
|----------------------------|------------------------------------------------------|
| cluster_endpoint           | Endpoint for EKS control plane                       |
| cluster_name               | EKS cluster name                                     |
| storage_bucket_name        | S3 bucket name for agent storage                     |
| pod_identity_role_arn      | IAM role ARN for pod identity                        |
| eso_role_arn               | IAM role ARN for External Secrets Operator            |
| mcd_secrets_access_role_arn | IAM role ARN for ESO to access Secrets Manager       |
| vpce_id                    | ID of the Monte Carlo PrivateLink VPC endpoint       |
| vpce_dns_entry             | DNS entries for the PrivateLink VPC endpoint          |
| vpc_endpoint_ids           | IDs of AWS service VPC endpoints (S3, SM, STS, EC2)  |
| helm_values                | Helm values for manual deployment (sensitive)         |

## Releases and Development

This module follows [standard module structure](https://www.terraform.io/docs/modules/index.html). Run `terraform fmt` before committing.

CircleCI runs `make sanity-check` on every PR.

To release a new version, create and push a new tag: `git tag v0.0.1 && git push origin v0.0.1`

## License

See [LICENSE](LICENSE).

## Security

See [SECURITY](SECURITY.md).
