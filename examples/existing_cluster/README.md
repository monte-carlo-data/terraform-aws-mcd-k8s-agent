# MCD On-Prem Agent - Existing Cluster Example

This example deploys the Monte Carlo on-prem agent on an existing EKS cluster.

The `aws` provider must be configured with the target region — see the `provider "aws"` block in `main.tf` and the module's [Provider Configuration](../../README.md#provider-configuration) section.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.3
- An existing EKS cluster with kubectl access
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials

## Usage

Update `main.tf` with your existing cluster name and region, then:

```bash
terraform init
terraform apply
```
