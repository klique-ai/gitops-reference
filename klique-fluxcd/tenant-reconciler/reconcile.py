#!/usr/bin/env python3
"""Create or update one Klique tenant from its folder under klique-fluxcd/tenants/.

The per-tenant Job runs this on the official python image (stdlib only). It
never deletes anything. Three layers:

  Source  load and validate tenant.json (plus the IdP metadata files it names)
  Plan    a pure function: desired state + observed state -> list of Actions,
          printed before anything changes
  Apply   run the Actions against the Platform Management server (tenants.*),
          the apiserver (system.*, sso.*) and the Kubernetes API (the tenant's
          key Secrets)

CI runs the Source layer alone:

  python3 reconcile.py --validate <folder>/tenant.json [--tenant <name>]

The Job runs it with no arguments, configured from the environment:

  TENANT                the tenant name (the folder's namespace:)
  CONFIG_DIR            tenant.json and its files (default /tenant)
  SECRETS_DIR           the mounted Secret <tenant>-sso (default /tenant-secrets)
  SECRETS_WAIT_SECONDS  how long to wait for its key files (default 300)
  PM_URL, PM_KEY, PM_SECRET     Platform Management server, for tenants.*
                        (the platform_management pair may call nothing else)
  API_URL, API_KEY, API_SECRET  apiserver, for system.* and sso.*
  APP_URL               optional: the web UI URL, for the logged login details

IdP secrets ({"key": K} in tenant.json) are read from the file SECRETS_DIR/K:
the Secret <tenant>-sso in klique, written by its ExternalSecret. A missing
file is waited for (the ExternalSecret may not have synced yet), then fails
the run before anything changes. A value is sent exactly as the file holds
it, trailing newline included: ESO writes the backend value as-is, so what is
stored in the backend is what the IdP gets.

An existing tenant of the same name is adopted. Its credentials are left
alone except the orchestrator and app-gateway keys this script owns; the key
create_tenant returns is revoked only right after this script's own create.

This file is carried by a ConfigMap that Flux post-build substitution may run
over, so it must never contain a dollar sign followed by an opening brace.
"""

import argparse
import base64
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

TENANT_FILE = "tenant.json"
SECRETS_DIR = "/tenant-secrets"
# The two keys every tenant gets, minted on the tenant's internal admin. The
# credential label is also the name of the Secret it is written to.
KEY_LABELS = ("orchestrator", "app-gateway")
# The label create_tenant gives the key it returns; revoked at once, nothing
# uses it.
DEFAULT_CREDENTIALS_LABEL = "Default Credentials"
MANAGED_BY = {"app.kubernetes.io/managed-by": "tenant-reconciler"}

OIDC_PRESETS = ("oidc", "auth0", "aws_cognito", "google", "keycloak",
                "microsoft_ad", "azure", "okta", "ping")
SAML_PRESETS = ("saml", "duo_saml", "google_saml", "jumpcloud_saml",
                "microsoft_saml")

# Used with fullmatch, so no anchors (and no dollar sign in this file).
# 50, not 63: the tenant's HelmRelease <tenant>-orchestrator becomes a label
# value (at most 63 characters).
TENANT_NAME_MAX = 50
TENANT_NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{1,48}[a-z0-9]")
# No "-" in a provider id: stored as <tenant>-<id>, so it stays unique.
PROVIDER_ID_RE = re.compile(r"[a-z0-9]{1,40}")
# Namespaces the platform itself uses: a tenant there would get the tenant
# RoleBinding (and later its workloads) next to platform components.
RESERVED_TENANTS = ("klique", "flux-system", "default", "external-secrets",
                    "cert-manager", "traefik", "keycloak", "openbao")
RESERVED_PREFIXES = ("kube-",)
SECRET_KEY_RE = re.compile(r"[-._a-zA-Z0-9]+")
FILE_NAME_RE = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9._-]*")

# --- field tables: tenant.json (camelCase) -> server wizard entry names ----
# Types: str, bool, secret ({"key": ...}: a key of Secret <tenant>-sso), list (of strings,
# sent comma-separated), map (string -> string, sent as k=v,...), or a tuple
# of allowed string values.

COMMON_FIELDS = {
    "autoProvision": ("auto_provision", "bool"),
}
OIDC_FIELDS = {
    "clientId": ("client_id", "str"),
    "clientSecret": ("client_secret", "secret"),
    "authorizationEndpoint": ("authorization_endpoint", "str"),
    "tokenEndpoint": ("token_endpoint", "str"),
    "userinfoEndpoint": ("userinfo_endpoint", "str"),
    "revocationEndpoint": ("revocation_endpoint", "str"),
    "endSessionEndpoint": ("end_session_endpoint", "str"),
    "jwksUri": ("jwks_uri", "str"),
    "audience": ("audience", "str"),
    "getUserinfoFromIdToken": ("get_userinfo_from_id_token", "bool"),
    "logoutFromProvider": ("logout_from_provider", "bool"),
    "checkEmailVerified": ("check_email_verified", "bool"),
    "verifyTokenSignature": ("verify_token_signature", "bool"),
    "codeChallenge": ("code_challenge", ("None", "Plain", "S256")),
    "scopes": ("scopes", "list"),
    "extraScopes": ("extra_scopes", "list"),
    "providerParams": ("provider_params", "map"),
}
OIDC_REQUIRED = ("clientId", "clientSecret", "authorizationEndpoint",
                 "tokenEndpoint")
