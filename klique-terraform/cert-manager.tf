# cert-manager issues the Klique certificate (certificates.tf) and every
# tenant's gateway certificate. Skippable when the cluster already runs it; its
# CRDs and webhook are then still required.

resource "helm_release" "cert_manager" {
  count = var.cert_manager.install ? 1 : 0

  name             = "cert-manager"
  repository       = var.cert_manager.repository
  chart            = "cert-manager"
  version          = var.cert_manager.chart_version
  namespace        = var.cert_manager.namespace
  create_namespace = true

  repository_username = try(var.helm_repository_credentials["cert_manager"].username, null)
  repository_password = try(var.helm_repository_credentials["cert_manager"].password, null)

  # Waits for the webhook too — a ClusterIssuer applied before the webhook
  # answers is rejected.
  wait    = true
  timeout = 600

  values = compact([
    file("${path.module}/helm-values/cert-manager.yaml"),
    var.cert_manager.extra_values,
  ])

  depends_on = [terraform_data.preflight]
}
