# Every input of this root. The README's "Variable reference" mirrors this
# file — keep the two in step.

# --- Cluster access -----------------------------------------------------------

variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the target (existing) cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "kubeconfig context to use. null = the file's current-context."
  type        = string
  default     = null
}

variable "require_default_storage_class" {
  description = "Fail the plan when the cluster has no default StorageClass — the control plane runs MongoDB, Elasticsearch and Valkey on PVCs."
  type        = bool
  default     = true
}

# --- Klique namespace ---------------------------------------------------------

variable "klique_namespace" {
  description = "Namespace the Klique releases run in. Terraform owns it. Leave it at \"klique\" unless you also change the Flux example: its manifests hardcode `klique` (kustomization.yaml, every metadata.namespace, the health checks)."
  type        = string
  default     = "klique"
}

variable "klique_namespace_labels" {
  description = "Extra labels on the Klique namespace — e.g. Pod Security Admission (pod-security.kubernetes.io/enforce), or a label your network policies select on."
  type        = map(string)
  default     = {}
}

variable "klique_namespace_annotations" {
  description = "Extra annotations on the Klique namespace — e.g. OpenShift's openshift.io/node-selector, or a scheduler/cost-center annotation."
  type        = map(string)
  default     = {}
}

# --- Helm chart sources -------------------------------------------------------

variable "helm_repository_credentials" {
  description = "Credentials for the add-on chart repositories, keyed by add-on: traefik, cert_manager, external_secrets. Only needed for a private mirror (see <addon>.repository)."
  type = map(object({
    username = string
    password = string
  }))
  default   = {}
  sensitive = true
}

# --- Ingress controller -------------------------------------------------------

variable "ingress" {
  description = <<-EOT
    Ingress controller. controller = "traefik" installs Traefik; "existing"
    installs nothing and uses the partner's IngressClass `class_name`.
    See the README's "Variable reference" for every field.
  EOT
  type = object({
    controller = optional(string, "traefik")
    class_name = optional(string, "traefik")

    # Traefik install (controller = "traefik").
    namespace           = optional(string, "traefik")
    repository          = optional(string, "https://traefik.github.io/charts")
    chart_version       = optional(string, "41.6.0")
    replicas            = optional(number, 1)
    default_class       = optional(bool, false)
    redirect_to_https   = optional(bool, true)
    service_type        = optional(string, "LoadBalancer")
    service_annotations = optional(map(string), {})
    load_balancer_ip    = optional(string, "")
    load_balancer_class = optional(string, "")
    node_selector       = optional(map(string), {})
    tolerations         = optional(list(map(string)), [])
    extra_values        = optional(string, "")

    # Where to read the LB IP from in dns.mode = "nip.io". Default: the
    # Traefik release's Service.
    service_namespace = optional(string, "")
    service_name      = optional(string, "")

    # Added to EVERY Klique Ingress.
    annotations = optional(map(string), {})
  })
  default = {}

  validation {
    condition     = contains(["traefik", "existing"], var.ingress.controller)
    error_message = "ingress.controller must be \"traefik\" or \"existing\"."
  }
  validation {
    condition     = contains(["LoadBalancer", "NodePort"], var.ingress.service_type)
    error_message = "ingress.service_type must be \"LoadBalancer\" or \"NodePort\"."
  }
  validation {
    condition     = var.ingress.extra_values == "" || can(yamldecode(var.ingress.extra_values))
    error_message = "ingress.extra_values must be valid YAML."
  }
}

# --- DNS ----------------------------------------------------------------------

