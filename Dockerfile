# syntax=docker/dockerfile:1.7
#
# Unified build for PHP 5.6 / 7.0 / 7.1 / 7.2 / 7.3 / 7.4 / 8.0 / 8.1, in two
# image variants: CLI and PHP-FPM. Every series is buildable from the manifests
# as shipped, with one value still required per version: the BASE_IMAGE digest
# (resolving a digest needs registry access -- see tools/resolve-base-digest.sh).
# Two OpenSSL routes exist and must match the base image:
#
#   OPENSSL_ROUTE=openssl11  -> base OS ships OpenSSL 1.1. PHP 5.6 only, and it
#                               is the route the pinned branch was named for
#                               (PHP-5.6-security-backports-openssl11). Debian
#                               bullseye (OpenSSL 1.1.1w) is the candidate base.
#   OPENSSL_ROUTE=openssl3   -> base OS ships OpenSSL 3.x. Everything from 7.0
#                               up: for 7.0-7.4 the OpenSSL 3 compatibility work
#                               comes from the backports branch itself (the
#                               official release tarball cannot do this), and
#                               8.0/8.1 support OpenSSL 3 natively (>= 8.0.13 /
#                               >= 8.1.0, enforced below). Debian bookworm
#                               (OpenSSL 3.0.22) is the candidate base.
#
# PHP_SRC_REPO: shivammathur/php-src-backports for all eight series, enforced
# below. Official PHP stopped releasing on every one of these lines -- its last
# builds were 5.6.40 (2019) through 8.1.34 (18 Dec 2025) -- while this fork
# continues to backport fixes from maintained branches onto exactly those
# version numbers. Pinning official php/php-src instead is a reviewed change to
# this guard, not a manifest value, because it would silently drop the fix set
# the image is named after.
#
# A ./configure success does NOT prove every extension was enabled. The build
# fails below unless `php -m` and `php --ri` confirm each required extension.
#
# Published images carry build provenance in /opt/php/BUILD-PROVENANCE and in
# OCI labels. Every label key is written in this file -- see the runtime stage,
# where each key is fixed and only its value comes from an ARG. Callers therefore
# control what a label *says*, never what a label *is called*, and a missing
# value degrades to "unknown" instead of breaking the build.

# Immutable provenance labels are applied in the runtime stage below.
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS build

ARG PHP_VERSION
ARG PHP_VARIANT=fpm
# Per-version extension sets: extensions ADDED to the kit's baseline for this
# series, names only. How each name is wired (configure flag, dev package,
# runtime library, PECL pin) is decided in this file, never in a manifest, so a
# manifest stays an audited allow-list rather than arbitrary build input. Empty
# means "baseline only", which is what every manifest ships today.
ARG PHP_EXTENSIONS=""
ARG PECL_EXTENSIONS=""
ARG PHP_SRC_REPO=https://github.com/shivammathur/php-src-backports.git
ARG PHP_SRC_COMMIT
ARG OPENSSL_ROUTE
ARG PATCHSET_APPROVED=0
ARG BASE_IMAGE
ARG BUILD_SOURCE_REF=unknown
# Build-stage apt packages. Empty means "use the per-route default list"; a
# manifest may set an explicitly version-pinned list instead.
ARG BUILD_PACKAGES=""
# Ship the patched source/build tree in the final image (official-image parity:
# it is what makes `docker-php-ext-install` work in a downstream build). It is
# by far the largest thing in the image, so set 0 for a size-sensitive
# deployment that will never build extensions inside this image. See the
# "Image size cleanup" step and the README's image-size section.
ARG SHIP_PHP_SOURCE=1
# Composer pins. Empty means "use the per-PHP-version policy default resolved
# in the Composer step below". Manifests may override both together.
ARG COMPOSER_VERSION=""
ARG COMPOSER_SHA256=""
ARG COMPOSER_INSTALLER_COMMIT=298f4ba7b62708d16c291573e1c52811b5e494bd
ARG COMPOSER_INSTALLER_SHA256=aad0c40a36d9938664f5a34eb2ed39dbc1021792f9706dbcb9cd6d8001227c99

ENV DEBIAN_FRONTEND=noninteractive
# The install prefix is /opt/php (see the configure step), and the vendored
# docker-php-ext-enable writes its fragments to "$PHP_INI_DIR/conf.d" with no
# fallback, so this stage must declare it. Same value the runtime stage uses,
# so enabling an extension points at the directory PHP actually scans.
ENV PHP_INI_DIR=/opt/php/etc

# --- Route/consistency guards ------------------------------------------------
# Fail fast before spending time on apt/git/make.
RUN set -eux; \
    # version-branch: series-allowlist \
    # SHIP_PHP_SOURCE is validated here, before any expensive step. \
    case "${SHIP_PHP_SOURCE}" in 0|1) ;; *) echo "SHIP_PHP_SOURCE must be 0 or 1" >&2; exit 2;; esac; \
    case "${PHP_VERSION}" in 5.6|7.0|7.1|7.2|7.3|7.4|8.0|8.1) ;; *) echo "Unsupported PHP_VERSION: ${PHP_VERSION}" >&2; exit 2;; esac; \
    case "${PHP_VARIANT}" in cli|fpm) ;; *) echo "Unsupported PHP_VARIANT: ${PHP_VARIANT}" >&2; exit 2;; esac; \
    case "${OPENSSL_ROUTE}" in openssl11|openssl3) ;; *) echo "Unsupported OPENSSL_ROUTE: ${OPENSSL_ROUTE}" >&2; exit 2;; esac; \
    # version-branch: route-by-series \
    if [ "${PHP_VERSION}" = "5.6" ] && [ "${OPENSSL_ROUTE}" != "openssl11" ]; then \
      echo "PHP 5.6 requires OPENSSL_ROUTE=openssl11 until OpenSSL 3 backports are verified" >&2; exit 2; \
    fi; \
    if [ "${PHP_VERSION}" != "5.6" ] && [ "${OPENSSL_ROUTE}" != "openssl3" ]; then \
      echo "PHP ${PHP_VERSION} requires OPENSSL_ROUTE=openssl3 with a verified source commit" >&2; exit 2; \
    fi; \
    # Source of record is the backports fork for every series: the fork is what
    # carries fixes past the final official release of each line, so a different
    # repo here means a different fix set than the image's version implies.
    # No version-conditional branch, hence no version-branch marker.
    case "${PHP_SRC_REPO}" in \
      *php-src-backports*) ;; \
      *) echo "PHP_SRC_REPO must be shivammathur/php-src-backports (got: ${PHP_SRC_REPO}); switching to official php/php-src is a reviewed change to this guard" >&2; exit 2;; \
    esac; \
    # --- Extension-set guards --------------------------------------------------\
    # version-branch: ext-baseline \
    # The kit's extension set is per-version by way of two lists: the baseline \
    # every series ships, plus whatever this manifest ADDs to it. Additive rather \
    # than a full replacement, so a manifest reads as a diff ("8.1 also ships \
    # opcache") and cannot accidentally shrink the set the kit promises. Two lists \
    # because the two kinds are wired by different steps (./configure vs pecl \
    # install), and the runtime stage needs to know which library each links. \
    ext_baseline_core="openssl curl mysqli pdo_mysql mbstring zip gd zlib"; \
    ext_baseline_pecl="apcu redis memcached"; \
    # version-branch: ext-availability \
    # mcrypt ships in the baseline of every series that can build it: it was \
    # carried in core up to 7.1 and removed in 7.2, and on those old series the \
    # core route is the only route -- the PECL replacement's package.xml floors \
    # at PHP 7.2.0 (read from 1.0.9, the newest release, on 2026-11-03), so on \
    # 7.2+ asking for it requests something this pinned tree cannot produce. \
    # Refusing at this guard is the only alternative to ./configure warning and \
    # then shipping a smaller set than the manifest claims -- which is exactly \
    # the failure mode verify-build exists to catch, caught too late to be cheap. \
    case "${PHP_VERSION}" in \
      5.6|7.0|7.1) \
        ext_baseline_core="${ext_baseline_core} mcrypt"; \
        ext_available="mcrypt" ;; \
      *) ext_available="" ;; \
    esac; \
    # No PECL extension beyond the baseline is wired yet: a name here would need \
    # a pin for this series in the PECL step below, and wiring one is a reviewed \
    # change to this file rather than a manifest edit. \
    pecl_available=""; \
    # ext_in: whitespace-separated membership test, no external tool. \
    ext_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }; \
    # ext_add: append unless already present, so a manifest that repeats a \
    # baseline extension cannot make the resolved list overstate the image. \
    ext_add() { \
      ext_add_out="$2"; \
      case " ${ext_add_out} " in \
        *" $1 "*) ;; \
        *) ext_add_out="${ext_add_out:+${ext_add_out} }$1" ;; \
      esac; \
      printf '%s' "$ext_add_out"; \
    }; \
    # Manifest values reach this stage as build args, so extension names get the \
    # same shape restriction BUILD_PACKAGES gets in build.sh -- lowercase letters, \
    # digits, underscore. Anything else is a typo or a probe, not an ext name. \
    for e in ${PHP_EXTENSIONS:-} ${PECL_EXTENSIONS:-}; do \
      case "${e}" in \
        *[!a-z0-9_]*) echo "Invalid extension name '${e}' in PHP_EXTENSIONS/PECL_EXTENSIONS (allowed: [a-z0-9_])" >&2; exit 2;; \
      esac; \
    done; \
    ext_requested="${ext_baseline_core}"; \
    for e in ${PHP_EXTENSIONS:-}; do \
      ext_in "${e}" "${ext_baseline_core}" || { \
        ext_in "${e}" "${ext_available}" || { \
          echo "Extension '${e}' is not buildable on PHP ${PHP_VERSION} (extra available: ${ext_available:-none})" >&2; \
          exit 2; }; \
      }; \
      ext_requested="$(ext_add "${e}" "${ext_requested}")"; \
    done; \
    pecl_requested="${ext_baseline_pecl}"; \
    for e in ${PECL_EXTENSIONS:-}; do \
      ext_in "${e}" "${ext_baseline_pecl}" || { \
        ext_in "${e}" "${pecl_available}" || { \
          echo "PECL extension '${e}' has no pin for PHP ${PHP_VERSION} (extra available: ${pecl_available:-none})" >&2; \
          echo "Wiring a new PECL extension is a reviewed change to this Dockerfile, not a manifest edit." >&2; \
          exit 2; }; \
      }; \
      pecl_requested="$(ext_add "${e}" "${pecl_requested}")"; \
    done; \
    echo "Extension set for PHP ${PHP_VERSION}: core=[${ext_requested}] pecl=[${pecl_requested}]"; \
    # The resolved sets are handed to the later steps of this stage through a \
    # file, because each RUN is its own shell and an expansion resolved here \
    # (baseline-or-manifest, the availability table) must not be re-derived \
    # differently by the apt, configure and PECL steps. Two properties of the \
    # file, both chosen against silent-failure modes: \
    #   Location: /opt/php, not /tmp -- the cleanup step runs `rm -rf /tmp/*` \
    #   before the provenance step reads it, and /opt/php ships to the runtime \
    #   image, so the record travels with the artifact. \
    #   Quoting: the values are quoted space-separated lists read with `. file` \
    #   -- bare, `ext_requested=openssl curl mysqli` would source as "assign \
    #   openssl, then run the command `curl mysqli ...`". The round-trip check \
    #   below turns a format mistake into a build error here. \
    ext_requested_seen="${ext_requested}"; \
    pecl_requested_seen="${pecl_requested}"; \
    mkdir -p /opt/php; \
    printf 'ext_requested="%s"\npecl_requested="%s"\n' "${ext_requested}" "${pecl_requested}" > /opt/php/BUILD-EXTENSIONS; \
    . /opt/php/BUILD-EXTENSIONS; \
    if [ "${ext_requested}" != "${ext_requested_seen}" ] || [ "${pecl_requested}" != "${pecl_requested_seen}" ]; then \
      echo "Extension set handoff file does not round-trip: [${ext_requested}] [${pecl_requested}]" >&2; exit 2; \
    fi; \
    echo "Extension set handoff recorded: core=[${ext_requested}] pecl=[${pecl_requested}]"; \
    test "${PATCHSET_APPROVED}" = "1"; \
    echo "${PHP_SRC_COMMIT}" | grep -Eq '^[0-9a-f]{40}$'

