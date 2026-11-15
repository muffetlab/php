#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-}"
VARIANT="${2:-fpm}"

# version-branch: series-allowlist
SUPPORTED_VERSIONS="5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1"

version_supported() {
  local v
  for v in $SUPPORTED_VERSIONS; do [[ "$v" == "$1" ]] && return 0; done
  return 1
}

# BUILD_PACKAGES / RUNTIME_PACKAGES are interpolated unquoted into apt-get
# inside the image build. A manifest is trusted project configuration, but a
# stray character in one of these lists would become shell injection at build
# time, so both are restricted to Debian package specifications:
# name[:arch][=version].
validate_package_list() {
  local name="$1" value="$2" tok
  local pkg_re='^[A-Za-z0-9][A-Za-z0-9.+-]*(:[A-Za-z0-9.+-]+)?(=[A-Za-z0-9.+:~-]+)?$'
  [[ -n "$value" ]] || return 0
  local -a toks=()
  read -r -a toks <<< "$value"
  for tok in "${toks[@]}"; do
    if [[ ! "$tok" =~ $pkg_re ]]; then
      echo "${name} contains an invalid package specification: ${tok}" >&2
      echo "Allowed form: name[:arch][=version] using A-Za-z0-9 . + - : ~ =" >&2
      exit 1
    fi
  done
}

if ! version_supported "$VERSION"; then
  echo "Usage: $0 <${SUPPORTED_VERSIONS// /|}> [cli|fpm]" >&2
  exit 2
fi
case "$VARIANT" in
  cli|fpm) ;;
  *) echo "Variant must be cli or fpm" >&2; exit 2 ;;
esac

MANIFEST="${ROOT}/manifests/${VERSION}.env"
test -f "$MANIFEST" || { echo "Missing manifest: $MANIFEST" >&2; exit 1; }

# These files are trusted project configuration and must not contain
# untrusted values. They are shell files, not generic data formats.
# shellcheck source=/dev/null
source "$MANIFEST"

: "${BASE_IMAGE:?Set BASE_IMAGE in manifest}"
# BASE_IMAGE_OVERRIDE: try a different Debian base without editing a reviewed
# pin. This exists for the "would a trixie base serve this series?" question,
# where the honest answer needs a build, not an argument -- and a build needs a
# digest, which is why tools/resolve-base-digest.sh grew --base. It is an
# override, not a new policy: the value goes through every check the manifest
# value goes through below (placeholder + 64-hex digest + the
# route/OpenSSL-major assertion inside the image), so a trial cannot be looser
# than a release, and what the trial actually used is recorded in the image
# itself (/opt/php/RUNTIME-OS-PACKAGES and BUILD-PROVENANCE). Nothing reads this
# variable in CI: the workflows pass BASE_IMAGE from the manifest, and
# publishing a trixie image still means committing a digest by hand.
if [[ -n "${BASE_IMAGE_OVERRIDE:-}" ]]; then
  echo "NOTICE: BASE_IMAGE_OVERRIDE is set -- building ${VERSION}/${VARIANT} on"
  echo "   '${BASE_IMAGE_OVERRIDE}' instead of the manifest's '${BASE_IMAGE}'."
  echo "   This is a TRIAL. Its result is evidence for a decision; the image it"
  echo "   produces is not a release artifact and no tag points at it."
  BASE_IMAGE="$BASE_IMAGE_OVERRIDE"
fi
: "${OPENSSL_ROUTE:?Set OPENSSL_ROUTE in manifest}"
: "${PHP_SRC_REPO:?Set PHP_SRC_REPO in manifest}"
: "${SOURCE_REF:?Set SOURCE_REF in manifest (branch/tag the commit was resolved from)}"
: "${PHP_SRC_COMMIT:?Set PHP_SRC_COMMIT in manifest}"
: "${BUILD_VARIANTS:?Set BUILD_VARIANTS in manifest (e.g. \"cli fpm\")}"
: "${PATCHSET_APPROVED:?Set PATCHSET_APPROVED in manifest}"
# Optional apt overrides. Empty means "use the Dockerfile's per-route defaults".
BUILD_PACKAGES="${BUILD_PACKAGES:-}"
RUNTIME_PACKAGES="${RUNTIME_PACKAGES:-}"
validate_package_list BUILD_PACKAGES "$BUILD_PACKAGES"
validate_package_list RUNTIME_PACKAGES "$RUNTIME_PACKAGES"
# 1 ships the configured source/build tree (official-image parity, and what
# makes docker-php-ext-install work downstream); 0 drops it and saves the most
# image space of any single knob here.
SHIP_PHP_SOURCE="${SHIP_PHP_SOURCE:-1}"
case "$SHIP_PHP_SOURCE" in
  0|1) ;;
  *) echo "SHIP_PHP_SOURCE must be 0 or 1 (got: $SHIP_PHP_SOURCE)" >&2; exit 1 ;;
esac
if [[ "$SHIP_PHP_SOURCE" = "0" ]]; then
  echo "SHIP_PHP_SOURCE=0: the image will NOT contain /usr/src/php, so"
  echo "docker-php-ext-install and pecl builds will not work inside it."
