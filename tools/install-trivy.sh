#!/usr/bin/env bash
# Install the trivy binary that tools/scan-image.sh uses, at a reviewed version and
# (once filled) a reviewed SHA-256.
#
# Why a tool instead of a third-party Action: the OS CVE gate reaches its verdict
# through the Debian suite and this repository's register, and trivy is only one of
# its inputs -- so trivy is fetched the way this kit fetches everything it executes:
# a pinned version, a pinned digest, a checksum verified before anything runs. The
# Composer installer in the Dockerfile is handled the same way.
#
# An empty pin must not buy a quiet pass: while a placeholder stood empty, this tool
# warned and exited 0 and the OS gate ran with no scanner at all. The pins carry real
# digests and scan-image.sh verdicts an unscanned run `unverified` and exits 1, so the
# convention this tool shares with tools/resolve-base-digest.sh (the machine resolves,
# a human reviews and commits the value, CI says so out loud) never trades a missing
# value for a silent pass.
#
# Usage:
#   tools/install-trivy.sh            # install, or report that a pin is missing
#   tools/install-trivy.sh --print-pin  # only print the paste-ready lines
#
# Exit: 0 = trivy usable, or a pin is missing and that has been reported.
#       1 = a download/verification failure (the pinned digest did not match).
#       2 = unsupported platform.
set -uo pipefail

TRIVY_VERSION="0.76.1"
# Paste-ready: fill from `tools/install-trivy.sh --print-pin`, run where GitHub is
# reachable (a CI runner). 64 lowercase hex or empty; anything else is rejected.
#
# Filled from upstream's own trivy_0.76.1_checksums.txt; each of the four assets
# below was downloaded and `shasum -a 256`-checked against that line -- so these are
# digests of the bytes the kit will execute, not of a table someone copied.
TRIVY_SHA256_LINUX_AMD64="c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0"
TRIVY_SHA256_LINUX_ARM64="e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f"
TRIVY_SHA256_DARWIN_ARM64="11a9b6cd2752011b54f01ea4bd0dbfa9f0c41dc6538d5a3f9d23955f471bf4e5"
TRIVY_SHA256_DARWIN_AMD64="7aa762eacd582052d053b62dcf972a1ab058abe39a57ccae234ed8894945b6b7"

sha256_of() { # macOS ships no sha256sum; the harness uses the same fallback
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f1
  else shasum -a 256 "$1" | cut -d ' ' -f1; fi
}

PRINT_PIN=0
[ "${1:-}" = "--print-pin" ] && PRINT_PIN=1

arch="$(uname -m)"
os="$(uname -s)"
case "$os/$arch" in
  Linux/x86_64)  ASSET="Linux-64bit";  PIN="$TRIVY_SHA256_LINUX_AMD64" ;;
  Linux/aarch64) ASSET="Linux-ARM64";  PIN="$TRIVY_SHA256_LINUX_ARM64" ;;
  Darwin/arm64)  ASSET="macOS-ARM64";  PIN="$TRIVY_SHA256_DARWIN_ARM64" ;;
  Darwin/x86_64) ASSET="macOS-64bit";  PIN="$TRIVY_SHA256_DARWIN_AMD64" ;;
  *) echo "install-trivy: unsupported platform $os/$arch" >&2; exit 2 ;;
esac
BASE_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${ASSET}.tar.gz"
SUMS_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt"

if command -v trivy >/dev/null 2>&1; then
  found="$(trivy --version 2>/dev/null | sed -n 's/^Version: //p' | head -1)"
  if [ "$found" = "$TRIVY_VERSION" ]; then
    echo "install-trivy: trivy ${found} already on PATH"
    exit 0
  fi
  echo "install-trivy: trivy ${found:-unknown} on PATH, this kit pins ${TRIVY_VERSION}"
  echo "               scan-image.sh will use the one on PATH and say so in its report"
  exit 0
fi

if [ "$PRINT_PIN" = "1" ]; then
  sums="$(curl -sSL --fail --retry 5 --retry-delay 3 --retry-all-errors --max-time 120 "$SUMS_URL")" \
    || { echo "install-trivy: could not fetch $SUMS_URL" >&2; exit 1; }
  echo "# Paste these into tools/install-trivy.sh (version ${TRIVY_VERSION}):"
  for a in Linux-64bit Linux-ARM64 macOS-ARM64 macOS-64bit; do
    line="$(printf '%s\n' "$sums" | grep -E "trivy_${TRIVY_VERSION}_${a}\.tar\.gz$" | head -1)"
    [ -n "$line" ] || { echo "::warning::checksums file has no ${a} asset"; continue; }
    var="TRIVY_SHA256_$(printf '%s' "$a" | tr 'a-z-' 'A-Z_')"
    echo "# ${var}=\"${line%% *}\"   # ${a}"
  done
  exit 0
