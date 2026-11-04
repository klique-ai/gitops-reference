terraform {
  required_version = ">= 1.10"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    # kubectl_manifest, not kubernetes_manifest, for the cert-manager CRs: it
    # plans without the CRDs present, so cert-manager and its ClusterIssuer can
    # land in the same apply.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
    # Only used by tls.mode = "self-signed-ca", to mint the quickstart CA.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