SAML_FIELDS = {
    "entityId": ("entity_id", "str"),
    # idpMetadataFile is handled on its own: the file's content goes to idp_file.
    "signedAssertions": ("signed_assertions", "bool"),
    "signedRequest": ("signed_request", "bool"),
    # A certificate, public by nature: plain text is fine.
    "publicKey": ("public_key", "str"),
    "privateKey": ("private_key", "secret"),
}
SAML_REQUIRED = ("idpMetadataFile",)
OIDC_CLAIMS = {
    "tenant": ("claim_tenant", "str"),
    "groups": ("claim_groups", "str"),
    "sub": ("claim_sub", "str"),
    "email": ("claim_email", "str"),
    "emailVerified": ("claim_email_verified", "str"),
    "name": ("claim_name", "str"),
    "givenName": ("claim_given_name", "str"),
    "familyName": ("claim_family_name", "str"),
    "picture": ("claim_picture", "str"),
    "custom": ("custom_claims", "list"),
}
SAML_CLAIMS = {
    "tenant": ("claim_tenant", "str"),
    "groups": ("claim_groups", "str"),
    "objectId": ("claim_object_id", "str"),
    "email": ("claim_email", "str"),
    "name": ("claim_name", "str"),
    "givenName": ("claim_given_name", "str"),
    "familyName": ("claim_family_name", "str"),
    "custom": ("custom_claims", "list"),
}
GROUP_FIELDS = {
    "caseSensitive": ("group_case_sensitive", "bool"),
    "claimFormat": ("group_claim_format", ("none", "ldap-dn")),
    "prohibitSignupIfNotInGroup": ("group_prohibit_user_signup_if_not_in_group", "bool"),
    "prohibitLoginIfNotInGroup": ("group_prohibit_user_login_if_not_in_group", "bool"),
}
PROVIDER_KEYS = ("id", "preset", "displayName", "enabled", "claims", "groups")


# ============================================================ Source =========

class ValidationError(Exception):
    def __init__(self, errors: List[str]):
        super().__init__("\n".join(errors))
        self.errors = errors


@dataclass(frozen=True)
class SecretRef:
    key: str  # a file name in the secrets dir (a key of Secret <tenant>-sso)
    path: str  # where tenant.json references it, for error messages


@dataclass
class ProviderSpec:
    id: str  # as stored on the server: <tenant>-<local id>
    local_id: str
    preset: str
    category: str  # oidc | saml
    display_name: str
    enabled: bool
    # Wizard entry name -> value; secrets are still SecretRefs here.
    configuration: Dict[str, object]


@dataclass
class Desired:
    tenant: str
    limits: Dict[str, int]  # create_tenant names: max_users, max_service_users
    sso: Dict[str, object]  # system.update_company_sso_config's sso object
    providers: List[ProviderSpec]

    def secret_refs(self) -> List[SecretRef]:
        return [v for p in self.providers for v in p.configuration.values()
                if isinstance(v, SecretRef)]

    def secret_keys(self) -> List[str]:
        return sorted({ref.key for ref in self.secret_refs()})


class _Checker:
    def __init__(self):
        self.errors: List[str] = []

    def err(self, path: str, msg: str):
        self.errors.append(f"{path}: {msg}")

    def obj(self, value, path: str, allowed, required=()) -> dict:
        if not isinstance(value, dict):
            self.err(path, "must be an object")
            return {}
        for k in value:
            if k not in allowed:
                self.err(f"{path}.{k}", "unknown field")
        for k in required:
            if k not in value:
                self.err(f"{path}.{k}", "required")
        return value

    def string(self, value, path: str) -> Optional[str]:
        if not isinstance(value, str) or not value.strip():
            self.err(path, "must be a non-empty string")
            return None
        return value.strip()

    def strlist(self, value, path: str, nonempty=False) -> Optional[List[str]]:
        if not isinstance(value, list) or not all(
                isinstance(x, str) and x.strip() for x in value):
            self.err(path, "must be a list of non-empty strings")
            return None
        if nonempty and not value:
            self.err(path, "must not be empty")
            return None
        return [x.strip() for x in value]

    def typed(self, value, kind, path: str):
        """Check one table field; return the value to send, or None."""
        if kind == "str":
            return self.string(value, path)
        if kind == "bool":
            if not isinstance(value, bool):
                self.err(path, "must be true or false")
                return None
            return value
        if kind == "secret":
            if isinstance(value, str):
                self.err(path, 'plaintext secrets are not allowed; use '
                               '{"key": "<key of Secret <tenant>-sso>"}')
                return None
            if (not isinstance(value, dict) or set(value) != {"key"}
                    or not isinstance(value["key"], str)
                    or not SECRET_KEY_RE.fullmatch(value["key"])):
                self.err(path, 'must be {"key": "<key of Secret <tenant>-sso>"} '
                               '(letters, digits, "-", "_", ".")')
                return None
            return SecretRef(value["key"], path)
        if kind == "list":
            items = self.strlist(value, path)
            if items is None:
                return None
            if any("," in x for x in items):
                self.err(path, "items must not contain a comma")
                return None
            return ",".join(items)
        if kind == "map":
            if not isinstance(value, dict) or not all(
                    isinstance(k, str) and isinstance(v, str)
                    for k, v in value.items()):
                self.err(path, "must be an object of strings")
                return None
            if any(c in k + v for k, v in value.items() for c in ",="):
                self.err(path, 'keys and values must not contain "," or "="')
                return None
            return ",".join(f"{k}={v}" for k, v in value.items())
        if isinstance(kind, tuple):
            if value not in kind:
                self.err(path, "must be one of " + ", ".join(kind))
                return None
            return value
        raise AssertionError(kind)

    def table(self, src: dict, table: dict, path: str, out: dict):
        for name, (target, kind) in table.items():
            if name in src:
                value = self.typed(src[name], kind, f"{path}.{name}")
                if value is not None:
                    out[target] = value


