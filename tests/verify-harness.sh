#!/bin/sh
# Stub harness for tools/verify-build.sh and tools/verify-runtime.sh.
#
# Why this exists: exercising the assertions that decide whether an image may be
# published for real means a full PHP compile. Both scripts take every path
# through the environment, so this harness fakes php / php-fpm / openssl / ldd /
# sha256sum and drives the positive and negative cases in milliseconds. It is
# the fastest way to prove a change to the verification logic did not silently
# weaken it.
#
# Usage: tests/verify-harness.sh
# Exit:  0 = every case behaved as expected, 1 = at least one did not.
#
# What the cases cover: 47 positive/negative cases across both verify scripts --
# each assertion's pass and fail path, driven through the stub binaries, so a
# weakened assertion turns at least one case red.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VB="$ROOT/tools/verify-build.sh"
VR="$ROOT/tools/verify-runtime.sh"
for f in "$VB" "$VR"; do
  [ -r "$f" ] || { echo "harness: missing $f" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

passed=0
failed=0

# --- stubs --------------------------------------------------------------------
# PHP_VERSION_SERIES / MISSING_EXT / EXTRA_EXT / SSL_TEXT / FLOOR_FAIL are the
# knobs the cases turn; everything else is a fixed, plausible answer.
write_stubs() {
  d="$1"
  mkdir -p "$d/bin"

  cat > "$d/bin/php" <<'STUB'
#!/bin/sh
case "$1" in
  -v) echo "PHP ${PHP_VERSION_SERIES:-8.1}.30 (cli) (built: Oct 30 2026) ( NTS )"; exit 0 ;;
  -m)
    for e in openssl curl mysqli pdo_mysql mbstring zip gd zlib apcu redis memcached ${EXTRA_EXT:-}; do
      [ "$e" = "${MISSING_EXT:-}" ] && continue
      echo "$e"
    done
    exit 0 ;;
  --ri) [ "$2" = "${MISSING_EXT:-}" ] && exit 1; echo "$2"; exit 0 ;;
  -r)
    case "$2" in
      *OPENSSL_VERSION_TEXT*) echo "${SSL_TEXT:-OpenSSL 3.0.15  3 Sep 2024}"; exit 0 ;;
      *PHP_MAJOR_VERSION*) echo "${PHP_VERSION_SERIES:-8.1}"; exit 0 ;;
      *8.0.13*) [ "${FLOOR_FAIL:-0}" = "1" ] && exit 1; exit 0 ;;
      *8.1.0*)  [ "${FLOOR_FAIL:-0}" = "1" ] && exit 1; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
STUB

  cat > "$d/bin/php-fpm" <<'STUB'
#!/bin/sh
echo "configuration file test successful"
STUB

  cat > "$d/bin/openssl" <<'STUB'
#!/bin/sh
echo "OpenSSL ${SSL_TEXT_VERSION:-3.0.15}  3 Sep 2024"
STUB

  cat > "$d/bin/ldd" <<'STUB'
#!/bin/sh
echo "	libssl.so.3 => /usr/lib/x86_64-linux-gnu/libssl.so.3 (0x00007f0000000000)"
STUB

  # Deterministic across macOS (no coreutils sha256sum) and CI runners.
  cat > "$d/bin/sha256sum" <<'STUB'
#!/bin/sh
if command -v shasum >/dev/null 2>&1; then exec shasum -a 256 "$@"; fi
exec /usr/bin/sha256sum "$@"
STUB

  chmod +x "$d/bin/php" "$d/bin/php-fpm" "$d/bin/openssl" "$d/bin/ldd" "$d/bin/sha256sum"
}

