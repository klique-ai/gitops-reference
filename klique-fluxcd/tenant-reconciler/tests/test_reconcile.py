"""Unit tests for reconcile.py: no network, a fake Klique server and a fake
Kubernetes API. Run from the repo root:

  python3 -B -m unittest discover -s klique-fluxcd/tenant-reconciler/tests
"""

import base64
import contextlib
import copy
import io
import json
import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "reconcile.py")
sys.dont_write_bytecode = True  # keep __pycache__ out of the repo
sys.path.insert(0, os.path.dirname(HERE))
import reconcile as r  # noqa: E402

TENANT = "tenant-a"
IDP_XML = ('<md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" '
           'entityID="https://idp.example.com/realms/a"/>')
CLIENT_SECRET = "oidc-client-secret-value"
PM_PAIR = ("pm-key", "pm-secret-value")
API_PAIR = ("apiserver-key", "apiserver-secret-value")
# What the platform_management user may call (config/default/services/auth.conf);
# the apiserver user has service "*". The PM server accepts only its own pair.
PM_PAIR_SERVICES = ("auth", "tenants", "apps", "hardware", "server")
PRIVATE_KEY = "saml-private-key-value"


def b64(s):
    return base64.b64encode(s.encode()).decode()


def tenant_doc(**over):
    doc = {
        "limits": {"maxUsers": 10},
        "sso": {
            "adminGroups": ["klique-admins"],
            "groupMapping": {"idp-ml": "ml"},
            "providers": [
                {
                    "id": "kc",
                    "preset": "keycloak",
                    "displayName": "Keycloak",
                    "clientId": "klique",
                    "clientSecret": {"key": "kc-client-secret"},
                    "authorizationEndpoint": "https://idp.example.com/auth",
                    "tokenEndpoint": "https://idp.example.com/token",
                    "scopes": ["openid", "profile", "email"],
                    "providerParams": {"prompt": "login"},
                    "claims": {"tenant": "tenant", "custom": ["dept", "site"]},
                    "groups": {"caseSensitive": False},
                },
                {
                    "id": "saml",
                    "preset": "saml",
                    "displayName": "Keycloak SAML",
                    "idpMetadataFile": "idp-metadata.xml",
                    "entityId": "klique-tenant-a",
                    "claims": {"tenant": "tenant", "groups": "member"},
                },
            ],
        },
    }
    doc.update(over)
    return doc


def files_reader(files):
    def read(name):
        if name not in files:
            raise FileNotFoundError(name)
        return files[name]
    return read


def load(doc, files=None, tenant=TENANT):
    files = {"idp-metadata.xml": IDP_XML} if files is None else files
    return r.load_source(json.dumps(doc), files_reader(files), tenant)


def errors_of(doc, files=None, tenant=TENANT):
    with assertRaises(r.ValidationError) as cm:
        load(doc, files, tenant)
    return "\n".join(cm.exception.errors)


@contextlib.contextmanager
def assertRaises(exc):
    class Holder:
        exception = None
    h = Holder()
    try:
        yield h
    except exc as ex:
        h.exception = ex
    else:
        raise AssertionError(f"{exc.__name__} not raised")


# ---------------------------------------------------------------- fakes -----

