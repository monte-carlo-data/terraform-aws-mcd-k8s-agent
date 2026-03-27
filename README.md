# Monte Carlo Agent - AWS EKS Module

This module deploys the [Monte Carlo](https://www.montecarlodata.com/) containerized agent on AWS using EKS (Elastic Kubernetes Service).

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.9
- [AWS CLI](https://aws.amazon.com/cli/) with [authentication](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#authentication-and-configuration)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for cluster access
- A Monte Carlo account with agent credentials (mcd_id and mcd_token)

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

### Full deployment (new cluster)

```hcl
module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  region              = "us-east-1"
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

| Name                       | Description                                     |
|----------------------------|-------------------------------------------------|
| cluster_endpoint           | Endpoint for EKS control plane                  |
| cluster_name               | EKS cluster name                                |
| storage_bucket_name        | S3 bucket name for agent storage                |
| pod_identity_role_arn      | IAM role ARN for pod identity                   |
| eso_role_arn               | IAM role ARN for External Secrets Operator       |
| mcd_secrets_access_role_arn | IAM role ARN for ESO to access Secrets Manager  |
| vpce_id                    | ID of the Monte Carlo PrivateLink VPC endpoint  |
| vpce_dns_entry             | DNS entries for the PrivateLink VPC endpoint     |
| helm_values                | Helm values for manual deployment (sensitive)    |

## Releases and Development

This module follows [standard module structure](https://www.terraform.io/docs/modules/index.html). Run `terraform fmt` before committing.

CircleCI runs `make sanity-check` on every PR.

To release a new version, create and push a new tag: `git tag v0.0.1 && git push origin v0.0.1`

## License

See [LICENSE](LICENSE).

## Security

See [SECURITY](SECURITY.md).