def load_source(text: str, read_file: Callable[[str], str],
                tenant: Optional[str]) -> Desired:
    """Parse and validate tenant.json. read_file(name) returns the content of
    a file next to tenant.json, or raises OSError. tenant=None (CI without
    --tenant) skips the tenant name check and uses a placeholder."""
    c = _Checker()
    if tenant is not None and not TENANT_NAME_RE.fullmatch(tenant):
        c.err("tenant", f"{tenant!r} must be a DNS label of 3 to "
                        f"{TENANT_NAME_MAX} lowercase letters, digits or '-', "
                        "starting and ending alphanumeric, so "
                        "<tenant>-orchestrator stays a valid label value "
                        "(it is the folder's namespace:)")
    elif tenant is not None and (tenant in RESERVED_TENANTS
                                 or tenant.startswith(RESERVED_PREFIXES)):
        c.err("tenant", f"{tenant!r} is reserved for the platform; reserved: "
                        + ", ".join(RESERVED_TENANTS) + ", kube-*")
    name = tenant or "<tenant>"
    try:
        doc = json.loads(text)
    except ValueError as ex:
        raise ValidationError([f"{TENANT_FILE}: not valid JSON: {ex}"])
    doc = c.obj(doc, "tenant.json", ("limits", "sso"), ("sso",))

    limits = {}
    if "limits" in doc:
        lim = c.obj(doc["limits"], "limits", ("maxUsers", "maxServiceUsers"))
        for k, target in (("maxUsers", "max_users"),
                          ("maxServiceUsers", "max_service_users")):
            if k in lim:
                v = lim[k]
                if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                    c.err(f"limits.{k}", "must be an integer >= 0")
                else:
                    limits[target] = v

    sso_src = c.obj(doc.get("sso", {}), "sso",
                    ("adminGroups", "builderGroups", "groupMapping", "providers"),
                    ("adminGroups", "providers"))
    sso: Dict[str, object] = {"tenant": name, "admin_groups": [],
                              "group_mapping": {}}
    if "adminGroups" in sso_src:
        sso["admin_groups"] = c.strlist(sso_src["adminGroups"],
                                        "sso.adminGroups", nonempty=True) or []
    if "builderGroups" in sso_src:
        # Present (even []) is sent; absent is never sent: [] makes every
        # non-admin a consumer, absent leaves the legacy "everyone a builder".
        bg = c.strlist(sso_src["builderGroups"], "sso.builderGroups")
        if bg is not None:
            sso["builder_groups"] = bg
    if "groupMapping" in sso_src:
        gm = sso_src["groupMapping"]
        if not isinstance(gm, dict) or not all(
                isinstance(v, str) or (isinstance(v, list) and all(
                    isinstance(x, str) for x in v)) for v in gm.values()):
            c.err("sso.groupMapping", "must map each IdP group to a group "
                                      "name or a list of group names")
        else:
            sso["group_mapping"] = gm

    providers: List[ProviderSpec] = []
    plist = sso_src.get("providers", [])
    if not isinstance(plist, list) or not plist:
        if "providers" in sso_src:
            c.err("sso.providers", "must be a non-empty list")
        plist = []
    seen_ids, seen_names = set(), set()
    for i, p in enumerate(plist):
        spec = _load_provider(c, p, f"sso.providers[{i}]", name, read_file)
        if spec is None:
            continue
        if spec.local_id in seen_ids:
            c.err(f"sso.providers[{i}].id", f"duplicate id {spec.local_id!r}")
        if spec.display_name in seen_names:
            c.err(f"sso.providers[{i}].displayName",
                  f"duplicate displayName {spec.display_name!r}")
        seen_ids.add(spec.local_id)
        seen_names.add(spec.display_name)
        providers.append(spec)

    if c.errors:
        raise ValidationError(c.errors)
    return Desired(tenant=name, limits=limits, sso=sso, providers=providers)


