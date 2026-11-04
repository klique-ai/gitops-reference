# The certificate the app, api and files Ingresses terminate TLS with.
# Terraform owns it because TLS is platform: which CA signs Klique is a
# decision about the cluster, not about a release. The tenants' gateway
# certificates are NOT here: each tenant folder in GitOps creates its own
# (<tenant>.sessions.<domain> and *.<tenant>.sessions.<domain>), from the
# issuer in the klique-platform-vars ConfigMap.

locals {
  certificates = {
    app = {
      name      = var.tls.app_secret_name
      dns_names = [local.hosts.app, local.hosts.api, local.hosts.files]
    }
  }
}

resource "kubectl_manifest" "certificate" {
  for_each = local.certificates

  yaml_body = templatefile("${path.module}/manifests/certificate.yaml", {
    name         = each.value.name
    namespace    = var.klique_namespace
    dns_names    = each.value.dns_names
    duration     = var.tls.duration
    renew_before = var.tls.renew_before
    issuer_kind  = local.issuer_kind
    issuer_name  = local.issuer_name

    key_algorithm       = var.tls.private_key.algorithm
    key_size            = var.tls.private_key.size
    key_rotation_policy = var.tls.private_key.rotation_policy
  })

  # The handoff ConfigMap waits on these, so the charts never render an
  # Ingress pointing at a TLS Secret that does not exist yet.
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }

  depends_on = [
    kubernetes_namespace_v1.klique,
    helm_release.cert_manager,
    kubectl_manifest.cluster_issuer_ca,
    kubectl_manifest.cluster_issuer_acme,
  ]
}
