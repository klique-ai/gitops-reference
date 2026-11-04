output "domain" {
  description = "The domain every Klique hostname sits under."
  value       = local.domain
}

output "urls" {
  description = "Public Klique URLs. Every tenant gets its own sessions host, shown here as a pattern."
  value = {
    app      = "https://${local.hosts.app}"
    api      = "https://${local.hosts.api}"
    files    = "https://${local.hosts.files}"
    sessions = "https://<tenant>.${local.hosts.sessions}"
  }
}

output "ingress_lb_address" {
  description = "The ingress controller's load balancer — where the hostnames must resolve to in dns.mode = \"custom\"."
  value       = local.lb_ip != "" ? local.lb_ip : local.lb_hostname
}

output "ca_certificate_pem" {
  description = "The private root CA the Klique certificates chain to — import it into browsers and SDK machines (REQUESTS_CA_BUNDLE). Empty for a public CA."
  value       = local.trust_ca_pem
}

output "secret_store" {
  description = "The SecretStore the GitOps ExternalSecrets read from, or a reminder that none was created."
  value       = local.create_secret_store ? "SecretStore/klique-secrets in ${var.klique_namespace}" : "NOT CREATED — set secret_store.provider_yaml; until then every ExternalSecret stays NotReady."
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Create the backend entries the ExternalSecrets read:
         klique-fluxcd/README.md#secrets-your-backend-must-hold
    2. Bootstrap Flux against your fork:
         flux bootstrap git --url=https://<your-git-host>/<org>/gitops-reference \
           --branch=main --path=./klique-fluxcd --token-auth
    3. Each tenant folder in klique-fluxcd/tenants gets its own sessions host,
       https://<tenant>.${local.hosts.sessions}, and its own certificate.
    4. Open https://${local.hosts.app}
  EOT
}
