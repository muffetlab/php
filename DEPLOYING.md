# Running the images

[README.md](README.md) is the one-minute start. This file is the rest of the
consumer surface: which tag to deploy, how to configure PHP and FPM without
rebuilding, how to add an extension in a derived image, how to read an image's
own build evidence, and how the example Nginx/FPM topology is meant to be
networked.

Nothing here builds or publishes an image. The build framework — manifests,
patch review, the CI chain, the release model — is in
[MAINTAINING.md](MAINTAINING.md); what is currently available, per version, is
in [SUPPORTED.md](SUPPORTED.md).

## Choosing a tag

```
ghcr.io/muffetlab/php:8.1-fpm          # floating minor tag — the recommended deploy tag
ghcr.io/muffetlab/php:8.1.34-r1-fpm    # immutable exact tag — PHP version + image revision + variant
```

Deploy `X.Y-<variant>` unless a log has to name the exact bytes. It cannot
change major version, and every release run moves it to that run's build, so the
next security patch reaches every pull without a release cut on your side.

`8.1.34-r1-fpm` and `8.1.34-r2-fpm` are two builds of the *same* PHP version:
an OS refresh that leaves the PHP pin alone, or a newer backports commit, bumps
the image revision rather than the PHP version. Exact tags are never moved, so
pinning one pins one build forever — receiving a fix then means moving to the
newer revision, or to the floating tag. None of these names is a git tag: the
tag a release is made from marks source, not an image, and
[MAINTAINING.md](MAINTAINING.md) ("Publishing images") describes it.

The digest beats both names: it is the only handle that binds to a manifest by
content rather than by name.

Things a tag does *not* tell you:

- **Whether it exists yet.** A series is pullable from its own release run on.
  Which tags exist is a live registry fact, and
  [SUPPORTED.md](SUPPORTED.md)'s generated "Release tags" section names them
  (read out of the registry at generation time); pulling anything else answers
  "manifest unknown". A `tested-in-CI` row means the image passes the project's
  CI build and runtime checks, not that a tag was published.
- **Which series got refreshed.** A release rebuilds only the series it selects, so a
  release of the 5.6 series does not move `8.1-cli`; [SUPPORTED.md](SUPPORTED.md)'s
  registry-read section shows what each floating tag resolved to when it was generated.
