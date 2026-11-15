# Vendored docker-php-ext tooling

These four scripts are vendored **unmodified** from
[docker-library/php](https://github.com/docker-library/php) (Apache License 2.0,
see `LICENSE` in this directory) at commit:

    5ec2a6a0dad498e89a91a39454dbb52e98ce2bdb  (fetched 2026-10-30)

File integrity is recorded in `SHA256SUMS` and verified in CI (validate job,
"Vendored docker-php-ext hash check"). Any update to these files must bump the
commit pin in the Dockerfile (`DOCKER_PHP_EXT_SRC_COMMIT`), refresh
`SHA256SUMS`, and re-run the full test chain — same discipline as PHP source
pins and patches.

## Files

- `docker-php-ext-configure` — phpize + ./configure an in-tree extension with custom flags
- `docker-php-ext-install` — build & install in-tree extensions as shared modules, auto-enabling them
- `docker-php-ext-enable` — write `conf.d/docker-php-ext-<name>.ini` (detects zend_extension via readelf)
- `docker-php-source` — source-tree lifecycle helper (`extract`/`delete`)

## Local adaptations (outside the scripts)

The scripts themselves are byte-identical to upstream. Integration with this kit
happens entirely in the Dockerfile:

1. `ENV PHP_INI_DIR=/opt/php/etc` — the scripts expect this variable (official
   images set it to `/usr/local/etc/php`).
2. `/usr/src/php/.docker-extracted` marker — our source is a pinned git checkout
   with reviewed patches applied, not the official tarball, so
   `docker-php-source extract` must be a no-op and never overwrite the tree.
3. `binutils` in the runtime image — `docker-php-ext-enable` calls `readelf`.
4. `PHP_CFLAGS/CPPFLAGS/LDFLAGS` set conservatively (no `-D_FORTIFY_SOURCE=2`,
   which newer upstream adds only for modern series and which may not build on
   5.6-era toolchains).

## Downstream usage

See
[Adding extensions in a derived image](../DEPLOYING.md#adding-extensions-in-a-derived-image)
for a worked `FROM ghcr.io/muffetlab/php:<version>-<variant>` example and the
toolchain note.
