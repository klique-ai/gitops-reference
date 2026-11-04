locals {
  install_traefik = var.ingress.controller == "traefik"

  # --- Load balancer address (dns.mode = "nip.io" only) ----------------------
  # Read from the controller's Service unless dns.lb_ip pins it.
  lookup_lb_ip         = var.dns.mode == "nip.io" && var.dns.lb_ip == ""
  lb_service_namespace = var.ingress.service_namespace != "" ? var.ingress.service_namespace : var.ingress.namespace
  lb_service_name      = var.ingress.service_name != "" ? var.ingress.service_name : "traefik"
  lb_ingress           = local.lookup_lb_ip ? try(data.kubernetes_service_v1.ingress_lb[0].status[0].load_balancer[0].ingress[0], {}) : {}
  lb_ip                = var.dns.lb_ip != "" ? var.dns.lb_ip : try(local.lb_ingress.ip, "")
  lb_hostname          = try(local.lb_ingress.hostname, "")

  # --- Hostnames -------------------------------------------------------------
  domain = var.dns.mode == "custom" ? var.dns.base_domain : "${local.lb_ip}.${var.dns.wildcard_dns_suffix}"
  hosts  = { for name, label in var.dns.hosts : name => "${label}.${local.domain}" }

  # --- TLS -------------------------------------------------------------------
  # Modes where THIS root creates the ClusterIssuer.
  own_issuer          = contains(["self-signed-ca", "ca", "acme"], var.tls.mode)
  cluster_issuer_name = var.tls.cluster_issuer_name != "" ? var.tls.cluster_issuer_name : (var.tls.mode == "acme" ? "klique-acme" : "klique-ca")
  issuer_kind         = local.own_issuer ? "ClusterIssuer" : var.tls.issuer_kind
  issuer_name         = local.own_issuer ? local.cluster_issuer_name : var.tls.issuer_name

  # The CA Secret a CA ClusterIssuer signs with: Terraform writes it in
  # self-signed-ca mode, and in ca mode when the key is passed in.
  write_ca_secret = var.tls.mode == "self-signed-ca" || (var.tls.mode == "ca" && var.tls_ca_key_pem != "")
  ca_cert_pem     = var.tls.mode == "self-signed-ca" ? try(tls_self_signed_cert.root[0].cert_pem, "") : var.tls.ca_cert_pem

  # The private root every Klique pod must trust. Empty = a public CA.
  trust_ca_pem = chomp(contains(["self-signed-ca", "ca"], var.tls.mode) ? local.ca_cert_pem : var.tls.trust_ca_pem)

}