class FakeKlique:
    """The server-side behaviour reconcile.py relies on, as read in the
    server source (bll/tenants/tenant_admin.py, services/system.py,
    bll/sso/__init__.py)."""

    def __init__(self):
        self.companies = {"default": {"name": "default", "defaults": {},
                                      "default_company": True}}
        self.admins = {}  # tenant id -> [admin]
        self.providers = {}  # id -> {company, provider, configuration, active}
        self.calls = []  # (server, endpoint, data)
        self.fail = {}  # endpoint -> remaining failures
        self.n = 0

    def _id(self, prefix):
        self.n += 1
        return f"{prefix}{self.n:04d}"

    def client(self, server, pair):
        fake = self

        class Client:
            def call(self, endpoint, data, raw=False):
                own = endpoint.startswith("tenants.")
                if (server == "pm") != own:
                    raise AssertionError(f"{endpoint} sent to {server}")
                if server == "pm" and pair != PM_PAIR:
                    raise r.ApiError(f"{endpoint}: 401/20 Invalid or missing credentials")
                if (server == "api" and pair == PM_PAIR
                        and endpoint.split(".")[0] not in PM_PAIR_SERVICES):
                    raise r.ApiError(f"{endpoint}: 403/0 endpoint not allowed")
                fake.calls.append((server, endpoint, copy.deepcopy(data)))
                if fake.fail.get(endpoint):
                    fake.fail[endpoint] -= 1
                    raise r.ApiError(f"{endpoint}: injected failure")
                return getattr(fake, endpoint.replace(".", "_"))(data)
        return Client()

    def mutations(self):
        reads = ("get_tenants", "get_tenant_admins", "company_info",
                 "get_provider_configurations", "download_saml_sp_metadata")
        return [c for c in self.calls if c[1].split(".")[1] not in reads]

    # tenants.* (Platform Management server)
    def tenants_get_tenants(self, _):
        return {"tenants": [{"id": i, "name": c["name"],
                             "default_company": c.get("default_company", False),
                             "admin_emails": []}
                            for i, c in self.companies.items()]}

    def tenants_create_tenant(self, data):
        if any(c["name"].lower() == data["name"].lower()
               for c in self.companies.values()):
            raise r.ApiError("tenants.create_tenant: 400/xx company with the "
                             "same name already exists")
        tid = self._id("company")
        defaults = {}
        if "max_users" in data:
            defaults["allowed_users"] = data["max_users"]
        if "max_service_users" in data:
            defaults["allowed_service_users"] = data["max_service_users"]
        self.companies[tid] = {"name": data["name"], "defaults": defaults}
        admin = {"id": self._id("user"), "credentials": []}
        self.admins[tid] = [admin]
        cred = self._mint(admin, "Default Credentials")
        return {"id": tid, "credentials": cred}

    def _mint(self, admin, label):
        if len(admin["credentials"]) >= 10:
            raise r.ApiError("CredentialsLimitExceeded")
        cred = {"access_key": self._id("AK"), "secret_key": self._id("SECRET-")}
        admin["credentials"].append(dict(cred, label=label))
        return cred

    def _admin(self, data):
        for a in self.admins[data["tenant"]]:
            if a["id"] == data["user"]:
                return a
        raise r.ApiError("InvalidUserId")

    def tenants_get_tenant_admins(self, data):
        if data["tenant"] not in self.companies:
            raise r.ApiError("InvalidId")
        return {"admins": [
            {"id": a["id"], "name": "admin",
             "credentials": [{"access_key": c["access_key"], "label": c["label"]}
                             for c in a["credentials"]]}
            for a in self.admins.get(data["tenant"], [])],
            "max_credentials": 10}

    def tenants_add_tenant_admin_credentials(self, data):
        admin = self._admin(data)
        return {"user": admin["id"],
                "credentials": self._mint(admin, data.get("label"))}

    def tenants_revoke_tenant_admin_credentials(self, data):
        admin = self._admin(data)
        keys = [c["access_key"] for c in admin["credentials"]]
        if data["access_key"] not in keys:
            raise r.ApiError("InvalidAccessKey")
        admin["credentials"] = [c for c in admin["credentials"]
                                if c["access_key"] != data["access_key"]]
        return {"revoked": 1}

    # system.* (apiserver)
    def system_company_info(self, data):
        c = self.companies[data["company"]]
        defaults = copy.deepcopy(c["defaults"])
        if "sso" in defaults:
            # the response model reports an unset builder_groups as []
            defaults["sso"].setdefault("builder_groups", [])
        return {"id": data["company"], "name": c["name"], "active": True,
                "defaults": defaults}

    def system_update_company_settings(self, data):
        d = self.companies[data["company"]]["defaults"]
        for k in ("allowed_users", "allowed_service_users"):
            if k in data:
                if data[k] is None:
                    d.pop(k, None)
                else:
                    d[k] = data[k]
        return {"updated": 1}

    def system_update_company_sso_config(self, data):
        if "debug" in data["sso"]:
            raise AssertionError("debug must never be sent")
        sso = copy.deepcopy(data["sso"])
        sso["debug"] = False
        self.companies[data["company"]]["defaults"]["sso"] = sso
        return {}

    # sso.* (apiserver)
    def sso_get_provider_configurations(self, data):
        return {"configurations": [
            {"id": i, "display_name": p["configuration"]["display_name"],
             "provider": p["provider"], "active": p["active"], "readonly": True}
            for i, p in self.providers.items() if p["company"] == data["company"]]}

    REQUIRED = {"oidc": ("id", "display_name", "client_id", "client_secret",
                         "authorization_endpoint", "token_endpoint"),
                "saml": ("id", "display_name", "idp_file")}

    def _check(self, data, skip=()):
        cat = "saml" if data["provider"] in r.SAML_PRESETS else "oidc"
        conf = data["configuration"]
        for k in self.REQUIRED[cat]:
            if k not in conf and k not in skip:
                raise r.ApiError(f"MissingConfigurationParameter {k}")
        for k, v in conf.items():
            if isinstance(v, (list, dict)):
                raise AssertionError(f"{k}: wizard values are flat, got {v!r}")
        return conf

    def sso_save_provider_configuration(self, data):
        conf = self._check(data)
        old = self.providers.get(conf["id"])
        if old and old["company"] != data["company"]:
            raise r.ApiError("InvalidId: defined under another company")
        self.providers[conf["id"]] = {"company": data["company"],
                                      "provider": data["provider"],
                                      "configuration": copy.deepcopy(conf),
                                      "active": True}

    def sso_set_provider_configurations_active(self, data):
        n = 0
        for i in data["ids"]:
            p = self.providers.get(i)
            if p and p["company"] == data["company"]:
                p["active"] = data["active"]
                n += 1
        return {"updated": n}

    def sso_download_saml_sp_metadata(self, data):
        conf = self._check(data, skip=("idp_file",))
        if not conf.get("callback"):
            raise r.ApiError("Reply url field is required")
        return (f'<EntityDescriptor entityID="{conf.get("entity_id", "clearml")}">'
                f'<ACS Location="{conf["callback"]}"/></EntityDescriptor>')

    # helpers for tests
    def tenant_id(self, name=TENANT):
        return next(i for i, c in self.companies.items() if c["name"] == name)

    def creds(self, name=TENANT):
        return self.admins[self.tenant_id(name)][0]["credentials"]


class FakeKube:
    def __init__(self):
        self.secrets = {}  # (ns, name) -> {"data": {...}}
        self.fail_writes = 0
        self.writes = []

    def get_secret(self, ns, name):
        if name not in r.KEY_LABELS:
            raise AssertionError(f"Secret {name} read via the API")
        s = self.secrets.get((ns, name))
        return copy.deepcopy(s) if s else None

    def write_secret(self, ns, name, values):
        if self.fail_writes:
            self.fail_writes -= 1
            raise r.ReconcileError("injected Secret write failure")
        self.writes.append((ns, name))
        data = {k: b64(v) for k, v in values.items()}
        self.secrets.setdefault((ns, name), {"data": {}})["data"].update(data)

    def access_key(self, label, ns=TENANT):
        s = self.secrets.get((ns, label))
        return base64.b64decode(s["data"]["access_key"]).decode() if s else None


class World:
    """secrets_dir stands for the mounted Secret <tenant>-sso."""

    def __init__(self, secrets_dir, sso_secret=True, pm_pair=PM_PAIR,
                 api_pair=API_PAIR):
        self.pm_pair, self.api_pair = pm_pair, api_pair
        self.klique = FakeKlique()
        self.kube = FakeKube()
        self.secrets_dir = secrets_dir
        if sso_secret:
            os.makedirs(secrets_dir)
            self.put_secret("kc-client-secret", CLIENT_SECRET)
            self.put_secret("saml-private-key", PRIVATE_KEY)
        self.out = []

    @staticmethod
    def never_sleep(seconds):
        # wait_seconds=0 must never sleep; a wait that ignored its deadline
        # would otherwise spin here forever instead of failing.
        raise AssertionError("waited although wait_seconds=0")

    def put_secret(self, key, value):
        with open(os.path.join(self.secrets_dir, key), "w", newline="") as f:
            f.write(value)

    def run(self, doc=None, app_url="https://app.klique.example.com",
            plan_only=False, files=None, secrets=None):
        desired = load(doc or tenant_doc(), files)
        self.out = []
        actions = r.run(desired, self.klique.client("pm", self.pm_pair),
                        self.klique.client("api", self.api_pair), self.kube,
                        secrets or r.SecretFiles(self.secrets_dir, wait_seconds=0,
                                                 sleep=self.never_sleep),
                        app_url,
                        plan_only=plan_only, out=self.out.append)
        return [a.kind for a in actions]


