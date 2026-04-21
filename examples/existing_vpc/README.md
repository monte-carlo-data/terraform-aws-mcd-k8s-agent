# Existing VPC Example

Deploys a new EKS cluster and Monte Carlo agent into an existing VPC.

You must provide the VPC ID and at least two private subnet IDs. The subnets should have outbound internet access (e.g., via NAT gateway) for pulling container images and reaching the Monte Carlo backend.

The `aws` provider must be configured with the target region — see the `provider "aws"` block in `main.tf` and the module's [Provider Configuration](../../README.md#provider-configuration) section.

## Usage

```bash
terraform init
terraform apply
```