- **The OpenSSL route.** The pipeline fixes one route per series, so a suffix
  could not express a choice you made. Read it out of the image instead —
  see [Checking what an image actually contains](#checking-what-an-image-actually-contains).

There is no `latest` tag at all, for any variant, and nothing else that moves:
`<minor>-<variant>` is the only floating name and it cannot change major version.
[MAINTAINING.md](MAINTAINING.md) ("Publishing images") records why the pipeline
publishes no such name and which gate keeps it that way.

## What each series is built against

| PHP series | OpenSSL route | Composer | Debian base |
| --- | --- | --- | --- |
| 5.6 | `openssl11` — OpenSSL 1.1.1w, frozen (README Security notice, the 5.6 item) | 1.10.28 | bullseye |
| 7.0–7.1 | `openssl3`, backported | 1.10.28 | bookworm |
| 7.2–7.3 | `openssl3`, backported | 2.11.0 | bookworm |
| 7.4–8.1 | `openssl3` — backported on 7.4, native from 8.0.13 / 8.1.0 | 2.11.0 | trixie |

The route is fixed per series, not chosen per deployment: the build fails if the
base image's OpenSSL major disagrees with the route its manifest declares, so
there is no choice for a tag name to express. It is recorded in
`/opt/php/BUILD-PROVENANCE`, in the `dev.php-legacy.openssl-route` OCI label, in
the [SUPPORTED.md](SUPPORTED.md) table, and re-checked by the image's own
`verify-runtime`. The point release each series pins is a SUPPORTED.md fact (it
moves with each release), not a table to copy here.

## Quick start

```dockerfile
FROM ghcr.io/muffetlab/php:8.1-fpm
COPY ./my-app /var/www/html
```

```sh
docker run --rm ghcr.io/muffetlab/php:8.1-cli php -v
docker run --rm -v "$PWD/app:/var/www/html:ro" \
  ghcr.io/muffetlab/php:8.1-cli php /var/www/html/artisan --version
```

The `fpm` variant listens on 9000 inside the container and is meant to sit
behind a web server; the `cli` variant is for one-shot and `docker exec`
workloads, not a long-running service. Every image ships `php`, `php-fpm` (fpm
variant) and `composer` on `PATH`.

## Running FPM behind Nginx

[`docker-compose.example.yml`](docker-compose.example.yml) and
[`nginx.conf.example`](nginx.conf.example) are a worked version of the network
model below: internal FPM network, Nginx as the only published port, FastCGI
with `try_files $uri =404`, dotfiles denied. Copy the service block per version
you expose.

One rule in the example is load-bearing: the app is mounted at the **same** path
(`/var/www/html`) in the Nginx container and in every FPM container.
`SCRIPT_FILENAME` crosses the network as a string and php-fpm opens it in its
own filesystem, so different paths on the two sides produce "Primary script
unknown" — which reads like a Docker or permissions bug and is neither. If
`/var/www/html` reaches the app through a symlink, use
`$realpath_root$fastcgi_script_name`: the same value with symlinks resolved,
which is what a backend that validates paths prefers. `$document_root` is
Nginx's per-request `root`/`alias` value, not a host variable, so it works in
containers as long as the two mounts agree.

The example's Nginx block serves HTTP only; publishing 443 means adding a
certificate and a second `server` block.

## Configuring PHP

`PHP_INI_DIR` is `/opt/php/etc` in both variants. The build copies PHP's own
`php.ini-production` verbatim to `/opt/php/etc/php.ini` and never edits it
afterwards; its `conf.d` subdirectory is the compiled-in scan dir, and the
vendored `docker-php-ext-enable` writes each enabled extension as
`/opt/php/etc/conf.d/docker-php-ext-<name>.ini` there. Order matters and is
overridable, not magic: files in `conf.d` are parsed after the main `php.ini`,
so a mounted fragment wins.

```sh
# an extra ini read after php.ini; later files inside the dir also win
docker run --rm -v ./zz-override.ini:/opt/php/etc/conf.d/zz-override.ini:ro \
  ghcr.io/muffetlab/php:8.1-fpm php -r 'echo ini_get("memory_limit");'
```

That leaves exactly three supported ways to change a PHP setting. The third:

- `PHP_INI_SCAN_DIR`, as an environment variable, **replaces** the scanned
  directory list. To add a directory without losing the default one (extension
  fragments included), keep an empty entry for the compiled-in dir:
  `PHP_INI_SCAN_DIR=:/opt/my/extra` (verified: a setting from the extra dir
  takes effect and the shipped fragments still load).
- `php -d ...` one-offs (CLI variant, or `docker exec` into the FPM container
  for a quick probe). Nothing persistent, no mount.

`php --ini` in either variant prints the effective main file, scan dir and
parsed files — the cheap way to prove which set a container really uses. The
facts above were verified against the published `8.1-fpm` image on 2026-11-03.

## Configuring the FPM pool

`fpm` variant only; the CLI image has no FPM binary. The build leaves
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

- Add a pool or a pool override as its own file in
  `/opt/php/etc/php-fpm.d/` (mount one as
  `-v ./my-pool.conf:/opt/php/etc/php-fpm.d/10-my.conf:ro`); the `include` glob
  reads every `*.conf` there. A later file's setting wins the key it touches, so
  a small override file beats editing `www.conf` in a derived image.
- Replace `www.conf` wholesale. Keep its `.default` sibling in view (7.x–8.x)
  while you do; PHP 5.6 has no `www.conf.default` — its build generates the pool
  file against no upstream template ([MAINTAINING.md](MAINTAINING.md#version-conditional-behaviour)
  records why) — so copy the current file out first if you override there.
- Validate without starting: `/opt/php/sbin/php-fpm -t` parses the full config
  including every included file.

`clear_env = yes` is deliberate and load-bearing: FPM does not pass the
container's environment to workers, so application configuration travels via
FastCGI params (as the compose example's Nginx does), via the pool file's
`env[NAME] = value`, or by flipping this directive — in that order of
preference.

## Adding extensions in a derived image

The official `docker-php-ext-configure` / `docker-php-ext-install` /
`docker-php-ext-enable` / `docker-php-source` scripts are vendored unmodified
from `docker-library/php` at a pinned commit (Apache-2.0, hash-verified in CI —
see [`docker-php-ext/README.md`](docker-php-ext/README.md)), and ship in every
published image together with the patched source tree at `/usr/src/php` and the
`PHP_INI_DIR` / `PHP_CFLAGS` environment variables. Derived images work exactly
like `FROM php:<version>`:

```dockerfile
FROM ghcr.io/muffetlab/php:8.1-fpm
RUN apt-get update && apt-get install -y --no-install-recommends \
      libicu-dev g++ make autoconf \
    && docker-php-ext-install intl \
    && pecl install igbinary && docker-php-ext-enable igbinary \
    && rm -rf /var/lib/apt/lists/*
```

The runtime image intentionally does not preinstall compilers (same as the
official images), and the source tree shipping in the final image costs about
313 MB (measured on `5.6` / bullseye: 710.3 MB uncompressed with the tree,
320.5 MB with `SHIP_PHP_SOURCE=0`) — the same trade-off the official images
make. If you build nothing inside the image, `SHIP_PHP_SOURCE=0` is the cheaper
manifest, at the cost of `docker-php-ext-install` and PECL compiles not working
there.

**Known limitation on the old series.** PHP before 7.4 loads `extension=name`
only if the name includes the `.so` suffix (measured on 5.6.40 and 7.1), and the
vendored `docker-php-ext-enable` writes the name it is given. So
`docker-php-ext-enable intl.so` works everywhere, whereas the bare form that
`docker-php-ext-install` generates needs fixing afterwards. The remedy
(suffix-aware helper versus documentation rule) is an open maintainer decision;
see [MAINTAINING.md](MAINTAINING.md#dockerfile-caveats-read-before-trusting-a-build)
caveat 3.

What an image can build is decided when the image is built, so an extension this
kit's sources cannot compile on that series is not something a `RUN` line can
request — `mcrypt` on 7.2+ is the example (removed from core in 7.2, and the PECL
replacement floors at PHP 7.2.0). Wiring one in is a reviewed change to the build:
[MAINTAINING.md](MAINTAINING.md#per-version-extension-sets) has the availability
table and what each step costs, and
[MAINTAINING.md](MAINTAINING.md#version-conditional-behaviour) inventories every
place the kit branches by version.

## Checking what an image actually contains

A tag name cannot tell you the OpenSSL route or the extension set, so the image
carries both:

```bash
docker run --rm --entrypoint cat ghcr.io/muffetlab/php:8.1-fpm /opt/php/BUILD-PROVENANCE
docker run --rm --entrypoint cat ghcr.io/muffetlab/php:8.1-fpm /opt/php/RUNTIME-OS-PACKAGES
docker run --rm --entrypoint /usr/local/bin/verify-runtime ghcr.io/muffetlab/php:8.1-fpm
```

- `BUILD-PROVENANCE` records the base digest, source repo/ref/commit, OpenSSL
  route and version, PECL pins, the resolved extension set
  (`extensions_core` / `extensions_pecl`), the effective build package list and
  the Composer version plus phar digest the image was built from. The
  `dev.php-legacy.openssl-route` and `dev.php-legacy.extensions-extra-*` OCI
  labels carry the same facts, but the extension labels show only what a
  manifest *added* — read `extensions_core` for what the image actually ships.
- `RUNTIME-OS-PACKAGES` records every Debian package actually installed in the
  image, by source name and version.
- `verify-runtime` re-checks those claims against the image you actually pulled,
  so a mismatch between the record and the bytes is detectable without
  rebuilding anything.

## Runtime network model

Run FPM on an internal Docker network and expose only Nginx/HTTPS publicly. Do
not publish port 9000 to the internet. Use a read-only root filesystem where
feasible, drop capabilities, use `no-new-privileges`, and mount application
files read-only unless writes are required. The CLI variant is intended for
one-shot/`exec` workloads (`docker run --rm image php script.php`), not as a
long-running service.

## Composer

Every image ships `composer` on `PATH` at `/opt/php/bin/composer`, pinned per PHP
series as in [What each series is built against](#what-each-series-is-built-against):
2.x requires PHP >= 7.2.5, which is why 5.6 / 7.0 / 7.1 stay on the final 1.x
release. Both the installer and the installed phar are SHA-256
verified against pinned digests, and the image records the version, the digest
and whether it was verified; the trust model is in
[MAINTAINING.md](MAINTAINING.md#composer-trust-model).

Practical notes for a `FROM` of one of these images: `COMPOSER_ALLOW_SUPERUSER=1`
is preset, `unzip` is installed (Composer 2 dist extraction needs it), and a
`composer install` still needs network access to whatever repository you depend
on — nothing here is vendored.

## What the image weighs

A PHP built from source on a distro base is easily over 1 GB, and most of that
is real: `php-fpm` plus its modules, the OpenSSL/libzip/libpng stack and the
extension headers. Measured on the first real 5.6 build (bullseye, arm64):
710.3 MB uncompressed with the source tree in it, 320.5 MB with
`SHIP_PHP_SOURCE=0`. Totals for the other seven series come from the CI job
summary of their first builds. The cleanup rules, and why the build refuses to
trim the configured tree, are in
[MAINTAINING.md](MAINTAINING.md#how-the-image-stays-slim-without-losing-the-audit-trail).

## Where to read next

- [README.md](README.md) — what the project is, the version list, the security notice
- [SUPPORTED.md](SUPPORTED.md) — per-version pins, base image, review status, published tags
- [SECURITY.md](SECURITY.md) — what "supported" means here, known limits, how to report a vulnerability
- [DISCLAIMER.md](DISCLAIMER.md) — the responsibility boundary
- [manifests/OS-CVE-STATUS.md](manifests/OS-CVE-STATUS.md) — the Debian side of the same question
- [MAINTAINING.md](MAINTAINING.md) — build it yourself, review a patchset, publish a release