# ---------------------------------------------------------------- Source ----

class SourceTest(unittest.TestCase):
    def test_valid_document_maps_to_wizard_fields(self):
        d = load(tenant_doc())
        self.assertEqual(d.tenant, TENANT)
        self.assertEqual(d.limits, {"max_users": 10})
        self.assertEqual(d.sso, {"tenant": TENANT, "admin_groups": ["klique-admins"],
                                 "group_mapping": {"idp-ml": "ml"}})
        kc, saml = d.providers
        self.assertEqual((kc.id, kc.category, kc.enabled), ("tenant-a-kc", "oidc", True))
        c = kc.configuration
        self.assertEqual(c["id"], "tenant-a-kc")
        self.assertEqual(c["client_secret"],
                         r.SecretRef("kc-client-secret", "sso.providers[0].clientSecret"))
        self.assertEqual(c["scopes"], "openid,profile,email")
        self.assertEqual(c["provider_params"], "prompt=login")
        self.assertEqual(c["custom_claims"], "dept,site")
        self.assertEqual(c["claim_tenant"], "tenant")
        self.assertIs(c["group_enabled"], True)
        self.assertIs(c["group_case_sensitive"], False)
        self.assertEqual(saml.configuration["idp_file"], IDP_XML)
        self.assertEqual(saml.configuration["entity_id"], "klique-tenant-a")
        self.assertIs(saml.configuration["group_enabled"], True)
        self.assertEqual(d.secret_keys(), ["kc-client-secret"])

    def test_builder_groups_kept_only_when_present(self):
        self.assertNotIn("builder_groups", load(tenant_doc()).sso)
        doc = tenant_doc()
        doc["sso"]["builderGroups"] = []
        self.assertEqual(load(doc).sso["builder_groups"], [])

    def test_unknown_fields_name_their_path(self):
        doc = tenant_doc(schema="x")
        doc["sso"]["debug"] = True
        doc["sso"]["providers"][0]["clientSecrett"] = "x"
        doc["sso"]["providers"][0]["claims"]["tennant"] = "x"
        doc["sso"]["providers"][1]["clientId"] = "x"  # OIDC field on SAML
        e = errors_of(doc)
        for path in ("tenant.json.schema", "sso.debug",
                     "sso.providers[0].clientSecrett",
                     "sso.providers[0].claims.tennant",
                     "sso.providers[1].clientId"):
            self.assertIn(f"{path}: unknown field", e)

    def test_plaintext_secrets_are_refused(self):
        doc = tenant_doc()
        doc["sso"]["providers"][0]["clientSecret"] = "hunter2"
        doc["sso"]["providers"][1]["privateKey"] = "-----BEGIN PRIVATE KEY-----"
        e = errors_of(doc)
        self.assertIn("sso.providers[0].clientSecret: plaintext secrets are not allowed", e)
        self.assertIn("sso.providers[1].privateKey: plaintext secrets are not allowed", e)
        self.assertNotIn("hunter2", e)

    def test_secret_reference_shape(self):
        for bad in ({"key": "a/b"}, {"key": "x", "name": "y"}, {"name": "x"}, 3):
            doc = tenant_doc()
            doc["sso"]["providers"][0]["clientSecret"] = bad
            self.assertIn("sso.providers[0].clientSecret: must be {", errors_of(doc))

    def test_claims_tenant_required(self):
        doc = tenant_doc()
        del doc["sso"]["providers"][0]["claims"]["tenant"]
        doc["sso"]["providers"][1]["claims"]["tenant"] = " "
        e = errors_of(doc)
        self.assertIn("sso.providers[0].claims.tenant: required", e)
        self.assertIn("sso.providers[1].claims.tenant: must be a non-empty string", e)
        doc = tenant_doc()
        del doc["sso"]["providers"][0]["claims"]
        self.assertIn("sso.providers[0].claims: required", errors_of(doc))

    def test_required_fields(self):
        e = errors_of({})
        self.assertIn("tenant.json.sso: required", e)
        e = errors_of({"sso": {"providers": []}})
        self.assertIn("sso.adminGroups: required", e)
        self.assertIn("sso.providers: must be a non-empty list", e)
        doc = tenant_doc()
        del doc["sso"]["providers"][0]["tokenEndpoint"]
        del doc["sso"]["providers"][1]["idpMetadataFile"]
        e = errors_of(doc)
        self.assertIn("sso.providers[0].tokenEndpoint: required", e)
        self.assertIn("sso.providers[1].idpMetadataFile: required", e)
        doc = tenant_doc()
        doc["sso"]["adminGroups"] = []
        self.assertIn("sso.adminGroups: must not be empty", errors_of(doc))

    def test_idp_metadata_file(self):
        self.assertIn("file 'idp-metadata.xml' not found", errors_of(tenant_doc(), files={}))
        self.assertIn("is not SAML metadata",
                      errors_of(tenant_doc(), files={"idp-metadata.xml": "<html/>"}))
        for name in ("../idp.xml", "/etc/passwd", "sub/idp.xml", ".hidden", "tenant.json"):
            doc = tenant_doc()
            doc["sso"]["providers"][1]["idpMetadataFile"] = name
            self.assertIn("must be the name of a file next to tenant.json", errors_of(doc))

    def test_ids_presets_and_names(self):
        doc = tenant_doc()
        doc["sso"]["providers"][0]["id"] = "Bad_ID"
        doc["sso"]["providers"][1]["preset"] = "ldap"
        e = errors_of(doc)
        self.assertIn("sso.providers[0].id: must be 1 to 40 lowercase", e)
        doc = tenant_doc()
        doc["sso"]["providers"][0]["id"] = "my-idp"  # a, a-b vs a-a, b: ambiguous
        self.assertIn("sso.providers[0].id: must be 1 to 40 lowercase letters or "
                      "digits (no '-'", errors_of(doc))
        doc["sso"]["providers"][0]["id"] = "x" * 41
        self.assertIn("sso.providers[0].id:", errors_of(doc))
        self.assertIn("sso.providers[1].preset: required, one of oidc,", e)
        doc = tenant_doc()
        doc["sso"]["providers"][1]["id"] = "kc"
        doc["sso"]["providers"][1]["displayName"] = "Keycloak"
        e = errors_of(doc)
        self.assertIn("duplicate id 'kc'", e)
        self.assertIn("duplicate displayName 'Keycloak'", e)
        self.assertIn("tenant: 'ab' must be a DNS label", errors_of(tenant_doc(), tenant="ab"))
        self.assertIn("must be a DNS label", errors_of(tenant_doc(), tenant="Tenant_A"))
        name50 = "t" + "a" * 48 + "z"
        self.assertEqual(load(tenant_doc(), tenant=name50).tenant, name50)
        e = errors_of(tenant_doc(), tenant=name50 + "x")
        self.assertIn(f"tenant: {name50 + 'x'!r} must be a DNS label of 3 to 50", e)
        self.assertIn("so <tenant>-orchestrator stays a valid label value", e)
        for bad in ("-abc", "abc-", "a.bc"):
            self.assertIn("must be a DNS label", errors_of(tenant_doc(), tenant=bad))
        self.assertEqual(load(tenant_doc(), tenant="abc").tenant, "abc")
        for name in ("klique", "flux-system", "default", "external-secrets",
                     "cert-manager", "traefik", "keycloak", "openbao",
                     "kube-system", "kube-public"):
            self.assertIn(f"tenant: {name!r} is reserved for the platform",
                          errors_of(tenant_doc(), tenant=name))
        self.assertEqual(load(tenant_doc(), tenant="klique-team").tenant, "klique-team")
        # no tenant (CI without --tenant): placeholder, no name check
        self.assertEqual(load(tenant_doc(), tenant=None).providers[0].id, "<tenant>-kc")

    def test_types(self):
        doc = tenant_doc(limits={"maxUsers": -1, "maxServiceUsers": True, "max": 1})
        p = doc["sso"]["providers"][0]
        p["enabled"] = "no"
        p["checkEmailVerified"] = 1
        p["codeChallenge"] = "sha256"
        p["scopes"] = ["openid,profile"]
        p["providerParams"] = {"a": "b=c"}
        p["groups"] = {"claimFormat": "dn"}
        doc["sso"]["groupMapping"] = {"a": 1}
        e = errors_of(doc)
        for msg in ("limits.maxUsers: must be an integer >= 0",
                    "limits.maxServiceUsers: must be an integer >= 0",
                    "limits.max: unknown field",
                    "sso.providers[0].enabled: must be true or false",
                    "sso.providers[0].checkEmailVerified: must be true or false",
                    "sso.providers[0].codeChallenge: must be one of None, Plain, S256",
                    "sso.providers[0].scopes: items must not contain a comma",
                    "sso.providers[0].providerParams: keys and values must not contain",
                    "sso.providers[0].groups.claimFormat: must be one of none, ldap-dn",
                    "sso.groupMapping: must map each IdP group"):
            self.assertIn(msg, e)

    def test_server_dependency_rules(self):
        doc = tenant_doc()
        p = doc["sso"]["providers"][0]
        p.update(logoutFromProvider=True, getUserinfoFromIdToken=False,
                 verifyTokenSignature=True)
        doc["sso"]["providers"][1]["signedRequest"] = True
        e = errors_of(doc)
        self.assertIn("sso.providers[0].endSessionEndpoint: required when", e)
        self.assertIn("sso.providers[0].userinfoEndpoint: required when", e)
        self.assertIn("sso.providers[0].jwksUri: required when", e)
        self.assertIn("sso.providers[1].signedRequest: needs both publicKey and privateKey", e)

    def test_invalid_json(self):
        with assertRaises(r.ValidationError) as cm:
            r.load_source("{", files_reader({}), TENANT)
        self.assertIn("not valid JSON", cm.exception.errors[0])


