# An EXISTING cluster, reached through a kubeconfig — no cloud provider here,
# so the same root works on EKS, GKE, AKS, OpenShift, RKE2 or bare metal.
# Cloud-specific auth (exec plugins, tokens) belongs in the kubeconfig itself.

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kubeconfig_context
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = var.kubeconfig_context
  load_config_file = true
}
