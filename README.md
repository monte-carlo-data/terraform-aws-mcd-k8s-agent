# Monte Carlo Agent - AWS EKS Module

This module deploys the [Monte Carlo](https://www.montecarlodata.com/) containerized agent on AWS using EKS (Elastic Kubernetes Service).

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.12
- [AWS CLI](https://aws.amazon.com/cli/) with [authentication](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#authentication-and-configuration)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for cluster access
- A Monte Carlo account with agent credentials (mcd_id and mcd_token) or OAuth client credentials (client_id and client_secret)
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

### OAuth authentication

As an alternative to key/token authentication, you can use OAuth 2.0 Client Credentials. Only one authentication method should be configured at a time.

**Option 1 -- Provide OAuth credentials (recommended):** The module creates and populates the secret in AWS Secrets Manager.

```hcl
oauth_credentials = {
  client_id     = "your-client-id"
  client_secret = "your-client-secret"
}
```

**Option 2 -- Use a pre-existing OAuth secret:** Point the module to an existing secret in AWS Secrets Manager by name. The secret must be in the same region as the module deployment. The secret value must be a JSON object with the following format:

```json
{
  "client_id": "YOUR_CLIENT_ID",
  "client_secret": "YOUR_CLIENT_SECRET"
}
```

```hcl
oauth_secret = {
  create = false
  name   = "my-existing-oauth-secret"
}
```

When using OAuth, omit `token_credentials` entirely.

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

### Full deployment with OAuth

```hcl
provider "aws" {
  region = "us-east-1"
}

module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  backend_service_url = "<backend_service_url>"

  oauth_credentials = {
    client_id     = var.oauth_client_id
    client_secret = var.oauth_client_secret
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

> **Note:** The cluster must have the `eks-pod-identity-agent` EKS add-on installed for
> the default identity mode (the module installs it only on clusters it creates). If it
> does not, use `identity.mode = "irsa"` instead — see
> [Identity: IRSA instead of EKS Pod Identity](#identity-irsa-instead-of-eks-pod-identity).

### Identity: IRSA instead of EKS Pod Identity

By default the module binds its pods to IAM with **EKS Pod Identity**: it creates the
`eks-pod-identity-agent` add-on (when it creates the cluster) and two Pod Identity
associations — the agent's and the External Secrets Operator's service accounts. The
cluster must have that add-on installed; on an existing cluster without it, every
credential fetch fails at runtime (pods stuck in `ContainerCreating`, ExternalSecrets
reporting `InvalidProviderConfig`).

Set `identity.mode = "irsa"` to use **IRSA** (IAM Roles for Service Accounts)
instead: the module creates no Pod Identity associations and no add-on, and binds both
service accounts via the standard `eks.amazonaws.com/role-arn` annotation (both, when
the module installs its own ESO), with roles trusted through the cluster's OIDC
identity provider. The cluster must already have an IAM OIDC provider (any cluster
created by this module has one; for an existing cluster the module looks it up by
issuer URL and fails at plan time when it is missing — the lookup errors with an AWS
`NoSuchEntity`-style message listing the issuer URL, which is the module's fail-fast
working as intended).

**IRSA is required when the agent joins a cluster whose workloads already use IRSA**
(for example, a cluster that already runs IRSA-bound workloads, such as a shared
External Secrets Operator or cert-manager): a Pod Identity association on
a shared service account rebinds it away from its IRSA identity, and the association's
injected credential endpoint outranks the IRSA annotation — the two mechanisms must
never be mixed on one service account.

#### Bringing your own role

Optionally, pass `identity.existing_agent_role_arn` to use a role you manage instead of
letting the module create one. This never changes behavior for existing configurations —
it is additive in every mode:

```hcl
  identity = {
    mode                    = "irsa"
    existing_agent_role_arn = "arn:aws:iam::<account-id>:role/<your-agent-role>"
  }
```

When supplied, the module creates **no agent role and no S3 policy** — it binds your role
to the agent's service account (via the annotation in irsa mode, or the Pod Identity
association in pod_identity mode). Supplying it requires `storage.existing_bucket_name`:
module-created bucket names embed a random ID that is unknowable before apply, so a
pre-authored role cannot be scoped to one. Your role must already carry the agent's
permissions on that bucket: the S3 actions from the
[object storage](https://docs.getmontecarlo.com/docs/object-storage) policy, and
`secretsmanager:GetSecretValue` on the agent's token secret and any integration
secrets — one role may cover both.

**Creating the role in the same configuration.** If the role is a resource in the same
root as this module, its ARN is unknown until apply, and Terraform must know at plan time
whether the module creates a role of its own (otherwise the plan fails with *Invalid count
argument*). Say so explicitly with `identity.create_agent_role = false`:

```hcl
resource "aws_iam_role" "mcd_agent" {
  # ... trust policy and permissions as described below
}

module "mcd_agent" {
  # ...
  identity = {
    mode                    = "irsa"
    create_agent_role       = false
    existing_agent_role_arn = aws_iam_role.mcd_agent.arn
  }
}
```

Leaving `create_agent_role` unset keeps the inferred behavior (the module creates a role
unless `existing_agent_role_arn` is set), which works whenever the ARN is known at plan time —
a literal string, a variable, or a data source lookup.

The role's trust policy must match the identity mode. These examples assume the default
namespace (`mcd-agent`); the service-account name is also available as the
`agent_service_account_name` output.

`pod_identity` mode:

```hcl
data "aws_iam_policy_document" "agent_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}
```

`irsa` mode (`<oidc-provider-id>` is the cluster's issuer URL without the `https://`
prefix, e.g. `oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE`):

```hcl
data "aws_iam_policy_document" "agent_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["<cluster-oidc-provider-arn>"]
    }

    condition {
      test     = "StringEquals"
      variable = "<oidc-provider-id>:sub"
      values   = ["system:serviceaccount:mcd-agent:mcd-agent-service-account"]
    }

    condition {
      test     = "StringEquals"
      variable = "<oidc-provider-id>:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
```

This pairs naturally with bring-your-own clusters (`cluster.create = false`), where the
customer may prefer — or be restricted to — authoring IAM roles in their own Terraform.

When reusing a pre-existing External Secrets Operator
(`helm.install_external_secrets_operator = false`), pass its IAM role as
`identity.existing_eso_role_arn` — the role the operator already runs under — so the
agent's SecretStore can sync through it. This is **required in both modes** (the module
validates it): in `irsa` mode the agent's SecretStore has no identity to read its token
secret through without it, and in `pod_identity` mode the module would otherwise create
a Pod Identity association on the shared `external-secrets` service account, rebinding
the existing operator away from its current identity. The role itself needs no
modification — the module's secrets-access role trusts it directly (a same-account
`sts:AssumeRole` needs only the trust entry), so the applying principal needs no IAM
write permission on it.

