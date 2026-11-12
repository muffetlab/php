#!/usr/bin/env bash
# Report how far each manifest's pinned source commit trails the upstream tag
# it was taken from.
#
# The pins are deliberately immutable: a manifest names a 40-character commit,
# never a branch head, and the build checks that commit out by SHA. That is the
# right default -- but it also means a series silently stops receiving fixes
# once the maintainer retags. This script is the alarm for that.
#
# It is a *report*, not a gate: it compares each pin to the current value of the
# same ref and prints the gap. It never fails a pipeline and never rewrites a
# manifest, because deciding to move a pin means re-reviewing the patchset that
# comes with it (see manifests/SECURITY-REVIEW.md).
#
# Comparison method: `git ls-remote` only. It asks the remote for one ref's SHA
# without cloning, so this is cheap enough to run on every CI build, and it
# reads the same refs the build would fetch.
#
# Usage:
#   tools/check-pin-drift.sh                # every manifest
#   tools/check-pin-drift.sh 5.6 8.1        # only these versions
#   tools/check-pin-drift.sh --quiet        # print drift only
#
# Exit code is always 0 for a completed run, including when drift is found.
# Network failure exits 1 with a message: "cannot tell" is not "no drift".
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUIET=0
REQUESTED=()

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    -h|--help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
      exit 0
      ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) REQUESTED+=("$1") ;;
  esac
  shift
done

SUPPORTED_VERSIONS="5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1"

if [ ${#REQUESTED[@]} -eq 0 ]; then
  # shellcheck disable=SC2206
  REQUESTED=(${SUPPORTED_VERSIONS})
fi

command -v git >/dev/null 2>&1 || { echo "git is required for ls-remote." >&2; exit 1; }

# ls-remote with a fixed, modest timeout so a black-holed connection cannot hang
# a CI job indefinitely. git honours the curl alarm only with these set.
#
# The ref to compare is the *peeled* one. These release tags are annotated, so
# ls-remote prints two lines: refs/tags/<ref> is the tag OBJECT's SHA and
# refs/tags/<ref>^{} is the commit it points at. The manifests pin commits --
# the build checks out PHP_SRC_COMMIT by SHA -- so comparing against the tag
# object SHA would report drift on all eight versions and be meaningless. --refs
# is deliberately NOT used: it suppresses the ^{} lines entirely.
remote_sha() {
  local repo="$1" ref="$2" listing
  listing="$(GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
    git ls-remote --tags "$repo" "refs/tags/${ref}" "refs/tags/${ref}^{}" 2>/dev/null)" || {
    printf ''
    return
  }
  # Prefer the peeled commit; fall back to the tag line only for a lightweight
  # tag, where there is no peeled ref and the tag names a commit directly.
  printf '%s\n' "$listing" \
    | awk -v commit="refs/tags/${ref}^{}" -v tag="refs/tags/${ref}" '
        $2 == commit { peeled = $1 }
        $2 == tag    { direct = $1 }
        END          { print (peeled != "" ? peeled : direct) }'
}

[ "$QUIET" = 1 ] || printf 'Source pin drift report\n  compares PHP_SRC_COMMIT with the current tip of SOURCE_REF on PHP_SRC_REPO\n  advisory only: nothing here fails a build or edits a manifest\n\n'

for ver in "${REQUESTED[@]}"; do
  case " ${SUPPORTED_VERSIONS} " in
    *" ${ver} "*) ;;
    *) echo "${ver}: unsupported version (allowed: ${SUPPORTED_VERSIONS})" >&2; exit 1 ;;
  esac
  manifest="${ROOT}/manifests/${ver}.env"
  [ -f "$manifest" ] || { echo "${ver}: no manifest" >&2; exit 1; }

  if ! (
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    . "$manifest"
    repo="${PHP_SRC_REPO:-}"
    ref="${SOURCE_REF:-}"
    pin="${PHP_SRC_COMMIT:-}"

    # An unfilled manifest has nothing to compare; say so and move on rather
    # than failing over a template string.
    case "$pin$ref" in
      *REPLACE_WITH*)
        echo "${ver}: source pin is still a template placeholder -- nothing to compare"
        exit 0 ;;
    esac

    # Same rule build.sh enforces: lowercase, exactly 40 hex. Accepting mixed
    # case here would let a manifest pass a check the build then rejects.
    case "$pin" in
      *[!0-9a-f]*|"")
        echo "${ver}: PHP_SRC_COMMIT is not a lowercase hex SHA ('${pin}') -- cannot compare" >&2
        exit 1 ;;
    esac
    if [ ${#pin} -ne 40 ]; then
      echo "${ver}: PHP_SRC_COMMIT must be a full 40-character SHA ('${pin}')" >&2
      exit 1
    fi
    [ -n "$repo" ] && [ -n "$ref" ] || { echo "${ver}: PHP_SRC_REPO/SOURCE_REF unset" >&2; exit 1; }

    current="$(remote_sha "$repo" "$ref")"
    if [ -z "$current" ]; then
      echo "${ver}: cannot reach ${repo} for tag ${ref} (offline, or the tag was removed)" >&2
      exit 1
    fi

    # Tag SHAs from ls-remote are lowercase, and build.sh already requires a
    # lowercase 40-hex pin, so compare strings directly -- normalising case here
    # would only hide a manifest that violates the build's own rule.
    if [ "$pin" = "$current" ]; then
      [ "$QUIET" = 1 ] || echo "${ver}: in sync -- tag ${ref} == ${pin}"
      exit 0
    fi

    echo "${ver}: DRIFT -- ${ref} points at ${current}, this manifest pins ${pin}"
    echo "        ${repo}"
    echo "        Moving PHP_SRC_COMMIT means a new review record: the commits between"
    echo "        the two SHAs are the patchset being accepted, so diff them, update"
    echo "        manifests/SECURITY-REVIEW.md, and set PATCHSET_APPROVED=1 again."
  ); then
    # One unreachable remote must not read as "no drift", but it is also not a
    # build failure: report loudly and keep going over the remaining versions.
    echo "::warning::${ver}: pin drift could not be determined (see message above)" >&2
  fi
done
exit 0
