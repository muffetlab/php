# Legacy PHP security images (PHP 5.6 – 8.1, CLI + FPM)

> **Read [DISCLAIMER.md](DISCLAIMER.md) and [SECURITY.md](SECURITY.md) first.**

The deliverable is a **set of Docker images**: PHP 5.6 – 8.1, `cli` and `fpm`,
built from a pinned source commit with the security backports that official PHP
stopped shipping for these lines. [SUPPORTED.md](SUPPORTED.md) is the status page
that tells you what is actually available: it shows, per version, what is
pinned, what base image it runs on, and how far the review has got.

This file is the consumer's view. The build framework behind the images —
manifests, patch review, CI chain, the release model — is documented in
[MAINTAINING.md](MAINTAINING.md), and you do not need any of it to pull and run
an image.

## Using the images

Published image: **`ghcr.io/muffetlab/php`** (a fork publishes under its own
namespace):

> A tag exists only once the series' own release run has written it, and which
> tags exist is therefore a release-history fact — [SUPPORTED.md](SUPPORTED.md)
> ("Release tags") states it, generated from the per-series release records in
> [manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md), so no document
> here asserts it by hand. Each existing tag is one multi-arch manifest list
> covering `linux/amd64` and `linux/arm64`, with a SLSA provenance statement and
> an SPDX SBOM attached per platform. A release run publishes the series it
> selects — one series for a single-series dispatch, every supported
> series at once for a `version=all` dispatch — and writes each of their exact and
> floating tags; the pipeline publishes no latest tag of
> any shape and fails closed at the merge if a leg did not push, so a
> half-published release cannot leave a name behind. See *Before you pull one*
> below.

```
ghcr.io/muffetlab/php:8.1-fpm             # minor tag: the recommended deploy tag
ghcr.io/muffetlab/php:8.1.34-r1-fpm       # exact PHP version + image revision + variant, for when a log must name what runs
```

There is no `latest` tag at all, for any variant. A bare `docker pull` of the
published image asks the registry for a `latest` and gets "manifest unknown", and
that is a decision rather than a missing convenience: a release run — a manual
dispatch naming one PHP series or `all` of
them — publishes the series it selected, so a `latest` name would resolve to
whichever series was released last —
releasing 7.4 after an 8.1 release would move it from 8.1
back to 7.4. That records the release order, not the code, and it is exactly the
silent major-version jump a legacy application must not inherit from a base image.
It could not even name the variant it meant: the one shape that makes a bare pull
work is the one that cannot say `cli` or `fpm`. `<minor>-<variant>` is the only
floating tag, and it cannot change major version. Pick the series you need from
[SUPPORTED.md](SUPPORTED.md), and read the removal note in MAINTAINING.md
("Publishing images") before adding any moving name back.

Every tag is a multi-arch manifest list covering `linux/amd64` and
`linux/arm64`, so `docker pull` gets the matching image on either architecture
without a `--platform` flag and without architecture-suffixed tag names.

```dockerfile
# A series is pullable from its first release run on, and SUPPORTED.md's
# generated "Release tags" section always names the exact tags that exist.
# This example's tag was written by an actual release run and stays valid.
FROM ghcr.io/muffetlab/php:8.1-fpm
COPY ./my-app /var/www/html
```

Recommended: deploy the minor tag, `X.Y-<variant>`. It cannot change major
version, and every release run moves it to that run's build, so the next security
patch reaches every pull without a release cut on your side.
There is one image name per build, and Exact tags are never moved: the first
release of PHP 8.1.34 publishes `8.1.34-r1-fpm`, and the fix on top of it — an OS
refresh that leaves the PHP pin alone, or a newer backports commit — publishes
`8.1.34-r2-fpm` *beside* it. The number is the image revision, set by whoever
dispatches the release. It is not in a git tag: a `vX.Y.Z` tag such as `v1.0.0` is
a source release tag, marking the commit a release was cut from, and it names
neither a PHP version nor a build — which is why one tag covers a release of eight
series, and why a run that dispatches from a commit with no source release tag
simply fails.
The consequence for a deployer is the flip side of that: pinning `8.1.34-r1-fpm`
pins one build forever, so receiving a fix means moving to the newer revision —
or to `X.Y-<variant>`, which is why it is the recommended one. SUPPORTED.md's
generated "Release tags" section names the exact tag currently behind each
floating name, read from the registry.
The digest still beats both: it is the only handle that binds to a manifest by
content rather than by name.
A release run rebuilds only the series it selects, so a release of the 5.6 series does
not refresh `8.1-cli`; each series moves when its own scope is dispatched, and the one
run that moves all eight at once is a `version=all` dispatch. Tags do not name
the OpenSSL route, because the
pipeline fixes one route per series (see below); to know what you are actually
running, read it out of the image:

```bash
docker run --rm --entrypoint cat ghcr.io/muffetlab/php:8.1-fpm /opt/php/BUILD-PROVENANCE
docker run --rm --entrypoint cat ghcr.io/muffetlab/php:8.1-fpm /opt/php/RUNTIME-OS-PACKAGES
docker run --rm --entrypoint /usr/local/bin/verify-runtime ghcr.io/muffetlab/php:8.1-fpm
```

`BUILD-PROVENANCE` records the base digest, source repo/ref/commit, OpenSSL
route and version, PECL pins, the resolved extension set, the effective build
package list and the Composer version plus phar digest the image was built from;
`RUNTIME-OS-PACKAGES` records every Debian package actually installed in the image,
by source name and version; `verify-runtime` re-checks
those claims against the image you actually pulled, so a mismatch is detectable
without rebuilding anything.

Every image ships `php`, `php-fpm` (fpm variant) and `composer` on `PATH`, the
extension set listed below, and — by default — the configured source tree, so
`docker-php-ext-install` works in a `FROM` of it exactly as in the official PHP
images.

**Before you pull one, read its row in [SUPPORTED.md](SUPPORTED.md).** A row
whose "Base image" says `digest placeholder — not buildable` cannot be built:
there is no image to pull, and CI skips it rather than force-releasing — a
release run for that series fails its readiness check instead of quietly
publishing nothing. Whatever a row actually records — pins, approval, the
status CI reached — two things it never means:

- **A row is not a published tag.** A `tested-in-CI` row means the image builds
  and behaves; a tag exists only once the series' own release run has written
  it. Pulling a series whose release run has not happened yet fails with
  "manifest unknown" — by design, exactly like pulling a `latest` name: the
  pipeline publishes no `latest` tag at all, see the note under *Using the
  images*. The tags that do exist are named by the generated "Release tags"
  section of [SUPPORTED.md](SUPPORTED.md).
- **It is not an approval, and it is not CVE proof.** The suite exercises the
  extension surface and the FPM pool, not the backported hunks; what a security
  review approves and what it covers is defined by the record in
  [manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md), not by a green
  CI row.

Targets:
- PHP 5.6, 7.0, 7.1, 7.2, 7.3, 7.4, 8.0, 8.1
- Two image variants per version: `cli` and `fpm` (PHP-FPM; deploy Nginx separately)
- Two architectures: `linux/amd64` and `linux/arm64`, built and tested natively on
  each architecture and published as one multi-arch manifest list per tag