def _load_provider(c: _Checker, p, path: str, tenant: str,
                   read_file) -> Optional[ProviderSpec]:
    if not isinstance(p, dict):
        c.err(path, "must be an object")
        return None
    preset = p.get("preset")
    if preset in OIDC_PRESETS:
        category, fields, required, claims_table = (
            "oidc", OIDC_FIELDS, OIDC_REQUIRED, OIDC_CLAIMS)
        extra_keys = ()
    elif preset in SAML_PRESETS:
        category, fields, required, claims_table = (
            "saml", SAML_FIELDS, SAML_REQUIRED, SAML_CLAIMS)
        extra_keys = ("idpMetadataFile",)
    else:
        c.err(f"{path}.preset", "required, one of " +
              ", ".join(OIDC_PRESETS + SAML_PRESETS))
        return None
    allowed = PROVIDER_KEYS + tuple(COMMON_FIELDS) + tuple(fields) + extra_keys
    c.obj(p, path, allowed, ("id", "displayName", "claims") + required)

    local_id = p.get("id")
    if not isinstance(local_id, str) or not PROVIDER_ID_RE.fullmatch(local_id):
        if "id" in p:
            c.err(f"{path}.id", "must be 1 to 40 lowercase letters or digits "
                                "(no '-': the stored id is <tenant>-<id>)")
        local_id = None
    display_name = c.string(p["displayName"], f"{path}.displayName") \
        if "displayName" in p else None
    enabled = p.get("enabled", True)
    if not isinstance(enabled, bool):
        c.err(f"{path}.enabled", "must be true or false")

    config: Dict[str, object] = {}
    c.table(p, COMMON_FIELDS, path, config)
    c.table(p, fields, path, config)

    if "claims" in p:
        claims = c.obj(p["claims"], f"{path}.claims", tuple(claims_table),
                       ("tenant",))
        c.table(claims, claims_table, f"{path}.claims", config)
    # Company adminGroups/builderGroups only apply when the provider returns
    # groups, so group sync is always on; the provider-level admins/builders
    # are left unset (the company settings override them at login).
    config["group_enabled"] = True
    if "groups" in p:
        groups = c.obj(p["groups"], f"{path}.groups", tuple(GROUP_FIELDS))
        c.table(groups, GROUP_FIELDS, f"{path}.groups", config)

    if category == "saml" and "idpMetadataFile" in p:
        fname = p["idpMetadataFile"]
        fpath = f"{path}.idpMetadataFile"
        if not isinstance(fname, str) or not FILE_NAME_RE.fullmatch(fname) \
                or fname == TENANT_FILE:
            c.err(fpath, "must be the name of a file next to tenant.json")
        else:
            try:
                xml = read_file(fname)
            except OSError:
                c.err(fpath, f"file {fname!r} not found next to tenant.json "
                             "(SAML tenants also list it in the folder's "
                             "configMapGenerator files:)")
            else:
                if "EntityDescriptor" not in xml:
                    c.err(fpath, f"{fname!r} is not SAML metadata "
                                 "(no EntityDescriptor)")
                else:
                    config["idp_file"] = xml

    # The server's own dependency checks (bll/sso), reported here by field.
    if category == "oidc":
        if config.get("logout_from_provider") and "end_session_endpoint" not in config:
            c.err(f"{path}.endSessionEndpoint", "required when logoutFromProvider is true")
        if config.get("get_userinfo_from_id_token") is False and "userinfo_endpoint" not in config:
            c.err(f"{path}.userinfoEndpoint", "required when getUserinfoFromIdToken is false")
        if config.get("verify_token_signature") and "jwks_uri" not in config:
            c.err(f"{path}.jwksUri", "required when verifyTokenSignature is true")
    elif config.get("signed_request") and not (
            "public_key" in config and "private_key" in config):
        c.err(f"{path}.signedRequest", "needs both publicKey and privateKey")

    if local_id is None or display_name is None:
        return None
    config["display_name"] = display_name
    full_id = f"{tenant}-{local_id}"
    config["id"] = full_id
    return ProviderSpec(id=full_id, local_id=local_id, preset=preset,
                        category=category, display_name=display_name,
                        enabled=enabled if isinstance(enabled, bool) else True,
                        configuration=config)


def load_dir(directory: str, tenant: Optional[str]) -> Desired:
    def read_file(name: str) -> str:
        with open(os.path.join(directory, name), encoding="utf-8") as f:
            return f.read()
    try:
        text = read_file(TENANT_FILE)
    except OSError as ex:
        raise ValidationError([f"{TENANT_FILE}: cannot read: {ex.strerror}"])
    return load_source(text, read_file, tenant)


# ============================================================ Observe ========

@dataclass
class Observed:
    tenant_id: Optional[str] = None
    # system.company_info defaults: only the keys the server has set.
    limits: Dict[str, int] = field(default_factory=dict)
    sso: Optional[dict] = None
    admin_id: Optional[str] = None
    # [{access_key, label}] of the tenant's first internal admin.
    credentials: List[dict] = field(default_factory=list)
    # label -> access_key in the Secret of that name (None: no such Secret).
    secrets: Dict[str, Optional[str]] = field(default_factory=dict)
    # Referenced secret key -> why it cannot be read (absent: readable).
    secret_problems: Dict[str, str] = field(default_factory=dict)
    # provider id -> {"active": bool}
    providers: Dict[str, dict] = field(default_factory=dict)


# Every secret value this run handles (IdP secrets, minted keys). Error
# messages are built from server and API replies, which could echo a request;
# these values are cut out of every message before it can be printed.
_SECRET_VALUES: set = set()


def register_secret(value: str):
    if value and len(value.strip()) >= 4:
        _SECRET_VALUES.add(value)
        _SECRET_VALUES.add(value.strip())


def scrub(text: str) -> str:
    for value in sorted(_SECRET_VALUES, key=len, reverse=True):
        text = text.replace(value, "<redacted>")
    return text


class ReconcileError(Exception):
    def __init__(self, message: str):
        super().__init__(scrub(str(message)))