fi
# Optional Composer overrides. Empty means "use the Dockerfile's per-version
# policy pin" (1.10.28 for PHP 5.6/7.0/7.1, 2.11.0 for 7.2+).
COMPOSER_VERSION="${COMPOSER_VERSION:-}"
COMPOSER_SHA256="${COMPOSER_SHA256:-}"
# Optional per-version extension additions. Both lists ADD to the kit's baseline
# (core: openssl curl mysqli pdo_mysql mbstring zip gd zlib, with mcrypt
# appended by the guard step on 5.6-7.1; PECL: apcu redis memcached) -- they are
# not a replacement, so a manifest cannot shrink the set the kit promises. Names
# only: how each one is wired (configure flag, dev package, runtime library,
# PECL pin) lives in the Dockerfile, and the Dockerfile is the single authority
# on which series can build which extension. The availability table there is
# what decides whether the build proceeds; a name it does not recognise for this
# series fails the build with the list of what is buildable, rather than
# shipping an image missing an extension the manifest asked for.
PHP_EXTENSIONS="${PHP_EXTENSIONS:-}"
PECL_EXTENSIONS="${PECL_EXTENSIONS:-}"
# Same injection concern as the package lists: these words are interpolated
# unquoted into shell inside the image build.
validate_extension_list() {
  local name="$1" value="$2" tok
  local ext_re='^[a-z0-9_]+$'
  [[ -n "$value" ]] || return 0
  local -a toks=()
  read -r -a toks <<< "$value"
  for tok in "${toks[@]}"; do
    if [[ ! "$tok" =~ $ext_re ]]; then
      echo "${name} contains an invalid extension name: ${tok}" >&2
      echo "Allowed form: one lowercase extension name per space-separated token (a-z 0-9 _)" >&2
      exit 1
    fi
  done
}
validate_extension_list PHP_EXTENSIONS "$PHP_EXTENSIONS"
validate_extension_list PECL_EXTENSIONS "$PECL_EXTENSIONS"

# Refuse unfilled templates.
for var in BASE_IMAGE SOURCE_REF PHP_SRC_COMMIT; do
  if [[ "${!var}" == REPLACE_WITH* ]]; then
    echo "Manifest field $var is still a template placeholder" >&2
    exit 1
  fi
done

if [[ ! "$PHP_SRC_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "PHP_SRC_COMMIT must be a full 40-character commit SHA" >&2
  echo "(pin a reviewed commit; never track a branch head)" >&2
  exit 1
fi
# A digest has to be 64 lowercase hex after the "@sha256:" marker. Checking for
# the marker alone would accept the unfilled "@sha256:REPLACE_WITH_DIGEST"
# template, which is exactly the placeholder every manifest still ships with.
case "$BASE_IMAGE" in
  *@sha256:*)
    digest="${BASE_IMAGE##*@sha256:}"
    if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
      echo "BASE_IMAGE digest is not a 64-character hex digest (got: $digest)." >&2
      echo "Fill it from tools/resolve-base-digest.sh in CI; a placeholder such as" >&2
      echo "REPLACE_WITH_DIGEST is not a digest." >&2
      exit 1
    fi
    ;;
  *) echo "BASE_IMAGE must be pinned by digest (repo@sha256:...)" >&2; exit 1 ;;
esac
if [[ "$PATCHSET_APPROVED" != "1" ]]; then
  echo "Refusing build: patch review not approved." >&2
  echo "Complete manifests/SECURITY-REVIEW.md for ${VERSION}, then set PATCHSET_APPROVED=1." >&2
  exit 1
fi

# Variant must be declared in the manifest.
variant_declared=0
for v in $BUILD_VARIANTS; do
  case "$v" in
    cli|fpm) [[ "$v" == "$VARIANT" ]] && variant_declared=1 ;;
    *) echo "Invalid entry in BUILD_VARIANTS: $v" >&2; exit 1 ;;
  esac
done
if [[ "$variant_declared" != "1" ]]; then
  echo "Variant '${VARIANT}' not listed in BUILD_VARIANTS (${BUILD_VARIANTS}) for ${VERSION}" >&2
  exit 1
fi

# Route must match the version policy:
#   5.6       -> openssl11 (OpenSSL 1.1 base) until OpenSSL 3 backports are verified
#   7.x       -> openssl3, backport patches verified per minor version
#   8.0/8.1   -> openssl3, native support (Dockerfile enforces >= 8.0.13 / >= 8.1.0)
# version-branch: route-by-series
case "$VERSION" in
  5.6)
    expected_route="openssl11" ;;
  *)
    expected_route="openssl3" ;;
esac
if [[ "$OPENSSL_ROUTE" != "$expected_route" ]]; then
  echo "OPENSSL_ROUTE mismatch: PHP ${VERSION} requires '${expected_route}', manifest says '${OPENSSL_ROUTE}'" >&2
  exit 1
fi

