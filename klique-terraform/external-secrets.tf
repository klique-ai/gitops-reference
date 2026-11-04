# External Secrets Operator, basic install. Every Klique credential in the
# GitOps repo is an ExternalSecret; the SecretStore they read from is
# secret-store.tf, driven by var.secret_store.

resource "helm_release" "external_secrets" {
  count = var.external_secrets.install ? 1 : 0

  name             = "external-secrets"
  repository       = var.external_secrets.repository
  chart            = "external-secrets"
  version          = var.external_secrets.chart_version
  namespace        = var.external_secrets.namespace
  create_namespace = true

  repository_username = try(var.helm_repository_credentials["external_secrets"].username, null)
  repository_password = try(var.helm_repository_credentials["external_secrets"].password, null)

  wait    = true
  timeout = 600

  values = compact([
    file("${path.module}/helm-values/external-secrets.yaml"),
    var.external_secrets.extra_values,
  ])

  depends_on = [terraform_data.preflight]
}
