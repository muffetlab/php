#!/bin/sh
# Build-stage verification for a freshly compiled PHP.
#
# Why this is a script and not an inline RUN block: "./configure succeeded" does
# NOT prove the extensions were enabled (the classic GD/zip/openssl failure mode
# this kit exists to catch). These assertions are the safety net, they are the
# part a reviewer most needs to read, and they are identical for every version
# and variant -- so they live in one reviewable file instead of being inlined
# into a 500-line Dockerfile.
#
# Every path and knob is overridable through the environment, which makes the
# script runnable outside an image build (that is how it is tested):
#   PHP_BIN       php binary to inspect        (default /opt/php/bin/php)
#   PHP_FPM_BIN   php-fpm binary               (default /opt/php/sbin/php-fpm)
#   PHP_VARIANT   cli | fpm                    (default fpm)
#   OPENSSL_ROUTE openssl11 | openssl3         (required)
#   PHP_VERSION   series, e.g. 5.6 / 8.1       (default: read from PHP_BIN)
#   REQUIRED_EXTENSIONS  space-separated extension names this build promised
#                                          (default: the kit's baseline set)
#
# Exit status: 0 = all assertions passed, 1 = verification failure, 2 = usage.
set -eu

PHP_BIN="${PHP_BIN:-/opt/php/bin/php}"
PHP_FPM_BIN="${PHP_FPM_BIN:-/opt/php/sbin/php-fpm}"
VARIANT="${PHP_VARIANT:-fpm}"
ROUTE="${OPENSSL_ROUTE:-}"
SERIES="${PHP_VERSION:-}"
# The set to verify is the set the build was asked for, not a constant: an image
# built with an extra extension must fail if that extension is absent, and a
# caller running this harness outside the build gets the baseline when it says
# nothing. The default duplicates the Dockerfile's ext_baseline_* lists; if
# those change, change this too (verify-build is the last line, so it stays
# conservative).
REQUIRED="${REQUIRED_EXTENSIONS:-openssl curl mysqli pdo_mysql mbstring zip gd zlib apcu redis memcached}"

fail() {
  echo "VERIFY-BUILD FAIL: $*" >&2
  exit 1
}

[ -n "$ROUTE" ] || { echo "VERIFY-BUILD: OPENSSL_ROUTE is required" >&2; exit 2; }
case "$VARIANT" in cli|fpm) ;; *) echo "VERIFY-BUILD: bad PHP_VARIANT '$VARIANT'" >&2; exit 2 ;; esac
[ -x "$PHP_BIN" ] || fail "no executable php at $PHP_BIN"

if [ -z "$SERIES" ]; then
  SERIES="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
fi

echo "== verify-build: PHP ${SERIES} / ${VARIANT} / ${ROUTE}"
"$PHP_BIN" -v

if [ "$VARIANT" = "fpm" ]; then
  [ -x "$PHP_FPM_BIN" ] || fail "no executable php-fpm at $PHP_FPM_BIN"
  "$PHP_FPM_BIN" -t
fi

# 1. Presence in `php -m`. This is the check that catches a silently disabled
#    extension; configure warnings are easy to miss in a long build log.
missing=""
for ext in $REQUIRED; do
  if ! "$PHP_BIN" -m | grep -qix "$ext"; then
    missing="$missing $ext"
  fi
done
if [ -n "$missing" ]; then
  fail "extensions missing from php -m:$missing"
fi
echo "== php -m: all required extensions present"

# 2. `php --ri` must actually produce reflection info, which fails when an
#    extension is listed but broken (missing symbol, bad ini, wrong linkage).
#    Same list as above: an extension this build promised has to reflect, not
#    merely appear in the module banner.
for ext in $REQUIRED; do
  "$PHP_BIN" --ri "$ext" >/dev/null || fail "php --ri $ext did not resolve"
done
echo "== php --ri: all required extensions resolve"

# 3. Route sanity: the OpenSSL the binary is linked against must be the major
#    version this route promises. extension_loaded("openssl") proves nothing
#    about the underlying library -- this does.
case "$ROUTE" in
  openssl11) want_ssl="OpenSSL 1\.1" ;;
  openssl3) want_ssl="OpenSSL 3\." ;;
  *) echo "VERIFY-BUILD: bad OPENSSL_ROUTE '$ROUTE'" >&2; exit 2 ;;
esac
sslver="$("$PHP_BIN" -r 'echo OPENSSL_VERSION_TEXT;')"
echo "== linked OpenSSL: $sslver"
if ! echo "$sslver" | grep -q "$want_ssl"; then
  fail "linked OpenSSL [$sslver] does not match route ${ROUTE}"
fi

# 4. Native OpenSSL 3 support floor for the 8.x series.
# version-branch: openssl-floor-8x
case "$SERIES" in
  8.0)
    "$PHP_BIN" -r 'exit(version_compare(PHP_VERSION, "8.0.13", ">=") ? 0 : 1);' \
      || fail "PHP 8.0 needs >= 8.0.13 for native OpenSSL 3 support"
    ;;
  8.1)
    "$PHP_BIN" -r 'exit(version_compare(PHP_VERSION, "8.1.0", ">=") ? 0 : 1);' \
      || fail "PHP 8.1 needs >= 8.1.0 for native OpenSSL 3 support"
    ;;
esac

echo "VERIFY-BUILD OK"