# --- Vendored docker-php-ext tooling ------------------------------------------
# docker-php-ext-configure / -install / -enable / docker-php-source from
# docker-library/php (Apache-2.0), vendored unmodified at a pinned commit and
# hash-verified in CI (see docker-php-ext/README.md). They give this image the
# same extension-management interface as the official PHP images, both during
# this build and for downstream `FROM ghcr.io/muffetlab/php:...` images.
ENV DOCKER_PHP_EXT_SRC_COMMIT=5ec2a6a0dad498e89a91a39454dbb52e98ce2bdb
COPY docker-php-ext/docker-php-ext-configure \
     docker-php-ext/docker-php-ext-enable \
     docker-php-ext/docker-php-ext-install \
     docker-php-ext/docker-php-source \
     /usr/local/bin/
RUN set -eux; \
    chmod +x /usr/local/bin/docker-php-ext-configure /usr/local/bin/docker-php-ext-enable \
             /usr/local/bin/docker-php-ext-install /usr/local/bin/docker-php-source

# --- Build-stage assertion harness --------------------------------------------
# The extension/OpenSSL assertions live in tools/verify-build.sh so they can be
# run and tested outside a container build (see tests/), instead of being
# readable only by staring at this file. Failing any assertion fails the build.
COPY tools/verify-build.sh /usr/local/bin/verify-build
RUN set -eux; \
    chmod 0755 /usr/local/bin/verify-build; \
    sh -n /usr/local/bin/verify-build

