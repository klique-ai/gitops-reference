# The ClusterIssuer the Klique certificates are signed by — created here in
# tls.mode self-signed-ca, ca and acme. In "issuer" mode the partner's existing
# issuer is referenced as-is.

# --- self-signed-ca: a private root minted by Terraform ----------------------
# Quickstart only: the root key lives in TF state. Anything longer-lived should
# bring its own CA (tls.mode = "ca" with a pre-created Secret).

resource "tls_private_key" "root" {
  count       = var.tls.mode == "self-signed-ca" ? 1 : 0
  algorithm   = var.tls.self_signed_ca.algorithm
  rsa_bits    = var.tls.self_signed_ca.rsa_bits
  ecdsa_curve = var.tls.self_signed_ca.ecdsa_curve
}

resource "tls_self_signed_cert" "root" {
  count           = var.tls.mode == "self-signed-ca" ? 1 : 0
  private_key_pem = tls_private_key.root[0].private_key_pem

  subject {
    common_name  = var.tls.self_signed_ca.common_name
    organization = var.tls.self_signed_ca.organization
  }

  is_ca_certificate     = true
  validity_period_hours = var.tls.self_signed_ca.validity_hours
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature"]
}

# The CA keypair cert-manager signs with, in cert-manager's namespace (a
# ClusterIssuer reads its Secret from there). Not written in ca mode with a
# pre-created Secret — the key then never touches TF state.
resource "kubernetes_secret_v1" "ca" {
  count = local.write_ca_secret ? 1 : 0

  metadata {
    name      = var.tls.ca_secret_name
    namespace = var.cert_manager.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = local.ca_cert_pem
    "tls.key" = var.tls.mode == "self-signed-ca" ? tls_private_key.root[0].private_key_pem : var.tls_ca_key_pem
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubectl_manifest" "cluster_issuer_ca" {
  count = contains(["self-signed-ca", "ca"], var.tls.mode) ? 1 : 0

  yaml_body = templatefile("${path.module}/manifests/clusterissuer-ca.yaml", {
    name           = local.cluster_issuer_name
    ca_secret_name = var.tls.ca_secret_name
  })

  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }

  depends_on = [helm_release.cert_manager, kubernetes_secret_v1.ca]
}

# --- acme: Let's Encrypt (or any ACME server) with a DNS-01 solver -----------

resource "kubectl_manifest" "cluster_issuer_acme" {
  count = var.tls.mode == "acme" ? 1 : 0

  yaml_body = templatefile("${path.module}/manifests/clusterissuer-acme.yaml", {
    name    = local.cluster_issuer_name
    email   = var.tls.acme_email
    server  = var.tls.acme_server
    solvers = indent(6, chomp(var.tls.acme_solvers_yaml))
  })

  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }

  depends_on = [helm_release.cert_manager]
}
