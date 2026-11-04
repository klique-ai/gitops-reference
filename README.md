# gitops-reference

Ready-to-use GitOps examples for installing Klique on Kubernetes. Each
directory is one complete, self-contained setup: fork the repo, replace the
placeholders, bootstrap, and the cluster converges from git. You own it from
the first commit.

The examples differ only in the tooling that reconciles the cluster. The
product underneath is always the same three Helm charts, pulled as OCI
artifacts from `index.docker.io/kliqueai` with the Docker Hub credentials
issued with your license.

> **Reference, not a product.** Verified against chart versions control-plane
> 1.6.2, orchestrator 1.1.1, gateway 1.4.0 — the releases track the newest 1.x,
> so what runs can be newer than what was verified, and newer versions may
> rename values keys. For help, use your normal Klique support channel.

## What every example installs

| chart | where | what it is |
|---|---|---|
| `control-plane` | once | apiserver, web UI, fileserver, MongoDB, Elasticsearch, Valkey, MCP server |
| `orchestrator` | per tenant | the k8s glue: runs the tenant's tasks as pods in its namespace and registers its queues |
| `gateway` | per tenant | routes the tenant's interactive sessions and running apps, at `<tenant>.<sessions host>` |

Tenants come from git too: each folder under an example's `tenants/` is one
Klique tenant, created and kept in line with its folder, with its own identity
provider (SSO per tenant; the fixed admin login is unchanged), and its own
orchestrator and gateway in its own namespace. There is no shared
orchestrator or gateway. See
[`klique-fluxcd/tenants/`](klique-fluxcd/tenants/README.md).

Deliberately out of scope everywhere: the Platform Management Center UI,
monitoring, provisioning ClearML applications from git. All can be added
later; none are needed for a working control plane.

## Examples

| directory | reconciles with | secrets via |
|---|---|---|
| [`klique-fluxcd/`](klique-fluxcd/README.md) | Flux | External Secrets Operator |

And one directory that is not an example but the ground under all of them:

| directory | what |
|---|---|
| [`klique-terraform/`](klique-terraform/README.md) | the cluster prerequisites on an existing cluster — ingress controller (Traefik or yours), cert-manager + certificates (your CA, an existing issuer, ACME, or a quickstart CA), ESO — and the `klique-platform` ConfigMap that hands hostnames, TLS and CA trust to GitOps |

Terraform owns the cluster; GitOps owns Klique. The `klique-platform`
ConfigMap is the one seam between them, read first by every HelmRelease.

Each example has its own README with the full walkthrough: prerequisites, the
placeholder list, bootstrap, day-2 operations. Pick the one that matches your
tooling and follow it end to end — the manifests assume their own wiring, so
don't mix pieces of one example into a different setup.

## Quick start

The shortest path, on the Flux example:

1. Fork this repo.
2. Prepare the cluster — ingress, TLS, ESO, namespace, `klique-platform`:

   ```bash
   cd klique-terraform
   cp examples/nip-io-quickstart.tfvars.example terraform.tfvars   # or another example
   terraform init && terraform apply
   ```

   Everything cluster-specific — ingress, TLS/CA, DNS, secret backend, Klique
   value overrides — is a tfvar; see the
   [variable reference](klique-terraform/README.md#variable-reference).
3. Create the credential entries in your secret backend, listed in the
   [example README](klique-fluxcd/README.md#secrets-your-backend-must-hold)
   (including the example tenant's dummy entry).
4. Bootstrap Flux against your fork:

   ```bash
   flux bootstrap git \
     --url=https://<your-git-host>/<org>/gitops-reference \
     --branch=main \
     --path=./klique-fluxcd \
     --token-auth
   ```

Everything after bootstrap is a git commit.

## The best practices every example follows

Keep them if you extend an example — they are what makes these setups safe to
run and safe to change:

1. **No secret values in git, ever.** Manifests hold pointers; the External
   Secrets Operator materialises the values in-cluster.
2. **Credentials by reference** (`existingSecret`), never by value through
   Helm, wherever the chart allows it, so no secret lands in the Helm release
   Secret. The control-plane chart is the known exception: it renders its own
   credentials Secret, so treat its Helm release Secret as sensitive (see the
   example READMEs).
3. **Know what the version constraint commits you to.** A range (`1.x.x`)
   upgrades the cluster within ~40 minutes of a publish, no commit — a renamed
   values key then fails quietly, so watch the reconcile status after one. Pin
   an exact version when a release must not move.
4. **One owner per list.** Helm replaces lists instead of merging them — a
   list split across two values sources silently drops one side.
5. **Prune.** Deleting a manifest in git deletes the object in the cluster;
   without prune, the repo quietly stops being the source of truth.
6. **Fail loud, fail visible.** An unconfigured secret backend leaves every
   ExternalSecret NotReady on purpose; health checks keep "Ready" meaning the
   apiserver actually answers, not just that objects exist.
7. **Public hostnames wherever a user or a task will see a URL.** In-cluster
   Service names must never leak into user-visible output.
8. **Cluster facts are not desired state.** Hostnames, IngressClass, TLS and
   CA trust come from `klique-platform`, written by whoever owns the cluster
   — never hand-copied into git, where they go stale silently.

## Layout

```
klique-terraform/ cluster prerequisites + the klique-platform handoff (Terraform)
klique-fluxcd/    Flux + ESO: the control plane and the tenants (each with its own orchestrator and gateway)
scripts/          maintainer tooling; scripts/install-tools.sh installs the pinned check and lint tools,
                  scripts/check.sh runs every repo check
tests/            maintainer tooling; tests/kind-e2e/ is the end-to-end harness on kind
```

`scripts/` and `tests/` are for the people who maintain this repo. Neither is
an example, and you don't need either to use one.

## Adding an example

Only the directories in the Examples table are examples. A new one belongs
there when it is complete and works the same way: one directory, reconciled by
one tool, installing the three charts above, secrets by pointer only, and its
own README covering prerequisites, placeholders, bootstrap, and day-2
operations. Partial snippets don't belong here — an example is either a
complete, bootstrappable setup or it isn't an example.