# --- Build dependencies ------------------------------------------------------
# Two explicit lists, one per OpenSSL route, because the base OS differs and
# the package set has to be reviewable per route instead of being assumed to
# coincide. Today the Debian names happen to be identical across bullseye-
# derived (openssl11, OpenSSL 1.1.1w-0+deb11u8) and bookworm-derived (openssl3,
# OpenSSL 3.0.22-1~deb12u2) bases; that is an observation about current Debian,
# not a guarantee, so each route spells out its own list and a manifest can pin
# exact versions through BUILD_PACKAGES.
#
#   libssl-dev       resolves to whatever OpenSSL the base ships; the assertion
#                    below proves it matches OPENSSL_ROUTE before compiling.
#   openssl          the CLI, installed explicitly rather than assumed present:
#                    the route assertion and verify-runtime both call it.
#   libzip-dev       needed by ext/zip on PHP < 7.2 (bundled libzip from 7.2);
#                    kept on both routes because it is harmless on newer ones.
#   libwebp-dev      only wired into GD on 7.4+ (--with-webp); harmless earlier.
#   libmemcached-dev PECL memcached links the system library on every version.
#   libxml2-dev      SimpleXML/DOM/XML are on by default in every series, and
#                    ./configure aborts without xml2-config whether or not a flag
#                    asked for them.
#   curl             the CLI, not libcurl. The Composer step fetches its pinned
#                    installer with it, and libcurl4-openssl-dev does not ship
#                    /usr/bin/curl.
#
# Extension-driven dev packages are appended by the mapping below, and appended
# even when a manifest overrides BUILD_PACKAGES -- the same reason openssl is
# forced in: a manifest that asks for an extension and pins its own package list
# must not be able to lose the library that extension links against, or the build
# would fall back to whatever configure can find and produce a smaller set than
# the manifest claims. The guard step resolved the requested sets once already
# (see /opt/php/BUILD-EXTENSIONS); this step reads that file rather than
# re-deriving it, so the two cannot disagree about what was asked for.
#
#   libmcrypt-dev    ext/mcrypt. Present on all three candidate Debian suites
#                    (measured 2026-10-31 against packages.debian.org:
#                    bullseye 2.5.8-3.4, bookworm 2.5.8-7, trixie 2.5.8-8), so
#                    adding it cannot make an existing route unbuildable.
#
# Acquire::Retries is set because a mirror connection drop is otherwise a build
# failure. It does not change what gets installed, only how often a fetch is
# retried.
RUN set -eux; \
    command -v apt-get >/dev/null; \
    . /opt/php/BUILD-EXTENSIONS; \
    # Which Debian release this base is, read from the base image itself rather
    # than inferred from OPENSSL_ROUTE: the route says which OpenSSL major PHP
    # needs, and the release says what its packages are *called*. Measured
    # 2026-11-03 against packages.debian.org, the two differ exactly once in this
    # list -- libfreetype6-dev has no candidate on trixie (its replacement is
    # libfreetype-dev, 2.13.3+dfsg-1+deb13u1), while bullseye (2.10.4+dfsg-1+deb11u2)
    # and bookworm (2.12.1+dfsg-5+deb12u4) carry both names and trixie carries only
    # the new one. Every -dev name above exists on all three suites.
    deb_codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-unknown}")"; \
    echo "apt package names selected for Debian [${deb_codename}]"; \
    case "${deb_codename}" in \
      trixie|forky|sid) ft_dev=libfreetype-dev ;; \
      *) ft_dev=libfreetype6-dev ;; \
    esac; \
    toolchain="ca-certificates curl openssl git patch build-essential autoconf bison re2c pkg-config"; \
    case "${OPENSSL_ROUTE}" in \
      openssl11) \
        route_libs="libssl-dev libcurl4-openssl-dev zlib1g-dev libzip-dev \
          libmemcached-dev libjpeg-dev libpng-dev ${ft_dev} \
          libwebp-dev libonig-dev libxml2-dev libsqlite3-dev" ;; \
      openssl3) \
        route_libs="libssl-dev libcurl4-openssl-dev zlib1g-dev libzip-dev \
          libmemcached-dev libjpeg-dev libpng-dev ${ft_dev} \
          libwebp-dev libonig-dev libxml2-dev libsqlite3-dev" ;; \
    esac; \
    # ext_dev_pkgs: the library a requested core extension compiles against. \
    # Extensions with no external library (mbstring's oniguruma, zlib, and the \
    # rest of the baseline) are already in route_libs unconditionally, which is \
    # why only the optional entries need a lookup here. \
    ext_dev_pkgs=""; \
    for e in ${ext_requested}; do \
      case "${e}" in \
        mcrypt) ext_dev_pkgs="${ext_dev_pkgs} libmcrypt-dev" ;; \
      esac; \
    done; \
    build_packages="${BUILD_PACKAGES:-$toolchain $route_libs}"; \
    build_packages="${build_packages}${ext_dev_pkgs}"; \
    # The openssl CLI is not assumed to exist in the base image, and the route
    # assertion below needs it. Force it into the effective list even when a
    # manifest overrides BUILD_PACKAGES, so the record stays accurate. \
    case " ${build_packages} " in \
      *" openssl "*) ;; \
      *) build_packages="${build_packages} openssl" ;; \
    esac; \
    # version-branch: bullseye-archive-security \
    # Debian 11 (bullseye) left LTS on 2026-08-31: its security index is still
    # published at deb.debian.org, but the pool no longer serves the .debs that
    # index lists (200 from archive.debian.org). Without this redirect the
    # bullseye route cannot be built at all. It changes where bytes come from,
    # never which bytes: the frozen 1.1.1w-0+deb11u8 that installs is what the
    # archive holds, and the base digest pins which OS they belong to. The
    # trailing grep is an assertion, not decoration: if a future base stops
    # keeping its sources in /etc/apt/sources.list, the sed would silently match
    # nothing and this build would fail here instead of failing later as a 404. \
    if sh -c '. /etc/os-release; [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 11 ]'; then \
      sed -i 's#deb\.debian\.org/debian-security#archive.debian.org/debian-security#' /etc/apt/sources.list; \
      grep -q 'archive.debian.org/debian-security' /etc/apt/sources.list; \
    fi; \
    apt-get -o Acquire::Retries=3 update; \
    # OS package currency. BASE_IMAGE is pinned by digest, and a digest freezes \
    # the OS packages that base was built with: rebuilding next month would \
    # still install the *base image's* versions of everything it preinstalls \
    # (tzdata, zlib1g, libsqlite3-0, apt's own dependency closure), however new \
    # the -dev packages installed below happen to be. Refresh those first, so \
    # what PHP links against here -- and what the runtime stage, which repeats \
    # this step, ships -- is the candidate Debian publishes today. A real \
    # refresh on the openssl3 route, a documented no-op on the frozen bullseye \
    # archive -- it is not a way to obtain a newer curl/zlib/sqlite3 on 5.6. \
    # Always-Include-Phasing: Debian holds a fresh upload back from part of the \
    # fleet while it phases in, and a phased-out version is not a candidate. \
    # Without this the step could silently skip a security fix published hours \
    # earlier, which is the exact failure it exists to close. \
    # --force-confdef/--force-confold: an upgraded package may ship a changed \
    # conffile; dpkg must never stop to ask in a noninteractive build. \
    # The simulation is a gate, not a preview: refreshing may upgrade packages, \
    # it may never *remove* one. A suite that suddenly wants a package gone is a \
    # change nobody reviewed, and the failure mode is an image whose library \
    # closure no longer matches the route lists measured against this base. \
    os_removals="$(apt-get -o Acquire::Retries=3 \
        -o APT::Get::Always-Include-Phasing=experimental \
        -s dist-upgrade -y --no-install-recommends \
        | sed -n 's/^[0-9]* upgraded, [0-9]* newly installed, \([0-9]*\) to remove.*/\1/p')"; \
    if [ "${os_removals:-none}" != "0" ]; then \
      echo "apt dist-upgrade on this base would remove '${os_removals}' package(s); refusing to refresh" >&2; \
      exit 2; \
    fi; \
    apt-get -o Acquire::Retries=3 -o APT::Get::Always-Include-Phasing=experimental \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      dist-upgrade -y --no-install-recommends; \
    # Unquoted on purpose: BUILD_PACKAGES / route_libs are word lists. \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends $build_packages; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    build_ssl="$(openssl version)"; \
    echo "Build-stage OpenSSL: $build_ssl"; \
    case "${OPENSSL_ROUTE}" in \
      openssl11) want_ssl="OpenSSL 1\.1" ;; \
      openssl3)  want_ssl="OpenSSL 3\." ;; \
    esac; \
    if ! echo "$build_ssl" | grep -q "$want_ssl"; then \
      echo "Build-stage OpenSSL [$build_ssl] does not match OPENSSL_ROUTE=${OPENSSL_ROUTE}; the base image is wrong for this version" >&2; exit 2; \
    fi; \
    mkdir -p /opt/php; \
    { \
      echo "build_packages=$build_packages"; \
      echo "build_openssl=$build_ssl"; \
    } > /opt/php/BUILD-DEPS; \
    cat /opt/php/BUILD-DEPS

# --- Pinned source checkout --------------------------------------------------
# Fetch the reviewed commit and check out an immutable SHA. Never build from a
# moving branch head.
#
# A shallow fetch of the exact commit is tried first: a full php-src history is
# hundreds of MB of build-time download that can never reach a consumer, because
# `.git` is deleted before the runtime copy (see the image-size cleanup step).
# Servers that refuse fetch-by-SHA fall back to a full clone; the pin is
# verified identically either way.
RUN set -eux; \
    git init -q /usr/src/php; \
    git -C /usr/src/php remote add origin "${PHP_SRC_REPO}"; \
    if ! git -C /usr/src/php fetch --depth 1 --no-tags origin "${PHP_SRC_COMMIT}"; then \
      echo "NOTICE: ${PHP_SRC_REPO} refused a shallow fetch of ${PHP_SRC_COMMIT}; falling back to a full clone"; \
      rm -rf /usr/src/php; \
      git clone "${PHP_SRC_REPO}" /usr/src/php; \
    fi; \
    cd /usr/src/php; \
    git checkout --detach "${PHP_SRC_COMMIT}"; \
    test "$(git rev-parse HEAD)" = "${PHP_SRC_COMMIT}"; \
    git status --porcelain; \
    # Marker consumed by docker-php-source: our source is a git checkout, not
    # the official tarball, so "extract" must be a no-op (it would otherwise
    # look for /usr/src/php.tar.xz). Also keeps any later `docker-php-source
    # delete` from removing a tree downstream builds still need.
    touch /usr/src/php/.docker-extracted

# Extra patches are optional and version-specific. The script rejects patch
# failures rather than silently continuing. Review patch ordering and avoid
# applying fixes already included in the pinned commit.
COPY patches/ /opt/patches/
RUN set -eux; \
    cd /usr/src/php; \
    # version-branch: patches-by-series \
    patchdir="/opt/patches/${PHP_VERSION}"; \
    if [ -d "$patchdir" ]; then \
      find "$patchdir" -maxdepth 1 -type f -name '*.patch' -print | sort > /tmp/patches.txt; \
      while IFS= read -r p; do \
        patch --batch --forward --dry-run -p1 < "$p"; \
        patch --batch --forward -p1 < "$p"; \
      done < /tmp/patches.txt; \
    fi

WORKDIR /usr/src/php