class SecretFiles:
    """The mounted Secret <tenant>-sso: one file per key. Keys are validated
    plain names ([-._a-zA-Z0-9]+), so a key never leaves the directory."""

    def __init__(self, directory: str = SECRETS_DIR, wait_seconds: int = 300,
                 interval: int = 10, sleep=time.sleep, clock=time.monotonic):
        self.directory = directory
        self.wait_seconds = wait_seconds
        self.interval = interval
        self.sleep = sleep
        self.clock = clock

    def wait(self, keys: List[str], tenant: str, out=print):
        """Wait, bounded, until every key's file is readable: an
        ExternalSecret created with the tenant may not have synced yet. Logs
        one line, names only."""
        deadline = self.clock() + self.wait_seconds
        logged = False
        while True:
            pending = [k for k in keys if self.problem(k)]
            if not pending or self.clock() >= deadline:
                return
            if not logged:
                out(f"waiting up to {self.wait_seconds} s for secret keys "
                    f"{', '.join(pending)} in {self.directory} (Secret "
                    f"{tenant}-sso in klique, not synced yet?)")
                logged = True
            self.sleep(min(self.interval, max(0.0, deadline - self.clock())))

    def _path(self, key: str) -> str:
        if not SECRET_KEY_RE.fullmatch(key) or key in (".", ".."):
            raise ReconcileError(f"invalid secret key {key!r}")
        return os.path.join(self.directory, key)

    def problem(self, key: str) -> Optional[str]:
        """None when the key's file can be read; never returns content."""
        try:
            with open(self._path(key), "rb") as f:
                f.read(1)
        except FileNotFoundError:
            return f"not found in {self.directory}"
        except OSError as ex:
            return f"unreadable in {self.directory} ({ex.strerror or type(ex).__name__})"
        return None

    def read(self, key: str) -> str:
        try:
            with open(self._path(key), encoding="utf-8", newline="") as f:
                value = f.read()
            register_secret(value)
            return value
        except (OSError, UnicodeDecodeError) as ex:
            raise ReconcileError(f"secret key {key!r}: cannot read "
                                 f"({type(ex).__name__})") from None


def observe(desired: Desired, pm, api, kube, secrets: SecretFiles) -> Observed:
    obs = Observed()
    # Ids are random; the name is the handle. Names are unique on the server,
    # compared case-insensitively.
    tenants = pm.call("tenants.get_tenants", {}).get("tenants", [])
    same = [t for t in tenants if t["name"].lower() == desired.tenant.lower()]
    if same and same[0]["name"] != desired.tenant:
        raise ReconcileError(f"a tenant named {same[0]['name']!r} exists; names "
                             f"are case-insensitive, so {desired.tenant!r} "
                             "cannot be created")
    if same:
        if same[0].get("default_company"):
            raise ReconcileError(f"{desired.tenant!r} is the default company; "
                                 "refusing to manage it")
        obs.tenant_id = same[0]["id"]
        admins = pm.call("tenants.get_tenant_admins",
                         {"tenant": obs.tenant_id}).get("admins", [])
        if admins:  # sorted by creation: the first is create_tenant's own
            obs.admin_id = admins[0]["id"]
            obs.credentials = [
                {"access_key": cr["access_key"], "label": cr.get("label")}
                for cr in admins[0].get("credentials", [])]
        info = api.call("system.company_info", {"company": obs.tenant_id})
        defaults = info.get("defaults") or {}
        obs.limits = {k: defaults[k] for k in
                      ("allowed_users", "allowed_service_users")
                      if defaults.get(k) is not None}
        obs.sso = defaults.get("sso") or None
        confs = api.call("sso.get_provider_configurations",
                         {"company": obs.tenant_id}).get("configurations", [])
        obs.providers = {cf["id"]: {"active": cf.get("active", True)}
                         for cf in confs}
    for label in KEY_LABELS:
        secret = kube.get_secret(desired.tenant, label)
        obs.secrets[label] = (_b64(secret.get("data", {}).get("access_key"))
                              if secret else None)
    for key in desired.secret_keys():
        problem = secrets.problem(key)
        if problem:
            obs.secret_problems[key] = problem
    return obs


def _b64(value: Optional[str]) -> Optional[str]:
    return base64.b64decode(value).decode() if value else None


# ============================================================ Plan ===========

@dataclass(frozen=True)
class Action:
    kind: str
    # CreateTenant: limits | SetLimits: fields | RevokeKey: label, access_key
    # (None = the key create_tenant returns), reason | MintKey: label |
    # SetCompanySso: sso | SaveProvider / ReportProvider: provider, mode |
    # SetProviderActive: ids, active
    args: tuple = ()

    def describe(self) -> str:
        a = dict(self.args)
        if self.kind == "CreateTenant":
            lim = ", ".join(f"{k}={v}" for k, v in a["limits"].items())
            return f"create tenant {a['name']}" + (f" ({lim})" if lim else "")
        if self.kind == "SetLimits":
            return "set limits " + ", ".join(f"{k}={v}" for k, v in a["fields"].items())
        if self.kind == "RevokeKey":
            key = a["access_key"] or "(the one create_tenant returns)"
            return f"revoke key {a['label']!r} {key}: {a['reason']}"
        if self.kind == "MintKey":
            return f"mint key {a['label']!r} into Secret {a['label']}"
        if self.kind == "SetCompanySso":
            s = a["sso"]
            bg = s.get("builder_groups", "(unset)")
            return (f"set company SSO: tenant={s['tenant']} admin_groups="
                    f"{s['admin_groups']} builder_groups={bg} "
                    f"group_mapping={s['group_mapping']}")
        if self.kind == "SaveProvider":
            p = a["provider"]
            how = "create" if a["mode"] == "create" else "update (full replace)"
            return f"save provider {p.id} ({p.preset}): {how}"
        if self.kind == "SetProviderActive":
            return f"set providers {', '.join(a['ids'])} active={a['active']}"
        if self.kind == "ReportProvider":
            return f"report login details of provider {a['provider'].id}"
        return self.kind


