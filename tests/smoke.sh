#!/usr/bin/env bash
# shellcheck disable=SC2016  # PHP snippets in single quotes must not expand shell vars
# Smoke test: version, required extensions (php -m AND php --ri), FPM config
# (fpm variant only), shared libraries, and route/OpenSSL consistency.
# Usage: tests/smoke.sh <image> [openssl11|openssl3] [cli|fpm]
set -Eeuo pipefail
IMAGE="${1:?Usage: $0 <image> [openssl11|openssl3] [cli|fpm]}"
ROUTE="${2:-}"
VARIANT="${3:-fpm}"
case "$VARIANT" in cli|fpm) ;; *) echo "Variant must be cli or fpm" >&2; exit 2 ;; esac

php() { docker run --rm --entrypoint /opt/php/bin/php "$IMAGE" "$@"; }

# The extension set an image promises is recorded in its own BUILD-PROVENANCE,
# so a per-version list (PHP_EXTENSIONS / PECL_EXTENSIONS in the manifest) is
# tested as it is, and an image predating those keys falls back to the baseline
# it would have been built with. One definition, used by both checks below.
provenance_extensions() {
  docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
set -eu
prov=/opt/php/BUILD-PROVENANCE
core="$(sed -n "s/^extensions_core=//p" "$prov" 2>/dev/null | head -1)"
pecl="$(sed -n "s/^extensions_pecl=//p" "$prov" 2>/dev/null | head -1)"
required="$core $pecl"
if [ -z "$core" ] && [ -z "$pecl" ]; then
  required="openssl curl mysqli pdo_mysql mbstring zip gd zlib apcu redis memcached"
  echo "NOTE: provenance records no extension set; checking the baseline" >&2
fi
echo "$required"
'
}

echo "== PHP version =="
php -v

echo "== Required extensions (php -m) =="
# An empty list here would make both checks below vacuous, so the read is
# guarded: `set -- $(provenance_extensions)` would not abort the script even
# under `set -e`, because the failing command substitution is inside an
# assignment whose own status is that of `set` (0). Reading into a variable
# first makes the substitution's status visible, and the non-empty test refuses
# the case where provenance exists but records nothing.
promised="$(provenance_extensions)" \
  || { echo "Could not read the promised extension set from $IMAGE" >&2; exit 1; }
if [[ -z "${promised// /}" ]]; then
  echo "This image promises no extensions at all (provenance empty): refusing to pass vacuously" >&2
  exit 1
fi
# shellcheck disable=SC2086  # word-splitting the extension list is the point
set -- $promised
missing=""
for ext in "$@"; do
  php -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$ext" || missing="$missing $ext"
done
if [[ -n "$missing" ]]; then
  echo "Missing:$missing" >&2
  exit 1
fi
echo "All promised extensions loaded: $*"

echo "== Extension info (php --ri) =="
# extension_loaded() alone is not enough: --ri proves the extension is actually
# initialized and exposes its linked library versions.
#
# Failing loudly is the point. `php --ri x && echo ok` under `set -e` does not
# abort on the failure (a non-final command in an AND-list is exempt), so a
# broken-but-loaded extension printed nothing and the test still exited 0 --
# which matters more now that this loop is the per-image promise check rather
# than a fixed list: mcrypt promised on 5.6 has to be able to fail this script.
# shellcheck disable=SC2061  # names come from the image provenance, see above
for ext in "$@"; do
  if ! php --ri "$ext" > /dev/null; then
    echo "php --ri $ext did not resolve: promised by this image, broken in it" >&2
    exit 1
  fi
  echo "ri OK: $ext"
done

echo "== OpenSSL route check =="
docker run --rm -e EXPECTED_ROUTE="$ROUTE" --entrypoint /opt/php/bin/php "$IMAGE" -r '
$route = getenv("EXPECTED_ROUTE");
$text = OPENSSL_VERSION_TEXT;
echo "OPENSSL_VERSION_TEXT: $text" . PHP_EOL;
if ($route === "openssl11" && !preg_match("/OpenSSL 1\.1\./", $text)) {
    fwrite(STDERR, "Route mismatch: expected OpenSSL 1.1.x\n"); exit(1);
}
if ($route === "openssl3" && !preg_match("/OpenSSL 3\./", $text)) {
    fwrite(STDERR, "Route mismatch: expected OpenSSL 3.x\n"); exit(1);
}
'

if [[ "$VARIANT" == "fpm" ]]; then
  echo "== FPM configuration =="
  docker run --rm --entrypoint /opt/php/sbin/php-fpm "$IMAGE" -t
fi

echo "== Shared libraries =="
docker run --rm -e VARIANT="$VARIANT" --entrypoint /bin/sh "$IMAGE" -c '
set -eu
binaries="/opt/php/bin/php"
if [ "$VARIANT" = "fpm" ]; then
  binaries="$binaries /opt/php/sbin/php-fpm"
fi
for binary in $binaries; do
  echo "-- $binary"
  output="$(ldd "$binary" 2>&1 || true)"
  printf "%s\n" "$output"
  if printf "%s\n" "$output" | grep -q "not found"; then
    echo "Missing shared library" >&2
    exit 1
  fi
done
'
echo "Smoke tests passed."
