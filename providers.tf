# NOTE: The aws provider is intentionally NOT configured here. Reusable modules
# should not include provider configuration blocks — the calling root module must
# configure the aws provider. See README for required provider settings.
#
# The helm and kubernetes providers are configured here because they depend on the
# cluster's kubeconfig, which is only available after the cluster is created/read.
# This is a known compromise for Kubernetes-deploying modules.

provider "helm" {
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca_certificate
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca_certificate
  token                  = data.aws_eks_cluster_auth.cluster.token
}
