# shellcheck shell=bash
# Shared helpers for e2e.sh. Sourced, never run.
#
# Two rules every function here keeps:
#   - Nothing mutates a cluster without guard() first, and every kubectl, flux
#     and terraform call goes through the harness's OWN kubeconfig ($KUBECONFIG
#     below), which holds the kind context and nothing else. The user's
#     ~/.kube/config is never read or written.
#   - No secret value is ever an argument (argv is world-readable in /proc),
#     echoed, or written to a file. Values live in shell variables and travel
#     on stdin or in a child's environment only.

# Settings. Several are read only by e2e.sh, which sources this file, so
# a lint of lib.sh alone would call them unused; the directive covers
# this block and nothing else.
# shellcheck disable=SC2034
{
readonly CLUSTER=klique-gitops-ref
readonly CONTEXT=kind-klique-gitops-ref

# Exact, so the run is reproducible. The default is the image kind v0.33.0 itself
# defaults to; a different kind release needs its own image (see its release notes).
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"

# The secret backend's chart (openbao-values.yaml has the values). The chart
# version pins the image too: its default tag is the chart's appVersion (2.7.2).
readonly OPENBAO_CHART_REPO=https://openbao.github.io/openbao-helm
readonly OPENBAO_CHART_VERSION=0.30.6

# The repo Flux pulls from. The ref must already be pushed there.
REPO_URL="${KLIQUE_E2E_REPO_URL:-https://github.com/klique-ai/gitops-reference}"
# The git remote of THIS checkout that points at REPO_URL; used read-only (ls-remote).
GIT_REMOTE="${KLIQUE_E2E_GIT_REMOTE:-origin}"

CRED_DIR="${KLIQUE_E2E_CRED_DIR:-$HOME/.config/klique}"
DOCKERHUB_ENV="$CRED_DIR/dockerhub.env"
GITHUB_TOKEN_FILE="$CRED_DIR/github-token.env"

# Everything a run creates on the host: kubeconfig, Terraform copy + state (holds
# the quickstart CA key), cloud-provider-kind pid and log. Removed by `down`.
W="${KLIQUE_E2E_DIR:-${TMPDIR:-/tmp}/klique-e2e-$(id -u)}"
# Made absolute against the directory you run from: terraform -chdir and the
# generated tfvars would otherwise resolve a relative path somewhere else.
[[ $W == /* ]] || W="$PWD/$W"
export KUBECONFIG="$W/kubeconfig"
# Helm's cache, config and data (the OpenBao chart download) live in $W too, so
# nothing outlives `down` and your own helm setup is never read or changed.
#
# First drop every HELM_* and KUBE_* variable the calling shell exported: the
# path ones would send helm's files elsewhere, and HELM_KUBEAPISERVER,
# HELM_KUBETOKEN, HELM_KUBECONTEXT, HELM_NAMESPACE (helm) or KUBE_HOST,
# KUBE_TOKEN, KUBE_CONFIG_PATH, KUBE_CTX (the Terraform kubernetes, helm and
# kubectl providers) would point a mutation past the guard at another cluster.
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(HELM|KUBE)_' || true)
export HELM_CACHE_HOME="$W/helm/cache" HELM_CONFIG_HOME="$W/helm/config" HELM_DATA_HOME="$W/helm/data"
# The *_HOME variables only set defaults; these are every other path `helm env`
# (v4.3.0) lists, set explicitly so nothing derives from anywhere else.
export HELM_REPOSITORY_CONFIG="$HELM_CONFIG_HOME/repositories.yaml" \
  HELM_REGISTRY_CONFIG="$HELM_CONFIG_HOME/registry/config.json" \
  HELM_REPOSITORY_CACHE="$HELM_CACHE_HOME/repository" \
  HELM_CONTENT_CACHE="$HELM_CACHE_HOME/content" \
  HELM_PLUGINS="$HELM_DATA_HOME/plugins"

# Timeouts, in seconds unless a kubectl/flux duration.
T_TERRAFORM="${T_TERRAFORM:-15m}"
T_BASE="${T_BASE:-5m}"
T_KLIQUE="${T_KLIQUE:-40m}"
T_PROBE_SECONDS="${T_PROBE_SECONDS:-300}"
}

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# xtrace would print every expanded command, secrets included.
no_xtrace() {
  case $- in *x*) die "refusing to run with 'set -x': it would print secret values" ;; esac
}

require_tools() {
  local t missing=()
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (scripts/install-tools.sh installs flux and cloud-provider-kind)"
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER"
}

# The one check before every mutation. Fails closed.
guard() {
  cluster_exists || die "guard: kind cluster '$CLUSTER' does not exist"
  [[ -f $KUBECONFIG ]] || die "guard: harness kubeconfig $KUBECONFIG missing"
  [[ $(kubectl config view -o jsonpath='{.contexts[*].name}') == "$CONTEXT" ]] ||
    die "guard: $KUBECONFIG must hold exactly one context, '$CONTEXT'"
  local ctx server
  ctx="$(kubectl config current-context 2>/dev/null)" || die "guard: no current-context in $KUBECONFIG"
  [[ $ctx == "$CONTEXT" ]] || die "guard: current-context is '$ctx', expected '$CONTEXT'"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  [[ $server == https://127.0.0.1:* ]] || die "guard: '$CONTEXT' points at '$server', not a local kind apiserver"
}

# Every kubectl/flux call names the context explicitly too, belt and braces.
k() { kubectl --context "$CONTEXT" "$@"; }
fx() { flux --context "$CONTEXT" "$@"; }

# kubectl wait fails at once on an object that does not exist yet; Flux creates
# most of what we wait for, so poll for existence first.
wait_exists() { # <timeout-seconds> <kubectl get args...>
  local deadline=$((SECONDS + $1))
  shift
  until k get "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || die "timed out waiting for: kubectl get $*"
    sleep 5
  done
}

# A credential file must be the user's own and private: it is the only place a
# value is kept.
check_private_file() { # <path> <what it is>
  local f=$1 what=$2 mode owner
  [[ -f $f ]] || die "$what not found at $f (see tests/kind-e2e/README.md, 'Credentials')"
  # GNU stat (-c) on Linux, BSD stat (-f) on macOS.
  mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")"
  owner="$(stat -c '%u' "$f" 2>/dev/null || stat -f '%u' "$f")"
  [[ $owner == "$(id -u)" ]] || die "$f must be owned by you"
  [[ $mode == 600 || $mode == 400 ]] || die "$f has mode $mode; run: chmod 600 $f"
}

# load_kv_env <file> <key>...: parses the listed KEYs from <file> into shell
# variables of the same name, with `read`, never `source`, so the file cannot
# run code and no other variable leaks in. Format (README): KEY=value per line,
# no `export`, no comment after a value, at most one pair of matching quotes
# around it. Errors name the line number, never the value, and never text that
# might be one (a token pasted without its KEY=).
load_kv_env() {
  local file=$1 line key val n=0 where k allowed="" ok only
  shift
  for k in "$@"; do
    printf -v "$k" '%s' ""
    allowed+="${allowed:+ and }$k"
  done
  ((${#} == 1)) && only="only $1 is allowed" || only="only $allowed are allowed"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    where="$file line $n"
    line="${line%$'\r'}" # a file saved with CRLF line ends
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^[[:space:]]*export[[:space:]] ]] && die "$where: drop the 'export' (format: KEY=value)"
    [[ $line == *=* ]] || die "$where: not KEY=value"
    key="${line%%=*}"
    val="${line#*=}"
    ok=""
    for k in "$@"; do [[ $key == "$k" ]] && ok=1; done
    [[ -n $ok ]] || die "$where: unknown key ($only)"
    if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ $val == [\"\']* || $val == *[\"\'] ]]; then
      die "$where: unbalanced quote around the value"
    elif [[ $val =~ ^[[:space:]] || $val =~ [[:space:]]$ ]]; then
      die "$where: whitespace before or after the value (quote the value if it is meant)"
    elif [[ $val =~ [[:space:]]# ]]; then
      die "$where: no comments after a value (quote the value if it really contains ' #')"
    fi
    printf -v "$key" '%s' "$val"
  done <"$file"
  for k in "$@"; do
    [[ -n ${!k} ]] || die "$file must set $allowed"
  done
}

load_dockerhub_env() { load_kv_env "$DOCKERHUB_ENV" DOCKERHUB_USERNAME DOCKERHUB_PASSWORD; }
load_github_token() { load_kv_env "$GITHUB_TOKEN_FILE" GITHUB_TOKEN; }

# REPO_URL's "<owner>/<repo>" (REPO_URL must be https://github.com/<owner>/<repo>,
# the form Flux and the token check both need).
repo_slug() {
  local slug="${REPO_URL#https://github.com/}"
  slug="${slug%.git}"
  [[ $REPO_URL == https://github.com/* && $slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
    die "KLIQUE_E2E_REPO_URL must be https://github.com/<owner>/<repo> (got $REPO_URL)"
  printf '%s\n' "$slug"
}

# Before `up` creates anything: the token must read the resolved commit $1 of
# REPO_URL's repository through the GitHub API (200). GET /commits/<sha> needs
# Contents: Read; GET /repos/<slug> would pass with the Metadata permission
# every fine-grained token has. The header goes to curl on stdin, never argv.
# GitHub answers 404 for a repository the token cannot see, 403 for a missing
# permission, and 422 for a commit the repository does not have.
check_github_token() { # <commit sha>
  local slug code
  slug="$(repo_slug)" || exit 1
  [[ $GITHUB_TOKEN =~ ^[A-Za-z0-9_]+$ ]] ||
    die "$GITHUB_TOKEN_FILE: GITHUB_TOKEN has characters a GitHub token never has (value not shown)"
  [[ $1 =~ ^[0-9a-f]{7,40}$ ]] || die "unexpected commit '$1' when checking the GitHub token"
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
    curl -sS -o /dev/null -w '%{http_code}' --max-time 30 --config - "https://api.github.com/repos/$slug/commits/$1")" ||
    die "could not reach api.github.com to check the GitHub token"
  case $code in
    200) info "GitHub token can read commit ${1:0:12} of $slug" ;;
    401 | 403 | 404) die "GitHub answered HTTP $code for commit ${1:0:12} of $slug: the token is invalid or expired, not approved by the org, cannot see $slug, or lacks Contents: Read-only on it ($GITHUB_TOKEN_FILE)" ;;
    422) die "commit ${1:0:12} not found in $slug: push it first (the harness never pushes), and check KLIQUE_E2E_REPO_URL" ;;
    *) die "GitHub answered HTTP $code for commit ${1:0:12} of $slug when checking the token" ;;
  esac
}

# Runs `bao` inside the OpenBao pod (openbao-0 of the chart's StatefulSet).
# The chart's dev mode puts the run's root token in the container environment
# (VAULT_DEV_ROOT_TOKEN_ID) and BAO_ADDR next to it, so the token is read there
# and never travels back to this host. stdin is passed only when piped, so a
# call without input never waits on the terminal.
bao() {
  local i=()
  [[ -p /dev/stdin ]] && i=(-i)
  # The single quotes are deliberate: $VAULT_DEV_ROOT_TOKEN_ID and "$@" expand
  # inside the pod.
  # shellcheck disable=SC2016
  k -n openbao exec "${i[@]}" openbao-0 -c openbao -- sh -c \
    'BAO_TOKEN="$VAULT_DEV_ROOT_TOKEN_ID" exec bao "$@"' bao "$@"
}