# --- Configure / build -------------------------------------------------------
# Starting point only. Flags and extension dependencies must be validated for
# every pinned source branch and base OS. Extension wiring differs per version
# (see the case branches below and README "Per-version extension notes"):
# mysqli =mysqlnd syntax ends at 7.4, --with-png-dir ends at 7.1, --with-libzip
# ends at 7.1, GD option renames land in 7.4.
#
# The baseline extensions are unconditional flags here -- with one exception:
# mcrypt, which only exists on 5.6-7.1 and is applied through the loop lookup
# below, like a manifest addition, because a flag that old series do not accept
# would break ./configure there. Which is exactly what the additive manifest
# design buys: a manifest can only ask for more extensions,
# never fewer, so the baseline flags and the baseline list cannot drift apart and
# this step does not have to re-check them. The additions are the only ones this
# step has to look up, and it looks them up in the file the guard wrote rather
# than re-reading the build arg -- so the configure flags, the dev packages, the
# PECL installs and the verification all speak about one resolved set.
RUN set -eux; \
    . /opt/php/BUILD-EXTENSIONS; \
    ./buildconf --force; \
    configure_flags=" \
      --prefix=/opt/php \
      --with-config-file-path=/opt/php/etc \
      --with-config-file-scan-dir=/opt/php/etc/conf.d \
      --with-openssl \
      --with-curl \
      --enable-mbstring \
      --with-zlib"; \
    # version-branch: ext-optional-configure \
    # Each optional extension gets its own flag spelling, and the availability \
    # table in the guard is what limits which series can reach this mapping at \
    # all. ext/mcrypt: --with-mcrypt, in core through 7.1 and removed in 7.2, \
    # compiling against the libmcrypt-dev added in the build-deps step. \
    for e in ${ext_requested}; do \
      case "${e}" in \
        mcrypt) configure_flags="$configure_flags --with-mcrypt" ;; \
      esac; \
    done; \
    # version-branch: mysqlnd-suffix \
    case "${PHP_VERSION}" in \
      5.6|7.0|7.1|7.2|7.3|7.4) \
        # mysqlnd is selected explicitly; =mysqlnd syntax still accepted. \
        configure_flags="$configure_flags \
          --with-mysqli=mysqlnd \
          --with-pdo-mysql=mysqlnd" ;; \
      *) \
        # PHP 8.0 removed the =mysqlnd suffix (mysqlnd is the only driver). \
        configure_flags="$configure_flags \
          --with-mysqli \
          --with-pdo-mysql" ;; \
    esac; \
    # version-branch: gd-zip-spelling \
    case "${PHP_VERSION}" in \
      5.6|7.0|7.1) \
        # ext/zip needs system libzip; GD uses the legacy option names; \
        # libpng is selected via --with-png-dir. \
        configure_flags="$configure_flags \
          --with-libzip \
          --with-gd \
          --with-jpeg-dir=/usr \
          --with-png-dir=/usr \
          --with-freetype-dir=/usr" ;; \
      7.2|7.3) \
        # --with-png-dir was removed in 7.2 (libpng support is automatic); \
        # bundled libzip arrives in 7.2, so --with-libzip is gone too. \
        configure_flags="$configure_flags \
          --with-gd \
          --with-jpeg-dir=/usr \
          --with-freetype-dir=/usr" ;; \
      *) \
        # 7.4+ renamed the GD options and added native webp support. \
        configure_flags="$configure_flags \
          --enable-gd \
          --with-jpeg \
          --with-freetype \
          --with-webp" ;; \
    esac; \
    # version-branch: zip-spelling \
    # ext/zip switched from PHP_ARG_ENABLE to PHP_ARG_WITH in 7.4, so the \
    # configure flag changed from --enable-zip to --with-zip. ./configure \
    # accepts unknown --enable-* names without erroring (it just does not flip \
    # the PHP_ZIP variable), so a wrong spelling leaves the zip extension \
    # absent from php -m while verify-build expects it. \
    case "${PHP_VERSION}" in \
      5.6|7.0|7.1|7.2|7.3) configure_flags="$configure_flags --enable-zip" ;; \
      *) configure_flags="$configure_flags --with-zip" ;; \
    esac; \
    # version-branch: pear-optional \
    # PHP 7.4 changed the --with-pear default from DEFAULT (always install) to \
    # no (opt-in). 5.6–7.3 install PEAR unconditionally; passing --with-pear \
    # there is unnecessary and the option spelling differs (older autoconf \
    # style), so the flag is only added for 7.4+. 8.0+ still accepts \
    # --with-pear (with a deprecation warning) and still needs it, because the \
    # default remains no. Without the flag the install-pear target is absent \
    # from install_targets, make install skips PEAR entirely, and the PECL \
    # step below dies at "/opt/php/bin/pear: not found". \
    case "${PHP_VERSION}" in \
      5.6|7.0|7.1|7.2|7.3) ;; \
      *) configure_flags="$configure_flags --with-pear" ;; \
    esac; \
    if [ "${PHP_VARIANT}" = "fpm" ]; then \
      configure_flags="$configure_flags \
        --enable-fpm \
        --with-fpm-user=php-fpm \
        --with-fpm-group=php-fpm"; \
    fi; \
    # Debian installs libcurl's headers under the multiarch directory, while PHP
    # 5.6's ext/curl config.m4 only probes <dir>/include/curl/easy.h for a fixed
    # list of prefixes (/usr/local, /usr) -- without the link below, configure
    # stops with "Please reinstall the libcurl distribution". The headers, the
    # library and /usr/bin/curl-config all come from that same package, so
    # nothing can drift apart. Newer series find curl through pkg-config and are
    # unaffected by the link either way.
    multiarch="$(gcc -dumpmachine)"; \
    if [ ! -e /usr/include/curl ] && [ -d "/usr/include/${multiarch}/curl" ]; then \
      ln -s "/usr/include/${multiarch}/curl" /usr/include/curl; \
    fi; \
    # version-branch: freetype-config-shim \
    # Debian dropped the freetype-config script from libfreetype6-dev, while the
    # GD probe in these series insists on finding <dir>/bin/freetype-config. The
    # shim replies through pkg-config, so the flags still describe the library
    # that is installed, and it lands in /usr/local/bin -- one of the prefixes GD
    # searches -- instead of patching the pinned source.
    case "${PHP_VERSION}" in \
      5.6|7.0|7.1|7.2|7.3) \
        if ! command -v freetype-config >/dev/null 2>&1 && pkg-config --exists freetype2; then \
          printf '%s\n' '#!/bin/sh' \
            'case "$1" in' \
            '  --cflags) exec pkg-config --cflags freetype2 ;;' \
            '  --libs) exec pkg-config --libs freetype2 ;;' \
            '  *) exit 1 ;;' \
            'esac' > /usr/local/bin/freetype-config; \
          chmod 0755 /usr/local/bin/freetype-config; \
        fi ;; \
    esac; \
    # shellcheck disable=SC2086 \
    ./configure $configure_flags; \
    make -j"$(nproc)"; \
    # `make install` also installs the PEAR environment, and PHP 5.6's \
    # install-pear target fetches http://pear.php.net/install-pear-nozlib.phar \
    # whenever the phar is not already in the tree -- through PHP's own fopen() \
    # stream: no retries, a 60 s SSL handshake timeout, no digest check. The \
    # target prefers a local copy, so fetching it here with curl --retry removes \
    # the flake without touching the pinned source; curl is in the toolchain \
    # list for exactly this reason. \
    # \
    # What this deliberately does NOT do is set a digest policy. The installer \
    # is a third-party artifact with no reviewed pin, so the observed sha256 is \
    # recorded in /opt/php/BUILD-PEAR and merged into BUILD-PROVENANCE for \
    # reviewers to compare across builds; making the build *require* a specific \
    # digest is a human decision, the same way BASE_IMAGE digests and \
    # PATCHSET_APPROVED are. \
    if [ ! -f pear/install-pear-nozlib.phar ]; then \
      curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
        --max-time 180 -o pear/install-pear-nozlib.phar \
        http://pear.php.net/install-pear-nozlib.phar; \
    fi; \
    { \
      echo "pear_installer_sha256=$(sha256sum pear/install-pear-nozlib.phar | awk '{print $1}')"; \
      echo "pear_installer_source=http://pear.php.net/install-pear-nozlib.phar"; \
      echo "pear_installer_pinned=no (digest recorded, not required)"; \
    } > /opt/php/BUILD-PEAR; \
    cat /opt/php/BUILD-PEAR; \
    make install; \
    mkdir -p /opt/php/etc/conf.d; \
    cp php.ini-production /opt/php/etc/php.ini

# --- FPM configuration (fpm variant only) ------------------------------------
RUN set -eux; \
    if [ "${PHP_VARIANT}" != "fpm" ]; then exit 0; fi; \
    if [ -f /opt/php/etc/php-fpm.conf.default ]; then \
      cp /opt/php/etc/php-fpm.conf.default /opt/php/etc/php-fpm.conf; \
    fi; \
    # version-branch: fpm-www-conf-fallback \
    if [ -f /opt/php/etc/php-fpm.d/www.conf.default ]; then \
      cp /opt/php/etc/php-fpm.d/www.conf.default /opt/php/etc/php-fpm.d/www.conf; \
    else \
      # PHP 5.6 keeps pool settings inside php-fpm.conf.default. \
      mkdir -p /opt/php/etc/php-fpm.d; \
      printf '[www]\nuser = php-fpm\ngroup = php-fpm\nlisten = 9000\nclear_env = yes\n' \
        > /opt/php/etc/php-fpm.d/www.conf; \
      sed -i 's|^;*include=.*|include=/opt/php/etc/php-fpm.d/*.conf|' /opt/php/etc/php-fpm.conf; \
    fi; \
    sed -i 's|^;*daemonize =.*|daemonize = no|' /opt/php/etc/php-fpm.conf; \
    sed -i 's|^listen = .*|listen = 9000|' /opt/php/etc/php-fpm.d/www.conf; \
    sed -i 's|^user = .*|user = php-fpm|' /opt/php/etc/php-fpm.d/www.conf; \
    sed -i 's|^group = .*|group = php-fpm|' /opt/php/etc/php-fpm.d/www.conf; \
    sed -i 's|^;*clear_env =.*|clear_env = yes|' /opt/php/etc/php-fpm.d/www.conf

