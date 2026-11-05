# shellcheck shell=bash
# Tenants and SSO for the kind e2e: Keycloak as every e2e tenant's own IdP,
# the e2e tenant folders (./tenants/), and the checks that log in through
# them. Sourced by e2e.sh after lib.sh, never run.
#
# The rules of lib.sh hold here too: guard() before every cluster mutation,
# and no secret value on a command line, in output, or in a kept file. The
# user passwords and OIDC client secrets are generated once per cluster and
# kept only in OpenBao (kv/kind-e2e/keycloak, kv/klique/tenants/<t>/sso).

# --- names shared with ./keycloak/ and ./tenants/ ------------------------------
# These must match the realm files and tenant.json files; the checks fail
# loudly, not silently, if they drift.
readonly KC_NS=keycloak
readonly E2E_TENANTS=(tenant-e2e tenant-e2e-b)
# The Klique provider ids: "<tenant>-<id from tenant.json>".
readonly PROV_A_OIDC=tenant-e2e-oidc PROV_A_SAML=tenant-e2e-saml PROV_B_OIDC=tenant-e2e-b-oidc
# The OIDC callback is <app>/callback_<client id>; SAML's is <app>/callback_saml.
readonly CLIENT_A_OIDC=klique-tenant-e2e CLIENT_B_OIDC=klique-tenant-e2e-b

T_TENANTS="${T_TENANTS:-30m}"
T_GATEWAY_SECONDS="${T_GATEWAY_SECONDS:-300}"
T_PULL_SECRET_SECONDS="${T_PULL_SECRET_SECONDS:-600}"

# --- OpenBao: the run's SSO secrets -------------------------------------------

# Generated once per cluster, then read back (a second `up` must not change
# them under a running Keycloak). Values go to OpenBao on stdin.
seed_sso_secrets() {
  seed_pmc_secrets
  if bao kv get -mount=kv kind-e2e/keycloak >/dev/null 2>&1; then
    info "SSO secrets already seeded"
    return
  fi
  local a b
  a="$(rand 24)" b="$(rand 24)"
  PA="$(rand 12)" PB="$(rand 12)" PC="$(rand 12)" SA="$a" SB="$b" jq -n '{
      pw_tenant_e2e_admin: env.PA, pw_tenant_e2e_builder: env.PB,
      pw_tenant_e2e_b_user: env.PC,
      oidc_secret_tenant_e2e: env.SA, oidc_secret_tenant_e2e_b: env.SB}' |
    bao kv put -mount=kv kind-e2e/keycloak - >/dev/null
  # What each tenant's `sso` ExternalSecret reads (key = tenant.json's
  # clientSecret.key). tenant-example's is a dummy: its IdP is a placeholder,
  # but the tenants Kustomization waits for every ExternalSecret.
  S="$a" jq -n '{oidcClientSecret: env.S}' | bao kv put -mount=kv klique/tenants/tenant-e2e/sso - >/dev/null
  S="$b" jq -n '{oidcClientSecret: env.S}' | bao kv put -mount=kv klique/tenants/tenant-e2e-b/sso - >/dev/null
  S="$(rand 12)" jq -n '{oidcClientSecret: env.S}' | bao kv put -mount=kv klique/tenants/tenant-example/sso - >/dev/null
  unset a b
  info "seeded kv/kind-e2e/keycloak and kv/klique/tenants/{tenant-example,tenant-e2e,tenant-e2e-b}/sso"
}

kc_secret() { bao kv get -mount=kv -field="$1" kind-e2e/keycloak; }

# The Platform Management Center's realm (klique-pmc): its admin's password and
# its OIDC client secret. A path of its own, seeded on its own, so a cluster
# seeded before the PMC existed gets them too.
seed_pmc_secrets() {
  if bao kv get -mount=kv kind-e2e/keycloak-pmc >/dev/null 2>&1; then
    return
  fi
  P="$(rand 12)" S="$(rand 24)" jq -n '{pw_pmc_admin: env.P, oidc_secret_pmc: env.S}' |
    bao kv put -mount=kv kind-e2e/keycloak-pmc - >/dev/null
  info "seeded kv/kind-e2e/keycloak-pmc"
}

pmc_secret() { bao kv get -mount=kv -field="$1" kind-e2e/keycloak-pmc; }

# What externalsecret-pmc-sso.yaml reads. Written once the domain is known
# (after Terraform). The browser-facing URLs are public; the token URL is
# in-cluster http, like the tenants' tokenEndpoint, so the Platform Management
# server never has to trust the private CA.
seed_pmc_sso_entry() { # <domain>
  local realm="https://keycloak.$1/realms/klique-pmc"
  S="$(pmc_secret oidc_secret_pmc)" B="$realm/" A="$realm/protocol/openid-connect/auth" \
    T="http://keycloak.$KC_NS.svc:8080/realms/klique-pmc/protocol/openid-connect/token" \
    jq -n '{clientId: "klique-pmc", clientSecret: env.S, baseUrl: env.B, authorizeUrl: env.A, tokenUrl: env.T}' |
    bao kv put -mount=kv klique/platform-management/sso - >/dev/null
  info "wrote kv/klique/platform-management/sso (realm klique-pmc)"
}

# --- Keycloak -----------------------------------------------------------------