def _act(kind: str, **kwargs) -> Action:
    return Action(kind, tuple(kwargs.items()))


def _sso_unchanged(desired: dict, observed: Optional[dict]) -> bool:
    if not observed:
        return False
    if observed.get("tenant") != desired["tenant"]:
        return False
    if (observed.get("admin_groups") or []) != desired["admin_groups"]:
        return False
    if (observed.get("group_mapping") or {}) != desired["group_mapping"]:
        return False
    # system.company_info reports an unset builder_groups as [], so a [] read
    # back could be either: unset (every non-admin a builder) or an explicit
    # [] (every non-admin a consumer). Only a non-empty list is trusted; when
    # tenant.json has [] or omits builderGroups and the server reports [],
    # the settings are sent again (the call is idempotent).
    obs_bg = observed.get("builder_groups")
    if not obs_bg:
        return False
    return obs_bg == desired.get("builder_groups")


def plan(desired: Desired, observed: Observed) -> List[Action]:
    """Pure: what Apply must do to bring the server to tenant.json."""
    bad = [f"{ref.path}: secret key {ref.key!r} "
           f"{observed.secret_problems[ref.key]}"
           for ref in desired.secret_refs() if ref.key in observed.secret_problems]
    if bad:
        raise ReconcileError(
            "; ".join(bad) + f" (the Secret {desired.tenant}-sso in klique, "
            f"from its ExternalSecret, backend path "
            f"klique/tenants/{desired.tenant}/sso)")
    actions: List[Action] = []
    if observed.tenant_id is None:
        actions.append(_act("CreateTenant", name=desired.tenant,
                            limits=dict(desired.limits)))
        actions.append(_act("RevokeKey", label=DEFAULT_CREDENTIALS_LABEL,
                            access_key=None, reason="unused default key"))
        actions += [_act("MintKey", label=label) for label in KEY_LABELS]
    else:
        if observed.admin_id is None:
            raise ReconcileError(f"tenant {desired.tenant} has no internal "
                                 "admin to mint keys on")
        wanted = {"max_users": "allowed_users",
                  "max_service_users": "allowed_service_users"}
        changes = {wanted[k]: v for k, v in desired.limits.items()
                   if observed.limits.get(wanted[k]) != v}
        if changes:
            actions.append(_act("SetLimits", fields=changes))
        # Adopted: only the KEY_LABELS keys are this script's. Any other key,
        # create_tenant's default one included, is left alone.
        revokes, mints = [], []
        for label in KEY_LABELS:
            in_secret = observed.secrets.get(label)
            keys = [cr["access_key"] for cr in observed.credentials
                    if cr["label"] == label]
            for key in keys:
                if key != in_secret:
                    reason = ("no Secret holds it" if in_secret is None
                              else f"Secret {label} holds another key")
                    revokes.append(_act("RevokeKey", label=label,
                                        access_key=key, reason=reason))
            if in_secret is None or in_secret not in keys:
                mints.append(_act("MintKey", label=label))
        # Revoke first: the per-user credential limit counts live keys.
        actions += revokes + mints
    if observed.tenant_id is None or not _sso_unchanged(desired.sso, observed.sso):
        actions.append(_act("SetCompanySso", sso=desired.sso))
    for p in desired.providers:
        mode = "update" if p.id in observed.providers else "create"
        actions.append(_act("SaveProvider", provider=p, mode=mode))
    # A save always leaves the provider active, so disabled ones are switched
    # off after every save.
    disabled = [p.id for p in desired.providers if not p.enabled]
    if disabled:
        actions.append(_act("SetProviderActive", ids=disabled, active=False))
    for p in desired.providers:
        actions.append(_act("ReportProvider", provider=p))
    return actions


# ============================================================ Apply ==========

@dataclass
class Context:
    tenant_id: Optional[str]
    admin_id: Optional[str]
    default_key: Optional[str] = None


def callback_url(p: ProviderSpec, app_url: Optional[str]) -> str:
    base = (app_url or "<app-url>").rstrip("/")
    if p.category == "saml":
        return f"{base}/callback_saml"
    # With tenant_login the server builds the OIDC callback from the client id.
    return f"{base}/callback_{p.configuration['client_id']}"


def render(p: ProviderSpec, secret_values: Dict[str, str]) -> dict:
    return {k: (secret_values[v.key] if isinstance(v, SecretRef) else v)
            for k, v in p.configuration.items()}