class CliTest(unittest.TestCase):
    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = r.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_validate(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "tenant.json")
            with open(path, "w") as f:
                json.dump(tenant_doc(), f)
            code, _, err = self.run_cli("--validate", path)
            self.assertEqual(code, 1)
            self.assertIn("idpMetadataFile: file 'idp-metadata.xml' not found", err)
            with open(os.path.join(d, "idp-metadata.xml"), "w") as f:
                f.write(IDP_XML)
            code, out, _ = self.run_cli("--validate", path, "--tenant", TENANT)
            self.assertEqual((code, out.strip()), (0, f"{path}: OK"))
            code, _, err = self.run_cli("--validate", os.path.join(d, "nope", "tenant.json"))
            self.assertEqual(code, 1)
            self.assertIn("cannot read", err)

    def with_env(self, env, fn):
        old = os.environ
        os.environ = env
        try:
            return fn()
        finally:
            os.environ = old

    def test_job_mode_needs_env(self):
        env = {k: v for k, v in os.environ.items()
               if k not in ("TENANT", "PM_KEY", "PM_SECRET", "API_KEY", "API_SECRET")}
        code, _, err = self.with_env(env, self.run_cli)
        self.assertEqual(code, 2)
        self.assertIn("missing environment: TENANT, PM_KEY, PM_SECRET, "
                      "API_KEY, API_SECRET", err)

    def test_job_mode_wires_each_pair_to_its_server(self):
        made, ran = [], {}

        class Api:
            def __init__(self, url, key, secret, timeout=60):
                made.append((url, key, secret))

        def fake_run(desired, pm, api, kube, secrets, app_url, plan_only=False):
            ran.update(tenant=desired.tenant, dir=secrets.directory,
                       wait=secrets.wait_seconds, app_url=app_url)

        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "tenant.json"), "w") as f:
                json.dump(tenant_doc(), f)
            with open(os.path.join(d, "idp-metadata.xml"), "w") as f:
                f.write(IDP_XML)
            env = {"TENANT": TENANT, "CONFIG_DIR": d, "SECRETS_DIR": "/s",
                   "SECRETS_WAIT_SECONDS": "7", "PM_URL": "http://pm",
                   "API_URL": "http://api", "PM_KEY": PM_PAIR[0],
                   "PM_SECRET": PM_PAIR[1], "API_KEY": API_PAIR[0],
                   "API_SECRET": API_PAIR[1]}
            saved = (r.KliqueApi, r.KubeApi, r.run)
            r.KliqueApi, r.KubeApi, r.run = Api, lambda: None, fake_run
            try:
                code, _, err = self.with_env(env, self.run_cli)
                bad = self.with_env(dict(env, SECRETS_WAIT_SECONDS="-1"), self.run_cli)
            finally:
                r.KliqueApi, r.KubeApi, r.run = saved
        self.assertEqual(code, 0, err)
        self.assertEqual(made, [("http://pm", *PM_PAIR), ("http://api", *API_PAIR)])
        self.assertEqual(ran, {"tenant": TENANT, "dir": "/s", "wait": 7, "app_url": None})
        self.assertEqual(bad[0], 2)
        self.assertIn("SECRETS_WAIT_SECONDS", bad[2])

    def test_job_mode_defaults(self):
        ran = {}

        def fake_run(desired, pm, api, kube, secrets, app_url, plan_only=False):
            ran.update(dir=secrets.directory, wait=secrets.wait_seconds,
                       interval=secrets.interval)

        class Api:
            def __init__(self, url, key, secret, timeout=60):
                ran.setdefault("urls", []).append(url)

        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "tenant.json"), "w") as f:
                json.dump(tenant_doc(), f)
            with open(os.path.join(d, "idp-metadata.xml"), "w") as f:
                f.write(IDP_XML)
            env = {"TENANT": TENANT, "CONFIG_DIR": d, "PM_KEY": PM_PAIR[0],
                   "PM_SECRET": PM_PAIR[1], "API_KEY": API_PAIR[0],
                   "API_SECRET": API_PAIR[1]}
            saved = (r.KliqueApi, r.KubeApi, r.run)
            r.KliqueApi, r.KubeApi, r.run = Api, lambda: None, fake_run
            try:
                code, _, err = self.with_env(env, self.run_cli)
            finally:
                r.KliqueApi, r.KubeApi, r.run = saved
        self.assertEqual(code, 0, err)
        self.assertEqual((ran["dir"], ran["wait"], ran["interval"]),
                         ("/tenant-secrets", 300, 10))
        self.assertEqual(ran["urls"], [
            "http://klique-control-plane-platform-management-server.klique.svc:5210",
            "http://klique-control-plane-apiserver.klique.svc:8008"])

    def test_no_env_but_tenant_starts_with_tenant(self):
        with open(SCRIPT, encoding="utf-8") as f:
            names = set(re.findall(r'env(?:\.get\(|\[)"([A-Z_]+)"', f.read()))
        self.assertIn("CONFIG_DIR", names)
        self.assertEqual({n for n in names if n.startswith("TENANT")}, {"TENANT"})

    def test_script_has_no_flux_substitution_marker(self):
        with open(SCRIPT, encoding="utf-8") as f:
            self.assertNotIn("$" + "{", f.read())


