#!/usr/bin/env bash
# Runs every static check for this repo. Install the tools first: scripts/install-tools.sh.
# Runs all checks even when one fails, so a single run shows everything to fix.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo" || exit 1

# Pinned so schema results do not drift with the catalog's main branch.
CRDS_CATALOG_SHA=6ab3493622cd387923a2d0da5234f53e80e1bd28
schemas="https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRDS_CATALOG_SHA/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

passed=()
failed=()

run() { # <name> <command...>
  local name="$1"
  shift
  echo "=== $name"
  if "$@"; then
    passed+=("$name")
  else
    failed+=("$name")
    echo "--- FAILED: $name"
  fi
}

# `terraform init` rewrites the tracked lockfile and leaves .terraform/, so validate a copy.
# -lockfile=readonly makes init fail when the lockfile lacks this platform's hash, instead of
# silently repairing it, so a lockfile regression is caught.
tf_validate() {
  local d="$tmp/tf"
  cp -r klique-terraform "$d" &&
    terraform -chdir="$d" init -backend=false -input=false -lockfile=readonly >/dev/null &&
    terraform -chdir="$d" validate
}

# The root klique-fluxcd/ cannot build in a fresh clone (flux-system/ appears only after bootstrap).
kubeconform_render() { # <dir>
  kubectl kustomize "$1" |
    kubeconform -strict -summary -schema-location default -schema-location "$schemas"
}

run "terraform fmt" terraform -chdir=klique-terraform fmt -check -recursive
run "terraform validate" tf_validate
run "tflint" tflint --chdir=klique-terraform
run "kustomize+kubeconform klique" kubeconform_render klique-fluxcd/klique
run "kustomize+kubeconform kustomizations" kubeconform_render klique-fluxcd/kustomizations
# `flux build` rewrites the kustomization.yaml it builds IN PLACE and restores it afterwards (and
# writes a generated one where none exists): two runs on one tree at once can leave the rewritten
# file behind. So every flux build runs on a copy, under the same relative paths.
src="$tmp/src"
mkdir -p "$src/tests/kind-e2e" &&
  cp -r klique-fluxcd "$src/" && cp -r tests/kind-e2e/tenants "$src/tests/kind-e2e/" &&
  cp -r tests/kind-e2e/flux "$src/tests/kind-e2e/"

# Stdout is the full rendered manifest set; only errors matter here.
flux_build() {
  (cd "$src" && flux build kustomization klique --path ./klique-fluxcd/klique \
    --kustomization-file klique-fluxcd/kustomizations/klique.yaml --dry-run >/dev/null)
}

run "flux build" flux_build

# --- Tenants ------------------------------------------------------------------------------------
# Two tenant trees, each reconciled by its own Flux Kustomization:
#   klique-fluxcd/tenants/    by klique-fluxcd/kustomizations/tenants.yaml (the example)
#   tests/kind-e2e/tenants/   by tests/kind-e2e/flux/e2e-tenants.yaml (the e2e harness only)
reconciler=klique-fluxcd/tenant-reconciler
tenant_sets=( # <dir>:<Flux Kustomization name>:<its file>:<substitution vars beyond klique-platform-vars>
  "klique-fluxcd/tenants:tenants:klique-fluxcd/kustomizations/tenants.yaml:"
  "tests/kind-e2e/tenants:e2e-tenants:tests/kind-e2e/flux/e2e-tenants.yaml:KEYCLOAK_SAML_CERT_TENANT_E2E"
)
# The klique-platform-vars keys, as klique-fluxcd/klique-platform.example.yaml documents them; the
# check below also requires klique-terraform to write the same set.
platform_vars_example=klique-fluxcd/klique-platform.example.yaml
platform_vars_tf=klique-terraform/platform-handoff.tf