fi

if [ -z "$PIN" ]; then
  echo "::warning::no SHA-256 pinned for trivy ${TRIVY_VERSION} on ${os}/${arch}; the OS CVE gate runs without trivy on this runner"
  echo "    Fill it in CI (where GitHub is reachable) with:"
  echo "        ./tools/install-trivy.sh --print-pin"
  echo "    and commit the printed line. scan-image.sh will still report the Debian"
  echo "    inventory and the suite's currency -- which is the part that catches a fix"
  echo "    this kit could have taken and did not -- but its verdict is then"
  echo "    \`unverified\`, not \`clean\`, and the job fails: an image nobody scanned is"
  echo "    not an image that is free of CVEs."
  exit 0
fi
case "$PIN" in
  *[!0-9a-f]*|'') echo "install-trivy: pinned SHA-256 for ${ASSET} is not 64 lowercase hex: '${PIN}'" >&2; exit 2 ;;
esac
[ "${#PIN}" = "64" ] || { echo "install-trivy: pinned SHA-256 for ${ASSET} must be 64 characters, got ${#PIN}" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
if ! curl -sSL --fail --retry 5 --retry-delay 3 --retry-all-errors --max-time 300 -o "$work/trivy.tar.gz" "$BASE_URL"; then
  echo "install-trivy: download failed: $BASE_URL" >&2
  exit 1
fi
got="$(sha256_of "$work/trivy.tar.gz")"
if [ "$got" != "$PIN" ]; then
  echo "install-trivy: trivy ${TRIVY_VERSION} ${ASSET} does not match its pinned digest" >&2
  echo "   expected ${PIN}" >&2
  echo "   actual   ${got}" >&2
  echo "   Upstream rotated the asset, or the download came from somewhere else. Refusing" >&2
  echo "   to run it. Re-review with --print-pin and commit the new digest if upstream's own" >&2
  echo "   checksums file agrees with it." >&2
  exit 1
fi
tar -xzf "$work/trivy.tar.gz" -C "$work" trivy

# Install where we can, then prove the binary is where the *next* step's PATH will
# find it. The old shape of this block trusted `mkdir -p` alone: a directory that
# exists but is not writable passes that test, `install` then fails, and because this
# script has no `set -e` it fell through to its own success line -- a log saying trivy
# was installed and a runner with no trivy on PATH.
install_to() { # $1 = candidate directory
  mkdir -p "$1" 2>/dev/null || return 1
  install -m 0755 "$work/trivy" "$1/trivy" 2>/dev/null || return 1
  [ -x "$1/trivy" ] || return 1
  return 0
}
dest=""
for candidate in "${TRIVY_INSTALL_DIR:-/usr/local/bin}" "${HOME}/.local/bin" "${HOME}/bin"; do
  [ -n "$candidate" ] || continue
  if install_to "$candidate"; then dest="$candidate"; break; fi
done
[ -n "$dest" ] || { echo "install-trivy: no writable install directory (tried TRIVY_INSTALL_DIR, /usr/local/bin, ~/.local/bin, ~/bin)" >&2; exit 1; }

found_version="$("$dest/trivy" --version 2>/dev/null | sed -n 's/^Version: //p' | head -1)"
[ "$found_version" = "$TRIVY_VERSION" ] || {
  echo "install-trivy: the binary installed from the verified tarball reports '${found_version:-nothing}', not ${TRIVY_VERSION}" >&2
  exit 1; }

# scan-image.sh runs in its own step and resolves trivy from PATH, which Actions does
# not carry between steps unless a directory is appended to GITHUB_PATH.
case ":${PATH}:" in
  *":${dest}:"*) ;;
  *) if [ -n "${GITHUB_PATH:-}" ]; then
       printf '%s\n' "$dest" >> "$GITHUB_PATH"
       echo "install-trivy: prepended $dest for later steps via GITHUB_PATH"
     else
       echo "install-trivy: $dest is not on PATH and there is no GITHUB_PATH to add it to" >&2
       echo "               (set TRIVY_INSTALL_DIR to a directory already on PATH, or run" >&2
       echo "               scan-image.sh with --findings -)" >&2
       exit 1
     fi ;;
esac

echo "install-trivy: trivy ${TRIVY_VERSION} (${ASSET}) verified, installed to $dest/trivy, and it reports Version: ${found_version}"
