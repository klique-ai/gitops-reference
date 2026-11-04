# klique-terraform

Prepares a Kubernetes cluster you already run for a GitOps Klique install,
entirely from one `terraform.tfvars`. It installs and configures:

- the ingress controller
- cert-manager and the certificates
- External Secrets Operator and the secret backend
- the namespace and the hostnames

It then hands every cluster-specific fact to GitOps in one ConfigMap. After
that, the Flux repo only decides which Klique versions run.

> **Reference, not a product.** Verified with Terraform 1.11, Traefik chart
> 41.6.0, cert-manager v1.21.2, and External Secrets 2.11.0.

- [What it sets up](#what-it-sets-up)
- [Who owns what](#who-owns-what)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Examples](#examples)
- [DNS](#dns) · [TLS](#tls) · [Secret backend](#secret-backend) · [Klique values](#klique-values) · [Upgrading](#upgrading)
- [Existing components](#existing-components) · [Private chart mirrors](#private-chart-mirrors)
- [Variable reference](#variable-reference) · [Outputs](#outputs)
- [Day-2](#day-2) · [Destroying](#destroying) · [Not included](#not-included)

## What it sets up

| file | what | skip it with |
|---|---|---|
| `preflight.tf` | fails the plan if the cluster has no default StorageClass | `require_default_storage_class = false` |
| `ingress.tf` | Traefik, IngressClass `traefik`, http→https redirect, no upload read timeout | `ingress.controller = "existing"` |
| `cert-manager.tf` | cert-manager with its CRDs | `cert_manager.install = false` |
| `issuers.tf` | the ClusterIssuer the certificates come from — see [TLS](#tls) | `tls.mode = "issuer"` |
| `certificates.tf` | `klique-tls` (app, api, files). Each tenant's gateway certificate is created by the tenant folder in GitOps | — |
| `external-secrets.tf` | External Secrets Operator | `external_secrets.install = false` |
| `secret-store.tf` | SecretStore `klique-secrets`, which every ExternalSecret reads from | leave `secret_store.provider_yaml` empty |
| `platform-handoff.tf` | the `klique` namespace, the `klique-platform` ConfigMap and the `klique-platform-vars` ConfigMap | — |

There are no cloud-provider resources, so the same root runs on EKS, GKE,
AKS, OpenShift, RKE2 or bare metal. Cloud auth lives in the kubeconfig.

## Who owns what

| set in tfvars (this directory) | set in git (`klique-fluxcd/`) |
|---|---|
| ingress controller, cert-manager, ESO: versions, placement, LB | which Klique chart versions run |
| CA, issuer, certificates | default functional values |
| hostnames and DNS mode | the ExternalSecrets: which backend paths hold which credential |
| secret backend and its auth | |
| Klique namespace, labels, annotations | |
| any Klique chart value (`klique_values`) | |

Each HelmRelease layers its values in this order, and the later source wins:

| # | source | written by |
|---|---|---|
| 1 | `klique-platform` / `<chart>.yaml`: hostnames, IngressClass, TLS, CA trust | this directory |
| 2 | `values/<chart>.yaml`, the defaults | git |
| 3 | `klique-platform` / `<chart>-overrides.yaml`, from `klique_values` | this directory |
| 4 | credentials | ESO |

Maps merge across these sources, but a list is **replaced**, never merged.
So when `klique_values` sets a list, it replaces the whole list from git.

The ConfigMap carries `reconcile.fluxcd.io/watch: Enabled`, so
helm-controller upgrades the releases as soon as `terraform apply` changes
it. Nothing secret is written into it. Beside the `<chart>.yaml` keys it
carries flat scalars for consumers that are not Helm charts: `domain`,
`ingress_class`, `issuer`, `app_url` and `api_url`.

## Requirements

- Terraform ≥ 1.10.
- A kubeconfig with **cluster-admin** on the target cluster. Terraform
  installs CRDs, ClusterIssuers and cluster-scoped RBAC.
- A default StorageClass. The preflight check enforces this.
- LoadBalancer Services, or `ingress.service_type = "NodePort"` with
  `dns.lb_ip` set to a node or external LB IP.
- Outbound access from wherever Terraform runs to the chart repositories, or
  a mirror (see [Private chart mirrors](#private-chart-mirrors)).
- For `dns.mode = "nip.io"`: users must be able to resolve public DNS, and
  the LB IP must be reachable from their machines.

## Quick start

```bash
cd klique-terraform
cp examples/nip-io-quickstart.tfvars.example terraform.tfvars
# set kubeconfig_context, and secret_store.provider_yaml for your backend
terraform init
terraform apply

terraform output urls
terraform output -raw ca_certificate_pem > klique-ca.pem   # import into your browser / SDK host
```

Then create the two credential entries in your backend, and run
`flux bootstrap`. Both steps are in
[klique-fluxcd/README.md](../klique-fluxcd/README.md#secrets-your-backend-must-hold).

## Examples

| file | for |
|---|---|
| [`nip-io-quickstart`](examples/nip-io-quickstart.tfvars.example) | a demo or PoC: Traefik, a minted CA and `<LB IP>.nip.io`, with no DNS or certificates to bring |
| [`own-ca`](examples/own-ca.tfvars.example) | your domain and your CA (the key stays out of state), AWS Secrets Manager, Traefik on dedicated nodes, GPU queue sizing |
| [`existing-issuer`](examples/existing-issuer.tfvars.example) | a shared cluster that already runs an ingress controller, cert-manager and ESO, with a corporate ClusterIssuer and Azure Key Vault |
| [`letsencrypt-dns01`](examples/letsencrypt-dns01.tfvars.example) | public certificates via ACME DNS-01, with Google Secret Manager |

## DNS

The `dns` variable has two modes:

- **`nip.io`**: the domain is `<LB IP>.nip.io`, so `app.<ip>.nip.io`
  resolves with no DNS to manage.
  - The IP comes from the controller's LoadBalancer Service, or from
    `dns.lb_ip`.
  - To use a different resolver, set `dns.wildcard_dns_suffix`, for example
    `sslip.io` or your own wildcard zone.
  - A load balancer that only reports a hostname (as AWS ELBs do) fails the
    plan with a clear message. Set `dns.lb_ip`, or use `custom`.
- **`custom`**: the domain is `dns.base_domain`. Point `app.`, `api.`,
  `files.` and `*.sessions.` at `terraform output ingress_lb_address`, or add
  a single wildcard record.
  - Each tenant's gateway is `<tenant>.sessions.<domain>`, and its running
    apps are `<id>.<tenant>.sessions.<domain>`. For DNS, one
    `*.sessions.<domain>` record covers both, at any depth. TLS does not
    work that way: see [TLS](#tls).

To rename the hostname labels, set `dns.hosts`.

## TLS

| `tls.mode` | where the certificates come from | CA key in TF state? |
|---|---|---|
| `self-signed-ca` (default) | a root CA minted by Terraform (`tls.self_signed_ca`), behind ClusterIssuer `klique-ca` | **yes**, so quickstart only |
| `ca` | **your CA**. Pre-create a `kubernetes.io/tls` Secret `tls.ca_secret_name` in the cert-manager namespace and set `tls.ca_cert_pem` to the public certificate | no. If you pass `tls_ca_key_pem` instead, yes |
| `acme` | Let's Encrypt or any ACME server. `tls.acme_solvers_yaml` **must** be DNS-01 | no |
| `issuer` | an issuer that already exists (Vault PKI, Venafi, AD CS, a corporate ClusterIssuer), set with `tls.issuer_kind` and `tls.issuer_name` | no |

- **Tenant gateway certificates:** each tenant's gateway serves its running
  apps on `<id>.<tenant>.sessions.<domain>`. A TLS wildcard covers exactly one
  label, so `*.<domain>` or `*.sessions.<domain>` do **not** cover them, and
  each tenant needs its own certificate for `<tenant>.sessions.<domain>` and
  `*.<tenant>.sessions.<domain>`.
  - The tenant folder in `klique-fluxcd/tenants` creates it, from the issuer
    in ConfigMap `klique-platform-vars` (`KLIQUE_ISSUER_KIND`,
    `KLIQUE_ISSUER_NAME`).
  - ACME therefore requires DNS-01: HTTP-01 cannot issue a wildcard.
  - **No `secret` mode:** tenants need cert-manager and a **ClusterIssuer**
    (a namespaced Issuer in `klique` cannot sign a Certificate in a tenant
    namespace). `tls.mode = "secret"`, and `tls.mode = "issuer"` with an
    `issuer_kind` other than `ClusterIssuer`, fail the plan with that message.
- **Private CAs:** the CA certificate is added to the gateway, the
  orchestrator and the Apps (`customCertificates.extraCerts`), and to every
  task pod (`propagateToTasks`). `propagateToTasks` alone is lost when a task
  image reinstalls `ca-certificates`; the Flux example's
  `values/orchestrator.yaml` also mounts the CA into task containers to cover
  that.
  - This keeps certificate verification on.
  - It happens automatically in `self-signed-ca` and `ca` modes.
  - In `issuer` mode, set `tls.trust_ca_pem` when the
    certificates chain to a private root.
- **What users must trust:** browsers and SDK machines need the same CA:
  `terraform output -raw ca_certificate_pem`, then `REQUESTS_CA_BUNDLE` for
  the SDK.
- **Key and lifetime:** set with `tls.private_key` (algorithm, size,
  rotation), `tls.duration` and `tls.renew_before`.

## Secret backend

Every ExternalSecret in the GitOps repo reads from SecretStore
`klique-secrets` in the Klique namespace. This directory creates that store
from `secret_store.provider_yaml`, which is the store's `spec.provider` block
for **any ESO provider**, e.g.:
- Vault
- AWS Secrets Manager or Parameter Store
- Google Secret Manager
- Azure Key Vault
- 1Password
- CyberArk

See the [provider list](https://external-secrets.io/latest/provider/provider-list/).
The examples show Vault, AWS, Azure and GCP.

- **Authentication:** prefer workload identity (IRSA/Pod Identity, GKE or
  Azure Workload Identity, Vault Kubernetes auth). No credential is stored
  anywhere then.
- **Static credentials:** when you need them, set `secret_store_credentials`
  (sensitive). Terraform writes them to Secret
  `klique-secret-store-credentials`, which `provider_yaml` references. They
  land in TF state, so pass them with `TF_VAR_secret_store_credentials` and
  never commit them.
- **Empty `provider_yaml`:** no store is created, and every ExternalSecret
  stays NotReady until one exists. This fails loudly on purpose, and
  `terraform output secret_store` says so.

The backend **entries** (`klique/apiserver`, `klique/registry/dockerhub`) and
their properties are defined by the ExternalSecrets in git. See
[klique-fluxcd/README.md](../klique-fluxcd/README.md#secrets-your-backend-must-hold).

## Klique values

`klique_values.control_plane`, `.orchestrator` and `.gateway` take YAML with
any Helm value of that chart. They are applied **after** the git values
files, so tfvars win:

```hcl
klique_values = {
  control_plane = <<-YAML
    controlPlane:
      maxUsers: 50
  YAML
  orchestrator = <<-YAML
    orchestratork8sglue:
      defaultContainerImage: "nvcr.io/nvidia/pytorch:24.08-py3"
  YAML
}
```

Rules for `klique_values`:

- Keep secret values out of it; they belong in ESO.
- A list set here replaces the git list entirely. For example, setting
  `apiserver.extraEnvs` drops the credential envs in git's
  `values/control-plane.yaml`, so copy them across if you override that list.
- You can also override the platform keys from section 1, such as
  hostnames. That works, but the certificates will not follow; change `dns`
  instead.

## Existing components

Every add-on can be turned off separately. When it is, the cluster must
already provide it:

| off | the cluster must already have |
|---|---|
| `ingress.controller = "existing"` | an IngressClass (`ingress.class_name`) that serves wildcard hosts and WebSockets, and allows large request bodies. `ingress.annotations` is added to every Klique Ingress, e.g. nginx `proxy-body-size: "0"`. In nip.io mode, also set `ingress.service_namespace`/`service_name`, or `dns.lb_ip` |
| `cert_manager.install = false` | cert-manager CRDs and a running webhook |
| `external_secrets.install = false` | ESO serving `external-secrets.io/v1` |

Any add-on chart value can be overridden with `<addon>.extra_values`, a YAML
string applied after this directory's values.

## Private chart mirrors

For air-gapped clusters or a corporate registry:

- **Chart source:** point `ingress.repository`, `cert_manager.repository` and
  `external_secrets.repository` at your mirror (HTTP or `oci://`).
- **Registry credentials:** set `helm_repository_credentials` (sensitive),
  keyed `traefik`, `cert_manager`, `external_secrets`.
- **Images:** redirect them through `<addon>.extra_values`, e.g. cert-manager
  `image.repository`.

## Variable reference

Every input, with its default. Object fields are all optional.

### Cluster and namespace

| variable | default | |
|---|---|---|
| `kubeconfig_path` | `~/.kube/config` | |
| `kubeconfig_context` | current-context | |
| `require_default_storage_class` | `true` | preflight check |
| `klique_namespace` | `klique` | leave as `klique` unless you also edit every namespace in the Flux example, where it is hardcoded |
| `klique_namespace_labels` | `{}` | e.g. Pod Security Admission |
| `klique_namespace_annotations` | `{}` | e.g. OpenShift node-selector |
| `helm_repository_credentials` | `{}` | sensitive; see [mirrors](#private-chart-mirrors) |

### `ingress`

| field | default | |
|---|---|---|
| `controller` | `traefik` | `traefik` \| `existing` |
| `class_name` | `traefik` | the IngressClass the Klique Ingresses use |
| `namespace` | `traefik` | Traefik only (applies to every field down to `extra_values`) |
| `repository` | `https://traefik.github.io/charts` | |
| `chart_version` | `41.6.0` | |
| `replicas` | `1` | |
| `default_class` | `false` | make it the cluster's default IngressClass |
| `redirect_to_https` | `true` | |
| `service_type` | `LoadBalancer` | `LoadBalancer` \| `NodePort` |
| `service_annotations` | `{}` | cloud LB settings |
| `load_balancer_ip` | `""` | |
| `load_balancer_class` | `""` | |
| `node_selector` | `{}` | |
| `tolerations` | `[]` | list of `{key, operator, value, effect}` |
| `extra_values` | `""` | YAML, applied last |
| `service_namespace`, `service_name` | the Traefik Service | where to read the LB IP in nip.io mode |
| `annotations` | `{}` | added to every Klique Ingress |

### `dns`

| field | default | |
|---|---|---|
| `mode` | `nip.io` | `nip.io` \| `custom` |
| `base_domain` | `""` | required for `custom` |
| `wildcard_dns_suffix` | `nip.io` | e.g. `sslip.io` |
| `lb_ip` | read from the LB | pins the nip.io IP |
| `hosts` | `app`, `api`, `files`, `sessions` | hostname labels |

### `tls`

| field | default | |
|---|---|---|
| `mode` | `self-signed-ca` | see [TLS](#tls) |
| `cluster_issuer_name` | `klique-ca` / `klique-acme` | the issuer this directory creates |
| `self_signed_ca` | `{common_name = "Klique Root CA", organization = "Klique", validity_hours = 87600, algorithm = "RSA", rsa_bits = 4096, ecdsa_curve = "P384"}` | `self-signed-ca` only |
| `ca_secret_name` | `klique-root-ca` | `ca`: the pre-created keypair Secret in the cert-manager namespace |
| `ca_cert_pem` | `""` | `ca`: the public CA certificate (required) |
| `acme_email`, `acme_server`, `acme_solvers_yaml` | Let's Encrypt production | `acme`: the solvers must be DNS-01 |
| `issuer_kind`, `issuer_name` | `ClusterIssuer`, `""` | `issuer` |
| `app_secret_name` | `klique-tls` | |
| `duration`, `renew_before` | `2160h`, `360h` | 90 days, renewed 15 days ahead |
| `private_key` | `{algorithm = "RSA", size = 2048, rotation_policy = "Always"}` | ECDSA sizes 256/384/521; Ed25519 has no size |
| `trust_ca_pem` | auto in `self-signed-ca`/`ca` | a private root to trust in `issuer` mode |

`tls_ca_key_pem` (sensitive, default `""`) is for `ca` mode only: the CA key,
if Terraform should write the CA Secret itself.

### `cert_manager`, `external_secrets`

| field | cert_manager | external_secrets |
|---|---|---|
| `install` | `true` | `true` |
| `namespace` | `cert-manager` | `external-secrets` |
| `repository` | `https://charts.jetstack.io` | `https://charts.external-secrets.io` |
| `chart_version` | `v1.21.2` | `2.11.0` |
| `extra_values` | `""` | `""` |

### `secret_store`

| field | default | |
|---|---|---|
| `provider_yaml` | `""` | the SecretStore's `spec.provider`; empty = no store |
| `refresh_interval` | `0` (ESO default) | seconds between store re-validations |

`secret_store_credentials` (sensitive, default `{}`) is written to Secret
`klique-secret-store-credentials`.

### `klique_values`

| field | default | |
|---|---|---|
| `control_plane`, `orchestrator`, `gateway` | `""` | YAML, applied after the git values files |

## Outputs

| output | |
|---|---|
| `domain` | the domain every hostname sits under |
| `urls` | app, api, files, and the sessions pattern `https://<tenant>.sessions.<domain>` |
| `ingress_lb_address` | where the hostnames must resolve (custom DNS) |
| `ca_certificate_pem` | the private root to trust; empty for a public CA |
| `secret_store` | whether SecretStore `klique-secrets` was created |
| `next_steps` | the remaining steps, including `flux bootstrap` |

## Day-2

```bash
terraform plan    # after any tfvars change; the klique-platform diff is what the releases will see
terraform apply   # helm-controller picks up klique-platform changes immediately
flux get helmreleases -n klique
kubectl -n klique get configmap klique-platform -o yaml
kubectl get clusterissuer; kubectl -n klique get certificate,secretstore,configmap klique-platform-vars
```

- **Add-on upgrades:** bump `<addon>.chart_version` after reading that
  chart's upgrade notes, then run `terraform apply`. cert-manager's CRDs are
  upgraded with the chart and kept if it is ever uninstalled.
- **Klique upgrades** are a git commit in `klique-fluxcd/`, not a tfvars
  change.
- **Namespace already exists:** if `klique` predates this directory (e.g.
  from an older `klique-fluxcd`), import it first:
  `terraform import kubernetes_namespace_v1.klique klique`.
- **Certificate renewal** is handled by cert-manager, `renew_before` ahead
  of expiry. Terraform is not involved.
- **State:** use an encrypted, access-controlled remote backend (`backend.tf`,
  `backend.hcl.example`) for anything shared. State can hold:
  - the CA key (`self-signed-ca`, or `tls_ca_key_pem`)
  - `secret_store_credentials`
  - `helm_repository_credentials`

## Upgrading

Moving the gateway into each tenant removed these inputs and resources.
Delete the old attributes from your tfvars. A leftover attribute inside `dns`
or `tls` (`dns.hosts.sessions_tcp`, `tls.sessions_secret_name`) is silently
**ignored**, so nothing tells you it does nothing. An undeclared top-level
`tcp_sessions` prints a warning. Two inputs now fail the plan: `tls.mode =
"secret"`, and `tls.mode = "issuer"` with an `issuer_kind` other than
`ClusterIssuer`.

| removed | why |
|---|---|
| `tcp_sessions` (all fields) and output `tcp_sessions_router_address` | the per-tenant gateways run with `streamSession` disabled, so there is no raw-TCP Service |
| `dns.hosts.sessions_tcp` | same |
| `tls.sessions_secret_name` | each tenant has its own `<tenant>-gateway-tls` Secret |
| Certificate `klique-sessions-tls` | `terraform apply` destroys it. cert-manager normally leaves its Secret behind: delete Secret `klique-sessions-tls` in the Klique namespace once the shared gateway is gone |

- **Existing `tls.mode = "secret"` installs** must switch before applying:
  `issuer` (your CA behind a ClusterIssuer), `ca` or `acme`. Tenant gateways
  now require cert-manager and a ClusterIssuer that can issue wildcards
  (`*.<tenant>.sessions.<domain>`). From then on cert-manager manages Secret
  `tls.app_secret_name`: it re-issues into a hand-made Secret of that name, so
  back it up and expect it to be replaced.
- **New:** ConfigMap `klique-platform-vars`, read by Flux (`KLIQUE_DOMAIN`,
  `KLIQUE_SESSIONS_HOST`, `KLIQUE_ISSUER_KIND`, `KLIQUE_ISSUER_NAME`,
  `KLIQUE_INGRESS_CLASS`).
- **Changed:** `klique-platform`'s `gateway.yaml` no longer sets `hostName`,
  `tlsSecretName`, `externalURL` or `streamSession`. Each tenant's gateway
  release sets them.
- **Order: `terraform apply` first, then the `klique-fluxcd/` commit.**
  Apply writes `klique-platform-vars`, which the tenants Kustomization needs.
  - **Expected transient:** until Flux prunes it, the old shared gateway
    release may fail an upgrade, because `klique-platform` no longer sets its
    `hostName`. It is removed by the same Flux commit.
  - **Leftover task pods:** pods the old shared orchestrator started in the
    `klique` namespace are not removed. List them, read-only, with
    `kubectl -n klique get pods -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind`:
    the components of the Klique releases have an owner (ReplicaSet,
    StatefulSet, Job), while task pods the orchestrator created directly show
    `<none>`. Delete the finished or stale ones after checking them.

## Destroying

`terraform destroy` removes the `klique` **namespace**, and with it
everything Flux installed there, including the MongoDB and Elasticsearch
PVCs. Suspend Flux and back up the datastores first. To remove only the
add-ons, turn them off in tfvars and apply.

## Not included

- Cluster creation.
- external-dns.
- Monitoring.
- Flux bootstrap. It stays manual on purpose: bootstrapping from Terraform
  would store a git write credential in state.