# A tenants dir has no kustomization.yaml, so Flux generates one: every subfolder holding a
# kustomization.yaml is included, and so is any .yaml it finds elsewhere, applied raw.
tenants_layout() {
  local rc=0 set dir f d
  for set in "${tenant_sets[@]}"; do
    dir="${set%%:*}"
    for f in "$dir"/*.yaml "$dir"/*.yml "$dir/kustomization.yaml"; do
      [[ -e "$f" ]] || continue
      echo "$f: no manifests directly in ${dir}/ (Flux would apply it as is); use a tenant folder" >&2
      rc=1
    done
    for d in "$dir"/*/; do
      [[ -d "$d" ]] || continue
      for f in kustomization.yaml tenant.json; do
        [[ -f "$d$f" ]] || { echo "${d%/}: missing $f (every subfolder is a tenant)" >&2; rc=1; }
      done
    done
  done
  return "$rc"
}

# Python with PyYAML: the one yamllint runs on (scripts/install-tools.sh puts it in a venv).
yaml_python() {
  local yl
  # sed follows the symlink itself; readlink -f is missing on macOS before 12.3.
  yl="$(command -v yamllint)" && sed -n '1s/^#!//p' "$yl"
}

# Renders each tenant tree exactly as Flux will and checks the wiring replacements.yaml produces
# (a selector that matches too much or too little shows up here, not in the cluster). Then
# unpacks each tenant's mounted ConfigMap into $tmp/tenants/<tenant>/ — the files the Job sees
# under /tenant — for the validation below; $tmp/tenants/folders maps <tenant> to its folder.
tenants_render() {
  local py set dir name ks extra rc=0
  py="$(yaml_python)" || return 1
  mkdir -p "$tmp/tenants" && : >"$tmp/tenants/folders"
  for set in "${tenant_sets[@]}"; do
    IFS=: read -r dir name ks extra <<<"$set"
    echo "--- $dir"
    (cd "$src" && flux build kustomization "$name" -n klique --path "./$dir" \
      --kustomization-file "$ks" --dry-run) >"$tmp/$name.yaml" &&
      kubeconform -strict -summary -schema-location default -schema-location "$schemas" \
        "$tmp/$name.yaml" &&
      "$py" -I -B - "$tmp/$name.yaml" "$dir" "$tmp/tenants" "$platform_vars_example" \
        "$platform_vars_tf" "$extra" <<'EOF' || rc=1
import glob, os, re, sys, yaml

render, tenants_dir, out_dir, vars_example, vars_tf, extra_vars = sys.argv[1:7]
# Tenant name (the folder's namespace:) -> folder, so every message names the repo folder.
folders = {}
for k in sorted(glob.glob(os.path.join(tenants_dir, "*", "kustomization.yaml"))):
    folders[(yaml.safe_load(open(k)) or {}).get("namespace")] = os.path.dirname(k)
docs = [d for d in yaml.safe_load_all(open(render)) if d]
configmaps = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ConfigMap"}
tenants = {d["metadata"]["name"] for d in docs if d["kind"] == "Namespace"}
tenant_cms = {}  # tenant -> its <tenant>-config-<hash>, from its Job
rc = 0


def fail(tenant, msg):
    global rc
    print(f"{folders.get(tenant, tenants_dir)}: {msg}", file=sys.stderr)
    rc = 1


# A tenant's namespace: line must not take over a namespace the platform already uses.
RESERVED = {"klique", "flux-system", "default", "external-secrets", "cert-manager", "traefik",
            "keycloak", "openbao"}
for t in sorted(tenants):
    if t in RESERVED or t.startswith("kube-"):
        fail(t, f"namespace: {t} is reserved for the platform; pick another tenant name")

# Flux postBuild substitution runs envsubst over every rendered object, tenant files included,
# and the result is not what the file says unless the file uses only these forms:
#   ${VAR}, ${VAR:-default}, ${VAR:=default} (not ${VAR-default}: Flux fails on it)
#     with VAR a variable this Kustomization provides (klique-platform-vars, plus the e2e
#     harness's own); an unknown VAR silently becomes "" (Flux is not strict by default);
#   $${...} for a literal ${...}.
# Anything else after "${" either fails the whole reconcile (${{X}}, ${ X }) or is evaluated
# (${#X} is a length, ${X:0:2} a substring, ${X,,} lowercase), and a "$$" not followed by "{"
# becomes "$". (Semantics checked against fluxcd/pkg/envsubst v1.9.0.)
platform_vars = next(d for d in yaml.safe_load_all(open(vars_example))
                     if d and d["metadata"]["name"] == "klique-platform-vars")["data"]
tf_text = open(vars_tf).read()
for v in platform_vars:
    if not re.search(rf"^\s*{v}\s*=", tf_text, re.M):
        print(f"{vars_tf}: klique-platform-vars has no {v} (documented in {vars_example})",
              file=sys.stderr)
        rc = 1
allowed = set(platform_vars) | {v for v in extra_vars.split(",") if v}
VAR_EXPR = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)(?:(:[-=])([^${}\n]*))?\}")


