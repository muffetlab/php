# Legacy PHP Security Images

Security-backported Docker images for legacy PHP applications: PHP 5.6–8.1, in
`cli` and `fpm` variants.

Each image is built from an explicitly pinned commit of
[`shivammathur/php-src-backports`](https://github.com/shivammathur/php-src-backports),
a fork that backports security fixes from maintained PHP branches to older,
unmaintained versions. Each pin has a corresponding review record documenting
the patches included.

The release pipeline publishes **`ghcr.io/muffetlab/php`**, with a Docker Hub
mirror when the mirror secrets are configured.

[SUPPORTED.md](SUPPORTED.md) tracks pins, base images, review status and the
names a release publishes. [DEPLOYING.md](DEPLOYING.md) explains how to run and
configure the images.

## Available PHP versions

PHP 5.6, 7.0–7.4 and 8.0–8.1, all with `cli` and `fpm` variants on `amd64` and
`arm64`.

Every published tag is a multi-arch manifest list, so `docker pull` gets the
matching platform without `--platform` or architecture-suffixed names. What each
series is built against -- OpenSSL route, Debian base, Composer pin, pinned
point release -- is in [DEPLOYING.md](DEPLOYING.md) and
[SUPPORTED.md](SUPPORTED.md); the 5.6 consequence is in the Security notice
below.

**Before you pull, read the version's row in [SUPPORTED.md](SUPPORTED.md).** A
row is never a published tag (`tested-in-CI` means the image passes CI; a tag
exists only once that series' release run wrote it), and it is never an approval
or CVE proof: the suite tests the extension surface and FPM pool, not the
backported hunks. Their record is
[`manifests/SECURITY-REVIEW.md`](manifests/SECURITY-REVIEW.md).

## Image tags

```
ghcr.io/muffetlab/php:8.1-fpm          # floating minor tag — the recommended deploy tag
ghcr.io/muffetlab/php:8.1.34-r1-fpm    # exact tag — PHP version + image revision + variant
```

- Deploy `X.Y-<variant>`: it cannot change major version, and it points to the
  latest published build within its PHP series, so the next security patch reaches
  your pull without a release cut.
- `8.1.34-r1-fpm` → `8.1.34-r2-fpm` is a second build of the *same* PHP version:
  an OS refresh or a newer backports commit bumps the revision, not the PHP
  version. The pipeline treats exact tags as immutable, so pinning one pins one
  build forever; receiving a fix means moving to the newer revision or the
  floating tag.
- There is no `latest` tag at all, for any variant: `<minor>-<variant>` is the
  only moving name, and it cannot move past its own major. Why the pipeline
  publishes none is [MAINTAINING.md](MAINTAINING.md#publishing-images).

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

Every image ships `php`, `php-fpm` (fpm variant) and `composer` on `PATH`, the
extension set below, and — by default — the configured source tree, so
`docker-php-ext-install` works in a `FROM` of it as it does in the official PHP
images. Read what the image you pulled really is:

```sh
docker run --rm --entrypoint cat ghcr.io/muffetlab/php:8.1-fpm /opt/php/BUILD-PROVENANCE
docker run --rm --entrypoint /usr/local/bin/verify-runtime ghcr.io/muffetlab/php:8.1-fpm
```

[`docker-compose.example.yml`](docker-compose.example.yml) and
[`nginx.conf.example`](nginx.conf.example) are the intended topology: internal
FPM network, Nginx as the only published port.

## Available extensions

Every image carries a common baseline — `mysqli`, `pdo_mysql`, `gd`, `mbstring`,
`curl`, `openssl`, `zip`, `zlib`, plus PECL `apcu`, `redis`, `memcached` — and
`mcrypt` additionally on 5.6–7.1, the series that can still build it in core
(legacy applications that call `mcrypt_*` are the reason a 5.6 image exists).

What each image really has is recorded inside it, in `/opt/php/BUILD-PROVENANCE`
— read that instead of trusting this list;
[DEPLOYING.md](DEPLOYING.md#checking-what-an-image-actually-contains) names the
fields. Extensions are added exactly as with `FROM php:<version>` — the official
`docker-php-ext-*` tools are vendored unmodified; the patched tree ships at
`/usr/src/php`:

```dockerfile
FROM ghcr.io/muffetlab/php:8.1-fpm
RUN apt-get update && apt-get install -y --no-install-recommends libicu-dev g++ make autoconf \
    && docker-php-ext-install intl && rm -rf /var/lib/apt/lists/*
```

Per-version configure spellings and PECL floors:
[MAINTAINING.md](MAINTAINING.md#per-version-extension-sets). The `.so`-suffix
limitation on PHP < 7.4, the absence of preinstalled compilers, Composer usage
and the source-tree size trade-off: [DEPLOYING.md](DEPLOYING.md).

## Security notice

Every PHP series here is end-of-life upstream; the final releases were, for
example, PHP 8.0.30 (August 2023) and PHP 8.1.34 (December 2025).
[SUPPORTED.md](SUPPORTED.md) lists the last official release of every series.
These images carry only the fixes that were backported, reviewed and recorded.
They are not a security guarantee, and the durable fix is to upgrade off EOL
PHP.

1. **Coverage is per version, not per project.** A pinned commit fixes what it says
   it fixes; nothing transfers between minor versions. Check the series you run in
   [SUPPORTED.md](SUPPORTED.md) and
   [`manifests/SECURITY-REVIEW.md`](manifests/SECURITY-REVIEW.md).
2. **No unverified CVE patches.** A patch is accepted only with a human review
   record ([`patches/REVIEW-TEMPLATE.md`](patches/REVIEW-TEMPLATE.md)). CI proves
   the image carries the bytes that record describes, not that they belong on the
   branch; [SECURITY.md](SECURITY.md) states this limit. Security fixes are
   reviewed at the pinned-commit level.
3. **PHP 5.6 is the sharpest limit.** It builds against OpenSSL 1.1.1w on a Debian
   bullseye base; bullseye left Debian LTS on 2026-08-31, and 1.1.1w has no
   maintained security source. Do not run 5.6 internet-facing unless you accept
   that freeze.
4. **Deployment is part of the security model.** Keep FPM on an internal network
   and publish only Nginx/HTTPS; never expose port 9000 or run the CLI variant as a
   service. Root filesystem read-only, dropped capabilities and `no-new-privileges`
   are covered in [DEPLOYING.md](DEPLOYING.md#runtime-network-model).
5. **Two layers, different owners.** An image is a PHP tree *and* a Debian package
   closure, so OS-layer findings are registered separately in
   [`manifests/OS-CVE-STATUS.md`](manifests/OS-CVE-STATUS.md).

The full known-limits list, and where this project's promises end, is in
[SECURITY.md](SECURITY.md) and its
[responsibility boundary](SECURITY.md#responsibility-boundary).

## Documentation links

| You want to… | Read |
| --- | --- |
| run and configure an image, add an extension, deploy FPM behind Nginx | [DEPLOYING.md](DEPLOYING.md) |
| see what is pinned, reviewed and what the published names mean | [SUPPORTED.md](SUPPORTED.md) |
| know what "supported" claims, and what the project leaves to you | [SECURITY.md](SECURITY.md#responsibility-boundary) |
| audit a patchset or an OS CVE disposition | [`manifests/SECURITY-REVIEW.md`](manifests/SECURITY-REVIEW.md), [`manifests/OS-CVE-STATUS.md`](manifests/OS-CVE-STATUS.md), [`patches/`](patches/) |
| build, review or publish an image yourself | [MAINTAINING.md](MAINTAINING.md) |
| the official extension tooling this kit vendors | [`docker-php-ext/README.md`](docker-php-ext/README.md) |