# --- PECL extensions ----------------------------------------------------------
# The set comes from the resolved PECL list the guard step wrote (baseline
# apcu + redis + memcached, plus anything PECL_EXTENSIONS adds to it), and each
# name is resolved against the pin table inside the step below. Every PECL
# release declares its own floor in package.xml (<php><min>), and `pecl install`
# refuses a series below it -- so the table pins, per series, the newest
# release whose declared floor admits that series. Floors read from the
# package.xml files of the pinned tarballs:
#
#   redis     5.6            -> 4.3.0 (last release for 5.6)
#             7.0, 7.1       -> 5.3.7 (min 7.0.0)
#             7.2, 7.3       -> 6.0.2 (min 7.2.0)
#             7.4+           -> 6.1.0 (min 7.4.0)
#   memcached 5.6            -> 2.2.0 (max < 6.0)
#             7.0+           -> 3.3.0 (min 7.0.0)
#   apcu      5.6            -> 4.0.11 (min 5.3.0; last of the 4.0.x line)
#             7.0+           -> 5.1.28 (min 7.0.0-dev, read 2026-11-03)
#
# mcrypt is deliberately absent from this table: the PECL package's floor is
# PHP 7.2.0 (read from 1.0.9 on 2026-11-03), so on 5.6-7.1 mcrypt ships from
# core (--with-mcrypt, in the core baseline for exactly those series) and on
# 7.2+ the guard step refuses the name outright.
#
# The floors, not preference, are why the table splits by series: pecl enforces
# them, so a pin raised past a series' floor fails the build there. Re-read
# package.xml before changing a pin, and change it only through a reviewed
# commit that re-runs the test chain.
# Old PECL (5.6 era) has no -D flag, so the settings are applied with explicit
# config-set calls; the libmemcached path is answered via the *LIBMEMCACHED_DIR
# env var. PEAR temp/cache dirs are redirected off /tmp because make install may
# run with /tmp mounted as a fresh tmpfs. Each key is set on its own command
# line (config-set does not read stdin), and `pear config-set` is used for
# temp_dir/cache_dir/preferred_state because pecl only lets channel-level keys
# through `pecl config-set` -- the two front-ends share one config file.
RUN set -eux; \
    . /opt/php/BUILD-EXTENSIONS; \
    mkdir -p /opt/php/tmp/pear-temp /opt/php/tmp/pear-cache; \
    export PATH="/opt/php/bin:/opt/php/sbin:${PATH}"; \
    export PHP_MEMCACHED_LIBMEMCACHED_DIR=/usr; \
    /opt/php/bin/pear config-set preferred_state stable; \
    /opt/php/bin/pear config-set temp_dir /opt/php/tmp/pear-temp; \
    /opt/php/bin/pear config-set cache_dir /opt/php/tmp/pear-cache; \
    # Official-image wiring: enable generates conf.d/docker-php-ext-<name>.ini \
    # and distinguishes zend_extension from extension via readelf. \
    # \
    # The names are passed with their ".so" suffix, and that is load-bearing: \
    # enable writes exactly what it was given, and old PHP resolves a bare name \
    # against extension_dir *as-is* -- it does not append the shared-object \
    # suffix, so "extension=redis" fails to load while "extension=redis.so" \
    # loads on every series. The suffix does not change the fragment filename: \
    # enable strips ".so" before naming the file, and its extension_loaded() \
    # pre-check compares against the stripped name. The vendored script is \
    # pinned and stays untouched. \
    #
    # Driven by PECL_EXTENSIONS: each requested extension is looked up in the pin \
    # table below, installed, and added to the enable list, so the set PECL \
    # contributes is exactly the set the manifest asked for -- and an extension \
    # with no pin for this series stops the build here instead of arriving as a \
    # missing module later. \
    pecl_enable_list=""; \
    pecl_record=""; \
    for e in ${pecl_requested}; do \
      case "${e}:${PHP_VERSION}" in \
        # version-branch: pecl-pins \
        # Each pin is the newest release whose package.xml floor admits the \
        # series (table above). pecl enforces that floor itself, so a pin \
        # raised past it fails the build instead of installing something the \
        # runtime cannot load. \
        redis:5.6)             pecl_ver="4.3.0" ;; \
        redis:7.0|redis:7.1)   pecl_ver="5.3.7" ;; \
        redis:7.2|redis:7.3)   pecl_ver="6.0.2" ;; \
        redis:*)               pecl_ver="6.1.0" ;; \
        memcached:5.6)         pecl_ver="2.2.0" ;; \
        memcached:*)           pecl_ver="3.3.0" ;; \
        apcu:5.6)              pecl_ver="4.0.11" ;; \
        apcu:*)                pecl_ver="5.1.28" ;; \
        *) echo "No PECL pin for '${e}' on PHP ${PHP_VERSION}" >&2; exit 2 ;; \
      esac; \
      /opt/php/bin/pecl install "${e}-${pecl_ver}"; \
      pecl_enable_list="${pecl_enable_list} ${e}.so"; \
      pecl_record="${pecl_record} ${e}=${pecl_ver}"; \
    done; \
    docker-php-ext-enable ${pecl_enable_list}; \
    echo "pecl${pecl_record}" >> /opt/php/BUILD-PECL

# --- Mandatory extension verification ----------------------------------------
# ./configure succeeding does not prove extensions were enabled. verify-build
# checks php -m, php --ri, the linked OpenSSL major against the declared route,
# and the 8.x native-OpenSSL-3 version floors; it fails the build on any miss.
#
# The set it verifies is the set this build was asked for, taken from the same
# resolved file the configure and PECL steps read. Verifying a fixed list instead
# would let an optional extension go missing silently: the baseline would still
# be green, and the manifest's extra entry would simply not be in the image.
RUN set -eux; \
    . /opt/php/BUILD-EXTENSIONS; \
    PHP_VERSION="${PHP_VERSION}" \
    PHP_VARIANT="${PHP_VARIANT}" \
    OPENSSL_ROUTE="${OPENSSL_ROUTE}" \
    REQUIRED_EXTENSIONS="${ext_requested} ${pecl_requested}" \
    verify-build