# Source of record: the backports fork, for every series. Official PHP shipped
# its last build on each of these lines between 2019 and Dec 2025, so
# php/php-src cannot carry fixes the image's version number does not already
# imply.
if [[ "$PHP_SRC_REPO" != *php-src-backports* ]]; then
  echo "PHP_SRC_REPO must be shivammathur/php-src-backports (got: ${PHP_SRC_REPO})." >&2
  echo "Official php/php-src has no security fixes for an EOL line; switching is a" >&2
  echo "reviewed change to this policy and to the Dockerfile guard, not a manifest edit." >&2
  exit 1
fi

# Composer version policy (see the Composer step in the Dockerfile): Composer
# 2.x needs PHP >= 7.2.5, so EOL 5.6/7.0/7.1 stay on the 1.10.x branch.
if [[ -n "$COMPOSER_VERSION" ]]; then
  if [[ ! "$COMPOSER_VERSION" =~ ^(1\.10|2)(\.[0-9]+)+$ ]]; then
    echo "COMPOSER_VERSION must be an exact 1.10.x or 2.x release (got: $COMPOSER_VERSION)" >&2
    exit 1
  fi
  # version-branch: composer-policy
  case "$VERSION" in
    5.6|7.0|7.1) policy_composer="1.10.28" ;;
    *)           policy_composer="2.11.0" ;;
  esac
  # version-branch: composer-major-guard
  case "$VERSION" in
    5.6|7.0|7.1)
      if [[ "$COMPOSER_VERSION" != 1.10.* ]]; then
        echo "PHP ${VERSION} cannot run Composer 2.x (requires PHP >= 7.2.5); use a 1.10.x pin." >&2
        exit 1
      fi ;;
  esac
  if [[ -z "$COMPOSER_SHA256" ]]; then
    if [[ "$COMPOSER_VERSION" != "$policy_composer" ]]; then
      echo "WARNING: COMPOSER_VERSION=${COMPOSER_VERSION} differs from the policy pin" >&2
      echo "(${policy_composer}) and has no COMPOSER_SHA256; the downloaded phar" >&2
      echo "digest will not be verified." >&2
    fi
  elif [[ ! "$COMPOSER_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "COMPOSER_SHA256 must be a 64-character lowercase hex SHA-256" >&2
    exit 1
  fi
fi

# Local build tag, never pushed. Named after this kit on purpose: the published
# address is ghcr.io/muffetlab/php (see .github/workflows/build-version.yml),
# and a local test build must not look like a ref of it -- the repo name below
# is docker.io/library/php-legacy-kit, which nobody outside docker-library can
# push to, so a stray `docker push $IMAGE` fails instead of publishing a -test
# tag into the real package. It is deliberately short enough to type, and never
# `php:<tag>`: those are docker-library/php's own names (php:5.6-cli exists), so
# a local build under that name would shadow the official image.
# tools/check-image-name.sh keeps this name, the CI test tag and the MAINTAINING
# examples in sync.
IMAGE="php-legacy-kit:${VERSION}-${VARIANT}-test"
# Provenance the runtime stage puts in image labels. A checkout without git
# metadata (an extracted tarball, a vendored copy) reports "unknown" rather than
# failing the build: the label is an audit record, not a precondition. CI passes
# its own revision instead (see .github/workflows/build-version.yml).
GIT_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$BUILD_PACKAGES" ]]; then
  echo "BUILD_PACKAGES override in effect (Dockerfile route defaults replaced)."
  echo "The effective list is recorded in the image at /opt/php/BUILD-DEPS."
fi
docker build --pull \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "PHP_VERSION=${VERSION}" \
  --build-arg "PHP_VARIANT=${VARIANT}" \
  --build-arg "PHP_SRC_REPO=${PHP_SRC_REPO}" \
  --build-arg "PHP_SRC_COMMIT=${PHP_SRC_COMMIT}" \
  --build-arg "OPENSSL_ROUTE=${OPENSSL_ROUTE}" \
  --build-arg "BUILD_PACKAGES=${BUILD_PACKAGES}" \
  --build-arg "SHIP_PHP_SOURCE=${SHIP_PHP_SOURCE}" \
  --build-arg "RUNTIME_PACKAGES=${RUNTIME_PACKAGES}" \
  --build-arg "PATCHSET_APPROVED=${PATCHSET_APPROVED}" \
  --build-arg "BUILD_SOURCE_REF=${SOURCE_REF}" \
  --build-arg "COMPOSER_VERSION=${COMPOSER_VERSION}" \
  --build-arg "COMPOSER_SHA256=${COMPOSER_SHA256}" \
  --build-arg "PHP_EXTENSIONS=${PHP_EXTENSIONS}" \
  --build-arg "PECL_EXTENSIONS=${PECL_EXTENSIONS}" \
  --build-arg "BUILD_MODE=local" \
  --build-arg "GIT_REVISION=${GIT_REVISION}" \
  --tag "$IMAGE" \
  "$ROOT"

echo "Built $IMAGE"
echo "Run: ./tests/smoke.sh $IMAGE ${OPENSSL_ROUTE} ${VARIANT}"
echo "Run: ./tests/extensions.sh $IMAGE ${OPENSSL_ROUTE}"
echo "Run: ./tests/composer.sh $IMAGE"