# --- case scaffolding ---------------------------------------------------------
# layout mirrors the image: $CASE/opt/php/{bin,sbin,BUILD-*}
setup() { # $1 = case name -> echoes the case dir
  d="$WORK/$1"
  mkdir -p "$d/opt/php/bin" "$d/opt/php/sbin" "$d/usr/src/php/main"
  write_stubs "$d"
  cp "$d/bin/php" "$d/opt/php/bin/php"
  cp "$d/bin/php-fpm" "$d/opt/php/sbin/php-fpm"
  printf 'provenance=stub\nopenssl_route=openssl3\nvariant=fpm\nphp_version_series=8.1\nsource_tree_shipped=1\n' \
    > "$d/opt/php/BUILD-PROVENANCE"
  # A configured source/build tree, as SHIP_PHP_SOURCE=1 leaves it.
  printf '#!/bin/sh\nexit 0\n' > "$d/usr/src/php/configure"
  chmod +x "$d/usr/src/php/configure"
  printf 'all:\n\t@true\n' > "$d/usr/src/php/Makefile"
  printf '#define PHP_VERSION "8.1.30"\n' > "$d/usr/src/php/main/php_config.h"
  printf '#!/bin/sh\necho "Composer version 2.11.0  2026-10-29 10:23:20"\n' \
    > "$d/opt/php/bin/composer"
  chmod +x "$d/opt/php/bin/php" "$d/opt/php/sbin/php-fpm" "$d/opt/php/bin/composer"
  sha="$(PATH="$d/bin:$PATH" sha256sum "$d/opt/php/bin/composer" | cut -d ' ' -f1)"
  {
    echo "Composer version 2.11.0  2026-10-29 10:23:20"
    echo "composer_pinned_version=2.11.0"
    echo "composer_phar_sha256=$sha"
    echo "composer_phar_sha256_verified=yes"
  } > "$d/opt/php/BUILD-COMPOSER"
  echo "$d"
}

# run <case-dir> <expected-exit> <script> [ENV=VAL ...]
run() {
  d="$1"; want="$2"; script="$3"; shift 3
  # The scripts are *expected* to fail in most cases, so suspend errexit around
  # the invocation and read the status explicitly.
  set +e
  out="$( cd "$d" && env \
        PATH="$d/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        PHP_DIR="$d/opt/php" \
        PHP_BIN="$d/opt/php/bin/php" \
        PHP_FPM_BIN="$d/opt/php/sbin/php-fpm" \
        PHP_SRC_DIR="$d/usr/src/php" \
        OPENSSL_BIN="$d/bin/openssl" \
        "$@" sh "$script" 2>&1 )"
  got=$?
  set -e
  name="$(basename "$d")"
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
    printf 'ok   %-34s exit=%s\n' "$name" "$got"
  else
    failed=$((failed + 1))
    printf 'FAIL %-34s want=%s got=%s\n' "$name" "$want" "$got"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
}

# --- runtime OS package inventory ---------------------------------------------
# The final stage writes /opt/php/RUNTIME-OS-PACKAGES (source|package|version
# for every installed Debian package) and verify-runtime re-derives the same
# list from dpkg before the image is allowed to be called audited: an inventory
# that no longer matches its image is evidence nobody can trust, and
# tools/scan-image.sh reads exactly that file to decide whether a CVE had a fix
# this kit could take. The stub below plays both sides of the comparison --
# matching, missing a recorded package, carrying a package the inventory never
# listed.
#
# dpkg-query prints whatever the case's data file holds; verify-runtime calls it
# with fixed flags and sorts the result itself.
os_packages() { # <case-dir> <data-file>
  printf '#!/bin/sh\ncat "%s"\n' "$2" > "$1/bin/dpkg-query"
  chmod +x "$1/bin/dpkg-query"
}

# <case-dir> <pkgs-file> [noheader] -> writes the recorded inventory. The digest
# is all zeros because nothing here resolves it; the field's *presence* is what
# the audit trail depends on (tools/scan-image.sh reads it to pick the Debian
# suite).
os_inventory() {
  d="$1"
  {
    echo "base_image=debian:bookworm-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    echo "collected_at=2026-11-02T00:00:00Z"
    [ "${3:-}" = "noheader" ] || echo "format=source|package|version"
    cat "$2"
  } > "$d/opt/php/RUNTIME-OS-PACKAGES"
}

echo "== verify-build"
d=$(setup vb-ok);            run "$d" 0 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vb-derived);       run "$d" 0 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=cli PHP_VERSION_SERIES=8.1
d=$(setup vb-missing-ext);   run "$d" 1 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm MISSING_EXT=gd
d=$(setup vb-missing-mysql); run "$d" 1 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm MISSING_EXT=pdo_mysql
d=$(setup vb-route-drift);   run "$d" 1 "$VB" OPENSSL_ROUTE=openssl11 PHP_VARIANT=fpm
d=$(setup vb-route11-ok);    run "$d" 0 "$VB" OPENSSL_ROUTE=openssl11 PHP_VARIANT=fpm \
                               SSL_TEXT="OpenSSL 1.1.1n  15 Mar 2022"
d=$(setup vb-bad-route);     run "$d" 2 "$VB" OPENSSL_ROUTE=openssl4 PHP_VARIANT=fpm
d=$(setup vb-no-route);      run "$d" 2 "$VB" PHP_VARIANT=fpm
d=$(setup vb-bad-variant);   run "$d" 2 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=apache
d=$(setup vb-floor);         run "$d" 1 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm \
                               PHP_VERSION=8.1 FLOOR_FAIL=1
