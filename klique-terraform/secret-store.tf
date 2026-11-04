# The ESO SecretStore every ExternalSecret in the GitOps repo reads from
# (klique-fluxcd/klique/externalsecret-*.yaml reference it BY NAME:
# SecretStore/klique-secrets). Backend choice and backend auth are
# per-installation facts, so they come from tfvars, not from git.
#
# secret_store.provider_yaml empty = no store: every ExternalSecret stays
# NotReady until one exists — a loud failure on purpose.

locals {
  create_secret_store      = var.secret_store.provider_yaml != ""
  secret_store_credentials = "klique-secret-store-credentials"
}

# Static backend credentials, when the provider cannot use workload identity.
# provider_yaml references them as Secret `klique-secret-store-credentials`.
resource "kubernetes_secret_v1" "secret_store_credentials" {
  count = length(var.secret_store_credentials) > 0 ? 1 : 0

  metadata {
    name      = local.secret_store_credentials
    namespace = kubernetes_namespace_v1.klique.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  data = var.secret_store_credentials
}

resource "kubectl_manifest" "secret_store" {
  count = local.create_secret_store ? 1 : 0

  yaml_body = templatefile("${path.module}/manifests/secretstore.yaml", {
    namespace        = kubernetes_namespace_v1.klique.metadata[0].name
    refresh_interval = var.secret_store.refresh_interval
    provider         = indent(4, chomp(var.secret_store.provider_yaml))
  })

  # No wait_for: Ready depends on the backend answering, which is the
  # ExternalSecrets' status to report, not a reason to block the apply.

  depends_on = [
    helm_release.external_secrets,
    kubernetes_secret_v1.secret_store_credentials,
  ]
}
