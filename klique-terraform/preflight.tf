# Fail-loud checks, evaluated before anything is installed: a cluster that
# cannot run Klique should stop the plan, not surface later as a Pending PVC.

data "kubernetes_resources" "storage_classes" {
  count       = var.require_default_storage_class ? 1 : 0
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
}

resource "terraform_data" "preflight" {
  lifecycle {
    precondition {
      condition = !var.require_default_storage_class || anytrue([
        for sc in try(data.kubernetes_resources.storage_classes[0].objects, []) :
        try(sc.metadata.annotations["storageclass.kubernetes.io/is-default-class"], "") == "true"
      ])
      error_message = "The cluster has no default StorageClass. The control plane runs MongoDB, Elasticsearch and Valkey on PVCs that request the default class — mark one as default (annotation storageclass.kubernetes.io/is-default-class=\"true\"), or set require_default_storage_class = false if the chart values name a class explicitly."
    }
    precondition {
      condition     = !(var.dns.mode == "nip.io" && var.ingress.controller == "existing" && var.dns.lb_ip == "" && var.ingress.service_name == "")
      error_message = "dns.mode = \"nip.io\" with an existing ingress controller needs either dns.lb_ip or ingress.service_namespace + ingress.service_name (the controller's LoadBalancer Service) to derive the domain from."
    }
  }
}