d=$(setup vb-floor-80);      run "$d" 1 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm \
                               PHP_VERSION=8.0 FLOOR_FAIL=1
d=$(setup vb-no-php);        rm -f "$d/opt/php/bin/php"; \
                             run "$d" 1 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vb-cli-no-fpm);    rm -f "$d/opt/php/sbin/php-fpm"; \
                             run "$d" 0 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=cli
d=$(setup vb-fpm-no-fpm);    rm -f "$d/opt/php/sbin/php-fpm"; \
                             run "$d" 1 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm

# Per-version extension sets. verify-build has to check the set *this image*
# promised, not a constant: an extension the manifest asked for and the build
# lost must fail the build (mcrypt on 5.6 is the case that started this), and an
# extension the image did not promise must not be demanded of it.
d=$(setup vb-ext-lost);      run "$d" 1 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm \
                               REQUIRED_EXTENSIONS="openssl curl mysqli pdo_mysql mbstring zip gd zlib redis memcached mcrypt"
d=$(setup vb-ext-mcrypt-ok); run "$d" 0 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm \
                               REQUIRED_EXTENSIONS="openssl curl mysqli pdo_mysql mbstring zip gd zlib redis memcached mcrypt" EXTRA_EXT=mcrypt
d=$(setup vb-ext-narrow);    run "$d" 0 "$VB" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm \
                               REQUIRED_EXTENSIONS="openssl curl"

echo "== verify-runtime"
d=$(setup vr-ok);            run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-from-prov);     run "$d" 0 "$VR"
d=$(setup vr-route-drift);   sed 's/^openssl_route=openssl3/openssl_route=openssl11/' \
                               "$d/opt/php/BUILD-PROVENANCE" > "$d/p" && mv "$d/p" "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-variant-drift); sed 's/^variant=fpm/variant=cli/' \
                               "$d/opt/php/BUILD-PROVENANCE" > "$d/p" && mv "$d/p" "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-no-prov);       rm -f "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-no-route);      rm -f "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 2 "$VR" PHP_VARIANT=fpm
d=$(setup vr-composer-drift);sed 's/^composer_phar_sha256=.*/composer_phar_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
                               "$d/opt/php/BUILD-COMPOSER" > "$d/c" && mv "$d/c" "$d/opt/php/BUILD-COMPOSER"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-composer-dup);  echo 'composer_phar_sha256=0000000000000000000000000000000000000000000000000000000000000000' \
                               >> "$d/opt/php/BUILD-COMPOSER"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-composer-ver);  printf '#!/bin/sh\necho "Composer version 2.10.0  2026-01-01 00:00:00"\n' \
                               > "$d/opt/php/bin/composer"; chmod +x "$d/opt/php/bin/composer"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-no-composer);   rm -f "$d/opt/php/bin/composer"; \
                             run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-ldd-bad);       printf '#!/bin/sh\necho "\tlibmemcached.so.10 => not found"\n' > "$d/bin/ldd"; \
                             chmod +x "$d/bin/ldd"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-ldd-skip);      printf '#!/bin/sh\necho "\tlibmemcached.so.10 => not found"\n' > "$d/bin/ldd"; \
                             chmod +x "$d/bin/ldd"; \
                             run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm SKIP_LDD=1
d=$(setup vr-ssl-route);     run "$d" 1 "$VR" OPENSSL_ROUTE=openssl11 PHP_VARIANT=fpm \
                               SSL_TEXT_VERSION=3.0.15
d=$(setup vr-cli);           rm -f "$d/opt/php/sbin/php-fpm"; \
                             sed 's/^variant=fpm/variant=cli/' \
                               "$d/opt/php/BUILD-PROVENANCE" > "$d/p" && mv "$d/p" "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=cli

# --- source/build tree (image size cleanup) ---
d=$(setup vr-src-git);       mkdir -p "$d/usr/src/php/.git"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-src-broken);    rm -f "$d/usr/src/php/main/php_config.h"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-src-omitted);   rm -rf "$d/usr/src/php"; mkdir -p "$d/usr/src/php"; \
                             echo "not shipped" > "$d/usr/src/php/SOURCE-NOT-SHIPPED"; \
                             sed 's/^source_tree_shipped=1/source_tree_shipped=0/' \
                               "$d/opt/php/BUILD-PROVENANCE" > "$d/p" && mv "$d/p" "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-src-undocumented); rm -rf "$d/usr/src/php"; mkdir -p "$d/usr/src/php"; \
                             echo "not shipped" > "$d/usr/src/php/SOURCE-NOT-SHIPPED"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-src-unrecorded); sed 's/^source_tree_shipped=1/source_tree_shipped=0/' \
                               "$d/opt/php/BUILD-PROVENANCE" > "$d/p" && mv "$d/p" "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm

