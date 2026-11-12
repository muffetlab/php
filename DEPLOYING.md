# Deploying the images

[README.md](README.md) is the one-minute start. This file is the rest of the
consumer surface, in the sections listed below and in the order a deployer meets
them.

Nothing here builds or publishes an image. The build framework (manifests, patch
review, the CI chain, the release model) is in [MAINTAINING.md](MAINTAINING.md);
what is available, per version, is in [SUPPORTED.md](SUPPORTED.md).

## Contents

- [Quick start](#quick-start)
- [Choosing a tag](#choosing-a-tag)
- [What each series is built against](#what-each-series-is-built-against)
- [Running FPM behind Nginx](#running-fpm-behind-nginx)
- [Configuring PHP](#configuring-php)
- [Configuring the FPM pool](#configuring-the-fpm-pool)
- [Adding extensions in a derived image](#adding-extensions-in-a-derived-image)
- [Checking what an image actually contains](#checking-what-an-image-actually-contains)
- [Runtime network model](#runtime-network-model)
- [Composer](#composer)

## Quick start

The one-minute start, including the `FROM` line for a derived image, is
[README.md](README.md#quick-start). What this file adds is the deployer's own
check: a one-shot CLI run and a CLI run against a read-only mount.

```sh
docker run --rm ghcr.io/muffetlab/php:8.1-cli php -v
docker run --rm -v "$PWD/app:/var/www/html:ro" \
  ghcr.io/muffetlab/php:8.1-cli php /var/www/html/artisan --version
```

The `fpm` variant listens on 9000 inside the container;
[Runtime network model](#runtime-network-model) covers how to expose it. Every
image ships `php`, `php-fpm` (fpm variant) and `composer` on `PATH`.

## Choosing a tag

```
ghcr.io/muffetlab/php:8.1-fpm          # floating minor tag: the recommended deploy tag
ghcr.io/muffetlab/php:8.1.34-r1-fpm    # exact tag, immutable by pipeline rule: PHP version + image revision + variant
```

Deploy `X.Y-<variant>` unless a log has to name the exact bytes. It cannot
change major version, and it points to the latest published build within its PHP
series, so the next security patch reaches every pull without a release cut on
your side.

`8.1.34-r1-fpm` and `8.1.34-r2-fpm` are two builds of the *same* PHP version: an
OS refresh that leaves the PHP pin alone, or a newer backports commit, bumps the
revision and keeps the PHP version. Exact tags are immutable by pipeline rule,
so pinning one pins one build forever; receiving a fix then means moving to the
newer revision, or to the floating tag. None of these names is a git tag: the
tag a release is made from marks source
([MAINTAINING.md](MAINTAINING.md#publishing-images)). A digest is the most exact
pin of the three: it binds to a manifest by content.

Things a tag does *not* tell you:

- **Whether it exists yet.** A series becomes pullable with its own release run.
  Which tags exist is a live registry fact no document copies:
  [SUPPORTED.md](SUPPORTED.md#checking-what-the-registry-serves) says how to read
  it; pulling anything else answers "manifest unknown". A `tested-in-CI` row means
  the image passes CI; the tag arrives with the series' release run.
- **Which series got refreshed.** A release rebuilds only the series it selects,
  so a 5.6 release does not move `8.1-cli`; the registry's answer says which
  floating tag moved, and to what.
- **The OpenSSL route.** The pipeline fixes one route per series, so a suffix
  could not express a choice you made. Read it out of the image instead:
  [Checking what an image actually contains](#checking-what-an-image-actually-contains).

There is no `latest` tag at all, for any variant, and nothing else that moves:
`<minor>-<variant>` is the only floating name and it cannot change major
version. [MAINTAINING.md](MAINTAINING.md#publishing-images) records why and
which gate keeps it that way.

## What each series is built against

| PHP series | OpenSSL route | Composer | Debian base |
| --- | --- | --- | --- |
| 5.6 | `openssl11`: OpenSSL 1.1.1w, frozen (README Security notice, the 5.6 item) | 1.10.28 | bullseye |
| 7.0–7.1 | `openssl3`, backported | 1.10.28 | bookworm |
| 7.2–7.3 | `openssl3`, backported | 2.11.0 | bookworm |
| 7.4–8.1 | `openssl3`: backported on 7.4, native from 8.0.13 / 8.1.0 | 2.11.0 | trixie |

The route is fixed per series: the build fails if the base image's OpenSSL major
disagrees with the route its manifest declares, so there is no choice for a tag
name to express. It is recorded in `/opt/php/BUILD-PROVENANCE`, in the
`dev.php-legacy.openssl-route` OCI label, in the [SUPPORTED.md](SUPPORTED.md)
table, and re-checked by the image's own `verify-runtime`. The point release
each series pins is a SUPPORTED.md fact: it moves with each release, so it is
read there.

## Running FPM behind Nginx

[`docker-compose.example.yml`](docker-compose.example.yml) and
[`nginx.conf.example`](nginx.conf.example) are a worked version of the network
model below: internal FPM network, Nginx as the only published port, FastCGI
with `try_files $uri =404`, dotfiles denied. Copy the service block per version
you expose.

The example publishes only Nginx (`80`/`443`) and keeps the FPM services on
`expose: 9000` inside `app-internal`, a network declared `internal: true`. Never
give an FPM service a `ports:` mapping. Whoever can reach a FastCGI endpoint can
choose `SCRIPT_FILENAME` and `PHP_VALUE` and execute code the application never
routed. That is why PHP's own FPM documentation warns against exposing it.
Only trusted services on that same network — in the example, Nginx — should be
able to connect.

One rule in the example must be kept: the app is mounted at the **same** path
(`/var/www/html`) in the Nginx container and in every FPM container.
`SCRIPT_FILENAME` crosses the network as a string and php-fpm opens it in its
own filesystem, so different paths on the two sides produce "Primary script
unknown", which reads like a Docker or permissions bug and is neither.

If `/var/www/html` reaches the app through a symlink, use
`$realpath_root$fastcgi_script_name`: the same value with symlinks resolved,
which is what a backend that validates paths prefers.

`$document_root` is Nginx's per-request `root`/`alias` value, evaluated inside
the Nginx container, so it works in containers as long as the two mounts agree.

The example's Nginx block serves HTTP only; publishing 443 means adding a
certificate and a second `server` block.

## Configuring PHP

`PHP_INI_DIR` is `/opt/php/etc` in both variants. The build copies PHP's
`php.ini-production` verbatim to `/opt/php/etc/php.ini` and does not modify it
afterwards.

The compiled-in scan directory is `/opt/php/etc/conf.d`. The vendored
`docker-php-ext-enable` writes each enabled extension to
`/opt/php/etc/conf.d/docker-php-ext-<name>.ini`. PHP reads these fragments after
the main `php.ini`, in alphabetical order, so a later fragment can override an
earlier setting.

```sh
# Mount into $PHP_INI_DIR/conf.d
docker run --rm \
  -v ./zz-custom.ini:/opt/php/etc/conf.d/zz-custom.ini:ro \
  ghcr.io/muffetlab/php:8.1-cli \
  php --ini
```

Name the file so it sorts after the fragment whose setting it overrides.
`php --ini` prints what the process actually loads, so the result is checkable
rather than assumed.

To keep fragments outside that directory instead, set `PHP_INI_SCAN_DIR`. The
variable replaces the scan list, so an empty entry retains the compiled-in
`conf.d`, extension fragments included:
`PHP_INI_SCAN_DIR=:/opt/php-ini-extra`. For a one-off run, pass
`php -d key=value`. That applies to the new process only: in the FPM container,
`docker exec` starts a separate CLI process and does not change the running FPM
configuration or workers.

## Configuring the FPM pool

`fpm` variant only; the CLI image has no FPM binary. The build retains the
upstream `.default` configuration files alongside the active files where
available, so the shipped state is inspectable inside the image:

| File | Shipped state |
| --- | --- |
| `/opt/php/etc/php-fpm.conf` | Based on the upstream default, with `daemonize = no` and `include=/opt/php/etc/php-fpm.d/*.conf` |
| `/opt/php/etc/php-fpm.d/www.conf` | Based on `www.conf.default` (7.x–8.x); `user`/`group = www-data`, `listen = 9000`, `clear_env = yes` |

The FPM command uses `-F` to stay in the foreground. `daemonize = no` keeps the
configuration consistent with that container behavior, and the container's life
is the FPM master's life, as expected for PID 1.

Ways to change the pool:

- **Override individual keys:** include a file that repeats the `[www]` section
  and sets only the keys to change. PHP-FPM merges a repeated pool section into
  the existing pool, and included files are read in filename sort order. Under
  the usual locale ordering the override must therefore sort after `www.conf` —
  `zz-overrides.conf`, not `my-pool.conf` — for its keys to win. The rest stays
  as shipped. For plain scalar directives this is last-one-wins; directives with
  their own handling rules may behave differently.
- **Add another pool:** add a separate `.conf` file under
  `/opt/php/etc/php-fpm.d/`, using a unique pool name and its own `listen`
  address; the `include` glob reads every `*.conf` there, and a section name
  that matches no existing pool creates a new one.
- **Replace the existing pool:** mount a replacement `www.conf` over the shipped
  one, or copy your own version into a derived image. Keep the `.default` sibling
  (7.x–8.x) in view while you do. PHP 5.6 has no `www.conf.default`: its build
  generates the pool configuration without an upstream template
  ([MAINTAINING.md](MAINTAINING.md#version-conditional-behaviour) records why).
  Copy the current file out first if you override there.

```ini
# zz-overrides.conf: repeat [www] and set only the keys to change
[www]
pm.max_children = 50
```

```sh
# Override selected www pool directives, then validate
docker run --rm \
  -v ./zz-overrides.conf:/opt/php/etc/php-fpm.d/zz-overrides.conf:ro \
  ghcr.io/muffetlab/php:8.1-fpm \
  /opt/php/sbin/php-fpm -t
```

`-t` parses the main configuration and all included files, catching invalid
pool definitions before deployment.

The shipped `clear_env = yes` is intentional: FPM clears inherited environment
variables from worker processes. For values that should reach PHP as request
variables, use FastCGI params (as the compose example's Nginx does). For a
worker that needs a specific process environment variable, set
`env[NAME] = $NAME` in the pool configuration. Set `clear_env = no` only when the
application deliberately needs the inherited container environment.

## Adding extensions in a derived image

The official `docker-php-ext-configure` / `docker-php-ext-install` /
`docker-php-ext-enable` / `docker-php-source` scripts are vendored unmodified
from `docker-library/php` at a pinned commit (Apache-2.0; see
[`docker-php-ext/README.md`](docker-php-ext/README.md)), and ship in every
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

The runtime image intentionally does not preinstall compilers (the same
trade-off the official images make), so the `apt-get install` line above is
where a derived build gets them.

The configured source tree at `/usr/src/php` is the expensive half of the
artifact, a few hundred MB depending on the series. A build can ship without it
(`SHIP_PHP_SOURCE=0` in the manifest), and then `docker-php-ext-install` and
PECL compiles do not work in that image. Which state a pulled image is in is
readable inside it: `/opt/php/BUILD-CLEANUP` records `source_tree_shipped`, and
an omitted tree is replaced by `/usr/src/php/SOURCE-NOT-SHIPPED`.

A PHP built from source on a distro base is easily over 1 GB, and most of that
is real: `php-fpm` plus its modules, the OpenSSL/libzip/libpng stack and the
extension headers. Each build measures its own totals and writes them to its CI
job summary through `tools/report-image-size.sh`. The cleanup rules, and why the
build refuses to trim the configured tree, are in
[MAINTAINING.md](MAINTAINING.md#how-the-image-stays-slim-without-losing-the-audit-trail).

**Known limitation on the old series.** `extension=name` resolves against the
extension directory exactly as written; the loader that also tries `name.so` was
measured on 8.1, while 5.6.40 and 7.1 fail on the bare form. The vendored
`docker-php-ext-enable` writes the name it is given. So
`docker-php-ext-enable intl.so` works on every series, whereas the bare form that
`docker-php-ext-install` generates needs fixing afterwards. The workaround, the
planned suffix-aware helper fix and the current status are recorded as a known
limitation in
[MAINTAINING.md](MAINTAINING.md#dockerfile-caveats-read-before-trusting-a-build)
caveat 1.

What an image can build is decided when the image is built: a `RUN` line can
request only extensions this kit's sources compile on that series; `mcrypt` on
7.2+ is the example (removed from core in 7.2, and the PECL replacement floors
at PHP 7.2.0). Wiring one in is a reviewed change to the build:
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
  route and version, PECL pins, the resolved extension set (`extensions_core` /
  `extensions_pecl`), the effective build package list and the Composer version
  plus phar digest the image was built from. The `dev.php-legacy.openssl-route`
  and `dev.php-legacy.extensions-extra-*` OCI labels carry the same facts, but the
  extension labels show only what a manifest *added*; read `extensions_core` for
  what the image actually ships.
- `RUNTIME-OS-PACKAGES` records every Debian package actually installed in the
  image, by source name and version.
- `verify-runtime` re-checks those claims against the image you actually pulled,
  so a mismatch between the record and the bytes is detectable without rebuilding
  anything.

## Runtime network model

Run FPM on an internal Docker network (`internal: true`) and expose only
Nginx/HTTPS publicly. Do not publish port 9000 on the host or reach it across
networks: a FastCGI endpoint that untrusted clients can reach is a code
execution path, so only trusted services on the same network should connect.
Use a read-only root filesystem where feasible, drop capabilities, use
`no-new-privileges`, and mount application files read-only unless writes are
required. The CLI variant is intended for one-shot/`exec` workloads
(`docker run --rm image php script.php`); the FPM variant is the long-running
service.

## Composer

Every image ships `composer` on `PATH` at `/opt/php/bin/composer`, pinned per
series as in
[What each series is built against](#what-each-series-is-built-against): 2.x
requires PHP >= 7.2.5, so 5.6 / 7.0 / 7.1 stay on the final 1.x release.

For a `FROM` of one of these images: `COMPOSER_ALLOW_SUPERUSER=1` is preset,
`unzip` is installed (Composer 2 dist extraction needs it), and
`composer install` still needs network access to your repositories: nothing is
vendored.