# ---------------------------------------------------------------- Plan/Apply

class ReconcileTest(unittest.TestCase):
    def world(self, **kwargs):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return World(os.path.join(tmp.name, "tenant-secrets"), **kwargs)

    def test_create_from_scratch(self):
        w = self.world()
        kinds = w.run()
        self.assertEqual(kinds, ["CreateTenant", "RevokeKey", "MintKey", "MintKey",
                                 "SetCompanySso", "SaveProvider", "SaveProvider",
                                 "ReportProvider", "ReportProvider"])
        k = w.klique
        tid = k.tenant_id()
        self.assertEqual(k.companies[tid]["defaults"]["allowed_users"], 10)
        self.assertNotIn("allowed_service_users", k.companies[tid]["defaults"])
        creds = k.creds()
        self.assertEqual(sorted(c["label"] for c in creds), ["app-gateway", "orchestrator"])
        for label in r.KEY_LABELS:
            cred = next(c for c in creds if c["label"] == label)
            s = w.kube.secrets[(TENANT, label)]["data"]
            self.assertEqual(base64.b64decode(s["access_key"]).decode(), cred["access_key"])
            self.assertEqual(base64.b64decode(s["secret_key"]).decode(), cred["secret_key"])
        sso = k.companies[tid]["defaults"]["sso"]
        self.assertEqual(sso["tenant"], TENANT)
        self.assertNotIn("builder_groups", sso)
        kc = k.providers["tenant-a-kc"]
        self.assertEqual((kc["company"], kc["provider"]), (tid, "keycloak"))
        self.assertEqual(kc["configuration"]["client_secret"], CLIENT_SECRET)
        self.assertEqual(k.providers["tenant-a-saml"]["configuration"]["idp_file"], IDP_XML)

    def test_second_run_changes_nothing_but_provider_saves(self):
        w = self.world()
        doc = tenant_doc()
        doc["sso"]["builderGroups"] = ["ml-builders"]
        w.run(doc)
        before = copy.deepcopy(w.klique.creds())
        w.klique.calls = []
        kinds = w.run(doc)
        self.assertEqual(kinds, ["SaveProvider", "SaveProvider",
                                 "ReportProvider", "ReportProvider"])
        self.assertEqual(w.klique.creds(), before)
        self.assertEqual([c[1] for c in w.klique.mutations()],
                         ["sso.save_provider_configuration"] * 2)
        self.assertFalse([line for line in w.out if line.startswith("hint:")])

    def test_second_run_without_builder_groups_resends_company_sso(self):
        # company_info cannot tell an unset builder_groups from [], so the
        # company settings are sent again; still no key is minted or revoked.
        w = self.world()
        w.run()
        before = copy.deepcopy(w.klique.creds())
        kinds = w.run()
        self.assertEqual(kinds, ["SetCompanySso", "SaveProvider", "SaveProvider",
                                 "ReportProvider", "ReportProvider"])
        self.assertEqual(w.klique.creds(), before)
        self.assertNotIn("builder_groups",
                         w.klique.companies[w.klique.tenant_id()]["defaults"]["sso"])

    def test_orphan_key_is_revoked_and_reminted(self):
        w = self.world()
        w.run()
        old = w.kube.access_key("orchestrator")
        gateway = w.kube.access_key("app-gateway")
        del w.kube.secrets[(TENANT, "orchestrator")]
        kinds = w.run()
        self.assertEqual(kinds[:2], ["RevokeKey", "MintKey"])
        self.assertIn("no Secret holds it", w.out[2])
        labels = [c for c in w.klique.creds() if c["label"] == "orchestrator"]
        self.assertEqual(len(labels), 1)
        self.assertNotEqual(labels[0]["access_key"], old)
        self.assertEqual(w.kube.access_key("orchestrator"), labels[0]["access_key"])
        self.assertEqual(w.kube.access_key("app-gateway"), gateway)

    def test_revoked_key_is_reminted(self):
        w = self.world()
        w.run()
        tid = w.klique.tenant_id()
        admin = w.klique.admins[tid][0]
        admin["credentials"] = [c for c in admin["credentials"]
                                if c["label"] != "app-gateway"]
        kinds = w.run()
        self.assertEqual(kinds[0], "MintKey")
        self.assertNotIn("RevokeKey", kinds)
        cred = next(c for c in w.klique.creds() if c["label"] == "app-gateway")
        self.assertEqual(w.kube.access_key("app-gateway"), cred["access_key"])

    def test_crash_between_mint_and_secret_write(self):
        w = self.world()
        w.kube.fail_writes = 1
        with self.assertRaises(r.ReconcileError):
            w.run()
        self.assertEqual(len([c for c in w.klique.creds() if c["label"] == "orchestrator"]), 1)
        kinds = w.run()
        self.assertEqual(kinds[:3], ["RevokeKey", "MintKey", "MintKey"])
        for label in r.KEY_LABELS:
            creds = [c for c in w.klique.creds() if c["label"] == label]
            self.assertEqual(len(creds), 1, label)
            self.assertEqual(w.kube.access_key(label), creds[0]["access_key"])

    def test_crash_after_create_adopts_and_leaves_default_key(self):
        w = self.world()
        w.klique.fail["tenants.revoke_tenant_admin_credentials"] = 1
        with self.assertRaises(r.ApiError):
            w.run()
        kinds = w.run()
        self.assertNotIn("CreateTenant", kinds)
        # The tenant now counts as adopted: its default key is left alone.
        self.assertEqual(kinds[:2], ["MintKey", "MintKey"])
        self.assertNotIn("RevokeKey", kinds)
        self.assertIn("adopted", w.out[0])
        self.assertEqual(w.out[1], "hint: tenant tenant-a has a 'Default Credentials' "
                                   "key; revoke it in the Platform Management Center "
                                   "if nothing uses it")
        self.assertEqual(sorted(c["label"] for c in w.klique.creds()),
                         ["Default Credentials", "app-gateway", "orchestrator"])
        self.assertEqual(len([c for c in w.klique.companies.values()
                              if c["name"] == TENANT]), 1)

    def test_adopts_hand_made_tenant(self):
        w = self.world()
        w.klique.tenants_create_tenant({"name": TENANT})
        tid = w.klique.tenant_id()
        w.klique._mint(w.klique.admins[tid][0], "a human's key")
        kinds = w.run()
        self.assertNotIn("CreateTenant", kinds)
        self.assertEqual(kinds[:3], ["SetLimits", "MintKey", "MintKey"])
        self.assertNotIn("RevokeKey", kinds)
        self.assertIn(f"tenant {TENANT} exists (id {tid}): adopted", w.out[0])
        hints = [line for line in w.out if line.startswith("hint:")]
        self.assertEqual(len(hints), 1)
        self.assertNotIn(w.klique.creds()[0]["access_key"], hints[0])
        mutated = [c for c in w.klique.calls if "revoke" in c[1]]
        self.assertEqual(mutated, [])
        self.assertEqual(sorted(c["label"] for c in w.klique.creds()),
                         ["Default Credentials", "a human's key", "app-gateway",
                          "orchestrator"])

    def test_name_clash_and_default_company_refused(self):
        w = self.world()
        w.klique.tenants_create_tenant({"name": "Tenant-A"})
        with self.assertRaisesRegex(r.ReconcileError, "case-insensitive"):
            w.run()
        w = self.world()
        w.klique.companies["default"]["name"] = TENANT
        with self.assertRaisesRegex(r.ReconcileError, "default company"):
            w.run()

    def test_limits(self):
        w = self.world()
        w.run()
        tid = w.klique.tenant_id()
        doc = tenant_doc(limits={"maxUsers": 10, "maxServiceUsers": 4})
        self.assertEqual(w.run(doc)[0], "SetLimits")
        self.assertIn("set limits allowed_service_users=4", w.out[2])
        self.assertEqual(w.klique.companies[tid]["defaults"]["allowed_service_users"], 4)
        # omitted limits are never sent, so the server keeps what it has
        w.klique.calls = []
        doc = tenant_doc()
        del doc["limits"]
        self.assertNotIn("SetLimits", w.run(doc))
        self.assertNotIn("system.update_company_settings",
                         [c[1] for c in w.klique.calls])
        d = w.klique.companies[tid]["defaults"]
        self.assertEqual((d["allowed_users"], d["allowed_service_users"]), (10, 4))

    def test_company_sso_changes(self):
        w = self.world()
        w.run()
        tid = w.klique.tenant_id()
        doc = tenant_doc()
        doc["sso"]["adminGroups"] = ["other-admins"]
        self.assertIn("SetCompanySso", w.run(doc))
        self.assertEqual(w.klique.companies[tid]["defaults"]["sso"]["admin_groups"],
                         ["other-admins"])
        doc["sso"]["builderGroups"] = []
        self.assertIn("SetCompanySso", w.run(doc))
        self.assertEqual(w.klique.companies[tid]["defaults"]["sso"]["builder_groups"], [])
        # [] read back is ambiguous (unset reads as [] too): always resent
        self.assertIn("SetCompanySso", w.run(doc))
        doc["sso"]["builderGroups"] = ["ml-builders"]
        self.assertIn("SetCompanySso", w.run(doc))
        self.assertNotIn("SetCompanySso", w.run(doc))
        del doc["sso"]["builderGroups"]
        self.assertIn("SetCompanySso", w.run(doc))
        self.assertNotIn("builder_groups", w.klique.companies[tid]["defaults"]["sso"])
        # an unset builder_groups on a server where it was [] is put back too
        w.klique.companies[tid]["defaults"]["sso"]["builder_groups"] = []
        self.assertIn("SetCompanySso", w.run(doc))
        self.assertNotIn("builder_groups", w.klique.companies[tid]["defaults"]["sso"])

    def test_disabled_provider_is_saved_then_deactivated(self):
        w = self.world()
        doc = tenant_doc()
        doc["sso"]["providers"][1]["enabled"] = False
        kinds = w.run(doc)
        self.assertLess(kinds.index("SaveProvider"), kinds.index("SetProviderActive"))
        self.assertFalse(w.klique.providers["tenant-a-saml"]["active"])
        self.assertTrue(w.klique.providers["tenant-a-kc"]["active"])
        w.run(doc)
        self.assertFalse(w.klique.providers["tenant-a-saml"]["active"])
        doc["sso"]["providers"][1]["enabled"] = True
        self.assertNotIn("SetProviderActive", w.run(doc))
        self.assertTrue(w.klique.providers["tenant-a-saml"]["active"])

    def test_provider_dropped_from_file_is_left_alone(self):
        w = self.world()
        w.run()
        doc = tenant_doc()
        doc["sso"]["providers"] = doc["sso"]["providers"][:1]
        w.klique.calls = []
        w.run(doc)
        self.assertIn("tenant-a-saml", w.klique.providers)
        self.assertTrue(w.klique.providers["tenant-a-saml"]["active"])
        self.assertNotIn("tenant-a-saml", json.dumps(w.klique.mutations()))

    def assert_fails_unchanged(self, w, pattern):
        with self.assertRaisesRegex(r.ReconcileError, pattern) as cm:
            w.run()
        self.assertEqual(w.klique.mutations(), [])
        self.assertEqual(w.kube.writes, [])
        self.assertNotIn(CLIENT_SECRET, str(cm.exception))
        self.assertNotIn(PRIVATE_KEY, str(cm.exception))
        return str(cm.exception)

    def test_secrets_dir_not_mounted_fails_before_any_change(self):
        w = self.world(sso_secret=False)
        msg = self.assert_fails_unchanged(
            w, r"sso\.providers\[0\]\.clientSecret: secret key 'kc-client-secret' "
               r"not found in .*tenant-secrets")
        self.assertIn("Secret tenant-a-sso in klique", msg)
        self.assertIn("klique/tenants/tenant-a/sso", msg)

    def test_missing_secret_file_fails_before_any_change(self):
        w = self.world()
        os.remove(os.path.join(w.secrets_dir, "kc-client-secret"))
        self.assert_fails_unchanged(
            w, r"sso\.providers\[0\]\.clientSecret: secret key 'kc-client-secret' not found")

    def test_unreadable_secret_file_fails_before_any_change(self):
        # a directory where the key's file should be: unreadable even as root
        w = self.world()
        os.remove(os.path.join(w.secrets_dir, "kc-client-secret"))
        os.mkdir(os.path.join(w.secrets_dir, "kc-client-secret"))
        self.assert_fails_unchanged(
            w, r"sso\.providers\[0\]\.clientSecret: secret key 'kc-client-secret' "
               r"unreadable in")

    def test_no_secret_references_need_no_mount(self):
        w = self.world(sso_secret=False)
        doc = tenant_doc()
        doc["sso"]["providers"] = doc["sso"]["providers"][1:]  # SAML only
        self.assertIn("SaveProvider", w.run(doc))

    def test_secret_file_content_is_sent_exactly(self):
        w = self.world()
        w.put_secret("kc-client-secret", "value with trailing newline\n")
        w.run()
        self.assertEqual(
            w.klique.providers["tenant-a-kc"]["configuration"]["client_secret"],
            "value with trailing newline\n")

    def test_secret_keys_cannot_leave_the_directory(self):
        files = r.SecretFiles("/tenant-secrets")
        for key in ("../x", "a/b", "..", ""):
            with self.assertRaises(r.ReconcileError):
                files.read(key)

    def test_no_secret_reaches_the_log(self):
        w = self.world()
        doc = tenant_doc()
        doc["sso"]["providers"][1].update(signedRequest=True, publicKey="CERT",
                                         privateKey={"key": "saml-private-key"})
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            w.run(doc)
        log = "\n".join(w.out) + out.getvalue() + err.getvalue()
        for value in (CLIENT_SECRET, PRIVATE_KEY, PM_PAIR[1], API_PAIR[1]):
            self.assertNotIn(value, log)
        self.assertNotIn("SECRET-", log)  # every minted secret_key starts so
        self.assertEqual(w.klique.providers["tenant-a-saml"]["configuration"]["private_key"],
                         PRIVATE_KEY)

    def test_server_error_echoing_a_secret_is_scrubbed(self):
        w = self.world()
        k = w.klique
        original = k.sso_save_provider_configuration

        def echo(data):
            raise r.ApiError("sso.save_provider_configuration: 400/1 bad value "
                             + json.dumps(data["configuration"]))
        k.sso_save_provider_configuration = echo
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with self.assertRaises(r.ApiError) as cm:
                w.run()
        self.assertIn("<redacted>", str(cm.exception))
        text = str(cm.exception) + "\n".join(w.out) + out.getvalue() + err.getvalue()
        self.assertNotIn(CLIENT_SECRET, text)
        minted = [s["data"]["secret_key"] for s in w.kube.secrets.values()]
        for value in minted:
            self.assertNotIn(base64.b64decode(value).decode(), text)
        k.sso_save_provider_configuration = original

    def test_secret_write_error_echoing_the_minted_key_is_scrubbed(self):
        w = self.world()
        written = []

        def failing_write(ns, name, values):
            written.append(values["secret_key"])
            raise r.ReconcileError(f"write Secret {ns}/{name}: 422 Invalid value: "
                                   f"{values['secret_key']}")
        w.kube.write_secret = failing_write
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with self.assertRaises(r.ReconcileError) as cm:
                w.run()
        self.assertTrue(written)
        self.assertIn("422 Invalid value: <redacted>", str(cm.exception))
        text = str(cm.exception) + "\n".join(w.out) + out.getvalue() + err.getvalue()
        self.assertNotIn(written[0], text)

    def test_api_client_never_shows_the_response_body(self):
        import urllib.error
        import urllib.request
        api = r.KliqueApi("http://api", *API_PAIR)
        # A marker no test registers as a secret: only "never show the body"
        # keeps it out, not the scrubber.
        bodies = [b"<html>proxy error: body-only-marker-7f3a</html>",
                  json.dumps({"meta": {"result_code": 400, "result_subcode": 2,
                                       "result_msg": "x" * 1000}}).encode()]
        msgs = []
        saved = urllib.request.urlopen
        try:
            for body in bodies:
                def fail(req, timeout=None, body=body):
                    raise urllib.error.HTTPError(req.full_url, 502, "Bad", {},
                                                 io.BytesIO(body))
                urllib.request.urlopen = fail
                with self.assertRaises(r.ApiError) as cm:
                    api.call("sso.save_provider_configuration", {})
                msg = str(cm.exception)
                msgs.append(msg)
                self.assertNotIn("body-only-marker-7f3a", msg)
                self.assertLess(len(msg), 400)
        finally:
            urllib.request.urlopen = saved
        self.assertEqual(msgs[0], "sso.save_provider_configuration: HTTP 502")
        self.assertEqual(msgs[1][:42], "sso.save_provider_configuration: 400/2 xxx")

    def test_pm_pair_on_the_apiserver_is_refused(self):
        w = self.world(api_pair=PM_PAIR)
        with self.assertRaisesRegex(r.ApiError, "system.company_info: 403"):
            w.klique.tenants_create_tenant({"name": TENANT})
            w.run()
        w = self.world(api_pair=PM_PAIR)
        with self.assertRaisesRegex(r.ApiError, "system.update_company_sso_config: 403"):
            w.run()
        w = self.world(pm_pair=API_PAIR)
        with self.assertRaisesRegex(r.ApiError, "tenants.get_tenants: 401"):
            w.run()

    def test_waits_for_secret_files_then_proceeds(self):
        w = self.world()
        os.remove(os.path.join(w.secrets_dir, "kc-client-secret"))
        now = [0.0]
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            now[0] += seconds
            if now[0] >= 30:  # the ExternalSecret syncs after 30 s
                w.put_secret("kc-client-secret", CLIENT_SECRET)
        secrets = r.SecretFiles(w.secrets_dir, wait_seconds=300, interval=10,
                                sleep=sleep, clock=lambda: now[0])
        kinds = w.run(secrets=secrets)
        self.assertEqual(kinds[0], "CreateTenant")
        self.assertEqual(sleeps, [10, 10, 10])
        waiting = [l for l in w.out if l.startswith("waiting")]
        self.assertEqual(waiting, ["waiting up to 300 s for secret keys kc-client-secret "
                                   f"in {w.secrets_dir} (Secret tenant-a-sso in klique, "
                                   "not synced yet?)"])

    def test_wait_is_bounded_then_fails_before_any_change(self):
        w = self.world()
        os.remove(os.path.join(w.secrets_dir, "kc-client-secret"))
        now = [0.0]
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            if len(sleeps) > 10:  # the deadline is ignored: fail, never hang
                raise AssertionError("wait does not stop at its deadline")
            now[0] += seconds
        secrets = r.SecretFiles(w.secrets_dir, wait_seconds=25, interval=10,
                                sleep=sleep, clock=lambda: now[0])
        with self.assertRaisesRegex(r.ReconcileError, "clientSecret: secret key "
                                                      "'kc-client-secret' not found"):
            w.run(secrets=secrets)
        self.assertEqual(now[0], 25)
        self.assertEqual(sleeps, [10, 10, 5])
        self.assertEqual(w.klique.mutations(), [])
        self.assertEqual(w.kube.writes, [])

    def test_report_with_and_without_app_url(self):
        w = self.world()
        w.run()
        log = "\n".join(w.out)
        self.assertIn("login URL:       https://app.klique.example.com/login/tenant-a", log)
        self.assertIn("callback URL:    https://app.klique.example.com/callback_klique", log)
        self.assertIn("callback URL:    https://app.klique.example.com/callback_saml", log)
        self.assertIn('<ACS Location="https://app.klique.example.com/callback_saml"/>', log)
        w.klique.calls = []
        w.run(app_url=None)
        log = "\n".join(w.out)
        self.assertIn("callback URL:    <app-url>/callback_klique", log)
        self.assertIn("SP metadata:     skipped (APP_URL is not set)", log)
        self.assertNotIn("sso.download_saml_sp_metadata", [c[1] for c in w.klique.calls])

    def test_report_post_logout_uri(self):
        # The server sends <app>/login/<tenant> as post_logout_redirect_uri;
        # the IdP must have it registered.
        doc = tenant_doc()
        doc["sso"]["providers"][0].update(
            logoutFromProvider=True,
            endSessionEndpoint="https://idp.example.com/logout")
        w = self.world()
        w.run(doc)
        log = "\n".join(w.out)
        line = "post-logout URI: https://app.klique.example.com/login/tenant-a"
        self.assertEqual(log.count("post-logout URI:"), 1)
        self.assertIn(line, log)
        w.run(doc, app_url=None)
        self.assertIn("post-logout URI: <app-url>/login/tenant-a", "\n".join(w.out))
        w = self.world()
        w.run()
        self.assertNotIn("post-logout URI:", "\n".join(w.out))

    def test_plan_only_changes_nothing(self):
        w = self.world()
        kinds = w.run(plan_only=True)
        self.assertEqual(kinds[0], "CreateTenant")
        self.assertEqual(w.klique.mutations(), [])
        self.assertEqual(w.kube.writes, [])
        self.assertTrue(w.out[0].startswith("plan for tenant tenant-a"))


if __name__ == "__main__":
    unittest.main()
