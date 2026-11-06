# Legacy PHP Security Images

Security-backported Docker images for legacy PHP applications:
PHP 5.6–8.1, in `cli` and `fpm` variants.

Each image is built from an explicitly pinned commit of
[`shivammathur/php-src-backports`](https://github.com/shivammathur/php-src-backports),
a fork that backports security fixes from maintained PHP branches
to older, unmaintained versions. Each pin has a corresponding
review record documenting the patches included.

Published as **`ghcr.io/muffetlab/php`**, with a Docker Hub mirror.

[SUPPORTED.md](SUPPORTED.md) tracks pins, base images, review status
and published tags. [DEPLOYING.md](DEPLOYING.md) explains how to run
and configure the images.

## Available PHP versions

- PHP 5.6
- PHP 7.0–7.4
- PHP 8.0–8.1

All series ship `cli` and `fpm` variants on `amd64` and `arm64`.

Every tag is a multi-arch manifest list, so `docker pull` gets the matching platform
without a `--platform` flag and without architecture-suffixed names. What each series
is built against — OpenSSL route, Debian base, Composer pin, pinned point release —
is in [DEPLOYING.md](DEPLOYING.md) and [SUPPORTED.md](SUPPORTED.md); the 5.6
consequence is in the Security notice below.

**Before you pull, read the version's row in [SUPPORTED.md](SUPPORTED.md).** A row is never a
published tag (`tested-in-CI` means the image passes the project's CI build and runtime
checks; a tag exists only once that series' own release run has written it — anything else
answers "manifest unknown"), and never an approval or CVE proof: the suite tests the
extension surface and the FPM pool, not the backported hunks, whose record is
[`manifests/SECURITY-REVIEW.md`](manifests/SECURITY-REVIEW.md).

## Image tags

```
ghcr.io/muffetlab/php:8.1-fpm          # floating minor tag — the recommended deploy tag
ghcr.io/muffetlab/php:8.1.34-r1-fpm    # exact tag — PHP version + image revision + variant
```

- Deploy `X.Y-<variant>`: it cannot change major version, and every release run moves it to
  that run's build, so the next security patch reaches your pull without a release cut.
- `8.1.34-r1-fpm` → `8.1.34-r2-fpm` is a second build of the *same* PHP version: an OS refresh,
  or a newer backports commit that leaves the PHP pin alone, bumps the revision rather than
  the PHP version. Exact tags are never moved, so pinning one pins one build forever and
  receiving a fix means moving to the newer revision or to the floating tag.
- There is no `latest` tag at all, for any variant: `<minor>-<variant>` is the only
  moving name, and it cannot move past its own major. Why the pipeline publishes none —
  and the gate that keeps it that way — is MAINTAINING.md ("Publishing images").

## Quick start

```dockerfile
FROM ghcr.io/muffetlab/php:8.1-fpm
COPY ./my-app /var/www/html
```

```sh
docker run --rm ghcr.io/muffetlab/php:8.1-cli php -v           # CLI: one-shot work
docker run -d --network app-internal -v "$PWD/app:/var/www/html:ro" \
  ghcr.io/muffetlab/php:8.1-fpm                               # FPM: behind a web server
```

Every image ships `php`, `php-fpm` (fpm variant) and `composer` on `PATH`, the extension set
below, and — by default — the configured source tree, so `docker-php-ext-install` works in a
`FROM` of it as it does in the official PHP images. Read what the image you pulled really is:

```sh
docker run --rm --entrypoint cat ghcr.io/muffetlab/php:8.1-fpm /opt/php/BUILD-PROVENANCE
docker run --rm --entrypoint /usr/local/bin/verify-runtime ghcr.io/muffetlab/php:8.1-fpm
```

[`docker-compose.example.yml`](docker-compose.example.yml) and [`nginx.conf.example`](nginx.conf.example)
are the intended topology: internal FPM network, Nginx as the only published port.

## Available extensions

A common baseline in every image — `mysqli`, `pdo_mysql`, `gd`, `mbstring`,
`curl`, `openssl`, `zip`, `zlib`, plus PECL `apcu`, `redis`, `memcached` — and
`mcrypt` additionally on 5.6–7.1, the series that can still build it in core
(legacy applications that call `mcrypt_*` are the reason a 5.6 image exists).

What each image really has is recorded inside it, in `/opt/php/BUILD-PROVENANCE` — read that
instead of trusting this list; [DEPLOYING.md](DEPLOYING.md) ("Checking what an image actually
contains") names the fields. Extensions are added exactly as with `FROM php:<version>` — the
official `docker-php-ext-*` tools are vendored unmodified; the patched tree ships at `/usr/src/php`:

```dockerfile
FROM ghcr.io/muffetlab/php:8.1-fpm
RUN apt-get update && apt-get install -y --no-install-recommends libicu-dev g++ make autoconf \
    && docker-php-ext-install intl && rm -rf /var/lib/apt/lists/*
```

Per-version configure spellings and PECL floors: [MAINTAINING.md](MAINTAINING.md#per-version-extension-sets).
The `.so`-suffix limitation on PHP < 7.4, the absence of preinstalled compilers, Composer
usage and the source-tree size trade-off: [DEPLOYING.md](DEPLOYING.md).

## Security notice

Every PHP series in this project is end-of-life upstream. For example, the final upstream
releases were PHP 8.0.30 (August 2023) and PHP 8.1.34 (December 2025);
[SUPPORTED.md](SUPPORTED.md) lists the last official release and date of every series,
5.6 through 8.1. These images carry only the fixes that were backported, reviewed and
recorded. They are not a security guarantee, and the durable fix is to upgrade off EOL PHP.

1. **Coverage is per version, not per project.** The source of record is a backports
   fork, and a pinned commit fixes what it says it fixes; nothing transfers between
   minor versions. Check the series you run in [SUPPORTED.md](SUPPORTED.md) and
   [`manifests/SECURITY-REVIEW.md`](manifests/SECURITY-REVIEW.md) before treating any of
   this as production evidence.
2. **No unverified CVE patches.** A patch is accepted only with a human review record
   ([`patches/REVIEW-TEMPLATE.md`](patches/REVIEW-TEMPLATE.md)); CI can prove the image
   carries the bytes that record describes, which is a different thing from the review
   that decides whether they belong on the branch — [SECURITY.md](SECURITY.md) states the
   limit in full. Today the kit adds no local patch at all: the reviewed unit is the
   pinned commit itself ([`manifests/SECURITY-REVIEW.md`](manifests/SECURITY-REVIEW.md)).
3. **PHP 5.6 is the sharpest limit.** It builds against OpenSSL 1.1.1w, which requires a
   Debian bullseye base; bullseye reached the end of its Debian LTS window on 2026-08-31,
   and 1.1.1w has no maintained security update source behind it any more. Do not run a
   5.6 image in an internet-facing production workload unless you accept that freeze
   explicitly.
4. **Deployment is part of the security model.** Keep FPM on an internal Docker network
   and publish only Nginx/HTTPS; never expose port 9000, and do not run the CLI variant
   as a service. The rest — root filesystem read-only where feasible, dropped
   capabilities, `no-new-privileges`, mount choices — is in [DEPLOYING.md](DEPLOYING.md)
   ("Runtime network model").
5. **Two layers, different owners.** An image is a PHP tree *and* a Debian package
   closure, so OS-layer findings are registered separately — each row naming which of
   the three real outcomes [SECURITY.md](SECURITY.md) states applies — in
   [`manifests/OS-CVE-STATUS.md`](manifests/OS-CVE-STATUS.md).

The full known-limits list — including why 5.6 stays on its OpenSSL route and the
currently public CVEs — is in [SECURITY.md](SECURITY.md); the responsibility boundary in
[DISCLAIMER.md](DISCLAIMER.md).

## Documentation links

| You want to… | Read |
| --- | --- |
| run and configure an image, add an extension, deploy FPM behind Nginx | [DEPLOYING.md](DEPLOYING.md) |
| see what is pinned, reviewed and actually served by the registry | [SUPPORTED.md](SUPPORTED.md) |
| know what "supported" claims — and what it does not | [SECURITY.md](SECURITY.md), [DISCLAIMER.md](DISCLAIMER.md) |
| audit a patchset or an OS CVE disposition | [`manifests/SECURITY-REVIEW.md`](manifests/SECURITY-REVIEW.md), [`manifests/OS-CVE-STATUS.md`](manifests/OS-CVE-STATUS.md), [`patches/`](patches/) |
| build, review or publish an image yourself | [MAINTAINING.md](MAINTAINING.md) |
| the official extension tooling this kit vendors | [`docker-php-ext/README.md`](docker-php-ext/README.md) |
