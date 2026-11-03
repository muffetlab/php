#!/usr/bin/env bash
# Resolve the immutable digest of every manifest's base image and print the
# exact BASE_IMAGE line to paste into it.
#
# Why this exists: the source pins in manifests/*.env are filled in, but a base
# image digest can only be resolved against the registry, and a review machine
# does not always have registry or Docker access. This is the CI-side half of
# filling a manifest.
#
# What it deliberately does NOT do: it never edits a manifest. A digest is a
# security-relevant pin -- the same class of decision as PHP_SRC_COMMIT -- so a
# human moves it from this output into the manifest and commits that change.
# Auto-editing would let a re-run silently repoint every image at a new base.
#
# Usage:
#   tools/resolve-base-digest.sh                  # every manifest
#   tools/resolve-base-digest.sh 5.6 8.1          # only these versions
#   tools/resolve-base-digest.sh --check          # CI drift report, never fails
#   tools/resolve-base-digest.sh --base debian:trixie-slim   # any tag, for a trial
#   tools/resolve-base-digest.sh --base debian:trixie-slim --value   # the ref alone, for CI
#
# Exit codes:
#   0  every requested manifest resolved (drift is reported, not an error)
#   1  a manifest is missing/malformed, or a digest could not be resolved
#
# --check reports drift as GitHub annotations (::warning::) and stays green: a
# base digest that has moved is a review prompt, not a broken pipeline.
#
# --base answers the question a base *change* raises: a manifest already carries a
# digest, so filling it in is a paste; trying a different Debian release needs the
# digest of a tag nothing here names yet. It prints the same paste-ready line for
# that tag and writes nothing -- which is also what build.sh's BASE_IMAGE_OVERRIDE
# consumes, so a trial is pinned exactly like a release.
#
# --value goes with --base and prints only the digest-pinned image reference, for a
# CI job that has to capture it as a value instead of reading a human's paste block.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=0
BASE_ARG=""
VALUE_ONLY=0
REQUESTED=()

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --base) BASE_ARG="${2:?--base needs an image tag, e.g. debian:trixie-slim}"; shift ;;
    --value) VALUE_ONLY=1 ;;
    -h|--help)
      # Everything from the summary line to the last comment before the script
      # body, stripped of its leading "# ". Bounded by the first executable line
      # rather than a line number, so documenting a new flag cannot silently cut
      # the help short.
      sed -n '2,/^set -Eeuo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^#[[:space:]]\{0,1\}//'
      exit 0
      ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) REQUESTED+=("$1") ;;
  esac
  shift
done

if [ "$VALUE_ONLY" = 1 ] && [ -z "$BASE_ARG" ]; then
  echo "--value only means something with --base (it prints that tag's digest-pinned reference and nothing else)" >&2
  exit 1
fi

SUPPORTED_VERSIONS="5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1"

