# Traefik as the ingress controller: it serves the plain Ingress objects the
# Klique charts render — including each tenant gateway's *.<tenant>.sessions.<domain>
# wildcard host — and WebSockets, with no controller-specific annotations.
#
# ingress.controller = "existing" skips this; the charts then use the
# partner's IngressClass (ingress.class_name).

resource "helm_release" "traefik" {
  count = local.install_traefik ? 1 : 0

  name             = "traefik"
  repository       = var.ingress.repository
  chart            = "traefik"
  version          = var.ingress.chart_version
  namespace        = var.ingress.namespace
  create_namespace = true

  repository_username = try(var.helm_repository_credentials["traefik"].username, null)
  repository_password = try(var.helm_repository_credentials["traefik"].password, null)

  # Also waits for the LoadBalancer Service to get an address, which the
  # nip.io domain is derived from.
  wait    = true
  timeout = 600

  values = compact([
    templatefile("${path.module}/helm-values/traefik.yaml", {
      class_name          = var.ingress.class_name
      default_class       = var.ingress.default_class
      redirect_to_https   = var.ingress.redirect_to_https
      replicas            = var.ingress.replicas
      service_type        = var.ingress.service_type
      service_annotations = jsonencode(var.ingress.service_annotations)
      load_balancer_ip    = var.ingress.load_balancer_ip
      load_balancer_class = var.ingress.load_balancer_class
      node_selector       = jsonencode(var.ingress.node_selector)
      tolerations         = jsonencode(var.ingress.tolerations)
    }),
    var.ingress.extra_values,
  ])

  depends_on = [terraform_data.preflight]
}

# The controller's LoadBalancer address, when dns.mode = "nip.io" derives the
# domain from it.
data "kubernetes_service_v1" "ingress_lb" {
  count = local.lookup_lb_ip ? 1 : 0

  metadata {
    namespace = local.lb_service_namespace
    name      = local.lb_service_name
  }

  depends_on = [helm_release.traefik]
}
