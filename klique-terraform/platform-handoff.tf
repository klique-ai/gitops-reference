# The handoff to GitOps: everything cluster-specific the Klique releases need,
# in ONE ConfigMap the Flux HelmReleases read first in their valuesFrom.
#
#   Terraform owns: the namespace, hostnames, IngressClass, TLS Secret names,
#                   the CA to trust.
#   GitOps owns:    what Klique does — releases, versions, functional values,
#                   ExternalSecrets.
#
# One owner per key: a key rendered here must not also appear in the GitOps
# values files. Values later in valuesFrom win a collision silently, and a
# list split across both is replaced, not merged.
#
# Nothing secret goes in here — credentials reach the charts through ESO.

resource "kubernetes_namespace_v1" "klique" {
  metadata {
    name = var.klique_namespace
    labels = merge(var.klique_namespace_labels, {
      "app.kubernetes.io/managed-by" = "Terraform"
    })
    annotations = var.klique_namespace_annotations
  }

  depends_on = [terraform_data.preflight]
}

locals {
  ingress_annotations = jsonencode(var.ingress.annotations)

  common_values = {
    domain              = local.domain
    app_host            = local.hosts.app
    api_host            = local.hosts.api
    files_host          = local.hosts.files
    pmc_host            = local.hosts.pmc
    ingress_class       = var.ingress.class_name
    ingress_annotations = local.ingress_annotations
    trust_ca_pem        = local.trust_ca_pem
  }
}

resource "kubernetes_config_map_v1" "klique_platform" {
  metadata {
    name      = "klique-platform"
    namespace = kubernetes_namespace_v1.klique.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
      # helm-controller watches labelled valuesFrom sources: a re-apply here
      # upgrades the releases right away, not at the next interval.
      "reconcile.fluxcd.io/watch" = "Enabled"
    }
  }

  data = {
    "control-plane.yaml" = templatefile("${path.module}/klique-values/control-plane.yaml", merge(local.common_values, {
      tls_secret = var.tls.app_secret_name
    }))
    "orchestrator.yaml" = templatefile("${path.module}/klique-values/orchestrator.yaml", local.common_values)
    "gateway.yaml"      = templatefile("${path.module}/klique-values/gateway.yaml", local.common_values)
    "platform-management-center.yaml" = templatefile("${path.module}/klique-values/platform-management-center.yaml", merge(local.common_values, {
      tls_secret = var.tls.app_secret_name
    }))

    # Partner overrides from var.klique_values, read by each HelmRelease AFTER
    # the git values file: tfvars win over git, credentials win over both.
    # Always present ("{}" when unset) so the reference never dangles.
    "control-plane-overrides.yaml" = var.klique_values.control_plane != "" ? var.klique_values.control_plane : "{}"
    "orchestrator-overrides.yaml"  = var.klique_values.orchestrator != "" ? var.klique_values.orchestrator : "{}"
    "gateway-overrides.yaml"       = var.klique_values.gateway != "" ? var.klique_values.gateway : "{}"
    "platform-management-center-overrides.yaml" = (
      var.klique_values.platform_management_center != "" ? var.klique_values.platform_management_center : "{}"
    )

    # Plain scalars, for consumers that are not Helm charts.
    "domain"        = local.domain
    "ingress_class" = var.ingress.class_name
    "issuer"        = "${local.issuer_kind}/${local.issuer_name}"
    # Public URLs. app_url is read by the Flux example's tenant reconciler
    # Jobs, which log each tenant's login and SSO callback URLs.
    "app_url" = "https://${local.hosts.app}"
    "api_url" = "https://${local.hosts.api}"
    "pmc_url" = "https://${local.hosts.pmc}"
  }

  lifecycle {
    precondition {
      condition     = var.dns.mode != "nip.io" || can(cidrhost("${local.lb_ip}/32", 0))
      error_message = "dns.mode = \"nip.io\" needs the ingress load balancer's IP, but found '${local.lb_ip}'${local.lb_hostname != "" ? " (the LB only reports a hostname: ${local.lb_hostname} — typical of AWS ELBs)" : ""}. Set dns.lb_ip, or use dns.mode = \"custom\" with your own domain."
    }
  }

  # Only once the TLS Secrets exist: the charts' Ingresses reference them.
  depends_on = [kubectl_manifest.certificate]
}

# The same facts as flat KEY=value pairs, for Flux postBuild.substituteFrom:
# the per-tenant gateway and Certificate are plain manifests in git, and
# klique-platform's keys ("control-plane.yaml") are not valid variable names.
# The tenants Kustomization lives in the Klique namespace, which is why this
# ConfigMap does too.
resource "kubernetes_config_map_v1" "klique_platform_vars" {
  metadata {
    name      = "klique-platform-vars"
    namespace = kubernetes_namespace_v1.klique.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  data = {
    KLIQUE_DOMAIN        = local.domain
    KLIQUE_SESSIONS_HOST = local.hosts.sessions
    KLIQUE_ISSUER_KIND   = local.issuer_kind
    KLIQUE_ISSUER_NAME   = local.issuer_name
    KLIQUE_INGRESS_CLASS = var.ingress.class_name
  }

  depends_on = [kubectl_manifest.certificate]
}