def envsubst(text):
    """(text as Flux would substitute it with the example values, [problems])."""
    out, problems, i = [], [], 0
    while True:
        j = text.find("$", i)
        if j < 0:
            out.append(text[i:])
            return "".join(out), problems
        out.append(text[i:j])
        nxt = text[j + 1:j + 2]
        if nxt == "$":
            if text[j + 2:j + 3] != "{":
                problems.append(f"{text[j:j + 20]!r}: Flux turns $$ into $")
            out.append("$")
            i = j + 2
        elif nxt == "{":
            m = VAR_EXPR.match(text, j + 1)
            if not m:
                problems.append(f"{text[j:j + 20]!r}: not a plain ${{VAR}} (Flux would fail on it "
                                f"or evaluate it); write $${{ for a literal ${{")
                out.append("${")
                i = j + 2
                continue
            name, op, default = m.groups()
            if name not in allowed:
                problems.append(f"${{{name}}} is not a substitution variable here (allowed: "
                                f"{', '.join(sorted(allowed))}); Flux would make it \"\"")
            out.append(platform_vars.get(name) or (default if op else None) or "PLACEHOLDER")
            i = m.end()
        else:
            out.append("$")
            i = j + 1


# Every rendered object, as Flux sees it; a tenant's own files are reported by file.
for d in docs:
    meta = d["metadata"]
    if d["kind"] == "ConfigMap" and meta.get("namespace") == "klique" and "-config-" in meta["name"]:
        tenant = meta["name"].rsplit("-config-", 1)[0]
        for fname, content in (d.get("data") or {}).items():
            for problem in envsubst(content)[1]:
                fail(tenant, f"{fname}: {problem}")
        continue
    for problem in envsubst(yaml.safe_dump(d))[1]:
        fail(meta.get("namespace"), f"{d['kind']} {meta.get('namespace')}/{meta['name']}: {problem}")


# `flux build --dry-run` does not substitute, so the example values stand in for validation.
def substitute(text):
    return envsubst(text)[0]


# Every name derived from the tenant name must stay a valid label value (63 characters):
# helm-controller labels each release's objects with helm.toolkit.fluxcd.io/name=<HelmRelease>,
# and the longest HelmRelease name is <tenant>-orchestrator (13 more characters). The Job
# (<tenant>-reconcile) and the gateway host's first label (<tenant>) fit with room to spare.
MAX_TENANT = 63 - len("-orchestrator")
for t in sorted(tenants):
    if len(t) > MAX_TENANT:
        fail(t, f"tenant name {t!r} is {len(t)} characters; at most {MAX_TENANT}, so "
                f"{t}-orchestrator stays a valid label value")


