#!/usr/bin/env bash
# The extension baseline is stated in more than one file, and every copy has to
# be the same list:
#
#   Dockerfile             ext_baseline_core / ext_baseline_pecl in the guard
#                          step -- the authority, because it is what a build
#                          actually compiles and installs.
#   tools/verify-build.sh  the REQUIRED fallback for a bare invocation.
#   tools/verify-runtime.sh the fallback for an image whose BUILD-PROVENANCE
#                          predates the extensions_core / extensions_pecl keys.
#   tests/smoke.sh         the same fallback, in the harness that gates CI.
#   tests/extensions.sh    the same fallback, feeding the promised-set logic.
#   tools/gen-supported.sh the set SUPPORTED.md publishes for versions with no
#                          manifest additions.
#
# A copy that disagrees is worse than no copy at all: it reports a healthy image
# as broken (or the reverse) for a reason that has nothing to do with the image.
# Each copy is checked to CONTAIN the names it must; extra names in a fallback
# are not a failure, because verifying more than the baseline costs nothing.
#
# Usage:
#   tools/check-ext-baseline.sh            print what each file says
#   tools/check-ext-baseline.sh --check    exit 1 if any copy is missing a name
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Extracted by pattern, never by sourcing: the authoritative value sits inside a
# Dockerfile RUN continuation, and these files are shell that would run build
# logic if sourced.
dockerfile_baseline() {
  grep -m1 "ext_baseline_$1=" "${ROOT}/Dockerfile" \
    | sed -e "s/.*ext_baseline_$1=\"//" -e 's/".*//'
}

# The first quoted string on the first line matching $1 in file $2, unquoted.
# A `${VAR:-default}` value is reduced to its default first: the copy that
# matters is the list, and the variable name around it is that file's own
# business.
first_quoted() {
  grep -m1 -E "$1" "${ROOT}/$2" \
    | grep -m1 -oE '"[^"]*"' \
    | tr -d '"' \
    | sed -e 's/^\${[A-Za-z_][A-Za-z0-9_]*:-//' -e 's/}$//'
}

core="$(dockerfile_baseline core)"
pecl="$(dockerfile_baseline pecl)"
authority="${core} ${pecl}"

# Each entry: expected set | file | line pattern | label
entries=(
  "${authority}|tools/verify-build.sh|^REQUIRED=|verify-build.sh REQUIRED"
  "${authority}|tools/verify-runtime.sh|required=\"openssl|verify-runtime.sh fallback"
  "${authority}|tests/smoke.sh|required=\"openssl|smoke.sh fallback"
  "${authority}|tests/extensions.sh|echo \"openssl|extensions.sh fallback"
  "${core}|tools/gen-supported.sh|ext_core=\"openssl|gen-supported.sh core"
  "${pecl}|tools/gen-supported.sh|ext_pecl=\"apcu|gen-supported.sh pecl"
)

status=0
for entry in "${entries[@]}"; do
  IFS='|' read -r expected file pattern label <<< "$entry"
  found="$(first_quoted "$pattern" "$file")"
  if [ "${1:-}" = "--check" ]; then
    missing=""
    for word in $expected; do
      case " $found " in
        *" $word "*) ;;
        *) missing="${missing:+$missing }$word" ;;
      esac
    done
    if [ -n "$missing" ]; then
      printf 'FAIL %-28s missing: %s\n' "$label" "$missing"
      status=1
    else
      printf 'ok   %-28s %s\n' "$label" "$found"
    fi
  else
    printf '%-30s %s\n' "$label" "$found"
  fi
done

if [ "${1:-}" != "--check" ]; then
  echo
  echo "Authority (Dockerfile): core=[$core] pecl=[$pecl]"
  echo "Run with --check to gate a PR on every copy containing all of it."
fi

exit "$status"
