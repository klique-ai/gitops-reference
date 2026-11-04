# klique-fluxcd

A minimal, working GitOps setup for Klique on Kubernetes: Flux reconciles the
control plane and the Klique tenants (each with its own orchestrator and
gateway) from this directory, and the External Secrets Operator (ESO) pulls
the credentials they need from your own secret backend.

Fork it, replace the placeholders, bootstrap Flux. You own it from the first
commit.

> **Example, not a product.** Verified against chart versions control-plane
> 1.6.2, orchestrator 1.1.1, gateway 1.4.0 — the releases track the newest 1.x,
> so what runs can be newer than what was verified, and newer versions may
> rename values keys. For help, use your normal Klique support channel.

## What gets installed

| release | chart | namespace | what it is |
|---|---|---|---|
| `control-plane` | control-plane | `klique` | apiserver, web UI, fileserver, MongoDB, Elasticsearch, Valkey, MCP server |
| `<tenant>-orchestrator` | orchestrator | the tenant's | the k8s glue: runs that tenant's tasks as pods in its namespace and registers its queues |
| `<tenant>-gateway` | gateway | the tenant's | routes that tenant's interactive sessions and running apps, at `https://<tenant>.<sessions host>` |

The **tenants**: one folder per Klique tenant under
[`tenants/`](tenants/README.md). Each folder gets a namespace, a Job that
creates the tenant, mints its keys and configures its own SSO provider, and
that tenant's own orchestrator and gateway, which authenticate with those
keys. The control plane runs its Platform Management server (in-cluster only)
for this, with tenant login on: each tenant signs in at
`https://<app host>/login/<tenant>`. The fixed admin login is unchanged, but
the default company it signs in to has no orchestrator: tasks run in tenants.

Deliberately not included: the Platform Management Center UI, monitoring,
provisioning ClearML applications from git. All can be added later; none are
needed for a working control plane.

## Layout

```
kustomization.yaml            root: flux-system + kustomizations/
kustomizations/klique.yaml    the Flux Kustomization that reconciles ./klique
kustomizations/tenants.yaml   the Flux Kustomization that reconciles ./tenants
klique-platform.example.yaml  the cluster-facts ConfigMaps, by hand (without klique-terraform)
secretstore.example.yaml      the ESO SecretStore, by hand (without klique-terraform)
klique/
  externalsecret-*.yaml       credentials pulled from your backend (pointers only)
  helmrepository.yaml         the Klique chart registry (OCI)
  helmrelease-control-plane.yaml  the control plane, version range here
  values/                     Helm values, one file per chart (orchestrator, gateway: shared by all tenants)
  valuesfrom-nameref.yaml     Kustomize wiring for the control-plane values ConfigMap
  secretstore-tenants.yaml    the store that serves only the pull secret to tenant namespaces
  clusterexternalsecret-dockerhub.yaml  copies the pull secret into every tenant namespace
tenants/                      one folder per Klique tenant; no kustomization.yaml on purpose
  README.md                   how to add a tenant, every tenant.json field, IdP setup
  tenant-example/             the folder to copy
tenant-reconciler/            what every tenant folder pulls in (a Kustomize Component)
  reconcile.py                the script each tenant's Job runs (stdlib Python)
  job.yaml, namespace.yaml, rolebinding.yaml, replacements.yaml
  helmrelease-orchestrator.yaml, helmrelease-gateway.yaml   the tenant's own releases
  certificate-gateway.yaml    the tenant gateway's TLS certificate
  valuesfrom-nameref.yaml     Kustomize wiring for the tenant's values files
  rbac/                       the Job's ServiceAccount and ClusterRole, via klique/
  tests/                      unit tests, run by scripts/check.sh
flux-system/                  created by `flux bootstrap` — not in a fresh clone
```

## Prerequisites

- A Kubernetes cluster you operate, with a default StorageClass (the control
  plane runs stateful datastores)