# --- Composer ------------------------------------------------------------------
# Version policy, verified against upstream on 2026-10-30:
#   * Composer 2.11.0 requires PHP ^7.2.5 || ^8.0, so 7.2/7.3/7.4/8.0/8.1 pin
#     2.11.0 (released 2026-10-29).
#   * Composer 2.2.31 (the 2.x LTS line) declares ^5.3.2 || ^7.0 || ^8.0, so it
#     would technically load on 5.6/7.0/7.1. This kit deliberately does not use
#     it there: the 1.10 branch is the line maintained for EOL PHP, and mixing
#     Composer 2 plugin/resolver behaviour into an unsupported PHP is an extra
#     unreviewed variable. 5.6/7.0/7.1 therefore pin 1.10.28 -- the final 1.x
#     release (2026-05-13); there is no later 1.10.x, so do not "bump" this pin.
#     Relaxing this for a specific PHP series is a reviewed Dockerfile change,
#     not a manifest override: build.sh and CI both reject Composer 2.x there.
# Trust model: the installer script is fetched from an immutable git commit and
# verified against a digest pinned in this repo, so no floating signature file
# is needed. Several mirrors are tried because raw.githubusercontent.com is
# unreachable from some networks; every candidate is digest-checked, so the
# source that succeeds cannot change what gets executed. The resulting phar is
# digest-checked too, which cross-verifies upstream: the 1.10.28 phar installed
# here is byte-identical to getcomposer.org/composer-1.phar and the 2.11.0 phar
# is byte-identical to the GitHub release asset composer.phar.
# Bumping any of these pins is a reviewed change like every other pin.
RUN set -eux; \
    export PATH="/opt/php/bin:/opt/php/sbin:${PATH}"; \
    # version-branch: composer-policy \
    case "${PHP_VERSION}" in \
      5.6|7.0|7.1) policy_ver="1.10.28"; policy_sha="0915af36eb01e3f0e16cd309adff7051832b9ef014e38371756804b20425cd5a";; \
      *)           policy_ver="2.11.0";   policy_sha="9674f12a2a181100d889ebfd0b4510805b3e94cea57869b14b383753d602599b";; \
    esac; \
    composer_ver="${COMPOSER_VERSION:-$policy_ver}"; \
    composer_sha="${COMPOSER_SHA256:-$policy_sha}"; \
    if [ -z "${COMPOSER_SHA256}" ] && [ -n "${COMPOSER_VERSION}" ] && [ "${COMPOSER_VERSION}" != "$policy_ver" ]; then \
      composer_sha=""; \
      echo "NOTICE: COMPOSER_VERSION=${COMPOSER_VERSION} overrides the policy pin without COMPOSER_SHA256; phar digest check skipped"; \
    fi; \
    if ! echo "$composer_ver" | grep -Eq '^(1\.10|2)(\.[0-9]+)+$'; then \
      echo "Unsupported COMPOSER_VERSION: $composer_ver (must be an exact 1.10.x or 2.x release)" >&2; exit 2; \
    fi; \
    case "$composer_ver" in 1.10.*) want_major="1";; *) want_major="2";; esac; \
    if [ -n "$composer_sha" ]; then \
      echo "$composer_sha" | grep -Eq '^[0-9a-f]{64}$' || { echo "COMPOSER_SHA256 must be 64 lowercase hex chars" >&2; exit 2; }; \
    fi; \
    # version-branch: composer-major-guard \
    case "${PHP_VERSION}" in \
      5.6|7.0|7.1) \
        if [ "$want_major" != "1" ]; then \
          echo "PHP ${PHP_VERSION} cannot run Composer 2.x (needs PHP >= 7.2.5); stay on the 1.10.x branch" >&2; exit 2; \
        fi;; \
    esac; \
    echo "${COMPOSER_INSTALLER_COMMIT}" | grep -Eq '^[0-9a-f]{40}$'; \
    echo "${COMPOSER_INSTALLER_SHA256}" | grep -Eq '^[0-9a-f]{64}$'; \
    fetched=""; \
    for url in \
      "https://raw.githubusercontent.com/composer/getcomposer.org/${COMPOSER_INSTALLER_COMMIT}/web/installer" \
      "https://api.github.com/repos/composer/getcomposer.org/contents/web/installer?ref=${COMPOSER_INSTALLER_COMMIT}" \
      "https://getcomposer.org/installer" \
    ; do \
      if curl --fail --location --retry 2 --retry-delay 5 --max-time 120 \
           -H 'Accept: application/vnd.github.raw' \
           -o /tmp/composer-setup.php "$url"; then \
        actual="$(sha256sum /tmp/composer-setup.php | awk '{print $1}')"; \
        if [ "$actual" = "${COMPOSER_INSTALLER_SHA256}" ]; then \
          echo "Composer installer OK from $url"; \
          fetched="yes"; \
          break; \
        fi; \
        echo "WARN: $url served sha256=$actual (expected ${COMPOSER_INSTALLER_SHA256}); trying next source"; \
      else \
        echo "WARN: $url unreachable; trying next source"; \
      fi; \
    done; \
    if [ -z "$fetched" ]; then \
      echo "Could not obtain the pinned Composer installer (commit ${COMPOSER_INSTALLER_COMMIT}, sha256 ${COMPOSER_INSTALLER_SHA256}) from any source" >&2; \
      exit 1; \
    fi; \
    php /tmp/composer-setup.php --no-ansi --install-dir=/opt/php/bin --filename=composer --version="$composer_ver"; \
    rm -f /tmp/composer-setup.php; \
    installed_sha="$(sha256sum /opt/php/bin/composer | awk '{print $1}')"; \
    if [ -n "$composer_sha" ]; then \
      if [ "$installed_sha" != "$composer_sha" ]; then \
        echo "Composer phar digest mismatch for $composer_ver: expected $composer_sha, got $installed_sha" >&2; exit 1; \
      fi; \
      echo "Composer phar SHA256 OK: $installed_sha"; \
    fi; \
    ver_line="$(COMPOSER_ALLOW_SUPERUSER=1 composer --no-ansi --version 2>/dev/null | grep -m1 -E '^Composer( version)? [0-9]+\.' || true)"; \
    if [ -z "$ver_line" ]; then \
      echo "Composer ${composer_ver} did not report a parseable version on PHP ${PHP_VERSION}" >&2; exit 1; \
    fi; \
    echo "$ver_line" | grep -qE "Composer( version)? ${want_major}\."; \
    if [ -n "$composer_sha" ]; then sha_verified="yes"; else sha_verified="no"; fi; \
    { \
      echo "$ver_line"; \
      echo "composer_pinned_version=$composer_ver"; \
      echo "composer_phar_sha256=$installed_sha"; \
      echo "composer_phar_sha256_verified=$sha_verified"; \
      echo "composer_installer_commit=${COMPOSER_INSTALLER_COMMIT}"; \
      echo "composer_installer_sha256=${COMPOSER_INSTALLER_SHA256}"; \
    } > /opt/php/BUILD-COMPOSER; \
    cat /opt/php/BUILD-COMPOSER

