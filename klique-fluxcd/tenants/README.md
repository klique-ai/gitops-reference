# Tenants

Each folder here is one Klique tenant. Flux reconciles this directory
(`kustomizations/tenants.yaml`). For each folder, a Job named
`<tenant>-reconcile` runs in `klique` and:

1. creates the Klique tenant if it doesn't exist yet. A tenant that already
   exists with the same name is adopted: the Job leaves its existing keys
   alone. Only a tenant the Job creates gets the default key that creation
   returns revoked at once;
2. mints the tenant's two keys and writes them to the Secrets `orchestrator`
   and `app-gateway` in the tenant's namespace (keys `access_key` and
   `secret_key`);
3. configures the tenant's SSO: its company settings (admin and builder
   groups) and its own identity providers;
4. logs what you need to finish the setup on the IdP side: the login URL,
   the callback URL, the tenant claim and, for SAML, the SP entity id and
   metadata. Secret values are never logged.

The Job never deletes anything. It does not delete a tenant, a provider you
drop from `tenant.json`, or a key.

Each tenant also gets **its own orchestrator and gateway**, in its namespace,
authenticating with those two keys (see
[Orchestrator and gateway](#orchestrator-and-gateway)). Its tasks run as pods
in its namespace; its running apps and sessions are served at
`https://<tenant>.<sessions host>`.

**A tenant folder is trusted, platform-reviewed content.** It is a Kustomize
directory: it can patch anything the component renders or add resources of
its own, and Flux applies them with cluster rights. Keep tenant folders
under the platform team's review, like any other manifest in this repo. The
checks in `scripts/check.sh` catch common mistakes, not a hostile folder.

There is no `kustomization.yaml` in this directory, on purpose: Flux then
includes every subfolder that has one, so **adding a tenant means adding a
folder**. Nothing else needs to change.

## Add a tenant

1. Copy `tenant-example/` to a new folder (the folder name doesn't matter).
2. In the new folder's `kustomization.yaml`, change the one line
   `namespace: tenant-example` to the tenant's name. That line is the
   tenant's name everywhere: the Klique tenant, its namespace, its Job
   (`<tenant>-reconcile`) and its backend path (`klique/tenants/<tenant>/sso`).
   The name must be a DNS label of 3 to 50 lowercase letters, digits or `-`.
   50, not 63, so that `<tenant>-orchestrator` is still a valid label value;
   `scripts/check.sh` enforces it.
3. Edit `tenant.json` (see [`tenant.json`](#tenantjson) below) for the
   tenant's IdP.
4. Put the IdP's secrets in your backend under `klique/tenants/<tenant>/sso`
   and list them in `externalsecret-sso.yaml` (see [Secrets](#secrets)).
5. SAML only: replace `idp-metadata.xml` with your IdP's metadata, and keep it
   listed under `configMapGenerator` `files:` in `kustomization.yaml`. Every
   file `tenant.json` names must be listed there, or the Job can't see it. An
   OIDC-only tenant deletes `idp-metadata.xml` and its `files:` line.
6. Run `scripts/check.sh`, commit, and push. When Flux has reconciled, read
   the Job's log:

   ```bash
   kubectl -n klique logs job/<tenant>-reconcile
   ```

7. In the IdP, register the callback URL from the log, and make the tenant
   claim carry the tenant's name (see [IdP setup](#idp-setup)).

Users then sign in at `https://<app host>/login/<tenant>`.

`tenant-example` is reconciled like any other folder, so a fork gets a
`tenant-example` tenant whose IdP doesn't exist. It needs its backend entry:
create `klique/tenants/tenant-example/sso` with a dummy `oidcClientSecret`
value. Without that entry its ExternalSecret stays NotReady, and so does the
`tenants` Kustomization. Delete the folder once you have your own tenant. The
namespace and the Klique tenant remain (see [Removing a tenant](#removing-a-tenant)).

## Folder layout

| file | what it is |
|---|---|
| `kustomization.yaml` | `namespace: <tenant>` (the tenant's name) plus fixed wiring: the shared component `../../tenant-reconciler`, its `replacements.yaml`, and the `tenant-config` file list |
| `tenant.json` | the tenant's limits and SSO settings |
| `externalsecret-sso.yaml` | pointers to the IdP secrets. Optional: delete it and its `resources:` line when the tenant has no IdP secret |
| `idp-metadata.xml` | SAML only: the IdP's metadata. Any name works, as long as `tenant.json` names it in `idpMetadataFile` and it is listed in `files:` |
| `orchestrator-values.yaml`, `gateway-values.yaml` | optional: this tenant's own Helm values for its orchestrator / gateway, listed in `files:` (exactly these names) |

`scripts/check.sh` checks the following:

- every folder here has a `kustomization.yaml` and a `tenant.json`;
- no `.yaml` sits directly in this directory: Flux would apply it as is;
- the tenants render;
- the ExternalSecrets have the expected shape;
- each tenant's orchestrator, gateway and Certificate come out with the
  tenant's names, namespace and host;
- every tenant name is at most 50 characters;
- every `${...}` is a variable `klique-platform-vars` provides, in a form
  Flux substitutes as written (see below);
- a tenant's values files set none of the keys listed under
  [Orchestrator and gateway](#orchestrator-and-gateway);
- every `tenant.json` passes the same validation the Job runs.

That validation rejects unknown fields, plaintext secrets, a missing tenant
claim and a metadata file missing from `files:`, and each error names the
field.

## tenant.json

```json
{
  "limits": {"maxUsers": 20, "maxServiceUsers": 5},
  "sso": {
    "adminGroups": ["klique-admins"],
    "builderGroups": ["klique-builders"],
    "providers": [ ... ]
  }
}
```

Unknown fields fail validation. The field names are camelCase and map to the
server's SSO wizard fields.

### Top level

| field | | |
|---|---|---|
| `limits.maxUsers` | optional, integer ≥ 0 | seat cap for users. Omitted: nothing is sent, and the control plane's `controlPlane.maxUsers` applies (20 in `../klique/values/control-plane.yaml`) |
| `limits.maxServiceUsers` | optional, integer ≥ 0 | cap for service users. Omitted: nothing is sent, and the server default applies (2) |
| `sso` | **required** | |
| `sso.adminGroups` | **required**, non-empty list | IdP groups whose members are tenant admins |
| `sso.builderGroups` | optional, list | IdP groups whose members are builders. Omitted: every non-admin is a builder. `[]`: every non-admin is a consumer |
| `sso.groupMapping` | optional, object | IdP group → Klique group name (or list of names) |
| `sso.providers` | **required**, non-empty list | the tenant's identity providers, below |

Removing `limits` (or one of its fields) later keeps the last applied value:
an omitted field is never sent.

Limits can be changed after creation. The Job compares them with the server's
values and updates them when they differ.

### Every provider

| field | | |
|---|---|---|
| `id` | **required** | 1 to 40 lowercase letters or digits (no `-`). Unique within the tenant. Stored as `<tenant>-<id>`, because provider ids are global across tenants; without `-` in the id, two tenants can never produce the same stored id |
| `preset` | **required** | OIDC: `oidc`, `auth0`, `aws_cognito`, `google`, `keycloak`, `microsoft_ad`, `azure`, `okta`, `ping`. SAML: `saml`, `duo_saml`, `google_saml`, `jumpcloud_saml`, `microsoft_saml` |
| `displayName` | **required** | the button label on the login page. Unique within the tenant |
| `enabled` | optional, default `true` | `false` deactivates the provider and keeps its configuration |
| `claims` | **required** | which claim carries what (tables below). `claims.tenant` is required |
| `groups` | optional | group sync options (table below). Group sync is always on, because `adminGroups` and `builderGroups` depend on it |
| `autoProvision` | optional, bool | |

Removing a provider from the file does **not** remove it from the server. To
turn one off, set `"enabled": false`.

### OIDC providers

| field | | |
|---|---|---|
| `clientId` | **required** | |
| `clientSecret` | **required**, secret | `{"key": "<key>"}`, see [Secrets](#secrets) |
| `authorizationEndpoint` | **required** | |
| `tokenEndpoint` | **required** | |
| `userinfoEndpoint` | optional | required when `getUserinfoFromIdToken` is `false` |
| `revocationEndpoint` | optional | |
| `endSessionEndpoint` | optional | required when `logoutFromProvider` is `true` |
| `jwksUri` | optional | required when `verifyTokenSignature` is `true` |
| `audience` | optional | |
| `getUserinfoFromIdToken` | optional, bool | |
| `logoutFromProvider` | optional, bool | also ends the IdP session on logout, see [Logout](#logout) |
| `checkEmailVerified` | optional, bool | |
| `verifyTokenSignature` | optional, bool | |
| `codeChallenge` | optional | `None`, `Plain` or `S256` |
| `scopes`, `extraScopes` | optional, list | items must not contain `,` |
| `providerParams` | optional, object of strings | keys and values must not contain `,` or `=` |

OIDC `claims`: `tenant` (**required**), `groups`, `sub`, `email`,
`emailVerified`, `name`, `givenName`, `familyName`, `picture`, `custom` (a
list). Each value is the name of the claim in the IdP's token.

### SAML providers

| field | | |
|---|---|---|
| `idpMetadataFile` | **required** | name of a file in this folder that holds the IdP's metadata XML, listed in `files:` |
| `entityId` | optional | the SP entity id the IdP knows Klique by |
| `signedAssertions` | optional, bool | |
| `signedRequest` | optional, bool | needs both `publicKey` and `privateKey` |
| `publicKey` | optional | the SP certificate (PEM). It is public, so plain text is fine |
| `privateKey` | optional, secret | `{"key": "<key>"}` |

SAML `claims`: `tenant` (**required**), `groups`, `objectId`, `email`, `name`,
`givenName`, `familyName`, `custom` (a list). Each value is an attribute name
in the IdP's assertion.

### `groups` (either kind)

| field | |
|---|---|
| `caseSensitive` | bool |
| `claimFormat` | `none` or `ldap-dn` |
| `prohibitSignupIfNotInGroup` | bool |
| `prohibitLoginIfNotInGroup` | bool |

## Secrets

Secret values are never written into `tenant.json`. A secret field holds a
reference, `{"key": "<key>"}`, and a plain string fails validation.

The values live in your secret backend, in one entry per tenant:
`klique/tenants/<tenant>/sso`, one property per secret.
`externalsecret-sso.yaml` lists the properties. Each `secretKey` there is the
`<key>` that `tenant.json` refers to:

```yaml
  data:
    - secretKey: oidcClientSecret          # tenant.json: {"key": "oidcClientSecret"}
      remoteRef:
        key: klique/tenants/tenant-example/sso
        property: oidcClientSecret
```

When you copy the folder, you don't need to edit any name in the file:

- the build renames the ExternalSecret `tenant-sso` to `<tenant>-sso`;
- it places that ExternalSecret in `klique`, which holds the SecretStore
  `klique-secrets`;
- it sets the third segment of every key to the tenant name.

So keep every key shaped `<a>/<b>/<tenant>/<c>`; `scripts/check.sh` fails on
any other shape. The materialised Secret `<tenant>-sso` stays in `klique`
and is mounted into the Job only. IdP secrets never reach the tenant's
namespace, where its workloads run.

A value is sent exactly as the backend holds it. Don't store a trailing
newline unless the IdP expects one.

If a secret file is missing when the Job starts, the Job waits for it (up to
300 seconds, for ESO to sync) and then fails, naming the field. If you add the
backend entry or property only after that, rerun the Job:

```bash
kubectl -n klique delete job <tenant>-reconcile
flux reconcile kustomization tenants -n klique
```

Changing a secret in the backend doesn't rerun the Job either, because the
Job's spec doesn't change. Rerun it the same way.

## IdP setup

For each provider, the Job logs:

```
provider <tenant>-<id> (<displayName>):
  login URL:       https://<app host>/login/<tenant>
  callback URL:    https://<app host>/callback_<client id>   (OIDC)
                   https://<app host>/callback_saml          (SAML)
  post-logout URI: https://<app host>/login/<tenant>         (OIDC, with logoutFromProvider)
  tenant claim:    '<claim>' must carry '<tenant>'
  SP entity id:    ...                                       (SAML)
  SP metadata:     ...                                       (SAML)
```

> **Trust boundary.** The tenant claim is the only thing that ties a login to
> a tenant. The server does not check that the provider belongs to the tenant
> being signed in to, so an IdP that puts another tenant's name in the claim
> signs its users in to that tenant. Every tenant's IdP must therefore be
> trusted by all tenants not to forge the claim: add only IdPs you, the
> platform operator, control or trust. Binding each provider to its own
> tenant on the server side has been requested from the Klique server team.

In the IdP:

- **Callback URL:** register it as the redirect URI (OIDC) or the ACS URL
  (SAML).
- **Tenant claim:** the IdP must send a claim (OIDC) or attribute (SAML),
  named by `claims.tenant`, whose value is exactly the tenant's name, for
  example as a hardcoded claim or a static attribute. The control plane runs
  with `skip_tenant_check: false`, so a login is accepted only when this
  claim names the tenant being signed in to.
- **Groups:** send the user's groups in the claim named by `claims.groups`.
  `adminGroups` and `builderGroups` are matched against it.
- **Post-logout redirect URI (OIDC with `logoutFromProvider`):** register the
  `post-logout URI` from the log (Keycloak: "Valid post logout redirect URIs"). Without it the IdP rejects the
  logout redirect, see [Logout](#logout).
- **SAML:** import the SP metadata from the log, or enter the SP entity id
  and ACS URL by hand.

The URLs come from the `app_url` key of the `klique-platform` ConfigMap
(written by klique-terraform, or by hand from
[`../klique-platform.example.yaml`](../klique-platform.example.yaml)).
Without that key, the log shows `<app-url>` and skips the SAML SP metadata.

### Logout

**OIDC.** To end the IdP session too when a user logs out of Klique, set
`logoutFromProvider: true` and `endSessionEndpoint` (the IdP's end-session URL,
reachable from the user's browser, for example
`https://idp.example.com/realms/<realm>/protocol/openid-connect/logout`), and
register `https://<app host>/login/<tenant>` as a post-logout redirect URI in
the IdP (the Job logs it as `post-logout URI`). Klique then sends the browser
to the IdP with `client_id` and `post_logout_redirect_uri`, and after the logout
the user lands on the tenant's login page.

- Klique sends no `id_token_hint`. Keycloak then shows its own logout
  confirmation page first. An IdP whose end-session endpoint requires
  `id_token_hint` cannot work with this: leave `logoutFromProvider` off for it.
- If the post-logout URI is not registered, the IdP rejects the redirect (for
  example Keycloak's "Invalid redirect uri") and the user is left on an IdP error
  page. The IdP session stays; the Klique session has already ended. Register
  the URI, or set `logoutFromProvider` to `false` (`tenant-example` turns it
  on).

**SAML.** There is no Single Logout. Logging out ends only the Klique session:
the browser lands on the generic `/login` (not the tenant's), and the IdP
session stays, so the next login may go through without a password.

## Orchestrator and gateway

Every tenant gets two Helm releases, rendered from the shared component and
installed into its namespace:

| HelmRelease (in `klique`) | release in the tenant's namespace | authenticates with | what it does |
|---|---|---|---|
| `<tenant>-orchestrator` | `klique-orchestrator` | Secret `orchestrator` | runs the tenant's tasks as pods in its namespace and registers its queues |
| `<tenant>-gateway` | `klique-gateway` | Secret `app-gateway` | serves the tenant's running apps and sessions at `https://<tenant>.<sessions host>` and `*.<tenant>.<sessions host>` |

The two key Secrets come from the tenant's Job, which runs alongside the
releases: on a new tenant, the orchestrator and gateway pods wait (briefly
`CreateContainerConfigError`) until the Job has minted them. If the Job
fails, the releases can exhaust their install retries; after fixing the Job,
run `flux reconcile helmrelease -n klique <tenant>-orchestrator --reset` (and
`-gateway`).

Values come, in order (later wins; maps merge, lists are replaced whole):

1. `klique-platform` / `orchestrator.yaml` or `gateway.yaml`: cluster facts;
2. `../klique/values/orchestrator.yaml` or `gateway.yaml`: shared by every
   tenant (credentials by name, the `default` queue, the task CA mount);
3. `klique-platform` / `*-overrides.yaml`: tfvars overrides;
4. this folder's `orchestrator-values.yaml` / `gateway-values.yaml`, if it
   lists them under `files:`;
5. gateway only: the tenant's host, TLS Secret and `streamSession.enabled:
   false`, set by the HelmRelease itself and not overridable.

For example, a tenant with its own GPU queue: add `orchestrator-values.yaml`

```yaml
orchestratork8sglue:
  queues:
    gpu:
      queueSettings:
        maxPods: 2
      templateOverrides:
        resources:
          limits:
            nvidia.com/gpu: 1
```

and list it in `kustomization.yaml`:

```yaml
configMapGenerator:
  - name: tenant-config
    files:
      - tenant.json
      - orchestrator-values.yaml
```

Every queue needs a `templateOverrides` entry, even `{}`: the chart fails to
render a queue without one. The shared `default` queue stays, because maps
merge.

A tenant's values files may tune its releases, but `scripts/check.sh` rejects
these keys in them, because they would reach beyond the tenant or swap its
credentials:

- `orchestratork8sglue.serviceAccountClusterAccess`,
  `orchestratork8sglue.additionalClusterRoleBindings`: cluster-wide rights;
- `sessions.portModeEnabled`: node ports every tenant would share;
- `controlPlane.existingSecret`, `controlPlane.existingSecretKeys`,
  `controlPlane.existingOrchestratork8sglueSecret`, `controlPlane.apiKey`,
  `controlPlane.apiSecret`: credentials;
- `imageCredentials`: pull credentials;
- `httpRoute`: a route on a host that is not the tenant's.

A setting every tenant needs goes in `../klique/values/` instead.

Editing a tenant's values file also reruns its Job (the files share one
ConfigMap), and editing `tenant.json` gives its releases a no-op upgrade. Both
are harmless.

The gateway needs, per cluster (see the
[Flux README](../README.md#placeholders-to-replace)):

- a cert-manager **ClusterIssuer** that can issue wildcards, named in
  `klique-platform-vars`. Each tenant's Certificate (`<tenant>-gateway-tls`)
  covers `<tenant>.<sessions host>` and `*.<tenant>.<sessions host>`;
- **DNS** for `*.<sessions host>` pointing at the ingress.

Tenant files are substituted too: a `${KLIQUE_DOMAIN}` in `tenant.json` becomes
the domain. Use only `${VAR}`, `${VAR:-default}` or `${VAR:=default}`, with a
`klique-platform-vars` variable. Write `$${` for a literal `${`. Flux also
turns a `$$` into `$`. `scripts/check.sh` rejects anything else after a `$`
that Flux would change: `${VAR-default}` and `${{...}}` fail the reconcile,
while `${#VAR}`, `${VAR:0:2}` and `${VAR,,}` are evaluated.

## Removing a tenant

Deleting a tenant's folder deletes its Job, its ConfigMap, its RoleBinding,
its ExternalSecret, and its orchestrator and gateway releases (Helm
uninstalls them; task pods the orchestrator already started are not part of
the release and stay until they end). It does **not** delete:

- **the namespace**, which is annotated `kustomize.toolkit.fluxcd.io/prune:
  disabled` because it holds the tenant's minted keys;
- **the Klique tenant**, because nothing here deletes tenants.

Delete those by hand if that is what you mean.

## Day-2

```bash
flux get kustomizations -n klique                 # tenants: Ready once every Job completed and every release is healthy
flux get helmreleases -n klique                   # <tenant>-orchestrator, <tenant>-gateway
kubectl -n klique get jobs                        # one <tenant>-reconcile per tenant
kubectl -n <tenant> get pods                      # the tenant's orchestrator, gateway and task pods
kubectl -n klique logs job/<tenant>-reconcile     # the plan, what was applied, the IdP details
```

A Job runs again only when its spec changes. That happens when the tenant's
files change, when `reconcile.py` changes (all tenants rerun), or when the
image changes (all tenants rerun).

To rerun one tenant without a commit, for example after you change a secret
in the backend or fix something on the server:

```bash
kubectl -n klique delete job <tenant>-reconcile
flux reconcile kustomization tenants -n klique
```

Running a Job again is safe:

- a second run mints no keys and leaves what already matches as it is;
- a key whose Secret was deleted is revoked and minted again.

A failed Job makes the `tenants` Kustomization NotReady and names the Job. The
reason is in its log.