- The cluster prerequisites and the `klique-platform` ConfigMap, either:
  - **with [`klique-terraform`](../klique-terraform/README.md)** (recommended)
    — installs the ingress controller, cert-manager, the certificates and
    ESO, creates the `klique` namespace and the SecretStore, and writes
    `klique-platform`, all from tfvars; or
  - **by hand** — an ingress controller, TLS Secrets for the hostnames
    below, External Secrets Operator, the `klique` namespace, and
    [`klique-platform.example.yaml`](klique-platform.example.yaml) and
    [`secretstore.example.yaml`](secretstore.example.yaml) filled in and
    applied
- The Flux CLI, for `flux bootstrap`
- The Docker Hub credentials for the Klique chart registry, issued with your
  license

## Secrets your backend must hold

Nothing secret is in this repo — every ExternalSecret is a pointer. Create
these entries in your backend before the first reconcile. The backend must support
path-style keys like `klique/apiserver`; some cannot (the ESO `kubernetes`
provider, for one — a Secret name can't contain `/`), in which case use your
own paths, see the placeholder table below:

| entry | properties | used for |
|---|---|---|
| `klique/registry/dockerhub` | `username`, `password` | pulling the Klique charts and images |
| `klique/apiserver` | `key`, `secret` | the apiserver's own service credential pair |
| | `admin_user`, `admin_password` | the fixed admin login for the web UI |
| `klique/tenants/<tenant>/sso` | one per secret the tenant's `tenant.json` refers to | that tenant's IdP secrets (client secrets, SAML private keys); see [tenants/](tenants/README.md#secrets) |
| `klique/tenants/tenant-example/sso` | `oidcClientSecret` (any dummy value) | the example tenant, reconciled like any other until you delete its folder |

The orchestrators and gateways need nothing here: each authenticates with
keys its tenant's Job mints (Secrets `orchestrator` and `app-gateway` in the
tenant's namespace). The pull secret reaches every tenant namespace as a copy
of `klique-dockerhub`, see "How it works".

A rule that is easy to get wrong:

- The admin password is mounted into a HOCON config file. Any character is
  safe because `externalsecret-users.yaml` quotes the value. Do not remove that
  `| quote`: unquoted, a `#` silently truncates the password and
  `+ = @ , { }` break the parse. Use a bcrypt hash (`pass_hashed: true` in
  `externalsecret-users.yaml`) if you would rather not store plaintext.

## Placeholders to replace

Nothing cluster-specific lives in git: hostnames, IngressClass, TLS Secret
names, the CA to trust and the secret backend all come from
`klique-terraform`'s tfvars (or the two `*.example.yaml` files). What is left
to set here:

| placeholder | meaning |
|---|---|
| `klique/registry/dockerhub`, `klique/apiserver` | paths in YOUR secret backend, if you use different ones |
| `klique/tenants/<tenant>/sso` | the same, but keep the shape `<a>/<b>/<tenant>/<c>`: the build writes the tenant name into the third segment |
| `tenants/tenant-example/` | the example tenant: copy it for your own tenants, then delete it |
| `spec.chart.spec.version` in each HelmRelease | the version range a release tracks (the per-tenant ones in `tenant-reconciler/helmrelease-*.yaml`) |

Writing `klique-platform` by hand? Also write `klique-platform-vars` (same
file): the tenants' gateway hosts and certificates come from it. Tenant
gateways need:

- **cert-manager with a ClusterIssuer** (`KLIQUE_ISSUER_KIND: ClusterIssuer`).
  A namespaced Issuer in `klique` cannot sign in tenant namespaces. Each
  tenant gets a certificate for `<tenant>.<sessions host>` and
  `*.<tenant>.<sessions host>`: the chart routes every running app to
  `*.<gateway host>`, and a TLS wildcard covers exactly one label. With ACME,
  that takes a DNS-01 solver. klique-terraform therefore requires
  cert-manager (it installs it, or uses yours with
  `cert_manager.install = false`) and a ClusterIssuer; by hand, you need both
  too.
- **DNS** for `*.<sessions host>` pointing at the ingress. A DNS wildcard
  also covers `<app>.<tenant>.<sessions host>`.

## Bootstrap

```bash
flux bootstrap git \
  --url=https://<your-git-host>/<org>/gitops-reference \
  --branch=main \
  --path=./klique-fluxcd \
  --token-auth
```

`flux bootstrap` writes `klique-fluxcd/flux-system/` and pushes it; from then on Flux
reconciles this repo. For GitHub/GitLab/Bitbucket there are provider-specific
bootstrap commands — see the Flux docs. Everything after bootstrap is a git
commit.

## How it works

- The bootstrap Kustomization renders the root `kustomization.yaml`, which
  reconciles `kustomizations/`.
- `kustomizations/klique.yaml` reconciles `./klique-fluxcd/klique` (Flux paths
  are relative to the repo root) with `prune: true` —
  deleting a manifest here deletes the object in the cluster. Without prune,
  the repo quietly stops being the source of truth.
- Each HelmRelease takes values from these places, in order:
  1. `klique-platform` / `<chart>.yaml` — the cluster facts (hostnames,
     IngressClass, TLS, CA trust), written by `klique-terraform`, not in git.
     Missing ConfigMap = release NotReady, on purpose.
  2. the values file (`klique/values/<chart>.yaml`, rendered into a ConfigMap)
     — the defaults. For the orchestrator and gateway it is shared by every
     tenant.
  3. `klique-platform` / `<chart>-overrides.yaml` — partner overrides from
     `klique-terraform`'s `klique_values` tfvar (optional)
  4. control-plane: its credentials. Tenant orchestrator and gateway: the
     tenant's own `orchestrator-values.yaml` / `gateway-values.yaml`
     (optional, see [tenants/](tenants/README.md#orchestrator-and-gateway)).
  5. gateway only: the tenant's identity (host, TLS Secret, no TCP sessions),
     in the HelmRelease itself, so nothing above can override it.

  Later wins: tfvars overrides beat the git defaults, and a credential is
  never silently overwritten by a values key. Maps merge; lists are replaced
  whole.
- The `klique` namespace is created outside this repo (by `klique-terraform`,
  alongside `klique-platform`), so prune never deletes the ConfigMap Flux
  depends on.
- **Tenants.** `kustomizations/tenants.yaml` reconciles `./klique-fluxcd/tenants`
  after `klique` is Ready (`dependsOn`). It has no `kustomization.yaml` there,
  so Flux includes every subfolder that has one: a new tenant is a new folder.
  Each folder's `namespace:` line is the tenant's name; the shared
  `tenant-reconciler/` component derives the rest from it. Per tenant that
  renders:
  - its namespace;
  - a Job `<tenant>-reconcile` in `klique`;
  - the Job's files as a ConfigMap `<tenant>-config-<hash>` in `klique`;
  - an ExternalSecret `<tenant>-sso` in `klique`, if the folder has one;
  - a RoleBinding that lets the Job write the key Secrets in the tenant's
    namespace only;
  - HelmReleases `<tenant>-orchestrator` and `<tenant>-gateway` in `klique`,
    installed into the tenant's namespace (release names `klique-orchestrator`
    and `klique-gateway`, Helm history in that namespace too);
  - a Certificate for the gateway, `<tenant>-gateway-tls`, in the tenant's
    namespace.

  The gateway must run beside the tenant's orchestrator: it finds the task
  pods it routes to in its own namespace. One gateway per tenant; TCP sessions
  are off (every gateway would claim the same NodePort range).

  The Job runs in `klique`, so the keys it uses (the Platform Management
  pair and the apiserver's own pair, both from `klique-conf`) and the IdP
  secrets never leave `klique`. Settings:
  - `force: true` makes a changed Job (tenant files, script or image) be
    recreated, and so run again.
  - `wait: true` keeps `tenants` NotReady until every Job has completed and
    every tenant's orchestrator and gateway is healthy.
  - `prune: true` removes a deleted folder's objects, except its namespace:
    deleting a tenant's folder uninstalls its orchestrator and gateway, and
    keeps its namespace, its keys and the Klique tenant.
  - `postBuild.substituteFrom: klique-platform-vars` fills in
    `${KLIQUE_SESSIONS_HOST}` (each gateway's host), `${KLIQUE_ISSUER_KIND}`
    and `${KLIQUE_ISSUER_NAME}` (its Certificate's issuer). It substitutes
    every `${...}` anywhere under `tenants/`, tenant files included (`$${`
    escapes); `scripts/check.sh` rejects a variable that ConfigMap doesn't
    have, because Flux would quietly replace it with an empty string.

  This Kustomization lives in `klique`, not `flux-system`, because Flux reads
  `postBuild.substituteFrom` sources only from a Kustomization's own
  namespace. Its `sourceRef` and `dependsOn` therefore point across
  namespaces, which a Flux install run with `--no-cross-namespace-refs`
  refuses.
- **The pull secret in tenant namespaces.** Every tenant's orchestrator,
  gateway and task pods pull with `klique-dockerhub`. One
  ClusterExternalSecret (`klique/clusterexternalsecret-dockerhub.yaml`) copies
  Secret `klique/klique-dockerhub` into each namespace labelled
  `klique.clearml.ai/tenant=true` (the component labels every tenant's). It
  reads through ClusterSecretStore `klique-dockerhub`
  (`klique/secretstore-tenants.yaml`): the ESO `kubernetes` provider, with a
  ServiceAccount that may `get` exactly that one Secret. It is not a store on
  your backend, which would let every tenant namespace read every backend
  entry. Rotating the backend entry reaches every copy within about two
  hours: up to an hour for `klique/klique-dockerhub` (its ExternalSecret's
  `refreshInterval`), then up to an hour for each copy.
  Any namespace labelled `klique.clearml.ai/tenant=true` receives the pull
  credential. That is accepted on purpose: setting a label on a namespace
  takes cluster-level rights, which a tenant does not have.
- The Jobs call the apiserver and the Platform Management server by their
  in-cluster Service names, which follow the control-plane HelmRelease's
  `releaseName: klique`. Change one and you must change
  `tenant-reconciler/job.yaml` too. The Platform Management server has no
  ingress, and its credential pair is generated by the chart into
  `klique-conf`, so it needs nothing from your backend.
- The tenant orchestrator and gateway credentials reach their charts **by
  reference** (`existingSecret: orchestrator` / `app-gateway`, keys
  `access_key`/`secret_key`), never through Helm values, so no secret value
  lands in their Helm release Secrets. **The control-plane is the exception.** The chart
  renders its own `klique-conf` Secret (the apiserver pair plus about a dozen
  internal keys it generates), so those values are in the control-plane's Helm
  release Secret no matter how the pair is passed in. The chart's
  `controlPlane.existingSecret` would avoid that, but it replaces `klique-conf`
  entirely, so your backend would have to hold every one of those keys.
  Treat the `klique` namespace's Helm release Secrets
  (`sh.helm.release.v1.klique.*`) as sensitive.
- The control-plane's values ConfigMap keeps Kustomize's content-hash suffix:
  editing its values file changes the ConfigMap name, which changes the
  HelmRelease spec, which reconciles immediately instead of waiting out the
  interval. `valuesfrom-nameref.yaml` is the Kustomize wiring that propagates
  the hash into the HelmRelease — remove either and the release goes NotReady.
  The orchestrator and gateway values ConfigMaps have fixed names instead (the
  tenant releases are rendered by the other Kustomization, which cannot follow
  a hash) and the label `reconcile.fluxcd.io/watch: Enabled`, so
  helm-controller still upgrades every tenant's release as soon as one
  changes.
- **Private CA in task pods.** With a private CA, `klique-platform` turns on
  the orchestrator chart's `customCertificates.propagateToTasks`, and
  `values/orchestrator.yaml` also mounts the CA (ConfigMap
  `klique-orchestrator-custom-ca-0` in the tenant's namespace, optional, so a
  public CA is unaffected)
  into every task container. A task image that reinstalls `ca-certificates`,
  as `ubuntu:22.04` does, then still trusts it. Every queue inherits this from
  `orchestratork8sglue.basePodTemplate`. To give a queue its own volumes, use
  `templateOverrides.extraVolumes` and `templateOverrides.extraVolumeMounts`:
  they add to the base lists and keep the CA mount. `templateOverrides.volumes`
  or `templateOverrides.volumeMounts` replace the base lists instead, so a
  queue that sets them must copy both `klique-task-ca-source` entries.

## Day-2 operations

```bash
flux get kustomizations -A         # flux-system and klique in flux-system, tenants in klique
flux get helmreleases -n klique    # control-plane, then <tenant>-orchestrator/-gateway per tenant
kubectl -n klique get jobs         # one <tenant>-reconcile per tenant; logs: kubectl -n klique logs job/<name>

# Push a commit, then skip the poll interval:
flux reconcile kustomization flux-system --with-source

# What a release is actually running, and which chart version resolved
# (a tenant's releases live in its namespace):
helm get values klique -n klique
helm list -n klique
helm list -n <tenant>

# What the 1.x.x range currently resolves to:
crane ls index.docker.io/kliqueai/control-plane
```

Adding, changing and rerunning tenants: see [tenants/](tenants/README.md#day-2).

**Upgrading from a version with a shared orchestrator and gateway** (releases
`orchestrator` and `gateway` in `klique`): this version deletes them (prune),
along with the agent pair. Tasks then run only in tenants; queues of the
default company are no longer served.

1. Apply klique-terraform first. It writes `klique-platform-vars`, which the
   tenants Kustomization needs, and removes the shared gateway's host and TLS
   from `klique-platform`. Until step 2, the old shared `gateway` release
   then fails to upgrade. That failure is expected and goes away with it.
2. Then push this version of `klique-fluxcd/`. Flux deletes the shared
   releases and creates each tenant's own.
3. Clean up:
   - Remove `agentKey`/`agentSecret` from `klique/apiserver` in your backend.
   - Delete task pods the old orchestrator left in `klique`. Helm does not
     own them, so uninstalling the release keeps them. Find them with
     `kubectl -n klique get pods`; their names typically start with
     `clearml-id-`.

Upgrades are automatic: every release tracks `1.x.x`, so a chart publish
upgrades the cluster within ~40 minutes, with no commit. That is the trade —
watch `flux get helmreleases -n klique` after a publish, because minor
versions have renamed values keys before and a range upgrade fails quietly
if one does. To hold a release still instead: pin it exactly
(`version: "1.6.2"`) and bump deliberately, after reading the chart's
changelog.

## The rules this repo follows

Keep them if you extend it — they are what makes this setup safe to run and
safe to change (the same eight apply to every example in this repo):

1. **No secret values in git, ever.** Manifests hold pointers; ESO
   materialises the values in-cluster.
2. **Credentials by reference** (`existingSecret`), never by value through
   Helm, wherever the chart allows it, so no secret lands in the Helm release
   Secret. The control-plane chart is the known exception; see "How it works".
3. **Know what the version constraint commits you to.** A range (`1.x.x`)
   upgrades the cluster within ~40 minutes of a publish, no commit — a renamed
   values key then fails quietly, so watch the reconcile status after one. Pin
   an exact version when a release must not move.
4. **One owner per list.** Helm replaces lists instead of merging them — a list
   split across two values sources silently drops one side.
5. **Prune.** Deleting a manifest in git deletes the object in the cluster;
   without `prune: true`, the repo quietly stops being the source of truth.
6. **Fail loud, fail visible.** An unconfigured secret backend leaves every
   ExternalSecret NotReady on purpose; health checks keep "Ready" meaning the
   apiserver actually answers, not just that objects exist.
7. **Public hostnames wherever a user or a task will see a URL.** In-cluster
   Service names must never leak into user-visible output.
8. **Cluster facts are not desired state.** Hostnames, IngressClass, TLS and
   CA trust come from `klique-platform`, written by whoever owns the cluster
   — never hand-copied into git, where they go stale silently.
