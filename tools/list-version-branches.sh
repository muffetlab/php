#!/usr/bin/env bash
# Inventory of every version-conditional branch in the kit.
#
# The single Dockerfile stays readable only if the places where behaviour
# depends on the PHP series are enumerable. Each such place carries a marker
# comment of the form
#
#     # version-branch: <tag>
#     // version-branch: <tag>      (inside the PHP code in tests/extensions.sh)
#
# and every tag must have exactly one row in the MAINTAINING.md table under
# "Version-conditional behaviour". CI runs this script in both directions:
# a tag with no row, or a row with no tag, fails the gate. That is what stops
# someone adding `case "${PHP_VERSION}" in 5.6) ...` and nobody ever documenting
# that 5.6 is special.
#
# Usage:
#   tools/list-version-branches.sh            human-readable inventory
#   tools/list-version-branches.sh --tags     one tag per line (sorted, unique)
#   tools/list-version-branches.sh --check    compare against MAINTAINING.md, exit 1 on drift
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${ROOT}/MAINTAINING.md"

# Scanned files. Deliberately explicit rather than a repo-wide grep: a marker is
# a contract, and the set of files that may contain build behaviour is known.
SCAN=(
  Dockerfile
  build.sh
  tools/verify-build.sh
  tools/verify-runtime.sh
  tools/gen-supported.sh
  tests/smoke.sh
  tests/extensions.sh
  tests/composer.sh
  tests/verify-harness.sh
)

collect() {
  local f rel hits
  for rel in "${SCAN[@]}"; do
    f="${ROOT}/${rel}"
    [[ -f "$f" ]] || { echo "list-version-branches: missing scanned file ${rel}" >&2; exit 2; }
    # Most scanned files legitimately contain no markers, so a non-matching
    # grep is not an error (pipefail would otherwise abort the whole run).
    # A trailing backslash is allowed because Dockerfile markers sit inside RUN
    # line continuations (Docker strips those comment lines before joining).
    hits="$(grep -nE '^[[:space:]]*(#|//)[[:space:]]*version-branch:[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*(\\)?[[:space:]]*$' "$f" || true)"
    [[ -n "$hits" ]] || continue
    while IFS=: read -r ln rest; do
      [[ -n "$ln" ]] || continue
      tag="$(printf '%s' "$rest" | sed -E 's/^[[:space:]]*(#|\/\/)[[:space:]]*version-branch:[[:space:]]*//; s/[[:space:]]*\\?[[:space:]]*$//')"
      printf '%s\t%s:%s\n' "$tag" "$rel" "$ln"
    done <<< "$hits"
  done
}

all_tags() { collect | cut -f1 | LC_ALL=C sort -u; }

# Tags documented in the MAINTAINING.md inventory: rows of the form
#   | `tag` | ... |
# inside the "Version-conditional behaviour" section only.
doc_tag_rows() {
  awk '
    /^## Version-conditional behaviour/ { insec = 1; next }
    insec && /^## /                     { insec = 0 }
    insec && /^\|[[:space:]]*`[A-Za-z0-9._-]+`[[:space:]]*\|/ {
      line = $0
      sub(/^\|[[:space:]]*`/, "", line)
      sub(/`.*$/, "", line)
      print line
    }
  ' "$DOC"
}

doc_tags() { doc_tag_rows | LC_ALL=C sort -u; }

# "<count> <tag>" for tags documented more than once.
doc_tags_all_count() { doc_tag_rows | LC_ALL=C sort | uniq -c | awk '{ print $1, $2 }'; }

case "${1:-}" in
  --tags)
    all_tags
    ;;
  --check)
    # The table moved out of README.md when the consumer docs were split from
    # the maintainer docs, so an absent MAINTAINING.md is a real failure, not a
    # "nothing to compare" case: without it every marker would look undocumented.
    [[ -f "$DOC" ]] || {
      echo "ERROR: inventory document $DOC not found -- the version-branch table has to exist for --check to mean anything." >&2
      exit 1
    }
    marked="$(all_tags)"
    documented="$(doc_tags)"
    rc=0

    undocumented="$(comm -23 <(printf '%s\n' "$marked") <(printf '%s\n' "$documented") | sed '/^$/d' || true)"
    if [[ -n "$undocumented" ]]; then
      echo "ERROR: version-branch tags with no inventory row:" >&2
      while IFS= read -r t; do
        echo "  - $t" >&2
        collect | awk -F'\t' -v t="$t" '$1 == t { printf "      at %s\n", $2 }' >&2
      done <<< "$undocumented"
      echo "Add a row to the 'Version-conditional behaviour' table in MAINTAINING.md." >&2
      rc=1
    fi

    stale="$(comm -13 <(printf '%s\n' "$marked") <(printf '%s\n' "$documented") | sed '/^$/d' || true)"
    if [[ -n "$stale" ]]; then
      echo "ERROR: inventory rows with no marker in the scanned files:" >&2
      while IFS= read -r t; do
        echo "  - $t" >&2
      done <<< "$stale"
      echo "Either remove the row or restore the '# version-branch: <tag>' marker." >&2
      rc=1
    fi

    # A tag used in more than one file is expected (Dockerfile + build.sh + tests
    # encode the same policy); a tag used nowhere is impossible by construction.
    dup_rows="$(doc_tags_all_count | awk '$1 > 1 { print $2 }' || true)"
    if [[ -n "$dup_rows" ]]; then
      echo "ERROR: duplicate inventory rows for the same tag:" >&2
      printf '%s\n' "$dup_rows" | sed 's/^/  - /' >&2
      rc=1
    fi

    if [[ "$rc" -eq 0 ]]; then
      n="$(printf '%s\n' "$marked" | sed '/^$/d' | wc -l | tr -d ' ')"
      echo "OK: ${n} version-branch tag(s) marked and documented."
    fi
    exit "$rc"
    ;;
  "")
    printf '%-24s %s\n' "TAG" "LOCATIONS"
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      locs="$(collect | awk -F'\t' -v t="$t" '$1 == t { printf "%s%s", sep, $2; sep = ", " }')"
      printf '%-24s %s\n' "$t" "$locs"
    done < <(all_tags)
    ;;
  *)
    echo "usage: tools/list-version-branches.sh [--tags|--check]" >&2
    exit 2
    ;;
esac