def apply(actions: List[Action], desired: Desired, observed: Observed,
          pm, api, kube, secrets: SecretFiles, app_url: Optional[str],
          out=print):
    ctx = Context(observed.tenant_id, observed.admin_id)
    # Read once, before the first change; never printed.
    secret_values = {key: secrets.read(key) for key in desired.secret_keys()}
    for action in actions:
        a = dict(action.args)
        out("apply: " + action.describe())
        if action.kind == "CreateTenant":
            r = pm.call("tenants.create_tenant", {"name": a["name"], **a["limits"]})
            ctx.tenant_id = r["id"]
            register_secret(r["credentials"]["secret_key"])
            ctx.default_key = r["credentials"]["access_key"]
            admins = pm.call("tenants.get_tenant_admins",
                             {"tenant": ctx.tenant_id})["admins"]
            ctx.admin_id = admins[0]["id"]
        elif action.kind == "SetLimits":
            api.call("system.update_company_settings",
                     {"company": ctx.tenant_id, **a["fields"]})
        elif action.kind == "RevokeKey":
            pm.call("tenants.revoke_tenant_admin_credentials",
                    {"tenant": ctx.tenant_id, "user": ctx.admin_id,
                     "access_key": a["access_key"] or ctx.default_key})
        elif action.kind == "MintKey":
            r = pm.call("tenants.add_tenant_admin_credentials",
                        {"tenant": ctx.tenant_id, "user": ctx.admin_id,
                         "label": a["label"]})
            cred = r["credentials"]
            register_secret(cred["secret_key"])
            # A crash between these two calls leaves a labelled key no Secret
            # holds; the next run revokes and remints it.
            kube.write_secret(desired.tenant, a["label"],
                              {"access_key": cred["access_key"],
                               "secret_key": cred["secret_key"]})
        elif action.kind == "SetCompanySso":
            api.call("system.update_company_sso_config",
                     {"company": ctx.tenant_id, "sso": a["sso"]})
        elif action.kind == "SaveProvider":
            p = a["provider"]
            api.call("sso.save_provider_configuration",
                     {"company": ctx.tenant_id, "provider": p.preset,
                      "configuration": render(p, secret_values)})
        elif action.kind == "SetProviderActive":
            api.call("sso.set_provider_configurations_active",
                     {"company": ctx.tenant_id, "ids": a["ids"],
                      "active": a["active"]})
        elif action.kind == "ReportProvider":
            _report(a["provider"], desired, secret_values, api, app_url, out)
        else:
            raise AssertionError(action.kind)


def _report(p: ProviderSpec, desired: Desired, secret_values: dict, api,
            app_url: Optional[str], out):
    base = (app_url or "<app-url>").rstrip("/")
    out(f"provider {p.id} ({p.display_name}):")
    out(f"  login URL:       {base}/login/{desired.tenant}")
    out(f"  callback URL:    {callback_url(p, app_url)}  (register it in the IdP)")
    if p.configuration.get("logout_from_provider"):
        out(f"  post-logout URI: {base}/login/{desired.tenant}  "
            "(register it in the IdP)")
    out(f"  tenant claim:    {p.configuration['claim_tenant']!r} must carry "
        f"{desired.tenant!r}")
    if p.category != "saml":
        return
    out(f"  SP entity id:    {p.configuration.get('entity_id', 'clearml')}")
    if not app_url:
        out("  SP metadata:     skipped (APP_URL is not set)")
        return
    conf = render(p, secret_values)
    conf.pop("idp_file", None)
    conf["callback"] = callback_url(p, app_url)
    xml = api.call("sso.download_saml_sp_metadata",
                   {"provider": p.preset, "configuration": conf}, raw=True)
    out("  SP metadata:")
    for line in xml.splitlines():
        out("    " + line)


# ============================================================ Clients ========

class ApiError(ReconcileError):
    pass