```hcl
module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  backend_service_url = "<backend_service_url>"

  helm = {
    chart_version                     = "0.0.2"
    install_external_secrets_operator = false # ESO already runs in this cluster
  }

  cluster = {
    create                = false
    existing_cluster_name = "my-cluster"
  }

  identity = {
    mode                  = "irsa"
    existing_eso_role_arn = "arn:aws:iam::<account-id>:role/<existing-eso-role>"
  }

  networking = {
    create_vpc = false
  }
}
```

`identity.oidc_provider_arn` can override the provider lookup when the provider is
managed elsewhere (e.g. by the root that owns the cluster). It must be a full
OIDC-provider ARN and must be null in `pod_identity` mode — the module validates both.

Supported identity combinations:

| `identity.mode` | `existing_agent_role_arn` | `existing_eso_role_arn` | `install_external_secrets_operator` | Outcome |
|---|---|---|---|---|
| `pod_identity` | unset | unset | `true` | Valid (default) |
| `pod_identity` | unset | unset | `false` | Rejected — `existing_eso_role_arn` is required (the module's Pod Identity association would otherwise rebind the existing ESO's service account) |
| `pod_identity` | unset | set | `false` | Valid (recommended with a reused ESO) |
| `irsa` | unset | unset | `true` | Valid |
| `irsa` | unset | unset | `false` | Rejected — `existing_eso_role_arn` is required |
| `irsa` | unset | set | `false` | Valid |
| either | set | unset | `true` | Valid — requires `storage.existing_bucket_name` |
| either | set | set | `false` | Valid — requires `storage.existing_bucket_name` |
| either | either | set | `true` | Rejected — `existing_eso_role_arn` must be null when the module installs ESO |

`identity.create_agent_role` does not change any outcome above: unset, it is inferred from
`existing_agent_role_arn`; set, it must agree with it (`false` requires the ARN, `true`
forbids it), and `false` also requires `storage.existing_bucket_name`.

Switching `identity.mode` on an existing deployment replaces the module-created agent
role (its name changes between `<cluster>-pod-identity` and `<cluster>-irsa`) and
removes the `eks-pod-identity-agent` add-on on module-created clusters — update
anything referencing the old `pod_identity_role_arn` output and expect the agent pods
to restart. The mode is effectively chosen at first deploy.

