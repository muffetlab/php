#!/usr/bin/env bash
# Syntax-checks the shell inside every RUN instruction of a Dockerfile.
#
# Why this exists: this kit has no local Docker, so a shell typo in a RUN block
# would otherwise only surface minutes into an expensive image build. This runs
# in seconds and is wired into the CI validate gate.
#
# It mirrors the Dockerfile parser in the one way that matters here: comment
# lines inside a line-continuation are removed by Docker before the shell sees
# them, so they are removed here too (keeping them would turn the rest of the
# logical line into a comment and hide real syntax).
#
# Usage: tools/lint-dockerfile-shells.sh [Dockerfile]
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${1:-${ROOT}/Dockerfile}"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "No such Dockerfile: $DOCKERFILE" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk -v out="$TMP" '
  function flush(   f) {
    if (block == "") return
    idx++
    f = out sprintf("/run-%03d.sh", idx)
    print "set -eux" > f
    print block >> f
    close(f)
    block = ""
  }
  function is_comment(line) {
    sub(/^[ \t]+/, "", line)
    return (line ~ /^#/)
  }
  BEGIN { block = ""; idx = 0; cont = 0 }
  {
    line = $0
    if (cont == 1) {
      # Docker drops comment lines inside a continuation before joining.
      if (is_comment(line)) next
      if (line ~ /\\[ \t]*$/) {
        sub(/\\[ \t]*$/, "", line)
        block = block line
        next
      }
      block = block line
      cont = 0
      flush()
      next
    }
    if (line ~ /^RUN[ \t]/) {
      sub(/^RUN[ \t]+/, "", line)
      startline = NR
      block = ""
      if (line ~ /<<-?[A-Za-z]/) {
        # Heredoc RUN form: not used in this Dockerfile; skip rather than
        # produce a misleading result.
        printf("SKIP %d: heredoc RUN form not supported by this linter\n", NR)
        next
      }
      if (line ~ /\\[ \t]*$/) {
        sub(/\\[ \t]*$/, "", line)
        block = line
        cont = 1
        next
      }
      block = line
      flush()
    }
  }
  END {
    if (cont == 1) {
      printf("ERROR: unterminated RUN continuation starting near line %d\n", startline)
      exit 1
    }
    print idx > (out "/count")
  }
' "$DOCKERFILE"

count="$(cat "$TMP/count" 2>/dev/null || echo 0)"
if [[ "$count" -eq 0 ]]; then
  echo "No RUN instructions found in $DOCKERFILE — nothing checked." >&2
  exit 1
fi

fail=0
for f in "$TMP"/run-*.sh; do
  [[ -e "$f" ]] || continue
  name="$(basename "$f" .sh)"
  for interp in sh bash; do
    if ! err="$("$interp" -n "$f" 2>&1)"; then
      echo "FAIL ${DOCKERFILE}: ${name} (${interp} -n)" >&2
      echo "$err" >&2
      nl -ba "$f" | cut -c1-400 >&2
      fail=1
    fi
  done
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "OK: ${count} RUN block(s) in ${DOCKERFILE} pass sh -n and bash -n."
