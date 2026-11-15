#!/bin/sh
# Runtime-stage verification, run inside the final image (and shipped in it, so
# anyone can re-run the audit on a pulled image: `verify-runtime`).
#
# The build stage proves PHP was compiled correctly; this proves the *published
# artifact* still satisfies the same claims after the multi-stage copy: nothing
# was dropped, no shared library is unresolved, the runtime OpenSSL still
# matches the declared route, and the Composer phar is byte-identical to the one
# recorded at build time.
#
# Environment overrides (same reason as verify-build.sh: testability):
#   PHP_DIR       prefix holding bin/, sbin/, BUILD-*   (default /opt/php)
#   PHP_SRC_DIR   patched source/build tree             (default /usr/src/php)
#   PHP_BIN       php binary                            (default $PHP_DIR/bin/php)
#   PHP_FPM_BIN   php-fpm binary                        (default $PHP_DIR/sbin/php-fpm)
#   PHP_VARIANT   cli | fpm                             (default: from provenance, else fpm)
#   OPENSSL_ROUTE openssl11 | openssl3                  (default: from provenance)
#   OPENSSL_BIN   openssl CLI                           (default openssl)
#   SKIP_LDD      set to 1 to skip the ldd pass (e.g. musl/static builds)
#
# PHP_VARIANT and OPENSSL_ROUTE fall back to $PHP_DIR/BUILD-PROVENANCE, which is
# what makes this usable on a pulled image where the Dockerfile ARGs are gone.
# When both are supplied, they are cross-checked: a mismatch means the image was
# built from something other than the manifest that claims to describe it.
#
# Exit status: 0 = all assertions passed, 1 = verification failure, 2 = usage.
set -eu

PHP_DIR="${PHP_DIR:-/opt/php}"
PHP_BIN="${PHP_BIN:-${PHP_DIR}/bin/php}"
PHP_FPM_BIN="${PHP_FPM_BIN:-${PHP_DIR}/sbin/php-fpm}"
VARIANT="${PHP_VARIANT:-}"
ROUTE="${OPENSSL_ROUTE:-}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
SKIP_LDD="${SKIP_LDD:-0}"
PROV="${PHP_DIR}/BUILD-PROVENANCE"

fail() {
  echo "VERIFY-RUNTIME FAIL: $*" >&2
  exit 1
}

# Read `key=value` from BUILD-PROVENANCE without depending on awk/grep -P.
prov_value() {
  [ -r "$PROV" ] || return 0
  sed -n "s/^$1=//p" "$PROV" | head -1
}

if [ -z "$ROUTE" ]; then
  ROUTE="$(prov_value openssl_route)"
  if [ -z "$ROUTE" ]; then
    echo "VERIFY-RUNTIME: OPENSSL_ROUTE is required (set it, or provide ${PROV})" >&2
    exit 2
  fi
else
  prov_route="$(prov_value openssl_route)"
  if [ -n "$prov_route" ] && [ "$prov_route" != "$ROUTE" ]; then
    fail "OPENSSL_ROUTE [$ROUTE] differs from provenance [$prov_route]"
  fi
fi

if [ -z "$VARIANT" ]; then
  VARIANT="$(prov_value variant)"
  [ -n "$VARIANT" ] || VARIANT="fpm"
else
  prov_variant="$(prov_value variant)"
  if [ -n "$prov_variant" ] && [ "$prov_variant" != "$VARIANT" ]; then
    fail "PHP_VARIANT [$VARIANT] differs from provenance [$prov_variant]"
  fi
fi

case "$VARIANT" in cli|fpm) ;; *) echo "VERIFY-RUNTIME: bad PHP_VARIANT '$VARIANT'" >&2; exit 2 ;; esac
[ -x "$PHP_BIN" ] || fail "no executable php at $PHP_BIN"

echo "== verify-runtime: ${VARIANT} / ${ROUTE}"
"$PHP_BIN" -v

if [ "$VARIANT" = "fpm" ]; then
  [ -x "$PHP_FPM_BIN" ] || fail "no executable php-fpm at $PHP_FPM_BIN"
  "$PHP_FPM_BIN" -t
fi

# Provenance must be present and non-empty: an image without it cannot be
# audited, which defeats the point of publishing it.
[ -s "${PHP_DIR}/BUILD-PROVENANCE" ] || fail "${PHP_DIR}/BUILD-PROVENANCE missing or empty"