# Prints the Keycloak realm signing certificate (one base64 line) from a SAML
# IdP descriptor on stdin.
saml_cert_from_descriptor() {
  grep -o '<ds:X509Certificate>[^<]*</ds:X509Certificate>' | head -1 |
    sed -e 's/<ds:X509Certificate>//' -e 's/<\/ds:X509Certificate>//' | tr -d ' \r\n'
}

setup_keycloak() {
  log "Keycloak (the e2e tenants' IdPs)"
  local domain kc ca="$W/klique-ca.pem" deadline cert
  domain="$(terraform -chdir="$W/src/klique-terraform" output -raw domain)"
  [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || die "unexpected domain from terraform output: '$domain'"
  terraform -chdir="$W/src/klique-terraform" output -raw ca_certificate_pem >"$ca"
  kc="https://keycloak.$domain"

  guard
  k create namespace "$KC_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  # The realms' ${E2E_*} placeholders, from OpenBao to the Secret on stdin.
  # Plain `create` (after a delete), not `apply`: apply would copy every value
  # into a last-applied annotation.
  k -n "$KC_NS" delete secret keycloak-env --ignore-not-found >/dev/null
  {
    printf 'E2E_DOMAIN=%s\n' "$domain"
    printf 'E2E_PW_TENANT_E2E_ADMIN=%s\n' "$(kc_secret pw_tenant_e2e_admin)"
    printf 'E2E_PW_TENANT_E2E_BUILDER=%s\n' "$(kc_secret pw_tenant_e2e_builder)"
    printf 'E2E_PW_TENANT_E2E_B_USER=%s\n' "$(kc_secret pw_tenant_e2e_b_user)"
    printf 'E2E_OIDC_SECRET_TENANT_E2E=%s\n' "$(kc_secret oidc_secret_tenant_e2e)"
    printf 'E2E_OIDC_SECRET_TENANT_E2E_B=%s\n' "$(kc_secret oidc_secret_tenant_e2e_b)"
    printf 'E2E_PW_PMC_ADMIN=%s\n' "$(pmc_secret pw_pmc_admin)"
    printf 'E2E_OIDC_SECRET_PMC=%s\n' "$(pmc_secret oidc_secret_pmc)"
  } | k -n "$KC_NS" create secret generic keycloak-env --from-env-file=/dev/stdin >/dev/null
  seed_pmc_sso_entry "$domain"
  k -n "$KC_NS" create configmap keycloak-realms \
    --from-file="$HERE/keycloak/realm-tenant-e2e.json" --from-file="$HERE/keycloak/realm-tenant-e2e-b.json" \
    --from-file="$HERE/keycloak/realm-klique-pmc.json" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  sed "s/__DOMAIN__/$domain/g" "$HERE/keycloak/keycloak.yaml" | k apply -f - >/dev/null
  k -n "$KC_NS" rollout status deploy/keycloak --timeout="$T_BASE"
  k -n "$KC_NS" wait --for=condition=Ready certificate/keycloak-tls --timeout="$T_BASE"

  # Through the ingress, as the browser side will use it.
  deadline=$((SECONDS + 300))
  until cert="$(curl -fsS --max-time 10 --cacert "$ca" "$kc/realms/tenant-e2e/protocol/saml/descriptor" 2>/dev/null |
    saml_cert_from_descriptor)" && [[ -n $cert ]]; do
    ((SECONDS < deadline)) || die "Keycloak did not answer at $kc/realms/tenant-e2e within 300s"
    sleep 5
  done
  [[ $cert =~ ^[A-Za-z0-9+/=]+$ ]] || die "unexpected SAML certificate in tenant-e2e's descriptor"
  info "$kc answers; tenant-e2e's SAML signing certificate read"

  # What Flux substitutes into ./tenants/ besides klique-platform-vars
  # (flux/e2e-tenants.yaml). Only the run-time Keycloak value: the domain and
  # every other cluster fact come from klique-platform-vars, as for real tenants.
  guard
  k -n klique create configmap kind-e2e-vars \
    --from-literal=KEYCLOAK_SAML_CERT_TENANT_E2E="$cert" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
}

apply_e2e_tenants() {
  log "Flux Kustomization e2e-tenants (./tests/kind-e2e/tenants)"
  guard
  k apply -f "$HERE/flux/e2e-tenants.yaml" >/dev/null
}

# --- login drivers (curl as the browser) --------------------------------------
#
# Every request goes through sso_curl: the minted CA, and one cookie jar per
# login (Keycloak's session cookies and Klique's login cookie), created mode
# 600 in $W and deleted when the login ends.

SSO_JAR=""
sso_curl() { curl -sS --max-time 30 --cacert "$W/klique-ca.pem" -b "$SSO_JAR" -c "$SSO_JAR" "$@"; }

# stdin -> application/x-www-form-urlencoded value.
urlencode() { jq -sRj @uri; }
urldecode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