class KliqueApi:
    """POST <base>/<service>.<action>, JSON body, HTTP basic auth."""

    def __init__(self, base_url: str, key: str, secret: str, timeout=60):
        self.base_url = base_url.rstrip("/")
        register_secret(secret)
        token = base64.b64encode(f"{key}:{secret}".encode()).decode()
        self.headers = {"Authorization": "Basic " + token,
                        "Content-Type": "application/json"}
        self.timeout = timeout

    def call(self, endpoint: str, data: dict, raw=False):
        req = urllib.request.Request(f"{self.base_url}/{endpoint}",
                                     data=json.dumps(data).encode(),
                                     headers=self.headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read().decode()
        except urllib.error.HTTPError as ex:
            # Only the server's code and short message, never the raw body (a
            # proxy error page or a validation echo could carry the request).
            # ReconcileError also cuts every known secret value out.
            try:
                with ex:
                    body = ex.read().decode(errors="replace")
                meta = json.loads(body)["meta"]
                msg = (f"{meta.get('result_code')}/{meta.get('result_subcode')}"
                       f" {str(meta.get('result_msg'))[:300]}")
            except (ValueError, KeyError, TypeError):
                msg = f"HTTP {ex.code}"
            raise ApiError(f"{endpoint}: {msg}") from None
        except urllib.error.URLError as ex:
            raise ApiError(f"{endpoint}: {ex.reason}") from None
        if raw:
            return body
        return json.loads(body).get("data") or {}


class KubeApi:
    """The in-cluster API, as the pod's ServiceAccount."""

    SA = "/var/run/secrets/kubernetes.io/serviceaccount"

    def __init__(self, timeout=30):
        host = os.environ["KUBERNETES_SERVICE_HOST"]
        if ":" in host:
            host = f"[{host}]"
        self.base = f"https://{host}:{os.environ['KUBERNETES_SERVICE_PORT']}"
        self.ssl = ssl.create_default_context(cafile=f"{self.SA}/ca.crt")
        self.timeout = timeout

    def _request(self, method: str, path: str, body=None,
                 content_type="application/json"):
        with open(f"{self.SA}/token", encoding="utf-8") as f:
            token = f.read().strip()
        req = urllib.request.Request(
            self.base + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": "Bearer " + token,
                     "Content-Type": content_type,
                     "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, context=self.ssl,
                                        timeout=self.timeout) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as ex:
            try:
                msg = json.loads(ex.read()).get("message", "")
            except ValueError:
                msg = ""
            return ex.code, {"message": msg}

    def get_secret(self, namespace: str, name: str) -> Optional[dict]:
        code, body = self._request(
            "GET", f"/api/v1/namespaces/{namespace}/secrets/{name}")
        if code == 404:
            return None
        if code != 200:
            raise ReconcileError(f"get Secret {namespace}/{name}: {code} "
                                 f"{body.get('message')}")
        return body

    def write_secret(self, namespace: str, name: str, values: Dict[str, str]):
        data = {k: base64.b64encode(v.encode()).decode() for k, v in values.items()}
        code, body = self._request(
            "POST", f"/api/v1/namespaces/{namespace}/secrets",
            {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
             "metadata": {"name": name, "namespace": namespace,
                          "labels": MANAGED_BY},
             "data": data})
        if code == 409:
            code, body = self._request(
                "PATCH", f"/api/v1/namespaces/{namespace}/secrets/{name}",
                {"metadata": {"labels": MANAGED_BY}, "data": data},
                content_type="application/merge-patch+json")
        if code not in (200, 201):
            raise ReconcileError(f"write Secret {namespace}/{name}: {code} "
                                 f"{body.get('message')}")


# ============================================================ main ===========

def run(desired: Desired, pm, api, kube, secrets: SecretFiles,
        app_url: Optional[str], plan_only=False, out=print) -> List[Action]:
    secrets.wait(desired.secret_keys(), desired.tenant, out)
    observed = observe(desired, pm, api, kube, secrets)
    actions = plan(desired, observed)
    if observed.tenant_id:
        out(f"tenant {desired.tenant} exists (id {observed.tenant_id}): "
            f"adopted; only its {' and '.join(KEY_LABELS)} keys are managed, "
            "other keys are left alone")
        if any(cr["label"] == DEFAULT_CREDENTIALS_LABEL
               for cr in observed.credentials):
            out(f"hint: tenant {desired.tenant} has a "
                f"{DEFAULT_CREDENTIALS_LABEL!r} key; revoke it in the Platform "
                "Management Center if nothing uses it")
    out(f"plan for tenant {desired.tenant}:")
    for action in actions:
        out("  " + action.describe())
    if not plan_only:
        apply(actions, desired, observed, pm, api, kube, secrets, app_url, out)
        out(f"tenant {desired.tenant}: done")
    return actions


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--validate", metavar="TENANT_JSON",
                        help="only validate this tenant.json (and the files it names)")
    parser.add_argument("--tenant", help="tenant name to validate against "
                                         "(with --validate; default: not checked)")
    parser.add_argument("--plan-only", action="store_true",
                        help="print the plan, change nothing")
    args = parser.parse_args(argv)

    if args.validate:
        try:
            load_dir(os.path.dirname(args.validate) or ".", args.tenant)
        except ValidationError as ex:
            for e in ex.errors:
                print(f"{args.validate}: {e}", file=sys.stderr)
            return 1
        print(f"{args.validate}: OK")
        return 0

    env = os.environ
    missing = [k for k in ("TENANT", "PM_KEY", "PM_SECRET", "API_KEY",
                           "API_SECRET") if not env.get(k)]
    if missing:
        print("missing environment: " + ", ".join(missing), file=sys.stderr)
        return 2
    try:
        wait = int(env.get("SECRETS_WAIT_SECONDS", "300"))
        if wait < 0:
            raise ValueError
    except ValueError:
        print("SECRETS_WAIT_SECONDS must be an integer >= 0", file=sys.stderr)
        return 2
    try:
        desired = load_dir(env.get("CONFIG_DIR", "/tenant"), env["TENANT"])
    except ValidationError as ex:
        for e in ex.errors:
            print(e, file=sys.stderr)
        return 1
    pm = KliqueApi(env.get("PM_URL", "http://klique-control-plane-platform-management-server.klique.svc:5210"),
                   env["PM_KEY"], env["PM_SECRET"])
    # Two pairs: the platform_management user may only call tenants.* (and a
    # few others) on the PM server; system.* and sso.* need the apiserver's
    # own internal user (services/auth.conf, permissions by user).
    api = KliqueApi(env.get("API_URL", "http://klique-control-plane-apiserver.klique.svc:8008"),
                    env["API_KEY"], env["API_SECRET"])
    try:
        run(desired, pm, api, KubeApi(),
            SecretFiles(env.get("SECRETS_DIR", SECRETS_DIR), wait_seconds=wait),
            env.get("APP_URL") or None,
            plan_only=args.plan_only)
    except ReconcileError as ex:
        print(f"error: {ex}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
