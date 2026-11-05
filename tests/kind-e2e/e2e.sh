#!/usr/bin/env bash
# End-to-end check of this repo's quickstart, on a local kind cluster:
#   klique-terraform (nip-io quickstart tfvars) -> Flux pulls klique-fluxcd from
#   GitHub at a pushed ref -> every Kustomization and HelmRelease Ready -> the
#   apiserver answers through the ingress, with the minted CA -> one task on
#   queue `default` reaches `completed` (a task pod trusts that CA) -> teardown.
#
# Maintainer tooling, not an example. See README.md next to this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
# shellcheck source=lib-sso.sh
source "$HERE/lib-sso.sh"

usage() {
  cat <<EOF
Usage: tests/kind-e2e/e2e.sh <command> [--ref <branch|sha>]

Commands:
  all      up + verify, then down (KEEP=1 keeps the cluster, also on failure)
  up       kind cluster, cloud-provider-kind, OpenBao, Terraform, Keycloak, Flux
  verify   wait for everything Ready, probe the apiserver through the ingress,
           then run the tenants check and the task check
  task     only the task check, on a cluster that is up: one task on
           tenant-e2e's queue 'default', as its admin, must reach 'completed'
           (up to T_TASK_SECONDS, default 900)
  tenants  only the tenants and SSO check, on a cluster that is up: the
           tenants exist with their key Secrets and providers, OIDC and SAML
           logins through Keycloak land with the right role, an OIDC logout
           ends the Keycloak session, and
           tenant-e2e's gateway answers on its own host and registered itself
  down     delete the cluster, its load-balancer containers and $W
           (safe to run when nothing is up)

Options:
  --ref <branch|sha>   what Flux reconciles and Terraform applies; default: the
                       current branch. It must already be pushed to
                       $GIT_REMOTE (the harness never pushes): a branch whose tip
                       matches your local one, or a sha that is a branch tip there.

Needs: ~/.config/klique/dockerhub.env and ~/.config/klique/github-token.env
(README.md, "Credentials"). Environment overrides are listed in README.md.
EOF
}

# --- Preflight (read-only) ----------------------------------------------------

# Resolves --ref to BRANCH + SHA on the remote, read-only (git ls-remote).
resolve_ref() {
  local ref="${REF:-}" heads local_sha url slug
  if [[ -z $ref ]]; then
    ref="$(git -C "$REPO" branch --show-current)"
    [[ -n $ref ]] || die "detached HEAD: pass --ref <branch|sha>"
  fi

  url="$(git -C "$REPO" remote get-url "$GIT_REMOTE")" || die "no git remote '$GIT_REMOTE'"
  slug="$(repo_slug)" || exit 1
  [[ ${url%.git} == *[/:]"$slug" ]] ||
    warn "remote $GIT_REMOTE ($url) does not look like $REPO_URL; Flux pulls from $REPO_URL"

  heads="$(git -C "$REPO" ls-remote --heads "$GIT_REMOTE")" || die "git ls-remote $GIT_REMOTE failed"

  SHA="$(awk -v r="refs/heads/$ref" '$2 == r { print $1 }' <<<"$heads")"
  if [[ -n $SHA ]]; then
    BRANCH=$ref
    local_sha="$(git -C "$REPO" rev-parse --verify -q "refs/heads/$ref^{commit}" || true)"
    if [[ -n $local_sha && $local_sha != "$SHA" ]]; then
      die "local branch '$ref' is at ${local_sha:0:12} but $GIT_REMOTE has ${SHA:0:12}: push it first (the harness never pushes), or pass --ref ${SHA:0:12}"
    fi
  elif [[ $ref =~ ^[0-9a-f]{7,40}$ ]]; then
    SHA="$(git -C "$REPO" rev-parse --verify -q "$ref^{commit}")" || die "unknown commit '$ref'"
    BRANCH="$(awk -v s="$SHA" '$1 == s { sub("^refs/heads/", "", $2); print $2; exit }' <<<"$heads")"
    [[ -n $BRANCH ]] || die "commit ${SHA:0:12} is not the tip of any branch on $GIT_REMOTE: push it first (the harness never pushes)"
  else
    die "branch '$ref' is not on $GIT_REMOTE: push it first (the harness never pushes)"
  fi

  git -C "$REPO" cat-file -e "$SHA^{commit}" 2>/dev/null ||
    die "commit ${SHA:0:12} is not in this clone: git fetch $GIT_REMOTE"
  if ! git -C "$REPO" diff --quiet "$SHA" -- klique-terraform klique-fluxcd; then
    warn "your working tree differs from ${SHA:0:12} in klique-terraform/ or klique-fluxcd/; only the pushed commit is tested"
  fi
  check_ref "$BRANCH" "$SHA" "$GIT_REMOTE"
  info "ref: $BRANCH @ $SHA"
}