# <url> -> JSON object of its query parameters, decoded.
query_json() {
  local q="${1#*\?}" kv parts
  [[ $1 == *\?* ]] || q=""
  q="${q%%#*}"
  IFS='&' read -ra parts <<<"$q"
  for kv in "${parts[@]}"; do
    [[ -n $kv ]] || continue
    if [[ $kv == *=* ]]; then
      printf '%s\t%s\n' "$(urldecode "${kv%%=*}")" "$(urldecode "${kv#*=}")"
    else
      printf '%s\t\n' "$(urldecode "$kv")"
    fi
  done | jq -Rn '[inputs | split("\t") | {(.[0]): (.[1:] | join("\t"))}] | add // {}'
}

# Keycloak's login page on stdin -> the URL its login form posts to.
kc_login_action() {
  grep -o '<form[^>]*id="kc-form-login"[^>]*>' | head -1 | grep -o 'action="[^"]*"' |
    sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g'
}

# Keycloak's login page on stdin -> its message to the user, if any ("Invalid
# username or password."), on one line.
kc_login_error() {
  tr -s '\n\r\t' '   ' | grep -o '<[^>]*kc-feedback-text[^>]*>[^<]*' | head -1 |
    sed -e 's/^[^>]*>//' -e 's/^ *//' -e 's/ *$//'
}

# An auto-submitting HTML form on stdin (Keycloak's SAML POST binding page) ->
# its action, or (with a name) the value of that hidden input.
html_form_action() {
  grep -io '<form[^>]*>' | head -1 | grep -io 'action="[^"]*"' | sed -e 's/^action="//I' -e 's/"$//' -e 's/&amp;/\&/g'
}
html_input_value() { # <name>
  grep -io "<input[^>]*name=\"$1\"[^>]*>" | head -1 | grep -io 'value="[^"]*"' | sed -e 's/^value="//I' -e 's/"$//'
}

# The body of a curl -w "$SSO_MARK..." response, and the trailer after it.
readonly SSO_MARK=$'\n__kind_e2e__'
sso_body() { printf '%s' "${1%"$SSO_MARK"*}"; }
sso_trailer() { printf '%s' "${1##*"$SSO_MARK"}"; }

# sso_login <provider id> <tenant> <callback name> <username> <password> [tenant to claim]
#
# A browser login, request by request: login.sso_authorize, Keycloak's login
# page, its form POST, then (SAML) the ACS POST through the webapp, then
# login.sso_callback. Prints the API response of the step that ended the login:
# sso_authorize's error, or sso_callback's result (which carries the session
# token: keep it in a variable). With a 6th argument the callback's state is
# rewritten to claim that tenant instead: what a user of one tenant's IdP
# would try against another tenant.
#
# With SSO_KEEP_JAR=<file> set it uses (and keeps) that jar instead.
#
# It runs in a subshell (the parentheses), so its EXIT trap removes the cookie
# jar however the login ends, die included, and never touches the caller's traps.
sso_login() (
  local provider=$1 tenant=$2 cb_name=$3 user=$4 pass=$5 claim=${6:-}
  local app="https://app.$KLIQUE_DOMAIN" resp redirect html action out code loc args cb acs saml relay
  if [[ -n ${SSO_KEEP_JAR:-} ]]; then
    # The caller owns this jar (and removes it): the logout check needs the
    # Keycloak session cookie after the login ends.
    SSO_JAR="$SSO_KEEP_JAR"
  else
    SSO_JAR="$(umask 077 && mktemp "$W/sso-cookies.XXXXXX")" || die "cannot create a cookie jar in $W"
    # shellcheck disable=SC2064 # the jar's path is fixed now
    trap "rm -f -- '$SSO_JAR'" EXIT
  fi
  cb="$app/callback_$cb_name"

  resp="$(P="$provider" T="$tenant" C="$app/callback_" jq -n \
    '{provider: env.P, tenant: env.T, callback_url_prefix: env.C, state: "kind-e2e"}' |
    sso_curl -X POST -H 'Content-Type: application/json' --data-binary @- "$app/api/login.sso_authorize")" ||
    die "login.sso_authorize: request failed"
  if ! redirect="$(jq -er '.data.redirect_url' <<<"$resp" 2>/dev/null)"; then
    printf '%s\n' "$resp"
    return 0
  fi

  html="$(sso_curl "$redirect")" || die "$provider: Keycloak's login page did not load"
  action="$(kc_login_action <<<"$html")"
  [[ -n $action ]] || die "$provider: no Keycloak login form (kc-form-login) at the authorize URL"

  # The credentials go to curl on stdin.
  out="$({
    printf 'username='
    printf '%s' "$user" | urlencode
    printf '&password='
    printf '%s' "$pass" | urlencode
    printf '&credentialId='
  } | sso_curl -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- \
    -w "${SSO_MARK}%{http_code} %{redirect_url}" "$action")" || die "$provider: Keycloak's login POST failed"
  code="$(sso_trailer "$out")"
  loc="${code#* }"
  code="${code%% *}"
  html="$(sso_body "$out")"

  if [[ $code == 30[0-9] ]]; then
    # OIDC: Keycloak redirects the browser to the callback with the code.
    [[ $loc == "$cb"\?* ]] || die "$provider: Keycloak redirected to an unexpected URL: ${loc%%\?*}"
    args="$(query_json "$loc")"
    if jq -e 'has("error")' <<<"$args" >/dev/null; then
      die "$provider: Keycloak returned error=$(jq -r '.error' <<<"$args")"
    fi
  elif saml="$(html_input_value SAMLResponse <<<"$html")" && [[ -n $saml ]]; then
    # SAML: Keycloak's page auto-posts the response to the ACS, which the
    # webapp's nginx hands to login.sso_callback_saml; that redirects to the
    # callback with a login_id.
    relay="$(html_input_value RelayState <<<"$html")"
    acs="$(html_form_action <<<"$html")"
    cb="$app/callback_saml"
    [[ $acs == "$cb" ]] || die "$provider: Keycloak posts the SAML response to an unexpected ACS: $acs"
    out="$({
      printf 'SAMLResponse='
      printf '%s' "$saml" | urlencode
      printf '&RelayState='
      printf '%s' "$relay" | urlencode
    } | sso_curl -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- \
      -o /dev/null -w '%{http_code} %{redirect_url}' "$acs")" || die "$provider: the SAML ACS POST failed"
    code="${out%% *}"
    loc="${out#* }"
    [[ $code == 30[0-9] && $loc == "$cb"\?* ]] ||
      die "$provider: the ACS answered HTTP $code instead of redirecting to $cb"
    args="$(query_json "$loc")"
  else
    die "$provider: Keycloak did not accept the login: $(kc_login_error <<<"$html" || true)"
  fi

  if [[ -n $claim ]]; then
    args="$(C="$claim" jq -c '.state |= (fromjson | .tenant = env.C | tojson)' <<<"$args")" ||
      die "$provider: the callback state is not the JSON login.sso_authorize sent"
  fi

  # The callback args (the OIDC code among them) reach curl on stdin.
  resp="$(A="$args" P="$cb_name" C="$cb" jq -n \
    '{provider: env.P, args: (env.A | fromjson), callback_url: env.C, return_token: true}' |
    sso_curl -X POST -H 'Content-Type: application/json' --data-binary @- "$app/api/login.sso_callback")" ||
    die "$provider: login.sso_callback: request failed"
  printf '%s\n' "$resp"
)