# OS package inventory. The base is pinned by digest but the build refreshes the
# suite's preinstalled packages, so the Debian versions this image actually
# ships are a build-time fact, not a manifest fact -- which is why they are
# recorded in the image (RUNTIME-OS-PACKAGES) and why re-checking them here is
# the point: a recorded inventory that no longer matches dpkg is an image that
# was not built by the Dockerfile claiming to describe it (or was edited
# afterwards). Absent is allowed and announced: images built before this file
# existed must stay auditable rather than fail. Present is a hard requirement --
# an image that ships the file but not the packages it lists is broken evidence,
# and the scanner that reads it (tools/scan-image.sh) refuses to guess.
osinv="${PHP_DIR}/RUNTIME-OS-PACKAGES"
if [ -f "$osinv" ]; then
  [ -s "$osinv" ] || fail "$osinv is empty"
  grep -q '^format=source|package|version$' "$osinv" \
    || fail "$osinv has no format header"
  if command -v dpkg-query >/dev/null 2>&1; then
    rec_f="$(mktemp)"; cur_f="$(mktemp)"
    sed -e '/^base_image=/d' -e '/^collected_at=/d' -e '/^format=/d' "$osinv" > "$rec_f"
    dpkg-query -W -f='${source:Package}|${Package}|${Version}\n' | sort > "$cur_f"
    drift="$(grep -vxF -f "$cur_f" "$rec_f" || true)"
    rec_n="$(grep -c . "$rec_f" || true)"; cur_n="$(grep -c . "$cur_f" || true)"
    rm -f "$rec_f" "$cur_f"
    if [ -n "$drift" ]; then
      printf '%s\n' "$drift" | sed 's/^/  | /' >&2
      fail "RUNTIME-OS-PACKAGES records packages this image does not contain"
    fi
    if [ "$rec_n" != "$cur_n" ]; then
      fail "RUNTIME-OS-PACKAGES lists $rec_n packages, dpkg has $cur_n"
    fi
    echo "== os packages: $cur_n Debian packages match ${osinv}"
  else
    echo "== os packages: inventory present, dpkg-query unavailable (not re-checked)"
  fi
else
  echo "== os packages: no RUNTIME-OS-PACKAGES in this image (built before the inventory existed)"
fi

# Composer: the phar that survived the stage copy must be the one the build
# recorded, and it must still run and report that same version.
if [ -x "${PHP_DIR}/bin/composer" ]; then
  [ -s "${PHP_DIR}/BUILD-COMPOSER" ] || fail "${PHP_DIR}/BUILD-COMPOSER missing or empty"
  recorded="$(head -1 "${PHP_DIR}/BUILD-COMPOSER")"
  rt_ver="$("${PHP_DIR}/bin/composer" --no-ansi --version 2>/dev/null \
    | grep -m1 -E '^Composer( version)? [0-9]+\.' || true)"
  if [ "$rt_ver" != "$recorded" ]; then
    fail "runtime composer [$rt_ver] differs from build record [$recorded]"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    # Exactly one recorded digest: a record with two `composer_phar_sha256=`
    # lines would let a stale (or planted) digest satisfy a plain grep.
    sha_lines="$(grep -c '^composer_phar_sha256=' "${PHP_DIR}/BUILD-COMPOSER" || true)"
    if [ "$sha_lines" != "1" ]; then
      fail "BUILD-COMPOSER has ${sha_lines} composer_phar_sha256= records (expected exactly 1)"
    fi
    rt_sha="$(sha256sum "${PHP_DIR}/bin/composer" | cut -d ' ' -f1)"
    if ! grep -qFx "composer_phar_sha256=${rt_sha}" "${PHP_DIR}/BUILD-COMPOSER"; then
      fail "runtime composer phar sha256 [$rt_sha] not the recorded digest"
    fi
    echo "== composer: ${rt_ver} (phar sha256 ${rt_sha})"
  else
    echo "== composer: ${rt_ver} (sha256sum unavailable; digest not re-checked)"
  fi
else
  echo "== composer: not present in this image (skipped)"
fi

# Source/build tree: exactly one of two states is acceptable, and both must
# agree with what BUILD-PROVENANCE claims.
#   shipped  -> it must still be a *configured* tree, because that is the only
#               reason to pay for it: `docker-php-ext-install` downstream needs
#               configure/Makefile/php_config.h and cannot regenerate them
#               without a toolchain (which this image deliberately lacks).
#   omitted  -> the absence must be recorded, so nobody discovers it by hitting
#               a confusing build failure six months later.
# `.git` must never be in the image either way: hundreds of MB of history that
# nothing at runtime can read.
src_dir="${PHP_SRC_DIR:-/usr/src/php}"
shipped="$(prov_value source_tree_shipped)"
if [ -f "${src_dir}/SOURCE-NOT-SHIPPED" ]; then
  if [ "$shipped" != "0" ]; then
    fail "${src_dir} is absent but provenance says source_tree_shipped=${shipped:-<unset>}"
  fi
  echo "== source tree: not shipped (SHIP_PHP_SOURCE=0); docker-php-ext-install unavailable in this image"
