#!/usr/bin/env bash
# Installs the pinned check and test tools used by this repo (scripts/check.sh runs the checks,
# tests/kind-e2e/ uses the rest). No sudo: everything lands in INSTALL_DIR.
#
# Versions are pinned so a check that passes here passes for the next person. Bump a pin
# deliberately, re-run, and fix what the newer tool reports.
#
# Usage: scripts/install-tools.sh            # installs into ~/.local/bin
#        INSTALL_DIR=/some/bin scripts/install-tools.sh
set -euo pipefail

TFLINT_VERSION=0.65.0
KUBECONFORM_VERSION=0.8.0
FLUX_VERSION=2.10.0
CRANE_VERSION=0.22.1
CLOUD_PROVIDER_KIND_VERSION=0.12.0
YAMLLINT_VERSION=1.38.0
SHELLCHECK_VERSION=0.11.0

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
# yamllint is Python; a private venv keeps it off the system interpreter's site-packages.
YAMLLINT_VENV="${YAMLLINT_VENV:-${XDG_DATA_HOME:-$HOME/.local/share}/gitops-reference/yamllint-venv}"

case "$(uname -s)" in
  Linux) os=linux; Os=Linux ;;
  Darwin) os=darwin; Os=Darwin ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64; arch_x=x86_64 ;;
  aarch64 | arm64) arch=arm64; arch_x=arm64 ;;
  *) echo "unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac

for cmd in curl tar unzip python3; do
  command -v "$cmd" >/dev/null || { echo "missing prerequisite: $cmd" >&2; exit 1; }
done
if command -v sha256sum >/dev/null; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
else
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

mkdir -p "$INSTALL_DIR"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Idempotency: a tool is skipped when its own --version output names the pinned version as a whole
# token, so 1.0.0 is not satisfied by 11.0.0 or 1.0.0-rc.1.
have_version() { # <binary> <version> <version-args...>
  local bin="$1" want="$2" out
  shift 2
  [[ -x "$INSTALL_DIR/$bin" ]] || return 1
  # Captured first: `grep -q` closing the pipe early would SIGPIPE the tool and fail under pipefail.
  out="$("$INSTALL_DIR/$bin" "$@" 2>&1)" || return 1
  local esc="${want//./\\.}"
  [[ "$out" =~ (^|[^0-9A-Za-z.])${esc}($|[^0-9A-Za-z+.-]|\.($|[^0-9])) ]]
}

# Downloads <asset> and <checksum-file> from <base-url>, refuses to continue unless the SHA-256
# matches the project's published checksum, then extracts into "$work/<bin>/".
fetch_verified() { # <bin> <base-url> <asset> <checksum-file>
  local bin="$1" base="$2" asset="$3" sums="$4" want got dir="$work/$1"
  mkdir -p "$dir"
  curl -fsSL --retry 3 -o "$dir/$asset" "$base/$asset"
  curl -fsSL --retry 3 -o "$dir/$sums" "$base/$sums"
  want="$(awk -v a="$asset" '$2 == a || $2 == "*" a {print $1}' "$dir/$sums")"
  [[ -n "$want" ]] || { echo "$asset not listed in $sums" >&2; exit 1; }
  got="$(sha256 "$dir/$asset")"
  [[ "$got" == "$want" ]] || { echo "checksum mismatch for $asset" >&2; exit 1; }
  case "$asset" in
    *.zip) unzip -q -o "$dir/$asset" -d "$dir/x" ;;
    *) mkdir -p "$dir/x" && tar -xzf "$dir/$asset" -C "$dir/x" ;;
  esac
}

install_release() { # <bin> <version> <base-url> <asset> <checksum-file> <version-args...>
  local bin="$1" version="$2" base="$3" asset="$4" sums="$5"
  shift 5
  if have_version "$bin" "$version" "$@"; then
    echo "ok       $bin $version (already installed)"
    return
  fi
  fetch_verified "$bin" "$base" "$asset" "$sums"
  install -m 0755 "$work/$bin/x/$bin" "$INSTALL_DIR/$bin"
  echo "installed $bin $version"
}

gh_dl() { echo "https://github.com/$1/releases/download/v$2"; }

