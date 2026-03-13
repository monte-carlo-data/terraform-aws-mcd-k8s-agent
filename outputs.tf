output "cluster_endpoint" {
  description = "Endpoint for EKS control plane."
  value       = var.cluster.create ? module.eks[0].cluster_endpoint : null
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = local.effective_cluster_name
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the cluster control plane."
  value       = var.cluster.create ? module.eks[0].cluster_security_group_id : null
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "storage_bucket_name" {
  description = "S3 bucket name for agent storage."
  value       = local.effective_bucket_name
}

output "storage_bucket_arn" {
  description = "S3 bucket ARN."
  value       = var.storage.create_bucket ? aws_s3_bucket.mcd_agent_store[0].arn : null
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for pod identity."
  value       = aws_iam_role.pod_identity.arn
}

output "eso_role_arn" {
  description = "IAM role ARN for External Secrets Operator."
  value       = aws_iam_role.eso_role.arn
}

output "mcd_secrets_access_role_arn" {
  description = "IAM role ARN for ESO to access Secrets Manager."
  value       = aws_iam_role.mcd_secrets_access_role.arn
}

output "mcd_agent_token_secret_arn" {
  description = "ARN of the Secrets Manager secret for the agent token."
  value       = var.token_secret.create ? aws_secretsmanager_secret.mcd_agent_token[0].arn : null
}

output "namespace" {
  description = "Kubernetes namespace for the agent."
  value       = local.namespace
}

output "helm_values" {
  description = "Helm values used for agent deployment. Use these for manual Helm deployment when deploy_agent is false."
  value       = local.helm_values_yaml
  sensitive   = false
}