# An API response -> "<subcode>" of its error (0 when it succeeded).
api_subcode() { jq -r 'if .meta.result_code == 200 then 0 else (.meta.result_subcode // -1) end' 2>/dev/null || echo -1; }

# A session token -> "role<US>company id" of its user (users.get_current_user).
whoami_from_token() {
  local resp
  resp="$(printf 'header = "Authorization: Bearer %s"\n' "$1" |
    curl -sS --max-time 30 --cacert "$W/klique-ca.pem" --config - -H 'Content-Type: application/json' \
      -X POST --data-binary '{}' "https://app.$KLIQUE_DOMAIN/api/users.get_current_user")" || return 1
  jq -er '.data.user | "\(.role)\u001f\(.company | if type == "object" then .id else . end)"' <<<"$resp"
}

# One expected login: <label> <expect role|refuse:<subcode>> <tenant id> then sso_login's args.
expect_login() {
  local label=$1 expect=$2 tenant_id=$3 resp sub token who role company
  shift 3
  resp="$(sso_login "$@")"
  sub="$(api_subcode <<<"$resp")"
  if [[ $expect == refuse:* ]]; then
    [[ $sub != 0 ]] || die "$label: expected a refusal (subcode ${expect#refuse:}), but the login succeeded"
    [[ $sub == "${expect#refuse:}" ]] ||
      die "$label: expected refusal (subcode ${expect#refuse:}), got: $(api_reason <<<"$resp")"
    info "$label: refused as expected ($(api_reason <<<"$resp"))"
    return
  fi
  [[ $sub == 0 ]] || die "$label: login failed: $(api_reason <<<"$resp")"
  [[ $(jq -r '.data.login_status' <<<"$resp") == logged_in ]] ||
    die "$label: login_status is '$(jq -r '.data.login_status' <<<"$resp")', not logged_in"
  token="$(jq -er '.data.token' <<<"$resp")" || die "$label: no session token in the callback response"
  [[ $token =~ ^[A-Za-z0-9._-]+$ ]] || die "$label: unexpected characters in the session token (not shown)"
  who="$(whoami_from_token "$token")" || die "$label: users.get_current_user failed"
  unset token resp
  role="${who%%"$US"*}"
  company="${who#*"$US"}"
  [[ $company == "$tenant_id" ]] || die "$label: logged into company $company, not the tenant's ($tenant_id)"
  [[ $role == "$expect" ]] || die "$label: role '$role', expected '$expect'"
  info "$label: logged in, role $role"
}

# --- checks -------------------------------------------------------------------

# Basic auth on stdin, with one of klique-conf's two system pairs, which stay
# in shell variables:
#   PM_KEY/PM_SECRET   (platform_management_*): tenants.* on the Platform
#                      Management server, and nothing else on the apiserver;
#   SYS_KEY/SYS_SECRET (apiserver_*): the apiserver's own pair, for sso.*.
pm_call() { # <base url> <endpoint> <json body>
  basic_call "$PM_KEY" "$PM_SECRET" "$@"
}
sys_call() { # <base url> <endpoint> <json body>
  basic_call "$SYS_KEY" "$SYS_SECRET" "$@"
}
basic_call() { # <key> <secret> <base url> <endpoint> <json body>
  printf 'user = "%s:%s"\n' "$1" "$2" |
    curl -sS --max-time 30 --cacert "$W/klique-ca.pem" --config - -H 'Content-Type: application/json' \
      -X POST --data-binary "$5" "$3/$4"
}

# tenants.get_tenants on the Platform Management server, which has no
# ingress: through a port-forward that lives only for this one call.
pm_get_tenants() {
  local pf_pid resp rc=0 pm="http://127.0.0.1:15210"
  guard
  k -n klique port-forward svc/klique-control-plane-platform-management-server 15210:5210 >/dev/null 2>&1 &
  pf_pid=$!
  for _ in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 "$pm/" && break
    sleep 1
  done
  resp="$(pm_call "$pm" tenants.get_tenants '{}')" || rc=$?
  kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true
  ((rc == 0)) || die "tenants.get_tenants: request failed (port-forward to the Platform Management server)"
  printf '%s\n' "$resp"
}