# --- published-image extension promise --- verify-runtime reads the promised
# set from the image's own BUILD-PROVENANCE (the build stage wrote it from the
# resolved extension set), so a pulled image is checked against what *it* claims
# rather than against a list that only describes the baseline. The fallback
# matters as much as the check: an image built before these keys existed must
# still be audited, not waved through.
d=$(setup vr-ext-lost);      printf 'extensions_core=openssl curl mysqli pdo_mysql mbstring zip gd zlib mcrypt\nextensions_pecl=redis memcached\n' \
                               >> "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 1 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-ext-mcrypt-ok); printf 'extensions_core=openssl curl mysqli pdo_mysql mbstring zip gd zlib mcrypt\nextensions_pecl=redis memcached\n' \
                               >> "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm EXTRA_EXT=mcrypt
d=$(setup vr-ext-narrow);    printf 'extensions_core=openssl curl\nextensions_pecl=redis\n' \
                               >> "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
d=$(setup vr-ext-blank);     printf 'extensions_core=\nextensions_pecl=\n' \
                               >> "$d/opt/php/BUILD-PROVENANCE"; \
                             run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm

# --- runtime OS package inventory --- The failing cases are the point. An image
# that records packages it does not contain, or contains packages nobody
# recorded, cannot answer "is CVE-x fixed here" honestly -- and
# tools/scan-image.sh builds its verdict out of exactly that file, so
# verify-runtime has to refuse the mismatch rather than note it. Version drift
# is the realistic failure (tzdata 2026e recorded, 2026f installed): the same
# package name in both lists is not agreement, because the version *is* the
# answer.
#
# os_case <name> <want> <recorded> <dpkg-prints> [noheader] "-" for either list
# means "do not create that side" (empty inventory, no dpkg-query at all).
os_case() {
  d="$(setup "$1")"; want="$2"; rec="$3"; cur="$4"; extra="${5:-}"
  if [ "$rec" = "-" ]; then
    : > "$d/opt/php/RUNTIME-OS-PACKAGES"
  else
    # Unquoted on purpose: the lists are space-separated package lines, and one
    # token per line is exactly the format dpkg-query's ${Version} fields use.
    # shellcheck disable=SC2086
    printf '%s\n' $rec > "$d/pkgs.txt"
    os_inventory "$d" "$d/pkgs.txt" "$extra"
  fi
  if [ "$cur" != "-" ]; then
    # shellcheck disable=SC2086
    printf '%s\n' $cur > "$d/cur.txt"
    os_packages "$d" "$d/cur.txt"
  fi
  run "$d" "$want" "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm
}

P_CURL='curl|libcurl4|7.88.1-10+deb12u14'
P_SSL='openssl|libssl3|3.0.15-1~deb12u1'
P_TZ='tzdata|tzdata|2026f-0~deb12u0'
P_TZ_OLD='tzdata|tzdata|2026e-0~deb12u0'
P_ZLIB='zlib1g|zlib1g|1:1.2.13.dfsg.1-1'

os_case vr-osinv-ok        0 "$P_CURL $P_SSL $P_TZ" "$P_CURL $P_SSL $P_TZ"
os_case vr-osinv-drops     1 "$P_CURL $P_SSL $P_TZ" "$P_SSL $P_TZ"
os_case vr-osinv-unrec     1 "$P_CURL $P_SSL $P_TZ" "$P_CURL $P_SSL $P_TZ $P_ZLIB"
os_case vr-osinv-version   1 "$P_CURL $P_SSL $P_TZ" "$P_CURL $P_SSL $P_TZ_OLD"
os_case vr-osinv-nohdr     1 "$P_CURL $P_SSL $P_TZ" "$P_CURL $P_SSL $P_TZ" noheader
os_case vr-osinv-empty     1 - -
# No inventory at all stays a pass, and says which case it is: images published
# before RUNTIME-OS-PACKAGES existed must remain auditable instead of being
# declared unverifiable. vr-ok above is this case; it is named here so the
# behaviour cannot be changed by accident.
d=$(setup vr-osinv-absent); run "$d" 0 "$VR" OPENSSL_ROUTE=openssl3 PHP_VARIANT=fpm

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