# A tenant's own orchestrator-values.yaml / gateway-values.yaml may tune its releases, but not
# widen what they can reach or whose credentials they use.
FORBIDDEN = {
    "orchestratork8sglue.serviceAccountClusterAccess": "cluster-wide pod access",
    "orchestratork8sglue.additionalClusterRoleBindings": "cluster-wide RBAC",
    "sessions.portModeEnabled": "node ports shared by every tenant",
    "controlPlane.existingSecret": "another Secret's credentials",
    "controlPlane.existingSecretKeys": "another Secret's credentials",
    "controlPlane.existingOrchestratork8sglueSecret": "another Secret's credentials",
    "controlPlane.apiKey": "credentials in git",
    "controlPlane.apiSecret": "credentials in git",
    "imageCredentials": "pull credentials",
    "httpRoute": "a route on a host that is not the tenant's",
}


def flatten(node, prefix=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield f"{prefix}{k}"
            yield from flatten(v, f"{prefix}{k}.")


for d in docs:
    meta = d["metadata"]
    if d["kind"] == "ExternalSecret":
        # Every tenant's ExternalSecret is renamed to <tenant>-sso and moved to klique; one named
        # otherwise was not picked up by replacements.yaml (its name must be tenant-sso).
        tenant = meta["name"][:-len("-sso")] if meta["name"].endswith("-sso") else None
        where = f"ExternalSecret {meta.get('namespace')}/{meta['name']}"
        if (meta.get("namespace") != "klique" or tenant not in tenants
                or d["spec"].get("target", {}).get("name") != meta["name"]):
            fail(meta.get("namespace"), f"{where}: name it tenant-sso, with target.name tenant-sso")
            continue
        # dataFrom would pull whatever the backend path holds, unlisted; the explicit data list
        # is the pointer (and the only form replacements.yaml rewrites).
        if "dataFrom" in d["spec"]:
            fail(tenant, f"{where}: dataFrom is not supported; list each key under data:")
        # replacements.yaml rewrites path segment 2 only: a key of another shape silently gets
        # the tenant name in the wrong place.
        for item in d["spec"].get("data", []):
            key = item["remoteRef"]["key"]
            parts = key.split("/")
            if len(parts) < 4 or parts[2] != tenant:
                fail(tenant, f"{where}: remoteRef key {key!r} must look like "
                             f"<a>/<b>/<tenant>/<c> (e.g. klique/tenants/<tenant>/sso)")
    if d["kind"] == "Job":
        spec = d["spec"]["template"]["spec"]
        env = {e["name"]: e.get("value") for e in spec["containers"][0].get("env", [])}
        tenant = env.get("TENANT")
        vols = {v["name"]: v for v in spec.get("volumes", [])}
        cm_name = vols.get("tenant-config", {}).get("configMap", {}).get("name", "")
        want = {
            "Job": (f"{meta.get('namespace')}/{meta['name']}", f"klique/{tenant}-reconcile"),
            "env CONFIG_DIR": (env.get("CONFIG_DIR"), "/tenant"),
            "env SECRETS_DIR": (env.get("SECRETS_DIR"), "/tenant-secrets"),
            "secret volume": (vols.get("tenant-secrets", {}).get("secret", {}).get("secretName"),
                              f"{tenant}-sso"),
        }
        if tenant not in tenants:
            fail(meta.get("namespace"), f"Job {meta.get('namespace')}/{meta['name']}: env "
                 f"TENANT={tenant!r} is not a tenant namespace; a tenant folder holds no Job of "
                 f"its own (the component brings <tenant>-reconcile)")
            continue
        for what, (got, expected) in want.items():
            if got != expected:
                fail(tenant, f"Job {meta['name']}: {what} is {got!r}, expected {expected!r}")
        # replacements.yaml writes the tenant name into env TENANT; its selector would also hit
        # any other variable whose name starts with TENANT.
        for n in env:
            if n.startswith("TENANT") and n != "TENANT":
                fail(tenant, f"Job {meta['name']}: env {n}: no other variable may start with TENANT")
        if not cm_name.startswith(f"{tenant}-config-") or cm_name not in configmaps:
            fail(tenant, f"Job {meta['name']}: mounts ConfigMap {cm_name!r}, "
                         f"expected {tenant}-config-<hash>")
            continue
        out = os.path.join(out_dir, tenant)
        if os.path.exists(out):
            fail(tenant, f"tenant {tenant} is defined twice (also in another tenant tree)")
            continue
        os.makedirs(out)
        for fname, content in configmaps[cm_name]["data"].items():
            with open(os.path.join(out, fname), "w") as f:
                f.write(substitute(content))
        with open(os.path.join(out_dir, "folders"), "a") as f:
            f.write(f"{tenant}\t{folders.get(tenant, tenants_dir)}\n")
        for vf in ("orchestrator-values.yaml", "gateway-values.yaml"):
            if vf not in configmaps[cm_name]["data"]:
                continue
            values = yaml.safe_load(substitute(configmaps[cm_name]["data"][vf])) or {}
            for key in flatten(values):
                if key in FORBIDDEN:
                    fail(tenant, f"{vf}: {key} is not allowed in a tenant values file "
                                 f"({FORBIDDEN[key]}); set it in ../klique/values/ if every "
                                 f"tenant needs it")
        tenant_cms[tenant] = cm_name

# The tenant's orchestrator and gateway: names, namespaces, the values chain and the gateway's
# identity, exactly as replacements.yaml and valuesfrom-nameref.yaml should leave them.
releases = {(d["metadata"].get("namespace"), d["metadata"]["name"]): d
            for d in docs if d["kind"] == "HelmRelease"}
certs = {(d["metadata"].get("namespace"), d["metadata"]["name"]): d
         for d in docs if d["kind"] == "Certificate"}
host = "${KLIQUE_SESSIONS_HOST}"
for d in docs:
    if d["kind"] == "Namespace" and d["metadata"]["name"] in tenants:
        t = d["metadata"]["name"]
        if (d["metadata"].get("labels") or {}).get("klique.clearml.ai/tenant") != "true":
            fail(t, f"Namespace {t}: label klique.clearml.ai/tenant=true missing (pull secret)")
for t in sorted(tenants):
    for chart in ("orchestrator", "gateway"):
        hr = releases.pop(("klique", f"{t}-{chart}"), None)
        if hr is None:
            fail(t, f"HelmRelease klique/{t}-{chart} is missing")
            continue
        s = hr["spec"]
        vf = {v["valuesKey"]: v["name"] for v in s.get("valuesFrom", [])}
        want = {
            "releaseName": (s.get("releaseName"), f"klique-{chart}"),
            "targetNamespace": (s.get("targetNamespace"), t),
            "storageNamespace": (s.get("storageNamespace"), t),
            f"valuesFrom {chart}-values.yaml": (vf.get(f"{chart}-values.yaml"), tenant_cms.get(t)),
        }
        if chart == "gateway":
            v = s.get("values") or {}
            want.update({
                "values.ingress.hostName": ((v.get("ingress") or {}).get("hostName"), f"{t}.{host}"),
                "values.ingress.tlsSecretName": ((v.get("ingress") or {}).get("tlsSecretName"),
                                                 f"{t}-gateway-tls"),
                "values.externalURL": (v.get("externalURL"), ""),
                "values.streamSession.enabled": ((v.get("streamSession") or {}).get("enabled"),
                                                 False),
            })
        for what, (got, expected) in want.items():
            if got != expected:
                fail(t, f"HelmRelease klique/{t}-{chart}: {what} is {got!r}, expected {expected!r}")
    c = certs.pop((t, "gateway"), None)
    if c is None:
        fail(t, f"Certificate {t}/gateway is missing")
    elif (c["spec"].get("secretName"), c["spec"].get("dnsNames")) != (
            f"{t}-gateway-tls", [f"{t}.{host}", f"*.{t}.{host}"]):
        fail(t, f"Certificate {t}/gateway: secretName/dnsNames are "
                f"{c['spec'].get('secretName')!r}/{c['spec'].get('dnsNames')!r}")
for (ns, name) in sorted(releases):
    fail(ns, f"HelmRelease {ns}/{name}: not a tenant's <tenant>-orchestrator/-gateway "
             f"(a tenant folder adds no releases of its own)")
sys.exit(rc)
EOF
  done
  return "$rc"
}

