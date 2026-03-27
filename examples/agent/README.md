# MCD On-Prem Agent - Full Deployment Example

This example deploys the Monte Carlo on-prem agent on a new EKS cluster with all infrastructure provisioned automatically.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.3
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Usage

```bash
terraform init
terraform apply
```

## After Deployment

1. Update the agent token secret in AWS Secrets Manager with your Monte Carlo credentials:
   ```bash
   aws secretsmanager update-secret --secret-id mcd/agent/token \
     --secret-string '{"mcd_id":"YOUR_MCD_ID","mcd_token":"YOUR_MCD_TOKEN"}'
   ```

2. Configure kubectl:
   ```bash
   aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region us-east-1
   ```
