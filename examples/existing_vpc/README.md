# Existing VPC Example

Deploys a new EKS cluster and Monte Carlo agent into an existing VPC.

You must provide the VPC ID and at least two private subnet IDs. The subnets should have outbound internet access (e.g., via NAT gateway) for pulling container images and reaching the Monte Carlo backend.

## Usage

```bash
terraform init
terraform apply -var="region=us-east-1"
```