### Pinning the Kubernetes version and support policy

```hcl
module "mcd_agent" {
  source = "monte-carlo-data/mcd-agent-k8s/aws"

  backend_service_url = "<backend_service_url>"

  cluster = {
    kubernetes_version = "1.36"
    upgrade_policy     = "STANDARD"
  }
}
```

`upgrade_policy` accepts `STANDARD` or `EXTENDED`. Leaving it unset (the default) lets AWS apply its own default of `EXTENDED`.

The distinction matters when a Kubernetes version reaches the end of standard support:

| Value | Behaviour at end of standard support |
|---|---|
| `EXTENDED` | The cluster moves to extended support and keeps running, at additional cost. |
| `STANDARD` | The cluster is **automatically upgraded** by AWS to the next version, at no additional cost. |

Choose `STANDARD` if an unplanned upgrade is preferable to an unplanned bill, and `EXTENDED` if you need to control exactly when upgrades happen.

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

### Scaling

Set replicas, per-replica concurrency, and pod resources through the `agent` variable:

```hcl
  agent = {
    replica_count           = 3
    ops_runner_thread_count = 36
    resources = {
      requests = { cpu = "500m", memory = "512Mi" }
      limits   = { cpu = "2", memory = "2Gi" }
    }
  }
```

`ops_runner_thread_count` is the number of operations a single replica processes concurrently (chart default is 18). Raising it is often cheaper than adding replicas, but set `resources` alongside it so the pods have headroom.

To autoscale instead of holding a fixed replica count, supply `agent.autoscaling`:

```hcl
  agent = {
    ops_runner_thread_count = 36
    resources               = { requests = { cpu = "500m", memory = "512Mi" } }

    autoscaling = {
      min_replicas                      = 2
      max_replicas                      = 6
      target_cpu_utilization_percentage = 70
    }
  }
```

Supplying the object enables autoscaling; set `enabled = false` to keep the settings without activating the HorizontalPodAutoscaler. When enabled, `replica_count` is ignored, `resources.requests` is required (the HPA uses requests as its utilization baseline, and the module validates this), and `metrics-server` must be installed in the cluster — standard on EKS, AKS, and GKE.

Set these through the `agent` variable rather than `custom_values`. `custom_values` replaces whole sections rather than merging into them, so a `container` map passed there drops the module's backend URL and data store settings. The same goes for `serviceAccount`: the module re-applies the IRSA role-arn annotation after merging, so a caller's own `serviceAccount.annotations` survive alongside it. Note that `serviceAccount.name` is not a chart value at all — the chart hardcodes the name (`mcd-agent-service-account`) in its templates and only reads `serviceAccount.annotations` — so the name cannot be overridden, and the module's trust-policy `:sub` condition always matches.

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

| Name                        | Description                                          |
|-----------------------------|------------------------------------------------------|
| cluster_endpoint            | Endpoint for EKS control plane                       |
| cluster_name                | EKS cluster name                                     |
| storage_bucket_name         | S3 bucket name for agent storage                     |
| agent_role_arn              | Effective IAM role ARN bound to the agent's service account |
| agent_service_account_name  | Name of the agent's Kubernetes service account        |
| pod_identity_role_arn       | Deprecated alias for `agent_role_arn`                |
| eso_role_arn                | Effective IAM role ARN for the External Secrets Operator — equals the supplied `identity.existing_eso_role_arn` when a pre-existing ESO is used |
| mcd_secrets_access_role_arn | IAM role ARN for ESO to access Secrets Manager       |
| mcd_agent_token_secret_arn  | ARN of the Secrets Manager secret for the agent token |
| mcd_agent_oauth_secret_arn  | ARN of the Secrets Manager secret for OAuth credentials |
| vpce_id                     | ID of the Monte Carlo PrivateLink VPC endpoint       |
| vpce_dns_entry              | DNS entries for the PrivateLink VPC endpoint          |
| vpc_endpoint_ids            | IDs of AWS service VPC endpoints (S3, SM, STS, EC2)  |
| helm_values                 | Helm values for manual deployment (sensitive)         |

## Releases and Development

This module follows [standard module structure](https://www.terraform.io/docs/modules/index.html). Run `terraform fmt` before committing.

CircleCI runs `make sanity-check` on every PR.

To release a new version, create and push a new tag: `git tag v0.0.1 && git push origin v0.0.1`

## License

See [LICENSE](LICENSE).

## Security

See [SECURITY](SECURITY.md).