# --- Image size cleanup -------------------------------------------------------
# Only things that are provably unusable in the final image are removed -- it
# has no compiler, no make and no git:
#   .git        php-src history is hundreds of MB; BUILD-PROVENANCE already
#               records repo/ref/commit, so the history is evidence nobody in
#               the runtime image can read.
#   */tests     PHPT suites need make + cc to run, and building an extension
#               with docker-php-ext-install does not read them.
#   .github     upstream CI workflows for a repo that is not checked out here.
#   scratch     pecl temp/cache contents, apt caches, /tmp.
#               Because this wipes /tmp, nothing a later step reads may live
#               there: the resolved extension set is a build-stage handoff and
#               is recorded at /opt/php/BUILD-EXTENSIONS for exactly that
#               reason (the provenance step runs after this one).
# Deliberately NOT removed: the configured build tree (Makefile, config.status,
# *.o/*.lo). `docker-php-ext-install` downstream depends on it and cannot
# re-create it without a toolchain, so trimming it piece by piece would trade
# megabytes for a silently broken extension build. Use SHIP_PHP_SOURCE=0 to
# drop the whole tree instead -- that is an honest, testable trade-off.
RUN set -eux; \
    src_before_kb="$(du -sk /usr/src/php | cut -f1)"; \
    rm -rf /usr/src/php/.git /usr/src/php/.github; \
    find /usr/src/php -type d -name tests -prune -exec rm -rf {} + ; \
    rm -rf /opt/php/tmp/pear-temp /opt/php/tmp/pear-cache; \
    mkdir -p /opt/php/tmp/pear-temp /opt/php/tmp/pear-cache; \
    rm -rf /tmp/* /var/tmp/*; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    if [ "${SHIP_PHP_SOURCE}" != "1" ]; then \
      rm -rf /usr/src/php; \
      mkdir -p /usr/src/php; \
      { \
        echo "This image was built with SHIP_PHP_SOURCE=0: the PHP source and"; \
        echo "build tree is not present, so docker-php-ext-install and pecl"; \
        echo "builds will NOT work inside it. Rebuild with SHIP_PHP_SOURCE=1"; \
        echo "(the default) if you need to compile extensions in this image."; \
      } > /usr/src/php/SOURCE-NOT-SHIPPED; \
    fi; \
    src_after_kb="$(du -sk /usr/src/php | cut -f1)"; \
    { \
      echo "source_tree_shipped=${SHIP_PHP_SOURCE}"; \
      echo "source_tree_kb_before_cleanup=${src_before_kb}"; \
      echo "source_tree_kb_after_cleanup=${src_after_kb}"; \
    } > /opt/php/BUILD-CLEANUP; \
    cat /opt/php/BUILD-CLEANUP

# --- Build provenance ---------------------------------------------------------
# Machine-readable record of exactly what this image was built from, shipped
# inside the image. Patch digests cover the whole patches/ tree as seen at
# build time (review records included, so the record itself is fingerprinted).
RUN set -eux; \
    # The resolved extension set comes from the guard step's handoff file, the \
    # same record the apt, configure, PECL and verify steps read. Reading it \
    # here rather than re-deriving it from PHP_EXTENSIONS keeps this provenance \
    # line describing what the build actually did even when the manifest asked \
    # for nothing (empty means "baseline"). Fail closed: an image that cannot \
    # state its own extension set is not publishable. \
    ext_core_record=""; ext_pecl_record=""; \
    if [ -r /opt/php/BUILD-EXTENSIONS ]; then \
      . /opt/php/BUILD-EXTENSIONS; \
      ext_core_record="${ext_requested}"; \
      ext_pecl_record="${pecl_requested}"; \
    fi; \
    if [ -z "${ext_core_record}" ] || [ -z "${ext_pecl_record}" ]; then \
      echo "BUILD-EXTENSIONS is missing or empty; the build did not record its extension set" >&2; \
      exit 2; \
    fi; \
    { \
      echo "php_version=$(/opt/php/bin/php -r 'echo PHP_VERSION;')"; \
      echo "php_version_series=${PHP_VERSION}"; \
      echo "variant=${PHP_VARIANT}"; \
      echo "base_image=${BASE_IMAGE}"; \
      echo "source_repo=${PHP_SRC_REPO}"; \
      echo "source_ref=${BUILD_SOURCE_REF}"; \
      echo "source_commit=${PHP_SRC_COMMIT}"; \
      echo "openssl_route=${OPENSSL_ROUTE}"; \
      echo "openssl_built_against=$(/opt/php/bin/php -r 'echo OPENSSL_VERSION_TEXT;')"; \
      # The extension set this image was built with, in the resolved form the \
      # build actually used -- not the manifest text, which may have been empty \
      # and therefore meant "baseline". A consumer comparing two images needs to \
      # see the difference between "mcrypt requested" and "mcrypt shipped"; the \
      # authoritative answer to the second question is `php -m` in the image, \
      # and verify-build proved this list is a subset of it. \
      echo "extensions_core=${ext_core_record}"; \
      echo "extensions_pecl=${ext_pecl_record}"; \
      echo "extensions_loaded=$(/opt/php/bin/php -r 'echo implode(" ", array_map("strtolower", get_loaded_extensions()));')"; \
      if [ -f /opt/php/BUILD-DEPS ]; then cat /opt/php/BUILD-DEPS; fi; \
      if [ -f /opt/php/BUILD-PEAR ]; then cat /opt/php/BUILD-PEAR; fi; \
      echo "patchset_approved=${PATCHSET_APPROVED}"; \
      echo "docker_php_ext_tools=${DOCKER_PHP_EXT_SRC_COMMIT}"; \
      if [ -f /opt/php/BUILD-CLEANUP ]; then cat /opt/php/BUILD-CLEANUP; fi; \
      if [ -f /opt/php/BUILD-PECL ]; then cat /opt/php/BUILD-PECL; fi; \
      if [ -f /opt/php/BUILD-COMPOSER ]; then \
        echo "composer=$(head -1 /opt/php/BUILD-COMPOSER)"; \
        grep -E '^composer_' /opt/php/BUILD-COMPOSER; \
      fi; \
      echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
      echo "patch_digests:"; \
      if [ -d /opt/patches ]; then \
        find /opt/patches -type f -print | sort | xargs sha256sum | sed 's/^/  /'; \
      fi; \
    } > /opt/php/BUILD-PROVENANCE; \
    cat /opt/php/BUILD-PROVENANCE

# --- Runtime stage ------------------------------------------------------------
# Keep the same base image as the build stage for the first validated version
# of this kit, so libc/OpenSSL ABI match by construction. RUNTIME_PACKAGES may
# be overridden from the manifest once package versions are explicitly pinned.
FROM ${BASE_IMAGE} AS runtime

ARG PHP_VERSION
ARG PHP_VARIANT=fpm
ARG OPENSSL_ROUTE
# Re-declared for the two jobs below: deciding which shared libraries the
# requested extensions link against, and labelling the image with the extension
# set it ships. These are the EXTRA lists (additive over the baseline, exactly as
# the manifest states them), so the empty default means "baseline only" here too
# -- the same reading the build stage gives them. The full resolved set, baseline
# included, is in /opt/php/BUILD-PROVENANCE as extensions_core/extensions_pecl.
ARG PHP_EXTENSIONS=""
ARG PECL_EXTENSIONS=""
ARG RUNTIME_PACKAGES=""
# Re-declared so the labels below can carry them: an ARG stops being visible at
# the end of its stage, and a build arg the caller passes is picked up again per
# stage. The defaults only apply when a caller omits the value.
ARG BASE_IMAGE="unknown"
ARG PHP_SRC_COMMIT="unknown"
ARG BUILD_SOURCE_REF="unknown"
ARG GIT_REVISION="unknown"
ARG BUILD_MODE="local"
# Every label KEY is written out here rather than interpolated from a
# caller-supplied "key=value" blob. BuildKit does not substitute an ARG default
# into a LABEL *key* position, so `LABEL ${PROVENANCE_LABELS}` with an unset or
# empty blob fails the whole build ("LABEL must have two arguments") -- which is
# exactly what happened to any local `./build.sh`, because only the release
# pipeline ever passed that blob. Values, on the other hand, expand fine, so the
# provenance a consumer reads with `docker inspect` comes from ARGs.
LABEL org.opencontainers.image.title="php-legacy-security-kit" \
      org.opencontainers.image.version="${PHP_VERSION}" \
      org.opencontainers.image.revision="${GIT_REVISION}" \
      dev.php-legacy.build-mode="${BUILD_MODE}" \
      dev.php-legacy.php-version="${PHP_VERSION}" \
      dev.php-legacy.variant="${PHP_VARIANT}" \
      dev.php-legacy.openssl-route="${OPENSSL_ROUTE}" \
      dev.php-legacy.source-repo="https://github.com/shivammathur/php-src-backports" \
      dev.php-legacy.source-commit="${PHP_SRC_COMMIT}" \
      dev.php-legacy.source-ref="${BUILD_SOURCE_REF}" \
      dev.php-legacy.base-image="${BASE_IMAGE}" \
      dev.php-legacy.extensions-extra-core="${PHP_EXTENSIONS}" \
      dev.php-legacy.extensions-extra-pecl="${PECL_EXTENSIONS}"
ENV PATH="/opt/php/bin:/opt/php/sbin:${PATH}"
ENV DEBIAN_FRONTEND=noninteractive
# Official-image environment contract, adapted to our /opt/php prefix.
ENV PHP_INI_DIR=/opt/php/etc
# Conservative, version-agnostic flags (official images add -Wp,-D_FORTIFY_SOURCE=2
# on newer series only). Downstream docker-php-ext-install builds inherit these.
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -pie"
# Composer warns (1.x) or errors (2.x plugins) when run as root without this;
# containers commonly run builds as root, same as official composer images.
ENV COMPOSER_ALLOW_SUPERUSER=1

# binutils provides readelf, required by docker-php-ext-enable.
# unzip is required by Composer 2 to install dist packages.
# openssl provides the CLI that verify-runtime uses to prove the runtime
# library matches OPENSSL_ROUTE; it is installed unconditionally because a
# RUNTIME_PACKAGES override must not be able to remove the ability to audit.
# The Acquire::Retries option matches the build stage (see the note there).
RUN set -eux; \
    command -v apt-get >/dev/null; \
    # The same shape rule the build-stage guard applies, re-checked here \
    # because this stage resolves its argument list independently. Unquoted \
    # expansion in the loop below cannot execute anything -- word splitting \
    # does not honour shell metacharacters, it only produces more words -- but \
    # a name that is not an extension name reaches no mapping in the case \
    # beneath it, and the image would then ship an extension whose library is \
    # missing, which is the silent failure this kit refuses everywhere else. \
    # Two stages must not disagree about when a manifest value is malformed. \
    for e in ${PHP_EXTENSIONS} ${PECL_EXTENSIONS}; do \
      case "${e}" in \
        *[!a-z0-9_]*) echo "Invalid extension name '${e}' in PHP_EXTENSIONS/PECL_EXTENSIONS (allowed: [a-z0-9_])" >&2; exit 2;; \
      esac; \
    done; \
    # version-branch: ext-runtime-libs \
    # An extension added to the requested set drags its runtime library into \
    # this stage, or it fails to load at container start -- the same class of \
    # failure that once died at verify-runtime with "libxml2.so.2: error while \
    # loading shared libraries". Derived from PHP_EXTENSIONS rather than from the \
    # route lists, and appended even when RUNTIME_PACKAGES overrides them: a \
    # manifest that pins its own runtime packages must not be able to drop a \
    # library an extension it asked for is linked against. Baseline extensions are \
    # not here because the route lists below already carry all of them. \
    ext_runtime_libs=""; \
    for e in ${PHP_EXTENSIONS}; do \
      case "${e}" in \
        # libmcrypt4's package name is the same on every candidate suite \
        # (measured 2026-10-31: bullseye 2.5.8-3.4, bookworm 2.5.8-7, \
        # trixie 2.5.8-8), so one entry covers both routes. \
        mcrypt) ext_runtime_libs="${ext_runtime_libs} libmcrypt4" ;; \
      esac; \
    done; \
    # version-branch: bullseye-archive-security \
    # Same bullseye archive redirect as the build stage (see the note there for
    # the measurements); the runtime libraries -- libssl1.1 above all -- come
    # from the security suite, so without it this stage 404s on an image whose
    # build stage succeeded. Keyed on the base being Debian 11, not on the
    # OpenSSL route, because it is an OS fact rather than a PHP one. \
    if sh -c '. /etc/os-release; [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 11 ]'; then \
      sed -i 's#deb\.debian\.org/debian-security#archive.debian.org/debian-security#' /etc/apt/sources.list; \
      grep -q 'archive.debian.org/debian-security' /etc/apt/sources.list; \
    fi; \
    # Same release probe as the build stage. The runtime library names below are
    # chosen by Debian release rather than by OpenSSL route, because the 64-bit
    # time (t64) transition renamed four of them -- an OS fact, not a PHP one. \
    deb_codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-unknown}")"; \
    echo "runtime package names selected for Debian [${deb_codename}]"; \
    apt-get -o Acquire::Retries=3 update; \
    # Same OS-package refresh the build stage applies (see the note there for \
    # the measurements and for why the phasing override and the removal gate are \
    # part of it). Re-run rather than inherited, because this stage is a separate \
    # filesystem: the packages it preinstalls are the base digest's, not the build \
    # stage's upgraded ones, and the ones installed below are chosen against the \
    # lists fetched here. Two stages that ship one image must not disagree about \
    # which OS versions they carry. \
    os_removals="$(apt-get -o Acquire::Retries=3 \
        -o APT::Get::Always-Include-Phasing=experimental \
        -s dist-upgrade -y --no-install-recommends \
        | sed -n 's/^[0-9]* upgraded, [0-9]* newly installed, \([0-9]*\) to remove.*/\1/p')"; \
    if [ "${os_removals:-none}" != "0" ]; then \
      echo "apt dist-upgrade on this base would remove '${os_removals}' package(s); refusing to refresh" >&2; \
      exit 2; \
    fi; \
    apt-get -o Acquire::Retries=3 -o APT::Get::Always-Include-Phasing=experimental \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      dist-upgrade -y --no-install-recommends; \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends binutils unzip openssl; \
    if [ -n "${RUNTIME_PACKAGES}" ]; then \
      # Manifest-pinned list wins; it must match the base OS and must include
      # every library the build linked against (plus binutils). \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends ca-certificates ${RUNTIME_PACKAGES}; \
    else \
      case "${OPENSSL_ROUTE}" in \
        openssl11) \
          # Names measured, not assumed (2026-10-31, against the pinned bullseye
          # digest, with apt-cache search inside that image): bullseye ships
          # libmemcached11 (1.0.18) and libwebp6. libmemcached10 and libwebp7 are
          # buster-era SONAMEs and have no candidate on bullseye -- an install of
          # this list as written before that measurement failed with
          # "Unable to locate package libmemcached10 / libwebp7".
          #
          # libxml2 is here because the build now installs libxml2-dev, and the
          # compiled binary links libxml2.so.2 for the always-on DOM/SimpleXML/ext
          # XML. Measured on the build stage with `ldd /opt/php/bin/php` piped
          # through `dpkg -S`: every SONAME in that closure has to resolve, and
          # this list is the direct set -- apt pulls the rest (libcurl4 brings
          # libnghttp2-14/libidn2-0/libpsl5/libssh2-1/librtmp1/libgssapi-krb5-2/
          # libldap-2.4-2/libbrotli1, libxml2 brings libicu67/liblzma5/libzstd1).
          # The runtime image without libxml2 died at verify-runtime with
          # "error while loading shared libraries: libxml2.so.2". \
          apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
            ca-certificates libssl1.1 libcurl4 zlib1g libzip4 libmemcached11 \
            libjpeg62-turbo libpng16-16 libfreetype6 libwebp6 libonig5 \
            libxml2 libsqlite3-0 ;; \
        openssl3) \
          # Measured the same way (2026-10-31) against debian:bookworm-slim: every
          # name below has a candidate there (libssl3 3.0.22, libmemcached11 1.1.4,
          # libwebp7 1.2.4, libzip4 1.7.3, libonig5 6.9.8). bookworm's libxml2 is
          # the same SONAME (libxml2.so.2). \
          openssl3_rt="ca-certificates libssl3 libcurl4 zlib1g libzip4 libmemcached11 \
            libjpeg62-turbo libpng16-16 libfreetype6 libwebp7 libonig5 \
            libxml2 libsqlite3-0"; \
          # trixie (Debian 13) is the same libraries under different package names: \
          # the 64-bit-time transition took the SONAME-less ones with it, and libzip \
          # moved up a SONAME. Measured 2026-11-03 against packages.debian.org and \
          # again against the trixie/trixie-security Packages index from inside a \
          # container, which is what apt actually reads -- libssl3, libcurl4, \
          # libpng16-16, libmemcached11 and libzip4 have no stanza in that index at \
          # all (absent, not transitional, so they cannot half-work), and their \
          # candidates are libssl3t64 3.5.7-1~deb13u3, libcurl4t64 8.14.1-2+deb13u7, \
          # libpng16-16t64 1.6.48-1+deb13u6, libmemcached11t64 1.1.4-1.1 and \
          # libzip5 1.11.3-2, while zlib1g, libjpeg62-turbo, libfreetype6, libwebp7, \
          # libonig5, libxml2 (2.12.7+dfsg+really2.9.14, i.e. still libxml2.so.2) \
          # and libsqlite3-0 (3.46.1-7+deb13u2) keep their bookworm names. The SONAMEs \
          # the PHP binaries link are unchanged; only the packaging names moved, so a \
          # wrong list here shows up as "Unable to locate package", never as a quiet \
          # missing library -- and verify-runtime's ldd pass is the backstop either way. \
          case "${deb_codename}" in \
            trixie|forky|sid) \
              openssl3_rt="ca-certificates libssl3t64 libcurl4t64 zlib1g libzip5 libmemcached11t64 \
                libjpeg62-turbo libpng16-16t64 libfreetype6 libwebp7 libonig5 \
                libxml2 libsqlite3-0" ;; \
          esac; \
          apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
            $openssl3_rt ;; \
        *) echo "Unsupported OPENSSL_ROUTE: ${OPENSSL_ROUTE}" >&2; exit 2 ;; \
      esac; \
    fi; \
    # Extension-driven libraries, installed after the route list because they are \
    # the same in both branches and must survive a RUNTIME_PACKAGES override. \
    # Unquoted on purpose: ext_runtime_libs is a word list, empty when the \
    # requested set contains nothing outside the baseline. \
    if [ -n "${ext_runtime_libs}" ]; then \
      echo "Installing extension runtime libraries:${ext_runtime_libs}"; \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends ${ext_runtime_libs}; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/php /opt/php