if [ ${#REQUESTED[@]} -eq 0 ]; then
  # shellcheck disable=SC2206
  REQUESTED=(${SUPPORTED_VERSIONS})
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required: digests can only be resolved against the registry." >&2
  echo "Run this in CI (the build-and-verify runner) and paste the output into the" >&2
  echo "manifests by hand." >&2
  exit 1
fi

if ! docker buildx version >/dev/null 2>&1; then
  echo "docker buildx is required for 'imagetools inspect' (it queries the registry" >&2
  echo "without pulling, and needs no daemon state for the image itself)." >&2
  exit 1
fi

# Ask the registry what a tag currently resolves to. Multi-arch bases must be
# pinned by the *index* digest: pinning a single-platform manifest digest would
# silently narrow every image built from it to one architecture, so the value
# taken here is the top-level "Digest:" line buildx prints for the tag.
# Requires 64 lowercase hex and takes only the first match -- an unparseable or
# truncated response fails loudly instead of producing a bogus pin.
resolve_digest() {
  local name="$1"
  docker buildx imagetools inspect "$name" 2>/dev/null \
    | sed -n 's/^Digest:[[:space:]]*sha256:\([0-9a-f]\{64\}\)[[:space:]]*$/\1/p' \
    | head -1
}

failures=0

# --base: one tag, no manifests involved. This is the trial path -- the digest a
# human needs before build.sh's BASE_IMAGE_OVERRIDE can be pinned, or the value to
# paste into a manifest once the trial says the base is worth taking.
if [ -n "$BASE_ARG" ]; then
  case "$BASE_ARG" in
    *@sha256:*) echo "--base wants a tag, not a digest ('${BASE_ARG}'): the digest is what this resolves." >&2; exit 1 ;;
  esac
  resolved="$(resolve_digest "$BASE_ARG")"
  if [ -z "$resolved" ]; then
    echo "could not resolve a digest for ${BASE_ARG} (registry unreachable, or the tag does not exist)" >&2
    echo "     Run this where the registry is reachable -- a CI runner, or a machine with a" >&2
    echo "     working proxy. Nothing here falls back to the tag itself: an unpinned trial is" >&2
    echo "     a trial whose result cannot be reproduced." >&2
    exit 1
  fi
  # --value: the one thing a CI job needs to capture, and nothing else. Kept
  # separate from the paste block so a caller can read the variable out of
  # stdout without parsing prose -- and so the gate above (a 64-hex digest, or
  # failure) is the same gate a human sees.
  if [ "$VALUE_ONLY" = 1 ]; then
    printf '%s@sha256:%s\n' "$BASE_ARG" "$resolved"
    exit 0
  fi
  echo "${BASE_ARG} currently resolves to sha256:${resolved}"
  echo "Paste-ready (for a manifest, or for BASE_IMAGE_OVERRIDE in a trial build):"
  echo "    BASE_IMAGE=\"${BASE_ARG}@sha256:${resolved}\""
  echo
  echo "Trial it against one series without touching any reviewed pin:"
  echo "    BASE_IMAGE_OVERRIDE=\"${BASE_ARG}@sha256:${resolved}\" ./build.sh 8.1 cli"
  echo "then run ./tools/scan-image.sh on the result and compare its CVE count with"
  echo "the same series on the current base. The manifest change is the step that"
  echo "stays human."
  exit 0
fi
printf 'Base image digest resolution\n'
printf '  mode: %s\n' "$([ "$CHECK" = 1 ] && echo '--check (CI drift report)' || echo 'fill (paste-ready output)')"
printf '  note: digests are printed, never written. Filling a manifest is a human commit.\n\n'

for ver in "${REQUESTED[@]}"; do
  case " ${SUPPORTED_VERSIONS} " in
    *" ${ver} "*) ;;
    *)
      echo "${ver}: unsupported version (allowed: ${SUPPORTED_VERSIONS})" >&2
      failures=1
      continue
      ;;
  esac
  manifest="${ROOT}/manifests/${ver}.env"
  if [ ! -f "$manifest" ]; then
    echo "${ver}: no manifest at ${manifest}" >&2
    failures=1
    continue
  fi

  # Trusted project config, not untrusted input. A subshell keeps one manifest's
  # values from leaking into the next.
  if ! (
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    . "$manifest"
    base="${BASE_IMAGE:-}"
    repo="${base%%@sha256:*}"
    current="${base#*@sha256:}"
    if [ -z "$repo" ] || [ "$repo" = "$base" ]; then
      echo "${ver}: BASE_IMAGE is not in repo@sha256:<digest> form ('${base}')" >&2
      exit 1
    fi

    resolved="$(resolve_digest "$repo")"
    if [ -z "$resolved" ]; then
      echo "${ver}: could not resolve a digest for ${repo} (registry unreachable, or the tag does not exist)" >&2
      exit 1
    fi

    if [ "$current" = "$resolved" ]; then
      echo "${ver}: ${repo} -- manifest digest is current (${resolved})."
      exit 0
    fi

    if [ -z "$current" ] || [ "$current" = "REPLACE_WITH_DIGEST" ]; then
      if [ "$CHECK" = 1 ]; then
        echo "::warning::${ver}: BASE_IMAGE is still a placeholder. Fill it with ${repo}@sha256:${resolved}"
      else
        echo "${ver}: unfilled -- paste this line into manifests/${ver}.env:"
        echo "    BASE_IMAGE=\"${repo}@sha256:${resolved}\""
      fi
      exit 0
    fi

    # A real digest that no longer matches what the tag serves. The pinned
    # digest is immutable and still builds -- what has moved is the tag -- so
    # this is "decide whether to follow", never an error.
    if [ "$CHECK" = 1 ]; then
      echo "::warning::${ver}: ${repo} now resolves to ${resolved}, the manifest pins ${current}. The pinned digest still builds; following the tag is a reviewed change -- rebuild, re-run the verification suite and record it in manifests/SECURITY-REVIEW.md."
    else
      echo "${ver}: DRIFT in ${repo}"
      echo "    manifest pins: ${current}"
      echo "    tag resolves:  ${resolved}"
      echo "    (the manifest value stays valid; change it only after review)"
    fi
  ); then
    failures=1
  fi
done

if [ "$failures" = 1 ] && [ "$CHECK" != 1 ]; then
  exit 1
fi
exit 0