variable "dns" {
  description = <<-EOT
    How the Klique hostnames are formed.

    mode = "nip.io": domain = <LB IP>.<wildcard_dns_suffix>, e.g. 203.0.113.10.nip.io.
      No DNS to manage; the IP comes from lb_ip, or from the ingress
      controller's LoadBalancer Service. Any wildcard-IP DNS works as the
      suffix (nip.io, sslip.io, or your own).
    mode = "custom": domain = base_domain. You point the hostnames (or a
      wildcard) at the ingress controller's load balancer.

    hosts: the label of each hostname under the domain.
  EOT
  type = object({
    mode                = optional(string, "nip.io")
    base_domain         = optional(string, "")
    wildcard_dns_suffix = optional(string, "nip.io")
    lb_ip               = optional(string, "")
    hosts = optional(object({
      app      = optional(string, "app")
      api      = optional(string, "api")
      files    = optional(string, "files")
      sessions = optional(string, "sessions")
      pmc      = optional(string, "pmc")
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["nip.io", "custom"], var.dns.mode)
    error_message = "dns.mode must be \"nip.io\" or \"custom\"."
  }
  validation {
    condition     = var.dns.mode != "custom" || var.dns.base_domain != ""
    error_message = "dns.mode = \"custom\" requires dns.base_domain."
  }
}

# --- TLS ----------------------------------------------------------------------

variable "tls" {
  description = <<-EOT
    Where the Klique certificates come from. mode:

      self-signed-ca  Terraform mints a private root CA (key in TF state) and a
                      cert-manager CA ClusterIssuer. Quickstart / nip.io.
      ca              YOUR CA. Set ca_cert_pem, and either pre-create
                      ca_secret_name (tls.crt + tls.key) in the cert-manager
                      namespace — the key never touches TF state — or pass the
                      key in var.tls_ca_key_pem.
      acme            ACME (Let's Encrypt by default). acme_solvers_yaml MUST
                      contain a dns01 solver: *.<tenant>.sessions.<domain> is a
                      wildcard, and HTTP-01 cannot issue wildcards.
      issuer          An issuer that already exists (Vault, Venafi, AD CS,
                      a corporate ClusterIssuer...): issuer_kind (must be ClusterIssuer)/issuer_name.
                      Set trust_ca_pem if it chains to a private root.

    trust_ca_pem: a private root CA the Klique pods (and task pods) must trust
    to reach the apiserver over https. Filled automatically in
    self-signed-ca and ca modes.
  EOT
  type = object({
    mode                = optional(string, "self-signed-ca")
    cluster_issuer_name = optional(string, "")

    # self-signed-ca: the minted root.
    self_signed_ca = optional(object({
      common_name    = optional(string, "Klique Root CA")
      organization   = optional(string, "Klique")
      validity_hours = optional(number, 87600) # 10 years
      algorithm      = optional(string, "RSA")
      rsa_bits       = optional(number, 4096)
      ecdsa_curve    = optional(string, "P384")
    }), {})

    # ca: your CA.
    ca_secret_name = optional(string, "klique-root-ca")
    ca_cert_pem    = optional(string, "")

    # acme.
    acme_email        = optional(string, "")
    acme_server       = optional(string, "https://acme-v02.api.letsencrypt.org/directory")
    acme_solvers_yaml = optional(string, "")

    # issuer.
    issuer_kind = optional(string, "ClusterIssuer")
    issuer_name = optional(string, "")

    # The app certificate (a cert-manager Certificate).
    app_secret_name = optional(string, "klique-tls")
    duration        = optional(string, "2160h")
    renew_before    = optional(string, "360h")
    private_key = optional(object({
      algorithm       = optional(string, "RSA")
      size            = optional(number, 2048)
      rotation_policy = optional(string, "Always")
    }), {})

    trust_ca_pem = optional(string, "")
  })
  default = {}

  validation {
    condition     = contains(["self-signed-ca", "ca", "acme", "issuer"], var.tls.mode)
    error_message = "tls.mode must be one of: self-signed-ca, ca, acme, issuer. (\"secret\" is not supported: every tenant's gateway needs a certificate from cert-manager and a ClusterIssuer, so tenants cannot run without them.)"
  }
  validation {
    condition     = var.tls.mode != "ca" || var.tls.ca_cert_pem != ""
    error_message = "tls.mode = \"ca\" requires tls.ca_cert_pem (the public CA certificate — it is also what the Klique pods trust)."
  }
  validation {
    condition     = var.tls.mode != "acme" || (var.tls.acme_email != "" && strcontains(var.tls.acme_solvers_yaml, "dns01"))
    error_message = "tls.mode = \"acme\" requires tls.acme_email and a dns01 solver in tls.acme_solvers_yaml: *.<tenant>.sessions.<domain> is a wildcard, which HTTP-01 cannot issue."
  }
  validation {
    condition     = var.tls.mode != "issuer" || (var.tls.issuer_name != "" && var.tls.issuer_kind == "ClusterIssuer")
    error_message = "tls.mode = \"issuer\" requires tls.issuer_name and tls.issuer_kind = \"ClusterIssuer\": each tenant's gateway Certificate lives in the tenant's namespace, where a namespaced Issuer in the Klique namespace cannot be used."
  }
  validation {
    condition     = contains(["RSA", "ECDSA"], var.tls.self_signed_ca.algorithm) && contains(["RSA", "ECDSA", "Ed25519"], var.tls.private_key.algorithm)
    error_message = "tls.self_signed_ca.algorithm must be RSA or ECDSA; tls.private_key.algorithm must be RSA, ECDSA or Ed25519."
  }
  validation {
    condition = (
      var.tls.private_key.algorithm == "Ed25519" ||
      (var.tls.private_key.algorithm == "RSA" && var.tls.private_key.size >= 2048) ||
      (var.tls.private_key.algorithm == "ECDSA" && contains([256, 384, 521], var.tls.private_key.size))
    )
    error_message = "tls.private_key.size must be >= 2048 for RSA, or one of 256/384/521 for ECDSA (ignored for Ed25519)."
  }
  validation {
    condition     = contains(["Always", "Never"], var.tls.private_key.rotation_policy)
    error_message = "tls.private_key.rotation_policy must be \"Always\" or \"Never\"."
  }
}

variable "tls_ca_key_pem" {
  description = "tls.mode = \"ca\" only: the CA private key, if Terraform should create the CA Secret. Prefer pre-creating tls.ca_secret_name instead — this value lands in TF state."
  type        = string
  default     = ""
  sensitive   = true
}

# --- Add-ons ------------------------------------------------------------------

variable "cert_manager" {
  description = "cert-manager. install = false when the cluster already runs it (its CRDs and webhook are still required: tenant gateways need cert-manager)."
  type = object({
    install       = optional(bool, true)
    namespace     = optional(string, "cert-manager")
    repository    = optional(string, "https://charts.jetstack.io")
    chart_version = optional(string, "v1.21.2")
    extra_values  = optional(string, "")
  })
  default = {}

  validation {
    condition     = var.cert_manager.extra_values == "" || can(yamldecode(var.cert_manager.extra_values))
    error_message = "cert_manager.extra_values must be valid YAML."
  }
}

variable "external_secrets" {
  description = "External Secrets Operator. install = false when the cluster already runs it (serving external-secrets.io/v1)."
  type = object({
    install       = optional(bool, true)
    namespace     = optional(string, "external-secrets")
    repository    = optional(string, "https://charts.external-secrets.io")
    chart_version = optional(string, "2.11.0")
    extra_values  = optional(string, "")
  })
  default = {}

  validation {
    condition     = var.external_secrets.extra_values == "" || can(yamldecode(var.external_secrets.extra_values))
    error_message = "external_secrets.extra_values must be valid YAML."
  }
}

# --- Secret backend -----------------------------------------------------------

variable "secret_store" {
  description = <<-EOT
    The ESO SecretStore `klique-secrets` in the Klique namespace, which every
    ExternalSecret in the GitOps repo reads from.

    provider_yaml: the SecretStore's spec.provider block, as YAML — any ESO
    provider (https://external-secrets.io/latest/provider/provider-list/).
    Empty = no SecretStore is created, and every ExternalSecret stays
    NotReady until one exists: a loud failure on purpose.

    refresh_interval: how often ESO re-validates the store.
  EOT
  type = object({
    provider_yaml    = optional(string, "")
    refresh_interval = optional(number, 0)
  })
  default = {}

  validation {
    condition     = var.secret_store.provider_yaml == "" || can(yamldecode(var.secret_store.provider_yaml))
    error_message = "secret_store.provider_yaml must be valid YAML (the contents of spec.provider)."
  }
}

variable "secret_store_credentials" {
  description = "Optional: static credentials the SecretStore authenticates to the backend with, written to Secret `klique-secret-store-credentials` in the Klique namespace for provider_yaml to reference. Prefer workload identity (IRSA, GKE/Azure Workload Identity, Vault Kubernetes auth) — these values land in TF state."
  type        = map(string)
  default     = {}
  sensitive   = true
}

# --- Klique values ------------------------------------------------------------

variable "klique_values" {
  description = <<-EOT
    Per-chart Helm values from tfvars, as YAML strings: control_plane,
    orchestrator, gateway, platform_management_center. Written to klique-platform as
    <chart>-overrides.yaml and read by each HelmRelease AFTER the git values
    file — so a key here wins over the same key in git (maps merge, lists
    are replaced). Credentials still win over both.

    For functional settings a partner wants in tfvars (seat cap, queues,
    default task image, node selectors...). Never secret values — use ESO.
  EOT
  type = object({
    control_plane = optional(string, "")
    orchestrator  = optional(string, "")
    gateway       = optional(string, "")

    platform_management_center = optional(string, "")
  })
  default = {}

  validation {
    condition = alltrue([
      for v in [
        var.klique_values.control_plane, var.klique_values.orchestrator, var.klique_values.gateway,
        var.klique_values.platform_management_center,
      ] :
      v == "" || can(yamldecode(v))
    ])
    error_message = "Every klique_values entry must be valid YAML."
  }
}