# Official-image parity: the extension tooling and the (patched, pinned) source
# tree ship in the final image so downstream builds can run
# `docker-php-ext-install <ext>` / `pecl install` directly, exactly like
# `FROM php:8.1-fpm`. Trade-off: ~200MB image growth, same as official images.
COPY --from=build /usr/local/bin/docker-php-ext-configure \
                  /usr/local/bin/docker-php-ext-enable \
                  /usr/local/bin/docker-php-ext-install \
                  /usr/local/bin/docker-php-source \
                  /usr/local/bin/
COPY --from=build /usr/src/php /usr/src/php

# Runtime assertion harness. Shipped in the final image on purpose: it lets a
# downstream operator re-run the same checks (php -v, php-fpm -t, provenance,
# composer digest, ldd, OpenSSL route) against a pulled image without rebuilding.
COPY tools/verify-runtime.sh /usr/local/bin/verify-runtime

RUN set -eux; \
    chmod 0755 /usr/local/bin/verify-runtime; \
    sh -n /usr/local/bin/verify-runtime; \
    # OS inventory. A scanner finding against this image is only actionable if \
    # anyone can tell which Debian versions it was made against, and those are now \
    # decided at build time (digest-pinned base + the refresh above), not by the \
    # manifest. So record them in the image: consumers can diff two builds without \
    # rebuilding either, and tools/scan-image.sh compares a reported CVE against \
    # the version actually shipped instead of guessing from the base tag. \
    { \
      echo "base_image=${BASE_IMAGE}"; \
      echo "collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
      echo "format=source|package|version"; \
      dpkg-query -W -f='${source:Package}|${Package}|${Version}\n' | sort; \
    } > /opt/php/RUNTIME-OS-PACKAGES; \
    chmod 0644 /opt/php/RUNTIME-OS-PACKAGES; \
    if [ "${PHP_VARIANT}" = "fpm" ]; then \
      groupadd --system php-fpm; \
      useradd --system --gid php-fpm --home-dir /nonexistent --shell /usr/sbin/nologin php-fpm; \
      mkdir -p /var/www/html; \
      chown -R php-fpm:php-fpm /var/www/html; \
    fi; \
    PHP_VARIANT="${PHP_VARIANT}" \
    OPENSSL_ROUTE="${OPENSSL_ROUTE}" \
    verify-runtime

WORKDIR /var/www/html
EXPOSE 9000
# FPM variant: run the master in foreground. CLI variant: php-fpm is not
# installed, so drop into the interactive CLI (override with docker run args).
CMD ["/bin/sh", "-c", "if [ -x /opt/php/sbin/php-fpm ]; then exec /opt/php/sbin/php-fpm -F; else exec php -a; fi"]