# Flux substitution (postBuild) rewrites ${...} in everything a Kustomization renders, and the
# e2e harness's tenant Kustomization uses it: the script, mounted from that render, must not
# contain the sequence at all.
reconciler_no_substitution() {
  [[ -f "$reconciler/reconcile.py" ]] || { echo "$reconciler/reconcile.py is missing" >&2; return 1; }
  # shellcheck disable=SC2016 # the literal two characters are the pattern, not an expansion
  if grep -nF '${' "$reconciler/reconcile.py"; then
    echo "reconcile.py contains \${ — Flux postBuild substitution would rewrite it" >&2
    return 1
  fi
}

# The same validation the Job runs first, on each tenant's rendered files: a field it rejects
# fails here, before a commit, naming the tenant's folder and the field.
tenants_validate() {
  local tenant folder d out rep rc=0
  [[ -s "$tmp/tenants/folders" ]] || { echo "nothing rendered (see tenants render)" >&2; return 1; }
  while IFS=$'\t' read -r tenant folder; do
    d="$tmp/tenants/$tenant/"
    echo "--- $folder (tenant $tenant)"
    out="$(python3 -B "$reconciler/reconcile.py" --validate "${d}tenant.json" --tenant "$tenant" 2>&1)" ||
      rc=1
    rep="$folder/" # in a variable: bash <= 4.2 keeps quotes in a quoted replacement
    echo "${out//"$d"/$rep}"
  done <"$tmp/tenants/folders"
  return "$rc"
}