# BRANCH and SHA come from the remote (or from $W/ref): data only, never run.
# Validated before anything uses them, and always quoted.
check_ref() { # <branch> <sha> <where they came from>
  [[ $2 =~ ^[0-9a-f]{40}$ ]] || die "$3: not a full commit sha"
  git check-ref-format --branch "$1" >/dev/null 2>&1 || die "$3: not a valid branch name"
}

# Reads $W/ref with sed, never `source`: a branch name may contain $(...).
read_ref() {
  BRANCH="$(sed -n 's/^BRANCH=//p' "$W/ref")"
  SHA="$(sed -n 's/^SHA=//p' "$W/ref")"
  check_ref "$BRANCH" "$SHA" "$W/ref"
}

# The tfvars, derived from the quickstart example AS COMMITTED at $SHA, so a
# drift in the example breaks this test. Written only to $W.
write_tfvars() {
  local ex="$1" out="$W/e2e.tfvars" store
  grep -qE '^kubeconfig_context *=' "$ex" || die "$ex has no kubeconfig_context line to replace"
  ! grep -qE '^(kubeconfig_path|secret_store) *=' "$ex" ||
    die "$ex now sets kubeconfig_path or secret_store itself; update write_tfvars()"

  # The commented "secret_store = { ... }" block (the Vault example) uncommented,
  # with only `server` pointed at the in-cluster OpenBao.
  store="$(awk '
    /^# secret_store = \{/ { f = 1 }
    f { sub(/^# ?/, ""); print }
    f && /^\}/ { exit }
  ' "$ex")"
  grep -q 'server: https://vault.example.com' <<<"$store" ||
    die "$ex: the commented secret_store Vault block changed shape; update write_tfvars()"
  store="${store/server: https:\/\/vault.example.com/server: http://openbao.openbao.svc:8200}"

  {
    sed -E 's/^kubeconfig_context *=.*/kubeconfig_context = "'"$CONTEXT"'"/' "$ex"
    printf '\n# --- Added by tests/kind-e2e/e2e.sh ---\n'
    printf 'kubeconfig_path = "%s"\n\n' "$KUBECONFIG"
    printf '%s\n' "$store"
  } >"$out"
  info "tfvars: $out"
}

preflight() {
  require_tools kind kubectl helm terraform flux cloud-provider-kind docker git curl jq openssl timeout
  check_private_file "$DOCKERHUB_ENV" "Docker Hub credentials"
  load_dockerhub_env
  unset DOCKERHUB_USERNAME DOCKERHUB_PASSWORD # checked only; read again when seeding
  check_private_file "$GITHUB_TOKEN_FILE" "GitHub token"
  resolve_ref
  load_github_token
  check_github_token "$SHA"
  unset GITHUB_TOKEN # checked only; read again when Flux gets it

  prepare_workdir
}

# $W is ours only if it carries the marker this function writes. A directory
# that already exists without it is someone else's: never chmod, write into or
# (in down) delete it.
prepare_workdir() {
  # The path is written into the tfvars as an HCL string; keep it to
  # characters that need no escaping there.
  [[ $W =~ ^/[A-Za-z0-9._/+-]+$ ]] ||
    die "work dir '$W' may contain only letters, digits and . _ / + - (set KLIQUE_E2E_DIR)"
  if [[ -e $W || -L $W ]]; then
    [[ -d $W && ! -L $W && -f $W/.klique-e2e ]] ||
      die "$W already exists and was not created by this harness; remove it or set KLIQUE_E2E_DIR to a new path"
    # One work dir = one commit: the Terraform copy and state in it belong to
    # the commit recorded at its first run.
    if [[ -f $W/ref ]]; then
      local had
      had="$(sed -n 's/^SHA=//p' "$W/ref")"
      [[ $had =~ ^[0-9a-f]{40}$ ]] || die "$W/ref is damaged: run 'tests/kind-e2e/e2e.sh down' first"
      [[ $had == "$SHA" ]] ||
        die "$W holds a run of ${had:0:12}, not ${SHA:0:12}: run 'tests/kind-e2e/e2e.sh down' first"
    fi
  else
    mkdir -p "$(dirname "$W")"
    mkdir -m 700 "$W"
    touch "$W/.klique-e2e"
  fi
  printf 'BRANCH=%s\nSHA=%s\n' "$BRANCH" "$SHA" >"$W/ref"
}

# --- up -----------------------------------------------------------------------

create_cluster() {
  log "kind cluster $CLUSTER"
  if cluster_exists; then
    info "exists, reusing"
    # Always re-exported: a kept file can hold a stale port or certificate.
    kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
  else
    # --kubeconfig: kind writes ONLY this file, never ~/.kube/config.
    kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --kubeconfig "$KUBECONFIG" --wait 2m
  fi
  chmod 600 "$KUBECONFIG"
  info "KUBECONFIG=$KUBECONFIG"
  guard
  # The single kind node is a control-plane node, which Kubernetes excludes
  # from LoadBalancer backends unless this label goes (cloud-provider-kind README).
  k label node "$CLUSTER-control-plane" node.kubernetes.io/exclude-from-external-load-balancers- >/dev/null 2>&1 || true
}

# On macOS cloud-provider-kind must run as root (it wires LoadBalancer IPs
# through to the host, which Docker Desktop's VM hides); on Linux it must not.
CPK_SUDO=()
[[ $(uname -s) == Darwin ]] && CPK_SUDO=(sudo)

# kill -0 fails with EPERM on a root-owned process, so test liveness with ps.
pid_alive() { ps -p "$1" >/dev/null 2>&1; }

# Prints the pid of the cloud-provider-kind this harness started, if that pid
# is still alive AND still cloud-provider-kind (pids get reused).
cpk_pid() {
  local f="$W/cloud-provider-kind.pid" pid
  [[ -f $f ]] || return 1
  pid="$(cat "$f")"
  [[ $pid =~ ^[0-9]+$ ]] && pid_alive "$pid" || return 1
  # comm is cut at 15 characters: "cloud-provider-".
  [[ $(ps -o comm= -p "$pid") == cloud-provider-* ]] || return 1
  echo "$pid"
}

start_cloud_provider_kind() {
  log "cloud-provider-kind"
  local pid others
  if pid="$(cpk_pid)"; then
    info "running (pid $pid)"
    return
  fi
  others="$(kind get clusters 2>/dev/null | grep -vx "$CLUSTER" || true)"
  [[ -z $others ]] || warn "cloud-provider-kind also serves LoadBalancers of your other kind clusters: $others"
  # Only LoadBalancer Services: no Gateway API CRDs or default IngressClass of
  # its own, so the cluster looks like the plain one the quickstart expects.
  local cpk
  cpk="$(command -v cloud-provider-kind)" # absolute: sudo resets PATH
  if ((${#CPK_SUDO[@]})); then
    info "macOS: cloud-provider-kind needs root, sudo may ask for your password"
    sudo -v || die "cloud-provider-kind needs sudo on macOS"
    # Background it inside the root shell so $! is cloud-provider-kind itself,
    # not sudo; the log stays in $W (root-owned, world-readable).
    pid="$(sudo -n sh -c 'nohup "$1" --enable-default-ingress=false --gateway-channel=disabled >"$2" 2>&1 & echo $!' \
      sh "$cpk" "$W/cloud-provider-kind.log")"
  else
    nohup "$cpk" --enable-default-ingress=false --gateway-channel=disabled \
      >"$W/cloud-provider-kind.log" 2>&1 &
    pid=$!
  fi
  echo "$pid" >"$W/cloud-provider-kind.pid"
  sleep 2
  pid_alive "$pid" || die "cloud-provider-kind exited; see $W/cloud-provider-kind.log"
  info "pid $pid, log $W/cloud-provider-kind.log"
}

rand() { openssl rand -hex "$1"; }

setup_openbao() {
  log "OpenBao (secret backend)"
  guard
  local status out err="$W/helm-status.err"
  # `helm status` reports every state (helm 4 dropped `list -a`). stdout is the
  # JSON; stderr (warnings included) goes to a file, read only on failure.
  # Exactly "release: not found" means "install it"; any other error stops.
  if out="$(helm status openbao -n openbao --kube-context "$CONTEXT" -o json 2>"$err")"; then
    status="$(jq -er .info.status <<<"$out")" || die "helm status openbao: output is not the expected JSON"
  elif grep -q 'release: not found' "$err"; then
    status=""
  else
    die "helm status openbao failed: $(cat "$err")"
  fi
  rm -f "$err"
  if [[ $status == deployed ]]; then
    info "release openbao deployed, reusing (a reinstall would change the root token)"
  elif [[ -n $status ]]; then
    die "release openbao is '$status', not deployed: run 'tests/kind-e2e/e2e.sh down' first"
  else
    # The official chart, pinned; dev mode and hardening in openbao-values.yaml.
    # The root token is generated here and reaches helm on stdin (-f -), never
    # argv or disk. It lives on in the throwaway cluster only: the release, the
    # pod's environment and, as dev mode prints it, the pod log.
    printf 'server:\n  dev:\n    devRootToken: "%s"\n' "$(rand 24)" |
      helm upgrade --install openbao openbao --kube-context "$CONTEXT" \
        --repo "$OPENBAO_CHART_REPO" --version "$OPENBAO_CHART_VERSION" \
        -n openbao --create-namespace \
        -f "$HERE/openbao-values.yaml" -f - \
        --wait --timeout "$T_BASE" >/dev/null
  fi
  k -n openbao wait --for=condition=Ready pod/openbao-0 --timeout="$T_BASE"

  bao secrets list -format=json | jq -e '."kv/"' >/dev/null ||
    bao secrets enable -path=kv -version=2 kv >/dev/null
  bao auth list -format=json | jq -e '."kubernetes/"' >/dev/null ||
    bao auth enable kubernetes >/dev/null
  # In-cluster defaults: the pod's own CA and service-account token review the
  # tokens ESO presents.
  bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null
  printf 'path "kv/data/klique/*" {\n  capabilities = ["read"]\n}\n' | bao policy write klique - >/dev/null
  # ESO authenticates with its controller's own service-account token (no
  # serviceAccountRef in the store): external-secrets/external-secrets, from
  # klique-terraform's external_secrets defaults.
  bao write auth/kubernetes/role/klique \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    token_policies=klique token_ttl=1h >/dev/null

  if bao kv get -mount=kv klique/apiserver >/dev/null 2>&1; then
    info "entries already seeded (kept: the running release uses them)"
    return
  fi

  # Values reach jq through its environment (not argv) and OpenBao through
  # stdin. None is printed or written.
  load_dockerhub_env
  U="$DOCKERHUB_USERNAME" P="$DOCKERHUB_PASSWORD" jq -n '{username: env.U, password: env.P}' |
    bao kv put -mount=kv klique/registry/dockerhub - >/dev/null
  unset DOCKERHUB_USERNAME DOCKERHUB_PASSWORD

  # The apiserver's own pair, and an admin password with the characters that
  # break unquoted HOCON, so the `| quote` rule is exercised. No agent pair:
  # every tenant's orchestrator and gateway use that tenant's minted keys.
  K1="$(rand 12)" S1="$(rand 24)" AU="e2e-admin" AP="$(rand 12)#+=@,{}" \
    jq -n '{key: env.K1, secret: env.S1, admin_user: env.AU, admin_password: env.AP}' |
    bao kv put -mount=kv klique/apiserver - >/dev/null
  info "seeded kv/klique/registry/dockerhub and kv/klique/apiserver"
}

apply_terraform() {
  log "klique-terraform at ${SHA:0:12}"
  local src="$W/src" tf="$W/src/klique-terraform"
  # From the commit, not the working tree; and a copy, so state, .terraform/
  # and the lockfile never touch the repo.
  # Extracted into a scratch dir and moved into place only when complete, so a
  # failed extraction never looks like a finished one.
  if [[ ! -e $src ]]; then
    rm -rf "$src.partial"
    mkdir -p "$src.partial"
    git -C "$REPO" archive "$SHA" klique-terraform | tar -x -C "$src.partial"
    echo "$SHA" >"$src.partial/.sha"
    mv "$src.partial" "$src"
  fi
  [[ -f $src/.sha ]] ||
    die "$src is incomplete (an earlier extraction was interrupted): run 'tests/kind-e2e/e2e.sh down' first"
  [[ $(cat "$src/.sha") == "$SHA" ]] ||
    die "$src was extracted from another commit: run 'tests/kind-e2e/e2e.sh down' first"
  write_tfvars "$tf/examples/nip-io-quickstart.tfvars.example"
  guard
  export TF_IN_AUTOMATION=1
  terraform -chdir="$tf" init -input=false -lockfile=readonly >/dev/null
  timeout "$T_TERRAFORM" terraform -chdir="$tf" apply -input=false -auto-approve -var-file="$W/e2e.tfvars"
}

install_flux() {
  log "Flux"
  guard
  fx install --timeout="$T_BASE"

  guard
  # The GitHub token, from the user's file to the Secret on stdin, as the
  # basic-auth password of the https clone (any non-empty username works).
  # Plain `create`, not `apply`: apply would copy it into a last-applied
  # annotation.
  load_github_token
  k -n flux-system delete secret flux-system --ignore-not-found >/dev/null
  {
    printf 'username=git\n'
    printf 'password=%s\n' "$GITHUB_TOKEN"
  } | k -n flux-system create secret generic flux-system --from-env-file=/dev/stdin >/dev/null
  unset GITHUB_TOKEN

  # The same names `flux bootstrap` uses, so kustomizations/klique.yaml's
  # sourceRef (GitRepository/flux-system) resolves. Branch + commit: exactly
  # the commit resolved above, even if the branch moves during the run.
  guard
  fx create source git flux-system --url="$REPO_URL" --branch="$BRANCH" --commit="$SHA" \
    --secret-ref=flux-system --interval=1m --timeout="$T_BASE"
  # ./klique-fluxcd/kustomizations, not ./klique-fluxcd: the root
  # kustomization.yaml lists flux-system/, which only `flux bootstrap` writes.
  guard
  fx create kustomization flux-system --source=GitRepository/flux-system \
    --path=./klique-fluxcd/kustomizations --prune=true --interval=10m --timeout="$T_BASE"
}

up_steps() {
  create_cluster
  start_cloud_provider_kind
  setup_openbao
  seed_sso_secrets
  apply_terraform
  setup_keycloak
  install_flux
  apply_e2e_tenants
  log "up: done"
  info "KUBECONFIG=$KUBECONFIG"
  info "next: tests/kind-e2e/e2e.sh verify"
}

cmd_up() {
  no_xtrace
  preflight
  up_steps
}

# --- verify -------------------------------------------------------------------

not_ready_rows() { # <flux get kind...>
  { fx get "$@" -A --no-header --status-selector ready=false 2>/dev/null || true; } |
    sed '/^[[:space:]]*$/d'
}

# Sets API (the public apiserver URL) and writes the minted CA certificate to
# $W/klique-ca.pem. The certificate is public; its key stays in state.
load_api() {
  local tf="$W/src/klique-terraform"
  API="$(terraform -chdir="$tf" output -json urls | jq -r .api)"
  # Checked, because it is templated into the task's Python source.
  [[ $API =~ ^https://[A-Za-z0-9.-]+$ ]] || die "unexpected apiserver URL from terraform output: '$API'"
  terraform -chdir="$tf" output -raw ca_certificate_pem >"$W/klique-ca.pem"
  KLIQUE_DOMAIN="$(terraform -chdir="$tf" output -raw domain)"
  [[ $KLIQUE_DOMAIN =~ ^[A-Za-z0-9.-]+$ ]] || die "unexpected domain from terraform output: '$KLIQUE_DOMAIN'"
}

probe_apiserver() {
  local api ca="$W/klique-ca.pem" deadline body
  load_api
  api="$API"
  log "apiserver through the ingress: $api/debug.ping"
  deadline=$((SECONDS + T_PROBE_SECONDS))
  until body="$(curl -fsS --max-time 10 --cacert "$ca" "$api/debug.ping" 2>&1)"; do
    ((SECONDS < deadline)) || die "no answer from $api/debug.ping within ${T_PROBE_SECONDS}s: $body"
    sleep 10
  done
  info "answered: $body"
}

# Not a pass/fail gate: proves the admin login made it from OpenBao through
# ESO into the apiserver's HOCON config.
probe_admin_login() {
  local api="$1" ca="$W/klique-ca.pem" user pass
  user="$(bao kv get -mount=kv -field=admin_user klique/apiserver)"
  pass="$(bao kv get -mount=kv -field=admin_password klique/apiserver)"
  pass="${pass//\\/\\\\}"
  pass="${pass//\"/\\\"}"
  # The credential goes to curl on stdin (--config -), never on its command line.
  if printf 'user = "%s:%s"\n' "$user" "$pass" |
    curl -fsS -o /dev/null --max-time 10 --cacert "$ca" --config - -X POST "$api/auth.login"; then
    info "admin login via auth.login: OK"
  else
    warn "admin login via auth.login did not return 2xx (informational, not a failure)"
  fi
  unset user pass
}

cmd_verify() {
  no_xtrace
  [[ -f $W/ref ]] || die "nothing up ($W/ref missing): run 'up' first"
  read_ref
  guard

  log "Flux source at ${SHA:0:12}"
  k -n flux-system wait --for=condition=Ready gitrepository/flux-system --timeout="$T_BASE"
  local rev
  rev="$(k -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}')"
  [[ $rev == *"$SHA"* ]] || die "GitRepository serves '$rev', expected $SHA"
  info "$rev"

  log "Kustomizations"
  k -n flux-system wait --for=condition=Ready kustomization/flux-system --timeout="$T_BASE"
  wait_exists 300 -n flux-system kustomization/klique

  log "secret backend"
  k -n klique wait --for=condition=Ready secretstore/klique-secrets --timeout="$T_BASE"
  # Created by the klique Kustomization; the dockerhub one gates every chart pull.
  wait_exists 300 -n klique externalsecret/klique-dockerhub
  k -n klique wait --for=condition=Ready externalsecret/klique-dockerhub --timeout="$T_BASE"

  log "Klique releases (up to $T_KLIQUE)"
  # klique's health checks cover the control plane; each tenant's orchestrator
  # and gateway are covered by the tenants and e2e-tenants Kustomizations below.
  k -n flux-system wait --for=condition=Ready kustomization/klique --timeout="$T_KLIQUE"
  k -n klique wait --for=condition=Ready externalsecret --all --timeout="$T_BASE"

  fx get kustomizations -A
  fx get helmreleases -A
  log "tenants (up to $T_TENANTS)"
  # Their Jobs run after klique is Ready; wait before the all-Ready check.
  wait_exists 300 -n klique kustomization/tenants
  wait_exists 300 -n klique kustomization/e2e-tenants
  # Each tenant's releases pull with klique-dockerhub in its own namespace:
  # say so plainly instead of waiting out the Kustomizations' 30 minutes.
  wait_tenant_pull_secrets
  k -n klique wait --for=condition=Ready kustomization/tenants --timeout="$T_TENANTS"
  k -n klique wait --for=condition=Ready kustomization/e2e-tenants --timeout="$T_TENANTS"

  local bad
  bad="$(not_ready_rows sources all)$(not_ready_rows kustomizations)$(not_ready_rows helmreleases)"
  [[ -z $bad ]] || die "not Ready:"$'\n'"$bad"

  probe_apiserver
  probe_admin_login "$API"
  # The tenants check logs in through Keycloak first; the task check then runs
  # as tenant-e2e's admin, on tenant-e2e's own orchestrator.
  tenants_check
  task_check
  log "verify: PASS"
}

# --- task check ---------------------------------------------------------------
#
# One real task on tenant-e2e's queue `default`, the way one of its users runs
# one from the UI: tenant-e2e's own orchestrator (in namespace tenant-e2e,
# authenticated with its minted `orchestrator` key) starts a pod from the
# default image, the agent inside it bootstraps (apt, venv) and talks to the
# apiserver over https, then the task's code calls the apiserver itself.
# `completed` proves both trust the private CA AFTER the image's own
# update-ca-certificates; a pod that lost the CA fails with
# CERTIFICATE_VERIFY_FAILED, in the agent or in the script.
#
# Talks to the REST API from this host through the ingress, as tenant-e2e's
# admin: the session token of a scripted OIDC login (lib-sso.sh), which only
# reaches tenant-e2e's company. The password and the token live in shell
# variables and reach curl on stdin only. The task carries no secret and is
# left in place (visible in the UI with KEEP=1); `down` removes it.

T_TASK_SECONDS="${T_TASK_SECONDS:-900}"
TASK_POLL_SECONDS="${TASK_POLL_SECONDS:-10}"
TASK_QUEUED_HINT_SECONDS="${TASK_QUEUED_HINT_SECONDS:-300}"

# One API call. Prints the response body; the token goes to curl on stdin.
api_call() { # <endpoint> <json body>
  printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN" |
    curl -sS --max-time 30 --cacert "$W/klique-ca.pem" --config - \
      -H 'Content-Type: application/json' -X POST --data-binary "$2" "$API/$1"
}

# api_call, then insist on result_code 200. Prints the response body.
api() { # <endpoint> <json body>
  local resp
  resp="$(api_call "$1" "$2")" || die "$1: request failed"
  jq -e '.meta.result_code == 200' <<<"$resp" >/dev/null 2>&1 ||
    die "$1 failed: $(jq -r '"\(.meta.result_code) \(.meta.result_msg)"' <<<"$resp" 2>/dev/null || echo "not a JSON API response")"
  printf '%s\n' "$resp"
}

# An API error response -> "<result_code> <result_msg>" on one line (at most
# 200 characters), or "not a JSON API response" (an HTML error page, say).
api_reason() {
  jq -er '"\(.meta.result_code) \(.meta.result_msg)" | gsub("[\n\r]"; " ") | .[0:200]' 2>/dev/null ||
    echo "not a JSON API response"
}

# The task's code: standard library only (no pip install), and the system
# bundle (/etc/ssl/certs/ca-certificates.crt) via ssl.create_default_context().
task_script() { # <api url>
  cat <<PY
# kind-e2e CA check, created by tests/kind-e2e/e2e.sh.
import ssl
import sys
import urllib.request

URL = "$1/debug.ping"
try:
    with urllib.request.urlopen(URL, context=ssl.create_default_context(), timeout=30) as r:
        print("kind-e2e CA check: %s -> HTTP %d" % (URL, r.status))
except Exception as e:
    print("kind-e2e CA check FAILED: %s: %r" % (URL, e))
    sys.exit(1)
PY
}

# tasks.create body: a literal script (empty repository, code in script.diff),
# which clearml-agent runs as <entry_point> in an empty directory.
task_body() { # <name> <script>
  N="$1" D="$2" jq -n '{
    name: env.N,
    type: "testing",
    comment: "kind e2e: private CA trusted inside a task pod",
    script: {repository: "", entry_point: "e2e_ca_check.py", working_dir: ".", diff: env.D}
  }'
}

# queues.get_all response -> the id of the queue named exactly "default".
queue_id_from() {
  jq -er '[.data.queues[]? | select(.name == "default")] | if length == 1 then .[0].id else empty end'
}

# tasks.get_by_id response -> status, status_reason, status_message and
# last_worker, joined by US (0x1f). Not tab: tab is IFS whitespace, so `read`
# would merge an empty field into its neighbour. Newlines and US inside a
# field become spaces, so the record stays one line.
readonly US=$'\x1f'
task_state_from() {
  jq -r '.data.task | [.status, .status_reason, .status_message, .last_worker]
    | map((. // "") | tostring | gsub("[\u001f\n\r]"; " ")) | join("\u001f")'
}

# events.get_task_log response -> the log lines, oldest first.
task_log_from() {
  jq -r '(.data.events // []) | sort_by(.timestamp) | .[] | (.msg // empty)'
}

task_failure() { # <task id> <state record> <why>
  local status reason message worker
  IFS=$US read -r status reason message worker <<<"$2"
  printf 'task %s: %s\n' "$1" "$3" >&2
  printf '  status:         %s\n  status_reason:  %s\n  status_message: %s\n  last_worker:    %s\n' \
    "$status" "$reason" "$message" "$worker" >&2
  printf '  last 40 log lines:\n' >&2
  (api events.get_task_log "$(T="$1" jq -n '{task: env.T, batch_size: 40, navigate_earlier: true}')" |
    task_log_from | tail -n 40 | sed 's/^/    | /' >&2) || true
  unset API_TOKEN
  die "task check failed: $3"
}

task_check() {
  log "task on tenant-e2e's queue 'default' (up to ${T_TASK_SECONDS}s)"
  API_TOKEN="$(tenant_admin_token)" || exit 1

  local resp queue id state status start deadline hinted=0 last="" rc why last_why=""
  # `|| exit 1` on every call: api() has already said why, and errexit does
  # not apply when a caller tests this function's status.
  resp="$(api queues.get_all '{"name": "^default$"}')" || exit 1
  queue="$(queue_id_from <<<"$resp")" ||
    die "queue 'default' not found in tenant-e2e (its orchestrator registers it)"

  resp="$(api tasks.create "$(task_body "kind-e2e CA check ${SHA:0:12} $(date -u +%Y%m%dT%H%M%SZ)" "$(task_script "$API")")")" || exit 1
  id="$(jq -er '.data.id' <<<"$resp")" || die "tasks.create returned no task id"
  api tasks.enqueue "$(T="$id" Q="$queue" jq -n '{task: env.T, queue: env.Q}')" >/dev/null || exit 1
  info "task $id enqueued on 'default' ($queue)"

  start=$SECONDS
  deadline=$((SECONDS + T_TASK_SECONDS))
  while :; do
    # A failed poll (an apiserver or ingress blip) is retried quietly until the
    # deadline: api_call directly, so no ERROR line for a blip. The reason is
    # kept (curl's exit code, or the API's result code and message, never the
    # request), and a retry line is printed only when it changes.
    rc=0
    resp="$(api_call tasks.get_by_id "$(T="$id" jq -n '{task: env.T}')" 2>/dev/null)" || rc=$?
    why=""
    if ((rc != 0)); then
      why="curl exit code $rc"
    elif ! jq -e '.meta.result_code == 200' <<<"$resp" >/dev/null 2>&1; then
      why="$(api_reason <<<"$resp")"
    fi
    if [[ -n $why ]]; then
      ((SECONDS < deadline)) ||
        die "tasks.get_by_id kept failing until the ${T_TASK_SECONDS}s deadline; last: $why"
      [[ $why == "$last_why" ]] || info "$((SECONDS - start))s: tasks.get_by_id failed ($why); retrying"
      last_why=$why
      sleep "$TASK_POLL_SECONDS"
      continue
    fi
    last_why=""
    state="$(task_state_from <<<"$resp")"
    status="${state%%"$US"*}"
    if [[ $status != "$last" ]]; then
      info "$((SECONDS - start))s: $status"
      last=$status
    fi
    case "$status" in
      completed) break ;;
      failed | stopped | closed | published) task_failure "$id" "$state" "ended '$status'" ;;
    esac
    if [[ $status == queued ]] && ((hinted == 0 && SECONDS - start >= TASK_QUEUED_HINT_SECONDS)); then
      warn "task still queued after ${TASK_QUEUED_HINT_SECONDS}s: not picked up; is tenant-e2e's orchestrator watching queue 'default'?"
      hinted=1
    fi
    ((SECONDS < deadline)) || task_failure "$id" "$state" "not completed within ${T_TASK_SECONDS}s"
    sleep "$TASK_POLL_SECONDS"
  done
  unset API_TOKEN
  info "task $id completed"
}

cmd_task() {
  no_xtrace
  [[ -f $W/ref ]] || die "nothing up ($W/ref missing): run 'up' first"
  read_ref
  guard
  load_api
  task_check
  log "task: PASS"
}

cmd_tenants() {
  no_xtrace
  [[ -f $W/ref ]] || die "nothing up ($W/ref missing): run 'up' first"
  read_ref
  guard
  load_api
  tenants_check
  log "tenants: PASS"
}

# --- down ---------------------------------------------------------------------

cmd_down() {
  no_xtrace
  log "teardown"
  local pid
  if pid="$(cpk_pid)"; then
    "${CPK_SUDO[@]}" kill "$pid"
    for _ in 1 2 3 4 5 6 7 8 9 10; do pid_alive "$pid" || break; sleep 1; done
    info "stopped cloud-provider-kind (pid $pid)"
  fi

  if cluster_exists; then
    # Name-scoped, and --kubeconfig keeps ~/.kube/config out of it.
    kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
  else
    info "no kind cluster $CLUSTER"
  fi

  # cloud-provider-kind's load-balancer containers outlive the cluster; they
  # carry the cluster's name in this label (cloud-provider-kind pkg/constants).
  local lbs
  lbs="$(docker ps -aq --filter "label=io.x-k8s.cloud-provider-kind.cluster=$CLUSTER")"
  if [[ -n $lbs ]]; then
    # shellcheck disable=SC2086 # one id per word
    docker rm -f $lbs >/dev/null
    info "removed load-balancer containers: $(wc -w <<<"$lbs")"
  fi

  if [[ -e $W || -L $W ]]; then
    [[ -d $W && ! -L $W && -f $W/.klique-e2e ]] ||
      die "$W exists but was not created by this harness; not removing it"
    rm -rf "$W"
    info "removed $W"
  fi
  info "kind clusters now: $(kind get clusters 2>/dev/null | tr '\n' ' ')"
}

# --- all ----------------------------------------------------------------------

diagnose() {
  cluster_exists && [[ -f $KUBECONFIG ]] || return 0
  log "diagnostics (status only, no Secret contents)"
  fx get all -A 2>&1 || true
  k get pods -A 2>&1 || true
  k -n klique get secretstore,externalsecret 2>&1 || true
  local t
  for t in tenant-example "${E2E_TENANTS[@]}"; do
    printf '\n--- namespace %s\n' "$t"
    # Names and types only: `get secret` never prints the data.
    k -n "$t" get pods,secrets 2>&1 || true
    k -n "$t" get events --sort-by=.lastTimestamp 2>&1 | tail -15 || true
  done
  k get events -A --sort-by=.lastTimestamp 2>&1 | tail -40 || true
}

cmd_all() {
  no_xtrace
  # Preflight first and OUTSIDE the trap: a run that fails here (no
  # credentials, ref not pushed, foreign work dir) must not tear down a
  # cluster an earlier `up` left running.
  preflight
  # shellcheck disable=SC2317,SC2329 # invoked by the trap
  on_exit() {
    local rc=$?
    ((rc == 0)) || diagnose
    if [[ ${KEEP:-0} == 1 ]]; then
      info "KEEP=1: cluster kept (KUBECONFIG=$KUBECONFIG); run 'tests/kind-e2e/e2e.sh down' when done"
    else
      cmd_down || true
    fi
    exit "$rc"
  }
  trap on_exit EXIT
  up_steps
  cmd_verify
}

# --- main ---------------------------------------------------------------------

CMD="${1:-}"
[[ -n $CMD ]] && shift
REF=""
while (($#)); do
  case "$1" in
    --ref)
      [[ $# -ge 2 ]] || die "--ref needs a value"
      REF="$2"
      shift 2
      ;;
    --ref=*)
      REF="${1#--ref=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$CMD" in
  up) cmd_up ;;
  verify) cmd_verify ;;
  task) cmd_task ;;
  tenants) cmd_tenants ;;
  down) cmd_down ;;
  all) cmd_all ;;
  -h | --help | help | "") usage ;;
  *) die "unknown command: $CMD (see --help)" ;;
esac