install_release tflint "$TFLINT_VERSION" "$(gh_dl terraform-linters/tflint "$TFLINT_VERSION")" \
  "tflint_${os}_${arch}.zip" checksums.txt --version

install_release kubeconform "v$KUBECONFORM_VERSION" "$(gh_dl yannh/kubeconform "$KUBECONFORM_VERSION")" \
  "kubeconform-${os}-${arch}.tar.gz" CHECKSUMS -v

install_release flux "$FLUX_VERSION" "$(gh_dl fluxcd/flux2 "$FLUX_VERSION")" \
  "flux_${FLUX_VERSION}_${os}_${arch}.tar.gz" "flux_${FLUX_VERSION}_checksums.txt" --version

# crane's release assets use capitalised OS and x86_64 naming, unlike the others.
install_release crane "$CRANE_VERSION" "$(gh_dl google/go-containerregistry "$CRANE_VERSION")" \
  "go-containerregistry_${Os}_${arch_x}.tar.gz" checksums.txt version

install_release cloud-provider-kind "$CLOUD_PROVIDER_KIND_VERSION" \
  "$(gh_dl kubernetes-sigs/cloud-provider-kind "$CLOUD_PROVIDER_KIND_VERSION")" \
  "cloud-provider-kind_${CLOUD_PROVIDER_KIND_VERSION}_${os}_${arch}.tar.gz" \
  "cloud-provider-kind_${CLOUD_PROVIDER_KIND_VERSION}_checksums.txt" version

# The shellcheck project publishes no checksum file, so the SHA-256 of each supported archive is pinned here,
# taken from the real v0.11.0 .tar.xz assets (re-hash them when bumping SHELLCHECK_VERSION).
case "$os-$arch" in
  linux-amd64) shellcheck_sha=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
  linux-arm64) shellcheck_sha=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
  darwin-amd64) shellcheck_sha=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6 ;;
  darwin-arm64) shellcheck_sha=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
esac
if have_version shellcheck "$SHELLCHECK_VERSION" --version; then
  echo "ok       shellcheck $SHELLCHECK_VERSION (already installed)"
else
  # Only needed here: shellcheck ships as .tar.xz, and stock macOS tar reads it without xz.
  if [[ "$os" == linux ]]; then
    command -v xz >/dev/null || { echo "missing prerequisite: xz" >&2; exit 1; }
  fi
  sc_asset="shellcheck-v${SHELLCHECK_VERSION}.${os}.${arch_x/arm64/aarch64}.tar.xz"
  mkdir -p "$work/shellcheck"
  curl -fsSL --retry 3 -o "$work/shellcheck/$sc_asset" \
    "$(gh_dl koalaman/shellcheck "$SHELLCHECK_VERSION")/$sc_asset"
  [[ "$(sha256 "$work/shellcheck/$sc_asset")" == "$shellcheck_sha" ]] \
    || { echo "checksum mismatch for $sc_asset" >&2; exit 1; }
  tar -xJf "$work/shellcheck/$sc_asset" -C "$work/shellcheck"
  install -m 0755 "$work/shellcheck/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$INSTALL_DIR/shellcheck"
  echo "installed shellcheck $SHELLCHECK_VERSION"
fi

# yamllint and its two dependencies are installed with --require-hashes from a pinned list, so a
# tampered or substituted PyPI file is rejected.
if have_version yamllint "$YAMLLINT_VERSION" --version; then
  echo "ok       yamllint $YAMLLINT_VERSION (already installed)"
else
  python3 -c 'import venv, ensurepip' 2>/dev/null || {
    echo "python3 venv support is missing (Debian/Ubuntu: apt install python3-venv)" >&2
    exit 1
  }
  python3 -m venv --clear "$YAMLLINT_VENV"
  "$YAMLLINT_VENV/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes -r "$(dirname "${BASH_SOURCE[0]}")/yamllint-requirements.txt"
  ln -sf "$YAMLLINT_VENV/bin/yamllint" "$INSTALL_DIR/yamllint"
  echo "installed yamllint $YAMLLINT_VERSION"
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "note: $INSTALL_DIR is not on PATH" >&2 ;;
esac
