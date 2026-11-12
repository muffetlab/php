#!/usr/bin/env bash
# Composer integration checks: presence, version policy per PHP series, and
# offline project validation. Network-dependent `composer diagnose` runs
# best-effort (warning only) so air-gapped CI does not false-fail.
# Usage: tests/composer.sh <image>
set -Eeuo pipefail
IMAGE="${1:?Usage: $0 <image>}"

docker run --rm --entrypoint /bin/sh "$IMAGE" -euxc '
php_major_minor="$(php -r "echo PHP_MAJOR_VERSION . \".\" . PHP_MINOR_VERSION;")"
out="$(composer --no-ansi --version 2>/dev/null | grep -m1 -E "^Composer( version)? [0-9]+\.")"
echo "$out"

# Version policy: Composer 2.x requires PHP >= 7.2.5.
#   PHP <= 7.1  -> must be Composer 1.10.x
#   PHP >= 7.2  -> must be Composer 2.x
# version-branch: composer-major-guard
case "$php_major_minor" in
  5.6|7.0|7.1)
    printf "%s" "$out" | grep -Eq "Composer( version)? 1\.10\." \
      || { echo "FAIL: expected Composer 1.10.x on PHP $php_major_minor" >&2; exit 1; } ;;
  *)
    printf "%s" "$out" | grep -Eq "Composer( version)? 2\." \
      || { echo "FAIL: expected Composer 2.x on PHP $php_major_minor" >&2; exit 1; } ;;
esac
echo "PASS: composer version policy for PHP $php_major_minor"

# Provenance cross-check: the phar in the image must be exactly the one the
# build stage recorded, and the build must have verified its digest.
test -s /opt/php/BUILD-COMPOSER
recorded="$(head -1 /opt/php/BUILD-COMPOSER)"
if [ "$out" != "$recorded" ]; then
  echo "FAIL: composer reports [$out] but build recorded [$recorded]" >&2
  exit 1
fi
want_sha="$(sed -n "s/^composer_phar_sha256=//p" /opt/php/BUILD-COMPOSER)"
actual_sha="$(sha256sum /opt/php/bin/composer | cut -d " " -f1)"
if [ -z "$want_sha" ] || [ "$want_sha" != "$actual_sha" ]; then
  echo "FAIL: composer phar sha256 [$actual_sha] != recorded [$want_sha]" >&2
  exit 1
fi
verified="$(sed -n "s/^composer_phar_sha256_verified=//p" /opt/php/BUILD-COMPOSER)"
if [ "$verified" != "yes" ]; then
  echo "WARN: phar digest was not verified against a pin (COMPOSER_VERSION override without COMPOSER_SHA256)"
fi
grep -q "^composer=" /opt/php/BUILD-PROVENANCE \
  || { echo "FAIL: BUILD-PROVENANCE has no composer= record" >&2; exit 1; }
echo "PASS: composer provenance ($verified sha256=$actual_sha)"

# Composer 1.10.x on EOL PHP: prove it can actually resolve and talk to its own
# runtime, not just print a version string.
composer config --list --global >/dev/null
echo "PASS: composer config readable"

# Offline sanity: validate a minimal project definition.
workdir="$(mktemp -d)"
cd "$workdir"
printf "%s" "{\"name\": \"test/project\", \"description\": \"composer smoke test\", \"require\": {}}" > composer.json
composer validate --no-check-publish --no-check-all
echo "PASS: composer validate"

# Best-effort network diagnostics (warning only; may be unavailable in CI).
composer diagnose || echo "WARN: composer diagnose reported issues (network?)"
'
echo "Composer tests passed."
