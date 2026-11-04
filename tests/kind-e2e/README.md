# kind end-to-end test

Maintainer tooling, not an example. It proves the quickstart converges as
written, on a local [kind](https://kind.sigs.k8s.io/) cluster:

1. `klique-terraform` applied with tfvars derived from
   `examples/nip-io-quickstart.tfvars.example`;
2. Flux reconciling `klique-fluxcd` from GitHub at a **pushed** commit;
3. every Kustomization, HelmRelease, the SecretStore and every ExternalSecret Ready;
4. the apiserver answering `https://api.<LB IP>.nip.io/debug.ping` through
   the ingress, verified against the CA Terraform minted;
5. one real task on tenant-e2e's queue `default` reaching `completed`, run by
   that tenant's own orchestrator, which proves a task pod trusts that CA (see
   [The task check](#the-task-check));
6. the tenants created from git, OIDC and SAML logins into an e2e tenant
   through its own IdP with the right role, and that tenant's own gateway
   (see [The tenants check](#the-tenants-check));
7. teardown.

Nothing it creates outlives `down`. It never pushes and never touches
`~/.kube/config`. The only sensitive files it writes are in its own work
directory (see [Safety rails](#safety-rails)), and `down` deletes them.

## What it does not cover

- **The root `klique-fluxcd/kustomization.yaml`.** It lists `flux-system/`,
  which only `flux bootstrap` writes, and the harness does not bootstrap (that
  would push to the repo). It runs `flux install` and creates
  `GitRepository/flux-system` and `Kustomization/flux-system` itself, with the
  names bootstrap uses, pointed at `./klique-fluxcd/kustomizations`. Everything
  from there down is reconciled exactly as committed.
- **Your working tree.** Terraform and Flux both use the pushed commit. If
  `klique-terraform/` or `klique-fluxcd/` differ locally, the harness warns.
- **The secret backend a reader uses.** The test backend is OpenBao in dev
  mode inside kind (the official `openbao` Helm chart), reached through ESO's
  `vault` provider. The tfvars use the
  commented Vault block from the quickstart example, with only `server`
  changed.
- **TCP sessions.** Every tenant gateway runs with TCP sessions off
  (`streamSession.enabled: false`), so there is nothing to test.

## Requirements

- Linux with Docker. cloud-provider-kind gives LoadBalancer IPs on the
  `kind` Docker network, which only a Linux host reaches directly.
- `kind` v0.33.0, which the pinned node image belongs to; for another release,
  set `KIND_NODE_IMAGE`. Also Terraform 1.10 or newer (klique-terraform's
  minimum), `kubectl`, `docker`, `git`, `curl`, `jq`, and `openssl`.
- `helm`, checked with v4.3.0. The harness uses `helm upgrade --install` with
  `--repo`, `--version`, `--create-namespace`, `-f -` (values on stdin),
  `--wait`, `--timeout` and `--kube-context`, plus `helm status -o json`.
  Helm 3 has all of these, but the harness has not been run with it.
- `flux` 2.10.0 and `cloud-provider-kind` 0.12.0, installed at those versions
  by `scripts/install-tools.sh` into `~/.local/bin`. Put that directory on your
  `PATH`.
- Outbound HTTPS access to GitHub (Flux's clone and `api.github.com`), Docker Hub, quay.io and the chart
  repositories. Your DNS resolver must answer `*.nip.io` names with private
  IPs: some routers drop them as DNS rebinding protection.
- Enough memory for a single-node cluster that runs MongoDB and Elasticsearch.

## Credentials

Two files, both created by you, owned by you, mode 600. The harness refuses
anything else, reads them at run time, and loads their contents into the kind
cluster only.

**`~/.config/klique/dockerhub.env`**: the Docker Hub credentials issued with
your Klique license.

```bash
mkdir -p ~/.config/klique && chmod 700 ~/.config/klique
install -m 600 /dev/null ~/.config/klique/dockerhub.env
$EDITOR ~/.config/klique/dockerhub.env
```

```
DOCKERHUB_USERNAME=<username>
DOCKERHUB_PASSWORD=<access token>
```

The file is parsed, not sourced. The format is strict:

- one `KEY=value` per line, with only the key or keys the file is documented to hold;
- no `export` prefix;
- no comment after a value; comment lines and blank lines are fine;
- no leading or trailing whitespace around a value;
- at most one pair of matching quotes around a value, needed only if it
  contains ` #` or starts or ends with whitespace. An unbalanced quote is an error.

CRLF line ends are accepted. An error names the line number, never the value
or anything else on that line.

**`~/.config/klique/github-token.env`**: a read-only GitHub token Flux clones
the repo with over HTTPS (`GITHUB_TOKEN=...`; the format is the same as
`dockerhub.env`).

1. On GitHub: Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token.
2. Resource owner: `klique-ai`. Repository access: only select repositories,
   `gitops-reference`. Repository permissions: **Contents: Read-only** (Metadata: Read-only is added automatically). Nothing
   else. The org may require an owner to approve the token before it works.
3. Store it, then paste the token after `GITHUB_TOKEN=`:

```bash
install -m 600 /dev/null ~/.config/klique/github-token.env
$EDITOR ~/.config/klique/github-token.env   # GITHUB_TOKEN=github_pat_...
```

Before it creates anything, `up` asks the GitHub API (`api.github.com`) whether
the token can read the commit it resolved for `--ref` (the token goes to curl on stdin) and stops
with a plain message if not: invalid or expired, not approved by the org, or
missing Contents: Read-only. Flux then gets it as the password of Secret
`flux-system` (username `git`), created from stdin and never printed or kept
in a file. Flux needs no SSH. `--ref` is resolved through your own git remote (`origin`),
which uses whatever URL and credentials you configured there, SSH included.

## Run it

Push the commit you want to test first. Then, from the repo root:

```bash
tests/kind-e2e/e2e.sh all                     # current branch: up, verify, down
tests/kind-e2e/e2e.sh all --ref <branch>      # another branch
tests/kind-e2e/e2e.sh all --ref <sha>         # a commit that is a branch tip on origin
KEEP=1 tests/kind-e2e/e2e.sh all              # keep the cluster afterwards, pass or fail
```

`--ref` must already be on the remote. A branch's tip there must match your
local branch. A sha must be the tip of some branch on `origin`, since
`git ls-remote` can only see tips. Otherwise the harness stops with
"push it first" before it creates anything.

The tested commit's own `klique-terraform/.terraform.lock.hcl` must hold this
platform's provider hashes, because the harness runs `terraform init
-lockfile=readonly`. `main` before the branch that added this harness does not,
so `--ref main` fails at `init` until that branch is merged.

One work directory holds one commit. To test a different `--ref`, run `down`
first; the harness refuses otherwise.

Step by step:

```bash
tests/kind-e2e/e2e.sh up        # cluster, cloud-provider-kind, OpenBao, Terraform, Keycloak, Flux
tests/kind-e2e/e2e.sh verify    # waits for Ready, probes the apiserver, runs the task check
tests/kind-e2e/e2e.sh task      # only the task check, again, on a cluster that is up
tests/kind-e2e/e2e.sh down      # idempotent; safe when nothing is up
```

While it is up, point your own tools at it with the `KUBECONFIG=...` line that
`up` prints (it is `$KLIQUE_E2E_DIR/kubeconfig`).

A full `all` takes tens of minutes. Most of it is image pulls and the
datastores starting. `verify` allows up to 40 minutes for the releases, then up
to 15 more for the task check (`T_TASK_SECONDS`).

## What `up` does

1. **Preflight (read-only).** Checks the tools and both credential files.
   Resolves `--ref` with `git ls-remote` and checks the GitHub token.
2. **kind cluster `klique-gitops-ref`** (context `kind-klique-gitops-ref`).
   It is written to its own kubeconfig in the work directory, so no other
   context is ever in reach. It also removes the node's
   `node.kubernetes.io/exclude-from-external-load-balancers` label, because
   the single kind node is a control-plane node.
3. **cloud-provider-kind** runs as a background host process (pid file in the
   work directory) and gives Traefik's LoadBalancer Service an IP, so the
   nip.io quickstart works unchanged. Its own ingress and Gateway API features
   are off. Note that it serves *every* kind cluster on the machine while it
   runs.
4. **OpenBao**: the official chart `openbao` 0.30.6 from
   `https://openbao.github.io/openbao-helm`, which runs image 2.7.2, with
   [`openbao-values.yaml`](openbao-values.yaml). It runs in dev mode, in
   memory, with all capabilities dropped and the injector and UI off. The
   chart's test pod runs only on `helm test`, which the harness never calls.
   The root token is random per run and reaches helm on stdin. It never
   comes back to the host, but inside the throwaway cluster it is in the Helm
   release, the pod's environment and the pod log (dev mode prints it). The
   harness enables KV v2 at `kv` and
   Kubernetes auth with role `klique`, bound to ESO's service account. It
   writes:
   - `kv/klique/registry/dockerhub`: from `dockerhub.env`;
   - `kv/klique/apiserver`: the apiserver's own random key pair, plus an
     admin login whose password contains `# + = @ , { }`, which exercises the
     `| quote` rule in `externalsecret-users.yaml`. There is no agent pair:
     each tenant's orchestrator and gateway use that tenant's minted keys.

   These values are generated at run time. They are never printed or written
   to a host file.
5. **klique-terraform**, extracted from the commit with `git archive` into the
   work directory. It runs `terraform init -lockfile=readonly`, then `apply`
   with the generated tfvars: the example with `kubeconfig_context`
   replaced, plus `kubeconfig_path` and the `secret_store` block.
6. **Keycloak** ([`keycloak/`](keycloak/)), the e2e tenants' IdP. See
   [The tenants check](#the-tenants-check).
7. **Flux**: `flux install`, a Secret `flux-system` with the GitHub token as
   basic-auth credentials, then `GitRepository/flux-system` (the branch, held at
   the exact commit) and `Kustomization/flux-system` at
   `./klique-fluxcd/kustomizations`. Last, `Kustomization/e2e-tenants`
   ([`flux/e2e-tenants.yaml`](flux/e2e-tenants.yaml)) for
   [`tenants/`](tenants/).

`verify` waits for the GitRepository to serve that commit, then for the
SecretStore, the ExternalSecrets and `Kustomization/klique`, whose health
checks cover the control plane. It then waits for:

- `klique-dockerhub` in every tenant namespace (`tenant-example`,
  `tenant-e2e`, `tenant-e2e-b`), with a plain message if one is missing;
- the `tenants` and `e2e-tenants` Kustomizations, whose Jobs create the
  tenants and whose HelmReleases run each tenant's orchestrator and gateway.

It prints `flux get kustomizations -A` and `flux get helmreleases -A`, fails
on any row that is not Ready, and probes `debug.ping`. An informational check
then tries the default company's admin login through `auth.login`; it does not
decide pass or fail. Then come the tenants check and the task check.

## The task check

The checks above pass even when tasks cannot run. A task pod is a different
place: it starts from the default image, and that image's own
`update-ca-certificates` can drop the private CA from
`/etc/ssl/certs/ca-certificates.crt`. The UI and `debug.ping` stay green, and
every task then fails with `CERTIFICATE_VERIFY_FAILED`. So `verify` runs one
task on `tenant-e2e`, the way one of its users would from the UI:

1. It logs in as tenant-e2e's admin (`e2e-admin`) with the scripted OIDC
   login of [The tenants check](#the-tenants-check). The session token only
   reaches tenant-e2e's company.
2. It finds tenant-e2e's queue `default` by name. tenant-e2e's own
   orchestrator registers it, running in namespace `tenant-e2e` with the
   tenant's minted `orchestrator` key. A missing queue is an error, not
   auto-created.
3. It creates a task whose code is a literal script (`script.diff`, empty
   repository). The script uses only the standard library: it opens
   `https://api.<LB IP>.nip.io/debug.ping` with `ssl.create_default_context()`,
   which trusts the system bundle, and exits non-zero on any TLS or HTTP error.
4. It enqueues the task on `default` and polls it every 10 seconds.

`completed` proves two things:

- the agent inside the task pod logged in and fetched the task over https;
- the task's own code verified the private CA after the image's bootstrap.

`failed`, `stopped` or no `completed` within `T_TASK_SECONDS` (default 900)
fails the run. The harness then prints the task's `status`, `status_reason`,
`status_message` and `last_worker`, and the last 40 lines of its log. If the
task is still `queued` after 5 minutes, it warns that tenant-e2e's
orchestrator may not be watching `default`.

The task pod runs in namespace `tenant-e2e`, so the check also proves the CA
reaches task pods of a tenant's own orchestrator.

Expect the check to add a few minutes: pulling the default image, the agent's
apt and venv setup, and a one-line script.

The admin password and the session token stay in shell variables and reach
curl on stdin. The task holds no secret. It is left in place, visible in the
UI when the cluster is kept with `KEEP=1`, and goes away with `down`.

`tests/kind-e2e/e2e.sh task` reruns only this check on a cluster that is up.

## The tenants check

`klique-fluxcd/tenants/` turns a folder into a Klique tenant with its own SSO
(see that folder's README). The e2e adds two tenants of its own, in
[`tenants/`](tenants/), with the same folder shape. Each has its own IdP: a
realm in one Keycloak, imported from [`keycloak/`](keycloak/).

| tenant | realm | providers | users (group) |
|---|---|---|---|
| `tenant-e2e` | `tenant-e2e` | OIDC `tenant-e2e-oidc`, SAML `tenant-e2e-saml` | `e2e-admin` (`e2e-admins`), `e2e-builder` (`e2e-builders`) |
| `tenant-e2e-b` | `tenant-e2e-b` | OIDC `tenant-e2e-b-oidc` | `e2e-b-user` (`e2e-b-admins`) |

Each realm's clients send a fixed `tenant` claim or attribute (the realm's
tenant name) and the user's `groups`.

How Keycloak is reached:

- **From the browser side:** `https://keycloak.<LB IP>.nip.io`, through
  Traefik, with a certificate from ClusterIssuer `klique-ca`. curl on the
  host plays the browser.
- **From the apiserver:** `http://keycloak.keycloak.svc:8080`, used only to
  redeem OIDC codes, so the apiserver never needs to trust the private CA.

Values that exist only at run time are filled in by Flux:
`Kustomization/e2e-tenants` substitutes from ConfigMap `kind-e2e-vars`, which
the harness writes once Keycloak is up. These are `${KLIQUE_DOMAIN}` and
`${KEYCLOAK_SAML_CERT_TENANT_E2E}`, realm `tenant-e2e`'s SAML signing
certificate. Keycloak generates that certificate at import, so
`tenants/tenant-e2e/idp-metadata.xml` in git is a template.

The passwords and OIDC client secrets are generated once per cluster and kept
only in OpenBao:

- `kv/kind-e2e/keycloak`: everything;
- `kv/klique/tenants/<tenant>/sso`: what each tenant's `sso` ExternalSecret
  reads. `tenant-example` gets a dummy, because the `tenants` Kustomization
  waits for every ExternalSecret.

Keycloak gets these values as `${E2E_*}` placeholders in the realm files,
resolved at import from a Secret the harness creates on stdin.

The check:

1. `tenants.get_tenants`, on the Platform Management server through a
   short-lived port-forward, lists `tenant-example`, `tenant-e2e` and
   `tenant-e2e-b`.
2. Every tenant namespace has Secrets `orchestrator` and `app-gateway`, each
   with `access_key` and `secret_key`.
3. `sso.get_provider_configurations` shows the three providers saved and
   active.
4. Scripted browser logins:
   - OIDC and SAML, as `e2e-admin` (role `admin`) and `e2e-builder` (role
     `user`), each landing in tenant-e2e's company.
   - As `e2e-b-user` into `tenant-e2e-b`, as a control that must succeed.
   - The same login with the callback's `state` rewritten to claim
     `tenant-e2e`, which must be refused with `cannot_login_tenant` (92).
     This proves the server compares the IdP's tenant claim with the tenant
     the login asks for (`skip_tenant_check: false`), for an IdP that sends
     its claim honestly.

     It is not tenant isolation. The state is unsigned and the claim comes
     from the tenant's own IdP, so an admin of any tenant's IdP can issue a
     claim for another tenant. Every tenant IdP must be trusted not to do
     that: see the trust boundary in `klique-fluxcd/tenants/README.md`.
   - tenant-e2e-b's provider asked for `tenant-e2e`, which must be refused
     with `invalid_login_provider` (51).
5. Logout, as the webapp calls it (`login.logout` with `redirect_url` =
   `https://app.<domain>/login`, no provider), for `e2e-b-user` and
   tenant-e2e's OIDC `e2e-admin`. Both OIDC providers set
   `logoutFromProvider` and `endSessionEndpoint`, and the Keycloak clients
   register `https://app.<domain>/login/<tenant>` as a post-logout redirect URI
   (client attribute `post.logout.redirect.uris`):
   - the returned `redirect_url` is that realm's end-session URL with
     `client_id` and `post_logout_redirect_uri=https://app.<domain>/login/<tenant>`;
   - following it in the same cookie jar as the login shows Keycloak's logout
     confirmation form (the server sends no `id_token_hint`); submitting it
     redirects to exactly that URI;
   - a fresh `login.sso_authorize` then shows Keycloak's login form again, so
     the IdP session is gone.

   SAML limitation: for `e2e-admin`'s SAML login `login.logout` returns no
   `redirect_url`. Only the Klique session ends; the IdP session stays.
6. tenant-e2e's own gateway:
   - `https://tenant-e2e.sessions.<domain>` answers, verified against the
     minted CA, with curl checking the host name;
   - `openssl s_client` shows its certificate names both
     `tenant-e2e.sessions.<domain>` and `*.tenant-e2e.sessions.<domain>`,
     the subdomain every running app gets;
   - `routers.get_task_routers` as tenant-e2e's admin lists that URL. This
     proves the gateway authenticated to the apiserver with tenant-e2e's
     minted `app-gateway` key and registered itself.
   - the same call as tenant-e2e-b's user does not list it, because routers
     are per company.

   Registration runs on an interval, so the check polls for up to
   `T_GATEWAY_SECONDS` (default 300).

Each login is the browser's request sequence:

1. `login.sso_authorize`;
2. Keycloak's login page, and its form POST with the credentials on stdin;
3. for SAML, the auto-posted response to `https://app.<domain>/callback_saml`,
   which the webapp's nginx hands to the apiserver;
4. `login.sso_callback`;
5. `users.get_current_user`, which gives the role and the company.

The cookie jar lives in the work directory only for one login, or for one
login-and-logout check (login, logout, confirmation, re-authorize).
The session token is never printed.

`tests/kind-e2e/e2e.sh tenants` reruns only this check on a cluster that is
up. It adds several minutes:

- pulling and starting Keycloak, about 1–2 minutes;
- the tenant Jobs, about 1;
- three tenants' orchestrators and gateways (images pulled once), an
  estimated 3–6.

`T_TENANTS` (default 30m) bounds the waits.

## Safety rails

- **One context.** Before every cluster, Terraform or Flux mutation, the
  `guard` checks four things:
  - the cluster exists;
  - the harness kubeconfig holds exactly one context, `kind-klique-gitops-ref`;
  - that context is current;
  - its server is `https://127.0.0.1:*`.

  Every kubectl and flux call also passes `--context`. Every `HELM_*` and
  `KUBE_*` variable from your shell is unset first, because some of them
  (`HELM_KUBEAPISERVER`, `KUBE_HOST`, `KUBE_CONFIG_PATH` and others) would
  redirect helm or Terraform's Kubernetes providers to another cluster.
  `KUBECONFIG` is set to the harness's own file.
- **No push.** The only remote git operation is `git ls-remote`.
- **No secret in host files or logs**, outside the work directory below. The
  script refuses `set -x`. Values pass
  through shell variables, a child's environment and stdin, never a command
  line. Failure diagnostics show status and events, never Secret contents.
- **What does land on disk:** the work directory, mode 700. It holds:
  - two sensitive files: the kind kubeconfig (cluster-admin on the throwaway
    cluster) and the Terraform state (the quickstart CA key, as the quickstart
    itself warns; nothing else secret);
  - public files: the tfvars, the CA certificate, the
    resolved ref, the cloud-provider-kind log, and helm's cache, config and
    data. Every helm path variable points here: `HELM_CACHE_HOME`,
    `HELM_CONFIG_HOME`, `HELM_DATA_HOME`, `HELM_REPOSITORY_CONFIG`,
    `HELM_REPOSITORY_CACHE`, `HELM_REGISTRY_CONFIG`, `HELM_CONTENT_CACHE` and
    `HELM_PLUGINS`, which are all the paths `helm env` lists on v4.3.0. Your
    own helm setup is neither used nor changed.

  `down` deletes the directory.
- **The work directory is its own.** `up` creates it with a marker file. If
  the path already exists without that marker, `up` refuses to use it and
  `down` refuses to delete it. A symlink counts as foreign.

## Environment overrides

| variable | default | |
|---|---|---|
| `KLIQUE_E2E_DIR` | `${TMPDIR:-/tmp}/klique-e2e-<uid>` | work directory. A relative path is taken from the directory you run in. Only letters, digits and `. _ / + -` are allowed |
| `KLIQUE_E2E_CRED_DIR` | `~/.config/klique` | where the two credential files are |
| `KLIQUE_E2E_REPO_URL` | `https://github.com/klique-ai/gitops-reference` | what Flux clones; must be `https://github.com/<owner>/<repo>` |
| `KLIQUE_E2E_GIT_REMOTE` | `origin` | the local remote `--ref` is checked against |
| `KIND_NODE_IMAGE` | `kindest/node:v1.37.0@sha256:a1ed…` | kind v0.33.0's default; other kind releases need their own |
| `T_TERRAFORM`, `T_BASE`, `T_KLIQUE` | `15m`, `5m`, `40m` | step timeouts |
| `T_PROBE_SECONDS` | `300` | how long `debug.ping` is retried |
| `T_TASK_SECONDS` | `900` | how long the task check waits for `completed` |
| `T_TENANTS` | `30m` | how long `verify` waits for the `tenants` and `e2e-tenants` Kustomizations |
| `T_PULL_SECRET_SECONDS` | `600` | how long `verify` waits for `klique-dockerhub` in each tenant namespace |
| `T_GATEWAY_SECONDS` | `300` | how long the gateway check waits for an answer and for the gateway's registration |
| `KEEP` | `0` | `1`: `all` does not tear down |

## Troubleshooting

- **Terraform fails on the nip.io domain:** Traefik got no LoadBalancer IP.
  Check the `cloud-provider-kind.log` file in the work directory.
- **`debug.ping` never answers, but everything is Ready:** check
  `dig api.<ip>.nip.io` on the host. A resolver that filters private answers
  breaks nip.io.
- **ImagePullBackOff on Traefik, cert-manager or ESO:** these come from public
  registries anonymously, and Docker Hub rate-limits anonymous pulls.
- **OpenBao restarted mid-run:** dev mode is in memory, so its entries are
  gone, and `up` would seed *new* credentials that the running release does
  not know. Run `down` and start again.