- Extensions: a common baseline of `mysqli`, `pdo_mysql`, `gd`, `mbstring`, `curl`,
  `openssl`, `zip`, `zlib` plus PECL `apcu`, `redis` and `memcached` — plus
  `mcrypt` on 5.6–7.1, the series that can still build it in core, because
  legacy applications that call `mcrypt_*` are the reason a 5.6 image exists. The
  set each image actually has is recorded inside it (`/opt/php/BUILD-PROVENANCE`,
  keys `extensions_core` / `extensions_pecl`) and checked by the tests against
  that record, not assumed. The `dev.php-legacy.extensions-extra-*` labels show
  only what the manifest added.
  See [Per-version extension notes](#per-version-extension-notes).

Every version here is end-of-life upstream — official PHP stopped releasing for
8.0 in 2023 and 8.1 in December 2025, which is the whole reason this project
exists. Published images carry only the fixes that were backported, reviewed,
and recorded; they are not a security guarantee, and the durable fix is to
upgrade off EOL PHP.

## Two OpenSSL routes

Every image is built for exactly one OpenSSL major, and the build fails if the
base image's OpenSSL major does not match the route its manifest declares — base
system and OpenSSL have to agree per version, so the route is fixed by the series
rather than chosen per deployment. Because there is no choice to express, the
route is not part of a tag name: `5.6.40-r1-fpm` is the openssl11 build and
`8.1.34-r1-fpm` is an openssl3 build. Where the route *is* recorded is
`/opt/php/BUILD-PROVENANCE`, the `dev.php-legacy.openssl-route` OCI label, the
table below, and the image's own `verify-runtime`.

| Version | Route | Why |
| --- | --- | --- |
| 5.6 | `openssl11` | 5.6's OpenSSL 3 support, in every upstream 5.6 branch, is a 6-line compile patch: zero `0x30000000L` guards and no provider API use in `ext/openssl`, so nothing is 3.x-aware. Moving 5.6 to an OpenSSL 3 base was measured and declined; it stays on 1.1.1w, whose Debian base is no longer maintained (see *Important security limits* below). |
| 7.0–7.4 | `openssl3` | OpenSSL 3 support is backported, verified **for that exact minor version** in the pinned commit. |
| 8.0 | `openssl3` | Native support needs >= 8.0.13 (the pin is 8.0.30). |
| 8.1 | `openssl3` | Native support (>= 8.1.0; the pin is 8.1.34). |

Every series — including 8.0 and 8.1 — builds from
[`shivammathur/php-src-backports`](https://github.com/shivammathur/php-src-backports),
not from official `php/php-src`, because the official tree no longer carries
fixes for any of these lines. See MAINTAINING.md for how that source of record
is enforced.

## Composer

Every image ships `composer` on PATH at `/opt/php/bin/composer`, pinned per PHP
series:

| PHP series | Composer pin | Why |
| --- | --- | --- |
| 5.6 / 7.0 / 7.1 | **1.10.28** | Final 1.x release (2026-05-13); there is no later 1.10.x. Composer 2.11.0 declares `php: ^7.2.5 \|\| ^8.0`, so it cannot be used here at all. |
| 7.2 / 7.3 / 7.4 / 8.0 / 8.1 | **2.11.0** | Current stable 2.x (2026-10-29); satisfies the `>= 7.2.5` floor. |

Both the installer and the installed phar are SHA-256 verified against pinned
digests, and the image records the version, the digest and whether it was
verified — the trust model behind those pins is in
[MAINTAINING.md](MAINTAINING.md#composer-trust-model).

Practical notes for a `FROM` of one of these images: `COMPOSER_ALLOW_SUPERUSER=1`
is preset, `unzip` is installed (Composer 2 dist extraction needs it), and a
`composer install` still needs network access to whatever repository you depend
on — nothing here is vendored.

## Adding extensions like the official Docker PHP images

The official `docker-php-ext-configure` / `docker-php-ext-install` /
`docker-php-ext-enable` / `docker-php-source` scripts are vendored unmodified
from `docker-library/php` at a pinned commit (Apache-2.0, hash-verified in CI —
see `docker-php-ext/README.md`), and ship in every published image together
with the patched source tree at `/usr/src/php` and `PHP_INI_DIR` /
`PHP_CFLAGS` environment variables. Derived images work exactly like
`FROM php:<version>`:

```dockerfile
FROM ghcr.io/muffetlab/php:8.1-fpm
RUN apt-get update && apt-get install -y --no-install-recommends \
      libicu-dev g++ make autoconf \
    && docker-php-ext-install intl \
    && pecl install igbinary && docker-php-ext-enable igbinary \
    && rm -rf /var/lib/apt/lists/*
```

Note the runtime image intentionally does not preinstall compilers (same as
official images), and the source tree shipping in the final image costs about
313 MB (measured on `5.6` / bullseye: 710.3 MB uncompressed with the tree,
320.5 MB with `SHIP_PHP_SOURCE=0`), which is the same trade-off the official
images make.

Known limitation while adding extensions on the old series: PHP before 7.4 loads
`extension=name` only if the name includes the `.so` suffix (measured on 5.6.40
and 7.1), and the vendored `docker-php-ext-enable` writes the name it is given.
So `docker-php-ext-enable intl.so` works everywhere, whereas the bare form that
`docker-php-ext-install` generates needs fixing afterwards. The remedy (helper
command versus documentation rule) is an open maintainer decision; see
[MAINTAINING.md](MAINTAINING.md#dockerfile-caveats-read-before-trusting-a-build)
caveat 3.

## Configuring PHP and FPM

The image ships a complete configuration surface at fixed paths, and there are
exactly three supported ways to change PHP settings. Every fact below was
verified against the published `8.1-fpm` image (2026-11-03); where a variant
differs, it says so.

**PHP INI.** `PHP_INI_DIR` is `/opt/php/etc` in both variants. The build copies
PHP's own `php.ini-production` verbatim to `/opt/php/etc/php.ini` and never
edits it afterwards; its `conf.d` subdirectory is the compiled-in scan dir, and
the vendored `docker-php-ext-enable` writes each enabled extension as
`/opt/php/etc/conf.d/docker-php-ext-<name>.ini` there. Order matters and is
overridable, not magic: files in `conf.d` are parsed after the main `php.ini`,
so a mounted fragment wins:

```sh
# an extra ini read after php.ini; later files inside the dir also win
docker run --rm -v ./zz-override.ini:/opt/php/etc/conf.d/zz-override.ini:ro \
  ghcr.io/muffetlab/php:8.1-fpm php -r 'echo ini_get("memory_limit");'
```

Two more ways to set PHP options, each with a use it genuinely fits:

- `PHP_INI_SCAN_DIR`, as an environment variable, **replaces** the scanned
  directory list. To add a directory without losing the default one (extension
  fragments included), keep an empty entry for the compiled-in dir:
  `PHP_INI_SCAN_DIR=:/opt/my/extra` (verified: a setting from the extra dir
  takes effect and the shipped fragments still load).
- `php -d ...` one-offs (CLI variant, or `docker exec` into the FPM container
  for a quick probe). Nothing persistent, no mount.

`php --ini` in either variant prints the effective main file, scan dir and
parsed files — the cheap way to prove which set a container really uses.

**FPM (`fpm` variant only; the CLI image has no FPM binary).** The build leaves
`php-fpm.conf.default` in place alongside the live files, so the shipped state
is diffable inside the image itself:

| File | Shipped state |
| --- | --- |
| `/opt/php/etc/php-fpm.conf` | copied from the upstream default, `daemonize = no`, `include=/opt/php/etc/php-fpm.d/*.conf` |
| `/opt/php/etc/php-fpm.d/www.conf` | copied from `www.conf.default` (7.x–8.x); `user`/`group = php-fpm`, `listen = 9000`, `clear_env = yes` |

`daemonize = no` matches what the image's own entrypoint does — the CMD is
`exec /opt/php/sbin/php-fpm -F` — so the container's life is the FPM master's
life, as a good PID-1 should be.

Ways to change the pool, verified by `php-fpm -t` picking up an added file:

- Add a pool or pool override as its own file in
  `/opt/php/etc/php-fpm.d/` (mount one as `-v ./my-pool.conf:/opt/php/etc/php-fpm.d/10-my.conf:ro`);
  the `include` glob reads every `*.conf` there. A later file's setting wins
  the key it touches, so a small override file beats editing `www.conf` in a
  derived image.
- Replace `www.conf` wholesale. Keep its `.default` sibling in view (7.x–8.x)
  while you do; PHP 5.6 has no `www.conf.default` — the build generates its
  pool file against no upstream template (seen in the Dockerfile's
  `version-branch: fpm-www-conf-fallback` note) — so copy the current file out
  first if you override there.
- Validate without starting: `/opt/php/sbin/php-fpm -t` parses the full config
  including every included file.

`clear_env = yes` is deliberate and load-bearing: FPM does not pass the
container's environment to workers, so application configuration travels via
FastCGI params (as `docker-compose.example.yml`'s Nginx does), via the pool
file's `env[NAME] = value`, or by flipping this directive — in that order of
preference. See [Runtime network model](#runtime-network-model) for why an
FPM address should stay off the internet.

## Per-version extension notes

Every series ships the **same baseline** — `openssl curl mysqli pdo_mysql mbstring
zip gd zlib`, plus PECL `apcu redis memcached` — with one per-series append the
Dockerfile itself makes: `mcrypt` joins the core baseline on 5.6–7.1, the series
that can still build it in core (the PECL replacement floors at PHP 7.2.0). A
manifest may **add** to that where the series can build the extension, but today
no manifest does — the lists are additive by design: a manifest can grow the
set the image promises, never shrink it, and an unverifiable claim ("5.6 also has
mcrypt") reads as a one-line diff instead of a whole extension list to re-review.

What a series may ask for is decided in the Dockerfile, not in the manifest:
`mcrypt` lived in PHP core up to 7.1 and was removed in 7.2, so requesting it on
7.2+ fails the build at the guard step with a named reason rather than producing
a `./configure` warning and an image smaller than its own manifest claims. (The
PECL replacement is a different package with different pins and is not wired
here.) Names are validated as `[a-z0-9_]` in `build.sh`, in the Dockerfile guard
and in every CI gate that reads a manifest, because they are interpolated into
build-stage shell.

How each extension is wired still differs by version:

| Extension | 5.6–7.1 | 7.2–7.3 | 7.4 | 8.0–8.1 |
| --- | --- | --- | --- | --- |
| mysqli / pdo_mysql | `=mysqlnd` explicit | `=mysqlnd` explicit | `=mysqlnd` still accepted | bare flags only (`=mysqlnd` removed) |
| zip | system libzip (`--with-libzip` + `libzip-dev`) | bundled libzip | bundled | bundled |
| gd | `--with-gd --with-jpeg-dir --with-png-dir --with-freetype-dir` | same minus `--with-png-dir` (removed; libpng automatic) | renamed: `--enable-gd --with-jpeg --with-freetype`, native `--with-webp` | same as 7.4 |
| mbstring | bundled oniguruma | system oniguruma (`libonig-dev`) | system | system |
| openssl | OpenSSL 1.1 route; TLS 1.3 only if backported | OpenSSL 3 via backports; TLS 1.3 stream constant only from 7.4 (7.0–7.3 have none) | OpenSSL 3 via backports | native OpenSSL 3 (>= 8.0.13 / >= 8.1.0) |
| mcrypt | in the core baseline: `ext/mcrypt` + `--with-mcrypt`, dev package `libmcrypt-dev`, runtime `libmcrypt4` | not buildable: removed from core in 7.2 (PECL replacement floors at PHP 7.2.0) — a manifest value here is a build error | not buildable | not buildable |
| redis (PECL) | 5.6: 4.3.0 (last 5.6 release); 7.0–7.1: 5.3.7 (last with floor 7.0) | 6.0.2 (6.1.0 needs 7.4) | pinned 6.1.0 | pinned 6.1.0 |
| memcached (PECL) | pinned 2.2.0 + system libmemcached (`libmemcached11` runtime, measured on bullseye) | pinned 3.3.0 + system libmemcached (`libmemcached11` runtime) | same | same |
| apcu (PECL) | 5.6: 4.0.11 (last of the 4.0.x line, floor 5.3.0) | pinned 5.1.28 (floor 7.0.0-dev, read 2026-11-03) | pinned 5.1.28 | pinned 5.1.28 |
| composer | pinned 1.10.28 (2.x requires PHP >= 7.2.5) | pinned 2.11.0 | pinned 2.11.0 | pinned 2.11.0 |

PECL pins are bounded by each release's declared floor: `pecl install` refuses
a series below the `package.xml` `<php><min>`, so the table pins the newest
release that admits the series. redis 6.1.0 declares PHP >= 7.4.0, which is why
7.0–7.3 cannot share it.

The set is not only built, it is verified: the resolved lists are handed to every
later step through `/opt/php/BUILD-EXTENSIONS`, recorded in `BUILD-PROVENANCE` as
`extensions_core` / `extensions_pecl`, asserted by `verify-build`, and then
re-checked in the published image by `verify-runtime`, `tests/smoke.sh` and
`tests/extensions.sh`, each against *that image's* promised set. So a 5.6 image
fails if mcrypt is absent, and a non-mcrypt image fails if mcrypt turns up.

If your application needs an extension outside the standard set (e.g. `intl`,
`bcmath`, `soap`), add it per version and validate configure spelling against
the same boundaries — do not assume one flag list works across all eight
versions. Wiring one that the Dockerfile cannot yet build is a reviewed change to
that file (availability table, dev/runtime package mapping, configure flag), not a
manifest edit. Every place where the kit branches is inventoried in
[MAINTAINING.md](MAINTAINING.md#version-conditional-behaviour).

## What the image weighs

A PHP built from source on a distro base is easily over 1 GB, and most of that
is real: `php-fpm` plus its modules, the OpenSSL/libzip/libpng stack and the
extension headers. What the kit removes is the part the final image can never
use — the single-commit `.git` object store, the PHPT `tests/` suites, PECL and
apt caches. That is roughly half of the bundled source tree, measured from
`--depth 1` checkouts of two pinned commits with `du -sk`:

| Pin | Checked-out tree, excluding `.git`/`.github` | `*/tests` (PHPT) | `.github` | Tree left after cleanup |
| --- | --- | --- | --- | --- |
| 8.1.34 | 186.0 MB | 97.8 MB | 0.7 MB | ~88.2 MB |
| 5.6.40 | 143.6 MB | 73.5 MB | ~0 MB | ~70.1 MB |

Those are `du` block counts of a fresh checkout, which is not what ships: the
final image carries the *configured and built* tree. Measured on the first real
5.6 build (bullseye, arm64, `tools/report-image-size.sh`), the source tree is
312.8 MB of a 710.3 MB uncompressed image — 44% of it, and the cleanup step does
exactly what it records (`source_tree_kb_before_cleanup=420736` →
`source_tree_kb_after_cleanup=320592`). The same image with `SHIP_PHP_SOURCE=0`
is 320.5 MB, so not compiling extensions in the image buys back ~390 MB — at the
cost that `docker-php-ext-install` and PECL compiles stop working there. Totals
for the other seven series come from the CI job summary of their first builds.
The
cleanup rules, and why the build refuses to trim the configured tree, are in
[MAINTAINING.md](MAINTAINING.md#how-the-image-stays-slim-without-losing-the-audit-trail).

## Important security limits

1. PHP 5.6–7.4 are end-of-life upstream. A successful build does not make them fully supported or secure.
2. `shivammathur/php-src-backports` is the source of record for every series here, not a guarantee that every CVE is fixed. Its head commit for each series carries the current bailout/CVE-2026-109618-109619 work (see the review record), but coverage is what the pinned commit says it is — verify it per minor version, and verify with a build and test run before treating it as production evidence.
3. CVE-2026-109618 and CVE-2026-109619 (public since Oct 2026) need separate verification for **every** version in scope. Dedicated legacy-backport projects publish targeted patches for them, but those projects state their fix scope is limited and does not replace full security maintenance. If the fix is already in the pinned commit, do not apply the patch again.
4. This kit does **not** include unverified CVE patches. Do not add a patch merely because its filename mentions a CVE; every patch needs a review record (`patches/REVIEW-TEMPLATE.md`), and CI verifies each patch's SHA-256 against its record.
5. PHP 5.6's OpenSSL compatibility is a separate engineering problem, and so is its base. The 5.6 image is built on Debian bullseye because that is the Debian release carrying OpenSSL 1.1.1w; bullseye's LTS window closed on 2026-08-31 and its `-security` pool has moved to `archive.debian.org`, so the OpenSSL inside a 5.6 image is frozen at 1.1.1w-0+deb11u8 and there is no maintained security source behind it. Do not run that in an internet-facing production workload without accepting the freeze explicitly. The Dockerfile redirects that suite to the archive in both stages, so 5.6 builds reproducibly and users can still `apt-get` inside the image — the freeze is deliberate, not a broken mirror. The measured evidence and the decision are recorded in [manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md).
6. The Dockerfile uses `BASE_IMAGE` as both build and runtime base to avoid silently copying binaries across incompatible libc/OpenSSL environments. This is safer as a starting point, but it is not a multi-stage minimal runtime yet.

## Runtime network model

Run FPM on an internal Docker network and expose only Nginx/HTTPS publicly.
Do not publish port 9000 to the internet. Use a read-only root filesystem
where feasible, drop capabilities, use `no-new-privileges`, and mount
application files read-only unless writes are required. The CLI variant is
intended for one-shot/exec workloads (`docker run --rm image php script.php`),
not as a long-running service.

`docker-compose.example.yml` and `nginx.conf.example` are a worked version of
that: internal FPM network, Nginx as the only published port, FastCGI with
`try_files $uri =404` and dotfiles denied. Copy the service block per version
you expose. One rule in it is load-bearing: the app is mounted at the *same*
path (`/var/www/html`) in the Nginx container and in every FPM container,
because `SCRIPT_FILENAME` crosses the network as a string and php-fpm opens it
in its own filesystem — different paths on the two sides produce "Primary script
unknown". The example serves HTTP only; publishing 443 means adding a
certificate and a second `server` block.

## Where to read next

- [SUPPORTED.md](SUPPORTED.md) — per-version pins, base image, review status (generated; the truth about what is buildable today)
- [SECURITY.md](SECURITY.md) — what "supported" means here, how to report a vulnerability, which gates CI enforces
- [manifests/OS-CVE-STATUS.md](manifests/OS-CVE-STATUS.md) — the Debian side of the same question: every OS-package CVE reported against these images, what the image actually contains, and what the tracker says about a fix for the suite it is built on. Where the honest answer is "newer than this Debian release", the file says so and names the base bump as a decision not taken; trialling one is a CI dispatch, not a pin edit (see [MAINTAINING.md](MAINTAINING.md))
- [DISCLAIMER.md](DISCLAIMER.md) — the responsibility boundary
- [MAINTAINING.md](MAINTAINING.md) — build it yourself, review a patchset, cut a source release tag and dispatch a release, CI chain, repository layout