# -B: no __pycache__ left in the tree.
reconciler_tests() {
  python3 -B -m unittest discover -s "$reconciler/tests"
}

run "tenants layout" tenants_layout
run "tenants render+kubeconform" tenants_render
run "reconcile.py no \${" reconciler_no_substitution
run "tenants validate" tenants_validate
run "reconciler unit tests" reconciler_tests
run "yamllint" yamllint -s .

# -x follows the `# shellcheck source=` directives; -P SCRIPTDIR resolves them relative to each
# script instead of the current directory.
shellcheck_scripts() {
  command -v shellcheck >/dev/null || { echo "shellcheck is not installed; run scripts/install-tools.sh" >&2; return 1; }
  shellcheck -x -P SCRIPTDIR tests/kind-e2e/*.sh scripts/*.sh
}

run "shellcheck" shellcheck_scripts
# Without the config trivy silently falls back to built-in rules that skip tests/, so a missing
# file must fail rather than weaken the scan. .trivyignore.yaml holds the scoped, explained
# exceptions; a missing one is reported as missing rather than as findings to chase.
trivy_scan() {
  local f
  for f in trivy-secret.yaml .trivyignore.yaml; do
    if [[ ! -f "$f" ]]; then
      echo "$f is missing; refusing to scan without it" >&2
      return 1
    fi
  done
  trivy fs --scanners secret,misconfig --secret-config trivy-secret.yaml \
    --ignorefile .trivyignore.yaml --exit-code 1 .
}

run "trivy" trivy_scan

echo
echo "=== Summary"
# ${a[@]+...}: an empty array under set -u is an unbound variable in bash < 4.4 (macOS ships 3.2).
for n in ${passed[@]+"${passed[@]}"}; do echo "PASS  $n"; done
for n in ${failed[@]+"${failed[@]}"}; do echo "FAIL  $n"; done
[[ ${#failed[@]} -eq 0 ]]