else
  if [ "$shipped" != "1" ]; then
    fail "${src_dir} is present but provenance says source_tree_shipped=${shipped:-<unset>}"
  fi
  if [ -d "${src_dir}/.git" ]; then
    fail "${src_dir}/.git is shipped in the image; the build must delete it"
  fi
  for f in configure Makefile main/php_config.h; do
    [ -e "${src_dir}/${f}" ] || fail "source tree is not a configured build tree: missing ${f}"
  done
  echo "== source tree: shipped and configured (docker-php-ext-install usable)"
fi

# No unresolved shared libraries. A missing libssl/libmemcached/libwebp at
# runtime is the most common way a "working" build stage produces a broken
# image.
if [ "$SKIP_LDD" = "1" ]; then
  echo "== ldd: skipped (SKIP_LDD=1)"
elif command -v ldd >/dev/null 2>&1; then
  bins="$PHP_BIN"
  if [ "$VARIANT" = "fpm" ]; then
    bins="$bins $PHP_FPM_BIN"
  fi
  for bin in $bins; do
    [ -e "$bin" ] || fail "expected binary missing: $bin"
    out="$(ldd "$bin" 2>&1)" || fail "ldd failed on $bin"
    echo "$out"
    if echo "$out" | grep -q "not found"; then
      fail "unresolved shared library in $bin"
    fi
  done
  echo "== ldd: no unresolved libraries"
else
  echo "== ldd: unavailable in this image (skipped)"
fi

# The extension set must still load in the published artifact. This is the
# runtime half of verify-build's `php -m` assertion, and it is not redundant:
# the stage-to-stage COPY can drop a conf.d fragment, and a fragment PHP cannot
# resolve shows up as a PHP Startup warning while the rest of `php -m` still
# looks healthy.
#
# The set checked here is the set the image's own provenance records, not a
# constant compiled into this script -- that is what makes it work on a pulled
# image (where the build args are gone) and what catches the per-version case:
# an image that promised mcrypt but lost libmcrypt4 in the runtime stage fails
# here rather than shipping quiet. Older images, built before those keys
# existed, fall back to the kit's baseline and say so.
#
# The form of the ini line matters across the versions this kit ships: PHP
# 5.6/7.1 try a bare `extension=name` against extension_dir *as-is* and fail,
# while PHP 8.1 tries both `name` and `name.so`. So a bare-name fragment is a
# real defect on the old series and only a warning on the new ones -- both are
# caught here.
startup="$("$PHP_BIN" -m 2>&1 >/dev/null || true)"
if [ -n "$startup" ] && echo "$startup" | grep -q "Unable to load dynamic library"; then
  echo "$startup" >&2
  fail "php reports an extension fragment it cannot load"
fi
core="$(prov_value extensions_core)"
pecl="$(prov_value extensions_pecl)"
required="${core} ${pecl}"
if [ -z "$core" ] && [ -z "$pecl" ]; then
  required="openssl curl mysqli pdo_mysql mbstring zip gd zlib apcu redis memcached"
  echo "== extensions: BUILD-PROVENANCE records no extension set; checking the baseline"
fi
missing=""
for ext in $required; do
  if ! "$PHP_BIN" -m | grep -qix "$ext"; then
    missing="$missing $ext"
  fi
done
if [ -n "$missing" ]; then
  fail "extensions missing from the published image's php -m:$missing"
fi
echo "== extensions: all modules this image promises load in the published image"

# The runtime OpenSSL major must still match the route the image claims.
case "$ROUTE" in
  openssl11) want_ssl="OpenSSL 1\.1" ;;
  openssl3) want_ssl="OpenSSL 3\." ;;
  *) echo "VERIFY-RUNTIME: bad OPENSSL_ROUTE '$ROUTE'" >&2; exit 2 ;;
esac
rtssl="$("$OPENSSL_BIN" version)"
echo "== runtime OpenSSL: $rtssl"
if ! echo "$rtssl" | grep -q "$want_ssl"; then
  fail "runtime OpenSSL [$rtssl] does not match route ${ROUTE}"
fi

echo "VERIFY-RUNTIME OK"