tenants_check() {
  log "tenants and SSO (up to $T_TENANTS)"
  local t resp ids id_a id_b id_ex k1 k2

  k -n klique wait --for=condition=Ready kustomization/e2e-tenants --timeout="$T_TENANTS"

  PM_KEY="$(k -n klique get secret klique-conf -o jsonpath='{.data.platform_management_key}' | base64 -d)"
  PM_SECRET="$(k -n klique get secret klique-conf -o jsonpath='{.data.platform_management_secret}' | base64 -d)"
  [[ -n $PM_KEY && -n $PM_SECRET && $PM_KEY$PM_SECRET =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "klique-conf has no usable platform_management_key/secret"
  SYS_KEY="$(k -n klique get secret klique-conf -o jsonpath='{.data.apiserver_key}' | base64 -d)"
  SYS_SECRET="$(k -n klique get secret klique-conf -o jsonpath='{.data.apiserver_secret}' | base64 -d)"
  [[ -n $SYS_KEY && -n $SYS_SECRET && $SYS_KEY$SYS_SECRET =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "klique-conf has no usable apiserver_key/secret"

  resp="$(pm_get_tenants)" || exit 1
  [[ $(api_subcode <<<"$resp") == 0 ]] || die "tenants.get_tenants failed: $(api_reason <<<"$resp")"
  ids="$(jq -c '[.data.tenants[] | {(.name): .id}] | add // {}' <<<"$resp")"
  for t in tenant-example "${E2E_TENANTS[@]}"; do
    jq -e --arg t "$t" 'has($t)' <<<"$ids" >/dev/null || die "tenant $t not found by tenants.get_tenants"
  done
  id_ex="$(jq -r '."tenant-example"' <<<"$ids")"
  id_a="$(jq -r '."tenant-e2e"' <<<"$ids")"
  id_b="$(jq -r '."tenant-e2e-b"' <<<"$ids")"
  info "tenants: tenant-example ($id_ex), tenant-e2e ($id_a), tenant-e2e-b ($id_b)"

  for t in tenant-example "${E2E_TENANTS[@]}"; do
    for k1 in orchestrator app-gateway; do
      k -n "$t" get secret "$k1" -o json |
        jq -e '(.data.access_key // "") != "" and (.data.secret_key // "") != ""' >/dev/null ||
        die "$t: Secret $k1 is missing or lacks access_key/secret_key"
    done
  done
  info "Secrets orchestrator and app-gateway in every tenant namespace"

  for k2 in "$id_a:$PROV_A_OIDC $PROV_A_SAML" "$id_b:$PROV_B_OIDC"; do
    resp="$(sys_call "$API" sso.get_provider_configurations "$(C="${k2%%:*}" jq -n '{company: env.C}')")"
    [[ $(api_subcode <<<"$resp") == 0 ]] || die "sso.get_provider_configurations failed: $(api_reason <<<"$resp")"
    for t in ${k2#*:}; do
      jq -e --arg p "$t" '[.data.configurations[] | select(.id == $p and .active)] | length == 1' <<<"$resp" >/dev/null ||
        die "SSO provider $t not saved (or not active) for company ${k2%%:*}"
    done
  done
  unset PM_KEY PM_SECRET SYS_KEY SYS_SECRET
  info "SSO providers saved: $PROV_A_OIDC, $PROV_A_SAML, $PROV_B_OIDC"

  local pa pb pc
  pa="$(kc_secret pw_tenant_e2e_admin)" pb="$(kc_secret pw_tenant_e2e_builder)" pc="$(kc_secret pw_tenant_e2e_b_user)"
  expect_login "OIDC e2e-admin -> tenant-e2e" admin "$id_a" "$PROV_A_OIDC" tenant-e2e "$CLIENT_A_OIDC" e2e-admin "$pa"
  expect_login "OIDC e2e-builder -> tenant-e2e" user "$id_a" "$PROV_A_OIDC" tenant-e2e "$CLIENT_A_OIDC" e2e-builder "$pb"
  expect_login "SAML e2e-admin -> tenant-e2e" admin "$id_a" "$PROV_A_SAML" tenant-e2e saml e2e-admin "$pa"
  expect_login "SAML e2e-builder -> tenant-e2e" user "$id_a" "$PROV_A_SAML" tenant-e2e saml e2e-builder "$pb"
  expect_login "OIDC e2e-b-user -> tenant-e2e-b (control)" admin "$id_b" "$PROV_B_OIDC" tenant-e2e-b "$CLIENT_B_OIDC" e2e-b-user "$pc"
  # 92 = cannot_login_tenant, 51 = invalid_login_provider (apierrors/errors.conf).
  # The first proves the claim-vs-requested-tenant check for an honest IdP. It
  # is not isolation: any tenant's IdP admin could issue a tenant-e2e claim
  # (trust boundary: klique-fluxcd/tenants/README.md).
  expect_login "OIDC e2e-b-user claiming tenant-e2e" refuse:92 "$id_a" \
    "$PROV_B_OIDC" tenant-e2e-b "$CLIENT_B_OIDC" e2e-b-user "$pc" tenant-e2e
  expect_login "tenant-e2e-b's provider asked for tenant-e2e" refuse:51 "$id_a" \
    "$PROV_B_OIDC" tenant-e2e "$CLIENT_B_OIDC" e2e-b-user "$pc"

  logout_check "$pa" "$pc"
  gateway_check "$pa" "$pc"
  unset pa pb pc
}

# --- logout -------------------------------------------------------------------

# An HTML page on stdin -> its <title>, or its data-page-id: what a failure
# message may show of a Keycloak page (never its cookies or form values).
html_page_label() {
  tr -s '\n\r\t' '   ' | { grep -o '<title>[^<]*</title>\|data-page-id="[^"]*"' || true; } | head -2 | tr '\n' ' '
}

# A Keycloak form page on stdin -> its hidden inputs (session_code...) as a
# urlencoded body; the caller adds the submit button's own field. Generic, so a
# theme change in the logout page does not need a code change here.
html_hidden_form_body() {
  local tag name value out=""
  while IFS= read -r tag; do
    name="$(grep -io 'name="[^"]*"' <<<"$tag" | head -1 | sed -e 's/^name="//I' -e 's/"$//')"
    value="$(grep -io 'value="[^"]*"' <<<"$tag" | head -1 | sed -e 's/^value="//I' -e 's/"$//' -e 's/&amp;/\&/g')"
    [[ -n $name ]] || continue
    out+="${out:+&}$(printf '%s' "$name" | urlencode)=$(printf '%s' "$value" | urlencode)"
  done < <(grep -io '<input[^>]*type="hidden"[^>]*>')
  printf '%s' "$out"
}

# login.logout the way the webapp calls it: the origin's /login as redirect_url,
# no provider (the server takes it from the session token). The token goes on
# stdin, the jar carries the cookie.
api_logout() { # <token> -> the response
  printf 'header = "Authorization: Bearer %s"\n' "$1" |
    sso_curl --config - -H 'Content-Type: application/json' -X POST \
      --data-binary "$(U="https://app.$KLIQUE_DOMAIN/login" jq -n '{redirect_url: env.U}')" \
      "https://app.$KLIQUE_DOMAIN/api/login.logout"
}

# logout_check_oidc <label> <provider id> <tenant> <client id> <realm> <user> <password>
#
# Logging out of an OIDC tenant must end the IdP session and return to the
# tenant's own login page: log in (the jar keeps Keycloak's session), call
# login.logout, follow the URL it returns in the same jar, confirm the page
# Keycloak shows (the server sends no id_token_hint), and require that a fresh
# authorize then asks for credentials again. Subshell: the EXIT trap removes
# the jar however this ends.
logout_check_oidc() (
  local label=$1 provider=$2 tenant=$3 client=$4 realm=$5 user=$6 pass=$7
  local app="https://app.$KLIQUE_DOMAIN" kc="https://keycloak.$KLIQUE_DOMAIN"
  local want_post="$app/login/$tenant" resp token url args out code loc html action body
  SSO_JAR="$(umask 077 && mktemp "$W/sso-cookies.XXXXXX")" || die "cannot create a cookie jar in $W"
  # shellcheck disable=SC2064 # the jar's path is fixed now
  trap "rm -f -- '$SSO_JAR'" EXIT

  resp="$(SSO_KEEP_JAR="$SSO_JAR" sso_login "$provider" "$tenant" "$client" "$user" "$pass")"
  [[ $(api_subcode <<<"$resp") == 0 && $(jq -r '.data.login_status' <<<"$resp") == logged_in ]] ||
    die "$label: login failed: $(api_reason <<<"$resp")"
  token="$(jq -er '.data.token' <<<"$resp")" || die "$label: no session token"
  [[ $token =~ ^[A-Za-z0-9._-]+$ ]] || die "$label: unexpected characters in the session token (not shown)"

  resp="$(api_logout "$token")" || die "$label: login.logout: request failed"
  unset token
  [[ $(api_subcode <<<"$resp") == 0 ]] || die "$label: login.logout failed: $(api_reason <<<"$resp")"
  url="$(jq -r '.data.redirect_url // empty' <<<"$resp")"
  [[ -n $url ]] || die "$label: login.logout returned no redirect_url (logoutFromProvider/endSessionEndpoint not applied?)"
  [[ $url == "$kc/realms/$realm/protocol/openid-connect/logout?"* ]] ||
    die "$label: login.logout redirects to ${url%%\?*}, expected $kc/realms/$realm/protocol/openid-connect/logout"
  args="$(query_json "$url")"
  [[ $(jq -r '.client_id // ""' <<<"$args") == "$client" ]] ||
    die "$label: end-session client_id is '$(jq -r '.client_id // ""' <<<"$args")', expected $client"
  [[ $(jq -r '.post_logout_redirect_uri // ""' <<<"$args") == "$want_post" ]] ||
    die "$label: post_logout_redirect_uri is '$(jq -r '.post_logout_redirect_uri // ""' <<<"$args")', expected $want_post"
  info "$label: login.logout -> Keycloak end-session URL (client_id=$client, post_logout_redirect_uri=$want_post)"

  # With a live session and no id_token_hint Keycloak asks for confirmation.
  out="$(sso_curl -w "${SSO_MARK}%{http_code}" "$url")" || die "$label: the end-session request failed"
  code="$(sso_trailer "$out")"
  html="$(sso_body "$out")"
  action="$(html_form_action <<<"$html")"
  [[ $code == 200 && -n $action ]] ||
    die "$label: expected Keycloak's logout confirmation form, got HTTP $code: $(html_page_label <<<"$html")"
  [[ $action == http* ]] || action="$kc$action"
  body="$(html_hidden_form_body <<<"$html")"
  out="$(printf '%s&confirmLogout=Yes' "$body" |
    sso_curl -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- \
      -w "${SSO_MARK}%{http_code} %{redirect_url}" "$action")" || die "$label: the logout confirmation POST failed"
  code="$(sso_trailer "$out")"
  loc="${code#* }"
  code="${code%% *}"
  [[ $code == 30[0-9] && $loc == "$want_post" ]] ||
    die "$label: after confirming, Keycloak answered HTTP $code (Location: ${loc%%\?*}$([[ $loc == *\?* ]] && echo " plus a query, not shown")), expected a redirect to $want_post: $(sso_body "$out" | html_page_label)"
  info "$label: confirmed; Keycloak redirects to $want_post"

  # The IdP session is gone: a fresh authorize shows the login form, where a
  # live session would have redirected straight back with a code.
  resp="$(P="$provider" T="$tenant" C="$app/callback_" jq -n \
    '{provider: env.P, tenant: env.T, callback_url_prefix: env.C, state: "kind-e2e"}' |
    sso_curl -X POST -H 'Content-Type: application/json' --data-binary @- "$app/api/login.sso_authorize")" ||
    die "$label: login.sso_authorize: request failed"
  url="$(jq -er '.data.redirect_url' <<<"$resp")" || die "$label: login.sso_authorize failed: $(api_reason <<<"$resp")"
  out="$(sso_curl -w "${SSO_MARK}%{http_code}" "$url")" || die "$label: Keycloak's authorize request failed"
  code="$(sso_trailer "$out")"
  [[ -n "$(sso_body "$out" | kc_login_action)" ]] ||
    die "$label: after logout, authorize answered HTTP $code without a login form: the IdP session survived ($(sso_body "$out" | html_page_label))"
  info "$label: a fresh authorize shows Keycloak's login form again (IdP session ended)"
)

# logout_check_saml <label> <provider id> <tenant> <user> <password>
# SAML has no single logout here: login.logout ends only the Klique session and
# returns no redirect_url, so the webapp falls back to the generic /login.
logout_check_saml() (
  local label=$1 resp token
  SSO_JAR="$(umask 077 && mktemp "$W/sso-cookies.XXXXXX")" || die "cannot create a cookie jar in $W"
  # shellcheck disable=SC2064 # the jar's path is fixed now
  trap "rm -f -- '$SSO_JAR'" EXIT
  resp="$(SSO_KEEP_JAR="$SSO_JAR" sso_login "$2" "$3" saml "$4" "$5")"
  [[ $(api_subcode <<<"$resp") == 0 && $(jq -r '.data.login_status' <<<"$resp") == logged_in ]] ||
    die "$label: login failed: $(api_reason <<<"$resp")"
  token="$(jq -er '.data.token' <<<"$resp")" || die "$label: no session token"
  [[ $token =~ ^[A-Za-z0-9._-]+$ ]] || die "$label: unexpected characters in the session token (not shown)"
  resp="$(api_logout "$token")" || die "$label: login.logout: request failed"
  unset token
  [[ $(api_subcode <<<"$resp") == 0 ]] || die "$label: login.logout failed: $(api_reason <<<"$resp")"
  [[ -z $(jq -r '.data.redirect_url // empty' <<<"$resp") ]] ||
    die "$label: login.logout returned a redirect_url for SAML ($(jq -r '.data.redirect_url' <<<"$resp" | cut -d'?' -f1)); the documented limitation (no IdP logout) changed"
  info "$label: login.logout returns no redirect_url (SAML: the IdP session stays; documented limitation)"
)

logout_check() { # <tenant-e2e admin password> <tenant-e2e-b user password>
  log "logout from OIDC tenants (IdP session ends) and SAML (documented limitation)"
  logout_check_oidc "OIDC e2e-b-user logout (tenant-e2e-b)" "$PROV_B_OIDC" tenant-e2e-b "$CLIENT_B_OIDC" tenant-e2e-b e2e-b-user "$2"
  logout_check_oidc "OIDC e2e-admin logout (tenant-e2e)" "$PROV_A_OIDC" tenant-e2e "$CLIENT_A_OIDC" tenant-e2e e2e-admin "$1"
  logout_check_saml "SAML e2e-admin logout (tenant-e2e)" "$PROV_A_SAML" tenant-e2e e2e-admin "$1"
}

# --- per-tenant pull secret, admin token, gateway -----------------------------

# Every tenant namespace needs klique-dockerhub before its orchestrator and
# gateway can pull. How it gets there is klique-fluxcd's business; this only
# turns a missing one into a pointed message.
wait_tenant_pull_secrets() {
  local t deadline
  for t in tenant-example "${E2E_TENANTS[@]}"; do
    wait_exists 600 namespace/"$t"
    deadline=$((SECONDS + T_PULL_SECRET_SECONDS))
    until k -n "$t" get secret klique-dockerhub >/dev/null 2>&1; do
      ((SECONDS < deadline)) ||
        die "klique-dockerhub not present in $t after ${T_PULL_SECRET_SECONDS}s: its orchestrator and gateway cannot pull"
      sleep 5
    done
  done
  info "klique-dockerhub present in tenant-example, ${E2E_TENANTS[*]}"
}

# A scripted OIDC login as <user> into <tenant> -> its session token (printed,
# for a variable). Dies unless the login lands.
sso_token() { # <provider id> <tenant> <client id> <user> <password>
  local resp token
  resp="$(sso_login "$@")"
  [[ $(api_subcode <<<"$resp") == 0 && $(jq -r '.data.login_status' <<<"$resp") == logged_in ]] ||
    die "$4 -> $2: login failed: $(api_reason <<<"$resp")"
  token="$(jq -er '.data.token' <<<"$resp")" || die "$4 -> $2: no session token"
  [[ $token =~ ^[A-Za-z0-9._-]+$ ]] || die "$4 -> $2: unexpected characters in the session token (not shown)"
  printf '%s\n' "$token"
}

# tenant-e2e's admin, for the task check.
tenant_admin_token() {
  KLIQUE_DOMAIN="${KLIQUE_DOMAIN:?load_api sets it}"
  sso_token "$PROV_A_OIDC" tenant-e2e "$CLIENT_A_OIDC" e2e-admin "$(kc_secret pw_tenant_e2e_admin)"
}

# The router URLs a routers.get_task_routers response lists, one per line.
router_urls_from() { jq -r '.data.routers[]?.url // empty'; }

# Whether <url> is among the router URLs on stdin. The gateway reports its
# external URL, with "/service/" appended for older servers.
has_router_url() { # <url>
  local u
  while IFS= read -r u; do
    u="${u%/}"
    [[ $u == "$1" || $u == "$1/service" ]] && return 0
  done
  return 1
}

# `openssl x509 -ext subjectAltName` output on stdin -> its DNS names, one per line.
san_dns_names() { grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://'; }

# routers.get_task_routers with a session token -> the response.
routers_list() { # <token>
  printf 'header = "Authorization: Bearer %s"\n' "$1" |
    curl -sS --max-time 30 --cacert "$W/klique-ca.pem" --config - -H 'Content-Type: application/json' \
      -X POST --data-binary '{}' "$API/routers.get_task_routers"
}

# tenant-e2e's own gateway (one per tenant, in its namespace):
#   - answers on https://tenant-e2e.sessions.<domain>, verified against the
#     minted CA (curl checks the host name);
#   - its certificate names both that host and *.<host>, the subdomain every
#     running app gets (openssl, explicitly);
#   - it authenticated to the apiserver with its own key: tenant-e2e's
#     routers.get_task_routers lists its URL, and tenant-e2e-b's does not
#     (routers are per company).
gateway_check() { # <tenant-e2e admin password> <tenant-e2e-b user password>
  local host="tenant-e2e.sessions.$KLIQUE_DOMAIN" url code names deadline resp ta tb
  url="https://$host"
  log "tenant-e2e's gateway: $url (up to ${T_GATEWAY_SECONDS}s)"

  deadline=$((SECONDS + T_GATEWAY_SECONDS))
  until code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$W/klique-ca.pem" "$url/" 2>/dev/null)" &&
    [[ $code =~ ^[1-4][0-9][0-9]$ ]]; do
    ((SECONDS < deadline)) || die "$url did not answer over verified TLS within ${T_GATEWAY_SECONDS}s (last HTTP ${code:-none})"
    sleep 5
  done
  info "answers: HTTP $code, certificate valid for $host"

  names="$(openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null |
    openssl x509 -noout -ext subjectAltName 2>/dev/null | san_dns_names)" ||
    die "could not read the certificate $host serves"
  grep -qxF "$host" <<<"$names" || die "$host's certificate does not name $host (has: $(tr '\n' ' ' <<<"$names"))"
  grep -qxF "*.$host" <<<"$names" || die "$host's certificate does not name *.$host (has: $(tr '\n' ' ' <<<"$names"))"
  info "certificate names $host and *.$host"

  ta="$(sso_token "$PROV_A_OIDC" tenant-e2e "$CLIENT_A_OIDC" e2e-admin "$1")"
  tb="$(sso_token "$PROV_B_OIDC" tenant-e2e-b "$CLIENT_B_OIDC" e2e-b-user "$2")"
  deadline=$((SECONDS + T_GATEWAY_SECONDS))
  while :; do
    resp="$(routers_list "$ta")" || resp=""
    if [[ $(api_subcode <<<"$resp") == 0 ]] && router_urls_from <<<"$resp" | has_router_url "$url"; then
      break
    fi
    ((SECONDS < deadline)) ||
      die "tenant-e2e's routers.get_task_routers never listed $url within ${T_GATEWAY_SECONDS}s (last: $(api_reason <<<"$resp"))"
    sleep 10
  done
  info "registered: tenant-e2e's routers.get_task_routers lists $url"

  resp="$(routers_list "$tb")"
  [[ $(api_subcode <<<"$resp") == 0 ]] || die "tenant-e2e-b's routers.get_task_routers failed: $(api_reason <<<"$resp")"
  ! router_urls_from <<<"$resp" | has_router_url "$url" ||
    die "tenant-e2e-b's routers.get_task_routers lists tenant-e2e's gateway $url"
  unset ta tb
  info "tenant-e2e-b's routers.get_task_routers does not list it"
}
