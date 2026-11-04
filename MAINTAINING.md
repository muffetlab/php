# Maintaining this kit

[README.md](README.md) is written for people who **pull** these images. This
file is for the much smaller audience that builds or publishes them: filling
manifests, reviewing patchsets, running the CI chain, cutting a source release tag
and dispatching a release, and
understanding why the gates are shaped the way they are.

Nothing here changes an image. The published address, the tag scheme and the
review gates are the same whether or not you read this file; what you are
reading is the procedure a human has to follow before a manifest stops being
skipped.

Read [SECURITY.md](SECURITY.md) and
[manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md) first: they define
what "reviewed" means, and this file assumes you will not weaken either.

## Contents

- [Building the images yourself](#building-the-images-yourself)
- [Build & verification order](#build--verification-order)
- [Version-conditional behaviour](#version-conditional-behaviour)
- [Per-version extension sets](#per-version-extension-sets)
- [Dockerfile caveats (read before trusting a build)](#dockerfile-caveats-read-before-trusting-a-build)
- [Composer trust model](#composer-trust-model)
- [How the image stays slim without losing the audit trail](#how-the-image-stays-slim-without-losing-the-audit-trail)
- [The Debian base and its CVEs](#the-debian-base-and-its-cves)
- [CI (GitHub Actions)](#ci-github-actions)
- [Publishing images](#publishing-images)
- [Why this kit doesn't auto-pick latest commits](#why-this-kit-doesnt-auto-pick-latest-commits)
- [Repository layout](#repository-layout)

## Building the images yourself

The manifests are already filled: `PHP_SRC_REPO`, `SOURCE_REF`, `PHP_SRC_COMMIT`,
`OPENSSL_ROUTE`, `BUILD_VARIANTS` and `PATCHSET_APPROVED` carry real pinned,
reviewed values, and `BASE_IMAGE` carries a resolved multi-arch index digest on
every version — 5.6 on `debian:bullseye-slim`, 7.0–7.3 on `debian:bookworm-slim`,
and 7.4–8.1 on `debian:trixie-slim` (the 2026-11-03 base split; 7.0–7.3 cannot
compile on trixie — see *The compile boundary* under *The Debian base and its
CVEs* — and 5.6 cannot leave bullseye because no later Debian ships OpenSSL 1.1).
That last field can only be resolved against a registry: run
`tools/resolve-base-digest.sh` and commit the line it prints. Pinned is not the
same as proven — the first release run on a changed base is the proof.

5.6 is buildable and has been built and tested (2026-10-31, cli and fpm). Its
base, Debian bullseye, left LTS on 2026-08-31 and its `-security` pool no longer
serves the `.debs` its own index still lists, so both apt stages of the Dockerfile
rewrite that one suite to `archive.debian.org` — keyed on the base reporting
Debian 11, followed by a `grep` assertion, and catalogued as the
`bullseye-archive-security` version-branch. Nothing else is redirected, so the
`openssl3` bases are byte-for-byte unaffected, and because the rewrite also
happens in the runtime stage the published image stays apt-patchable by its users.
What no mirror can buy is a new library version: `libssl1.1` stays at
`1.1.1w-0+deb11u8` on that base forever. The decision, the 404/200 measurements
for both architectures and the rebuild evidence are in
`manifests/SECURITY-REVIEW.md`.

1. Moving a base pin (or adding a series) starts with the digest, in CI (any
   runner with Docker + registry access):
   ```bash
   ./tools/resolve-base-digest.sh                    # paste-ready BASE_IMAGE lines
   ./tools/resolve-base-digest.sh --check            # CI report: placeholders + drift
   ./tools/resolve-base-digest.sh --base debian:trixie-slim        # a tag no manifest names yet
   ./tools/resolve-base-digest.sh --base debian:trixie-slim --value # that ref alone, for CI to capture
   ```
   `--base` exists because a base *change* asks a question the manifest walk cannot:
   a filled manifest already carries a digest, but the candidate is a tag nothing
   here names. `--value` is the same resolution with the prose removed, which is how
   the CI trial job (below) feeds a digest-pinned ref to `build-version.yml`.
   The tool prints digests and never writes a manifest: choosing a base image
   digest is the same class of security decision as choosing a source commit, so
   a human pastes the line and commits it. Confirm the tag you resolved to is
   the maintained one for the route. For `openssl3` that means bookworm-derived.
   For `openssl11` there is no maintained Debian release shipping OpenSSL 1.1 any
   more — bullseye's LTS window closed on 2026-08-31 — which is why 5.6's pinned
   digest is a deliberate freeze rather than a track-the-maintained-tag choice.
2. Optionally tighten the per-version fields:
   - `BUILD_PACKAGES` — pinned build-time package list; replaces the route
     default entirely, so it must include the toolchain and every `-dev`
     package this version's configure flags need
   - `RUNTIME_PACKAGES` — pinned runtime libraries the build linked against
   - `PHP_EXTENSIONS` / `PECL_EXTENSIONS` — extensions this version **adds** to
     the kit baseline (`openssl curl mysqli pdo_mysql mbstring zip gd zlib`
     core — `mcrypt` appended by the guard step on 5.6–7.1 — / `apcu redis
     memcached` PECL). Additive, not a replacement: a manifest cannot shrink
     the promised set. Only names the Dockerfile can wire on that series are
     accepted; the one wireable extra name today is `mcrypt` on 5.6–7.1, and
     since it joined the baseline there, adding it is a deduped no-op kept
     legal so old manifests keep building (see
     [Per-version extension sets](#per-version-extension-sets)); today every
     manifest leaves both empty
   - `SHIP_PHP_SOURCE` — `1` keeps the configured source tree in the final
     image (so `docker-php-ext-install` works downstream), `0` drops it for
     size; see [How the image stays slim](#how-the-image-stays-slim-without-losing-the-audit-trail)
   - `COMPOSER_VERSION` / `COMPOSER_SHA256` — empty uses the policy pin
   - `BUILD_VARIANTS` — `"cli fpm"` or just one
3. Review. `manifests/SECURITY-REVIEW.md` records what is known about the
   backports patchset behind each pin; extend it with a
   `patches/REVIEW-TEMPLATE.md`-based record for every file you add under
   `patches/<version>/`, and set `PATCHSET_APPROVED=1` only for a patchset you
   have actually accepted. `tools/check-pin-drift.sh` reports whether a pin
   still matches the tip of its upstream tag.
4. Build **one version at a time**, sequentially. `build.sh` tags the result
   `php-legacy-kit:<version>-<variant>-test` — a local-only name that
   intentionally never matches a published ref, because the image people pull is
   `ghcr.io/muffetlab/php`:
   ```bash
   ./build.sh 5.6 fpm        # or: ./build.sh 5.6 cli
   ./tests/smoke.sh php-legacy-kit:5.6-fpm-test openssl11 fpm
   ./tests/extensions.sh php-legacy-kit:5.6-fpm-test openssl11
   ./tools/report-image-size.sh php-legacy-kit:5.6-fpm-test "5.6-fpm (openssl11)"
   ./tools/scan-image.sh php-legacy-kit:5.6-fpm-test   # the OS gate, same numbers a trial is judged on
   ```
   then 7.0 … 7.4, then 8.0/8.1 (all with `openssl3`).

   To try a candidate base without editing a reviewed pin, prefix the build with
   `BASE_IMAGE_OVERRIDE` (see *Trialing a newer Debian release*):
   ```bash
   BASE_IMAGE_OVERRIDE="$(./tools/resolve-base-digest.sh --base debian:trixie-slim --value)" \
     ./build.sh 8.1 cli
   ```
   The override replaces `BASE_IMAGE` before every check that reads it, so a trial
   is held to the same rules as a release: digest-pinned, and its in-image OpenSSL
   major still asserted against `OPENSSL_ROUTE`. A tag-only value fails with
   `BASE_IMAGE must be pinned by digest`.
5. Run your application's integration/regression tests against the image before production rollout.

## Build & verification order

Do not compile the versions in parallel from the start. Bring up PHP 5.6
first — source, OpenSSL 1.1, GD and ZIP toolchain — run smoke + extension
tests and application regression, and only then extend through 7.x to 8.1.
The CI workflow encodes this order as a chained job sequence. Each version
passes through: manifest fill → patch/CVE review → build (cli + fpm) →
smoke.sh → extensions.sh → application regression → staging.

Two further gates run inside the image build itself, before any tag exists:
`verify-build` in the build stage (a successful `./configure` does not prove
the extensions were enabled) and `verify-runtime` in the final stage (nothing
was dropped by the multi-stage copy, no unresolved library, the Composer phar
still matches its recorded digest). `smoke.sh` and `extensions.sh` then test the
published artifact from outside.

## Version-conditional behaviour

The kit uses one Dockerfile for all eight series, so every place where behaviour
depends on the PHP version is marked with a `# version-branch: <tag>` comment
and listed here. `tools/list-version-branches.sh --check` is a CI gate in both
directions: a marker without a row, or a row without a marker, fails the build.
Adding a new `case "${PHP_VERSION}"` therefore cannot stay undocumented.

Run `./tools/list-version-branches.sh` for the current tag → file:line index.

| Tag | Versions affected | What differs |
| --- | --- | --- |
| `series-allowlist` | all | The set of series this kit will build at all; must stay in step with `manifests/*.env` and the `SECURITY-REVIEW.md` status table. |
| `route-by-series` | 5.6 vs 7.0+ | 5.6 is pinned to the `openssl11` route; every other series requires `openssl3` (the backported OpenSSL 3 work is const-level compile compatibility, verified against the pinned branches). Enforced in `build.sh` and again in the Dockerfile. |
| `bullseye-archive-security` | 5.6 (by base OS, not by PHP series) | Debian bullseye left LTS on 2026-08-31: its `bullseye-security` index is still published but the pool 404s from `deb.debian.org` (measured for both arm64 and amd64), while `archive.debian.org` serves the same files. Both apt stages therefore rewrite the security suite in `/etc/apt/sources.list` to the archive, keyed on `/etc/os-release` `VERSION_ID=11` and followed by a `grep` assertion so a base that stops keeping its sources in that file fails here rather than as a mid-build 404. No other base matches, so the `openssl3` route is untouched. The rewrite happens in the runtime stage too, so it is baked into the published image and users can `apt-get update` and install from the archive. Cost: 1.1.1w-0+deb11u8 forever. If `deb.debian.org` also retires bullseye *main* — it still serves it today — the same one-line sed has to cover `deb.debian.org/debian` as well. |
| `patches-by-series` | all | Extra patches are read from `patches/<series>/`, so a backport can never leak into a series it was not reviewed for. |
| `mysqlnd-suffix` | 8.0+ | `--with-mysqli=mysqlnd` / `--with-pdo-mysql=mysqlnd` lost the `=mysqlnd` suffix in 8.0; earlier series pass it explicitly. |
| `gd-zip-spelling` | 5.6–7.1, 7.2–7.3, 7.4+ | Three different GD/ZIP flag spellings: system libzip + `--with-gd --with-png-dir`; then `--with-png-dir` and `--with-libzip` removed in 7.2; then GD renamed to `--enable-gd --with-jpeg --with-freetype --with-webp` in 7.4. |
| `zip-spelling` | 5.6–7.3 vs 7.4+ | ext/zip switched from `PHP_ARG_ENABLE` to `PHP_ARG_WITH` in 7.4, so the configure flag changed from `--enable-zip` to `--with-zip`. The baseline used to carry `--enable-zip` unconditionally; that silently no-ops on 7.4+ (`./configure` accepts unknown `--enable-*` names without erroring, it just does not flip `PHP_ZIP`), leaving the zip extension absent from `php -m` while `verify-build` expects it. |
| `pear-optional` | 7.4+ | PHP 7.4 changed the `--with-pear` configure default from `DEFAULT` (always install PEAR) to `no` (opt-in). 5.6–7.3 install PEAR unconditionally and need no flag; 7.4, 8.0 and 8.1 all still accept `--with-pear` (7.4/8.0 emit a deprecation warning) and all default to skipping PEAR without it. Without the flag `install-pear` is absent from `install_targets`, `make install` never creates `/opt/php/bin/pear`, and the PECL step below fails at `/opt/php/bin/pear: not found`. |
| `freetype-config-shim` | 5.6–7.3 | GD here finds FreeType only through the `freetype-config` script, which Debian no longer ships in the freetype -dev package at all (measured on bullseye: absent from `libfreetype6-dev`, while `pkg-config freetype2` works). The build drops a pkg-config-backed shim in `/usr/local/bin` when the script is missing; 7.4+ asks pkg-config directly, so it gets none. |
| `fpm-www-conf-fallback` | 5.6 | 5.6 has no `php-fpm.d/www.conf.default`, so the pool file is generated and the `include=` line is rewritten in `php-fpm.conf`. |
| `pecl-pins` | 5.6 vs 7.0/7.1 vs 7.2/7.3 vs 7.4+ | redis 4.3.0 on 5.6, 5.3.7 on 7.0/7.1, 6.0.2 on 7.2/7.3, 6.1.0 from 7.4; memcached 2.2.0 on 5.6 and 3.3.0 on every later series. Each pin is the newest release whose `package.xml` PHP floor admits the series — redis 6.1.0 declares `>= 7.4.0` (and 6.0.2 `>= 7.2.0`), and `pecl install` refuses a series below the floor, so a single "current major" pin breaks the 7.0 build. Driven by a loop over the resolved PECL set (`ext-availability`), so the pin table is keyed `extension:series` and an unknown pair exits 2 instead of silently skipping the extension. |
| `ext-baseline` | all | The extension set is a kit-wide baseline (`openssl curl mysqli pdo_mysql mbstring zip gd zlib` core, `apcu redis memcached` PECL) plus one per-series append the guard step itself makes (`mcrypt` joins the core baseline on 5.6–7.1, the series that can still build it), plus per-manifest additions. The baseline is defined once, in the guard step; five other places need a fallback copy because they must also run outside a build (`verify-build`, `verify-runtime`, `smoke.sh`, `extensions.sh`, `gen-supported.sh`), and `tools/check-ext-baseline.sh --check` fails CI if any copy loses a name. |
| `ext-availability` | 5.6–7.1 vs 7.2+ | Which EXTRA extensions each series can build at all: `mcrypt` (in core through 7.1, removed in 7.2) and nothing else. A name outside the table is refused by the guard rather than becoming a `./configure` warning and an image smaller than its manifest claims. `pecl_available` is empty by design — the PECL mcrypt replacement (PHP >= 7.2, different package) is not wired, and the catalog only lists names this Dockerfile can actually build. |
| `ext-optional-configure` | 5.6–7.1 when requested | For each extra core extension in the resolved set, append its configure flag (`mcrypt` -> `--with-mcrypt`). Mapping lives beside the flag list, not in the manifest, so per-version flag spelling stays reviewable in one file. |
| `ext-runtime-libs` | 5.6–7.1 when requested | The runtime stage installs the library each extra extension links (`mcrypt` -> `libmcrypt4`), appended even when `RUNTIME_PACKAGES` overrides the route list, so a pinned manifest cannot drop a dependency an asked-for extension needs. Package names measured on all three candidate suites (bullseye 2.5.8-3.4, bookworm 2.5.8-7, trixie 2.5.8-8). |
| `ext-mcrypt-presence` | 5.6–7.1 | `tests/extensions.sh` runs the RIJNDAEL-128/CBC round-trip and `mcrypt_list_algorithms()` only when the image promised mcrypt, and reports an explicit `SKIP` otherwise; every other extension block is gated the same way on the promised set instead of a hardcoded list. |
| `composer-policy` | 5.6–7.1 vs 7.2+ | Default Composer pin: 1.10.28 for the EOL series that cannot run 2.x, 2.11.0 otherwise. Duplicated in `build.sh` and `tools/gen-supported.sh` on purpose, and CI checks all copies agree. |
| `composer-major-guard` | 5.6–7.1 | Composer 2.x requires PHP >= 7.2.5, so a 2.x override on those series is rejected rather than warned about. |
| `openssl-floor-8x` | 8.0, 8.1 | Native OpenSSL 3 support starts at 8.0.13 / 8.1.0; `verify-build` fails an older point release instead of shipping it. |
| `tls13-const-74` | 7.4+ | `STREAM_CRYPTO_METHOD_TLSv1_3_CLIENT` only exists since 7.4 (PHP's TLS 1.3 stream support; absent before that even on the openssl3 route), so `tests/extensions.sh` asserts the constant only there and reports an INFO line elsewhere. |
| `aead-openssl-encrypt-71` | 7.1+ | The AEAD arguments to `openssl_encrypt()` (tag by reference, tag length) are a 7.1 signature, so `tests/extensions.sh` round-trips AES-256-CBC everywhere and AES-256-GCM only from 7.1. |

Per-version divergence is documented rather than merely tolerated because
backport coverage does not transfer between minor versions — a flag list that
works on 7.4 is not evidence about 8.0, and the same is true of a CVE fix.

## Per-version extension sets

The kit used to install one identical extension set on all eight series, which
was wrong in the direction that matters most for a legacy image: PHP 5.6 has
`ext/mcrypt` in core and legacy applications call `mcrypt_*`, so refusing to
build it pushed those users back onto an unpinned third-party image — the exact
thing this kit exists to replace. Today the set is a **baseline** (core
`openssl curl mysqli pdo_mysql mbstring zip gd zlib`, PECL `apcu redis
memcached`) **plus a per-series append the guard step itself makes** (`mcrypt`
joins the core baseline on 5.6–7.1, the series that can still build it) **plus
whatever a manifest adds** — and as of the change that moved apcu and mcrypt
into the baseline, no manifest adds anything:

```sh
# manifests/5.6.env (any of the eight)
PHP_EXTENSIONS=""
PECL_EXTENSIONS=""
```

Three properties are deliberate and are the reason the mechanism looks the way it
does. It is **additive**: the manifest lists what this version *adds*, so it can
grow the promised set but can never shrink it, and the review of a version's
extension surface is a one-line diff. It is **availability-checked before it is
built**: the Dockerfile's guard step owns the table of what each series can build
(`mcrypt` on 5.6–7.1, nothing on 7.2+), so a manifest that asks for something the
pinned tree cannot produce stops there instead of leaving `./configure` to warn
and ship a smaller image than the manifest claims. And it is **verified against
the promise, not a constant**: `verify-build`, `verify-runtime`, `smoke.sh` and
`extensions.sh` all read the resolved set, so an image that promised mcrypt and
lost it fails, and an image that did not promise it and grew one also fails.

The resolved lists are computed once in the guard step and handed to every later
step through `/opt/php/BUILD-EXTENSIONS` — read by the build-stage apt step (which
maps each name to its `-dev` package), the configure step (`--with-mcrypt`), the
PECL install loop (a missing pin is an error rather than a skipped extension),
the `verify-build` invocation and the provenance step. Two properties of the file,
both chosen against silent-failure modes:

- **Location: `/opt/php`, not `/tmp`.** The cleanup step runs `rm -rf /tmp/*` before
  the provenance step reads it, and `/opt/php` ships into the runtime stage, so the
  record travels with the artifact.
- **Quoting.** The values are quoted space-separated lists that a later step reads
  with `. file` — bare, `ext_requested=openssl curl mysqli` would source as "assign
  `openssl`, then run `curl mysqli …`". The guard sources the file once and compares
  before continuing, so a format change that breaks round-tripping is a build error
  at the point it is introduced.

The provenance keys are `extensions_core` / `extensions_pecl` (the resolved set
the build used, baseline included) and `extensions_loaded` (what `php -r` reports
from the compiled binary). The OCI labels carry only the manifest's addition —
`dev.php-legacy.extensions-extra-core` / `.extensions-extra-pecl` — because a
label is written from a build arg in the runtime stage, where the resolved set
has already been recorded in `/opt/php/BUILD-EXTENSIONS` and `BUILD-PROVENANCE`.
A consumer that wants what the image actually ships reads `extensions_core`, not
the labels.
`tools/gen-supported.sh` renders the resolved set into the SUPPORTED.md
`Extensions` column, so the published table shows `… zlib mcrypt apcu redis
memcached` on 5.6–7.1 and the bare baseline (without mcrypt) on the rest.

**To wire a new core extension** (mcrypt is the worked example), all five places
must agree, and the CI gate below catches the ones people forget:

1. the availability table in the guard step (`ext_available`, keyed by series);
2. the dev-package mapping in the build-stage apt step;
3. the configure flag in the configure step, spelled for that series;
4. the runtime library in the runtime apt step (`ext_runtime_libs`), with the
   package name measured on every base the affected routes use;
5. a behaviour test in `tests/extensions.sh`, gated on `promised("<ext>")` so it
   runs only on images that promised it.

For a PECL extension the same shape applies, but step 3 is a pin in the
`pecl-pins` table (`extension:series` -> version) and step 4 is whatever library
that extension links. `pecl_available` is empty until someone does that work;
naming an extension in a manifest without wiring it is rejected on purpose.

**To drop one** (a manifest addition), delete the manifest line: the availability
table may keep the entry (the series *can* build it), but nothing installs the
library any more. For a *baseline* member like mcrypt the drop is a Dockerfile
change instead: remove it from the guard step's per-series append, and the
release notes should say so, because the resolved set changes for every image of
that series. The security argument for keeping mcrypt narrow still stands —
`libmcrypt` has had no upstream release since 2.5.8 (2007), has no AEAD modes,
and its API is deprecated even where it exists, so shipping it on 5.6–7.1 is a
deliberate compatibility purchase, reviewed per version. That review record is
the **libmcrypt** entry under "Bundled third-party components" in
`manifests/SECURITY-REVIEW.md`; a new baseline extension needs an entry of its
own there before it is merged.

`tools/check-ext-baseline.sh --check` is the drift gate for all of this: the
baseline lives in the Dockerfile, five scripts need their own copy as a fallback,
and a sixth place (SUPPORTED.md) is generated. The tool reads the names out of
each file rather than trusting a duplicated literal, and fails if any copy is
missing one.

## Dockerfile caveats (read before trusting a build)

1. **Base system and OpenSSL must match, per version.** The `libssl1.1`/`libssl3`
   runtime package sets are route defaults only; they do not work on an arbitrary
   Debian image. Do not force all eight versions onto one system library set just
   to share a Dockerfile — the routes exist because the base OS has to ship the
   OpenSSL major the series is verified against:

   | Version | Route | Base OS requirement |
   | --- | --- | --- |
   | 5.6 | `openssl11` | an OS shipping OpenSSL 1.1 — in practice Debian bullseye at 1.1.1w, which left LTS on 2026-08-31, so this is a *frozen* choice rather than a maintained one (measured, with the archive-mirror consequences, in `manifests/SECURITY-REVIEW.md`); the pinned commit must contain verified OpenSSL 1.1 compatibility patches |
   | 7.0–7.4 | `openssl3` | maintained OS shipping OpenSSL 3.x (e.g. Debian bookworm-derived); OpenSSL 3 backports verified **for that exact minor version** in the pinned commit |
   | 8.0 | `openssl3` | OpenSSL 3.x base; native support needs >= 8.0.13 (build-enforced, pin is 8.0.30) |
   | 8.1 | `openssl3` | OpenSSL 3.x base; native support (>= 8.1.0, build-enforced, pin is 8.1.34) |

   For the openssl3 route on EOL versions, the source compatibility patch work
   must be finished first and runtime dependencies adjusted accordingly.
2. **Extension flags must be validated per version.** Especially GD, ZIP and
   OpenSSL. The Dockerfile switches configure spellings at the 7.4 boundary
   (`--with-gd`/`--with-*-dir` for <= 7.3, `--enable-gd`/`--with-jpeg`/
   `--with-webp` for >= 7.4), but a successful `./configure` still does not
   prove every extension was enabled — the build fails unless `php -m` and
   `php --ri` confirm each required extension, and the linked OpenSSL major
   matches the route.
3. **An extension fragment has to name the file, not just the extension.** When
   an ini line is a bare name, old PHP resolves it against `extension_dir` and
   does *not* append the shared-object suffix. Measured 2026-10-31: this kit's
   own 5.6.40 and the official `php:7.1-cli` image both report
   `Unable to load dynamic library '<extension_dir>/name'`, while `php:8.1-cli`
   tries `name` and `name.so` and loads either. The vendored
   `docker-php-ext-enable` writes exactly the argument it was handed (current
   upstream relies on the newer loader behaviour), so this build passes
   `redis.so` / `memcached.so` explicitly — that form is accepted on every series,
   which is why it is the one used. `tools/verify-runtime.sh` fails any published
   image whose own fragments do not load. What is *not* yet settled is the
   downstream case: `docker-php-ext-install intl` inside a 5.6/7.1 image from this
   kit still emits the bare form, so the documented workflow needs either a
   suffix-aware helper or a documentation rule.
4. **One Dockerfile builds all eight series; it is not a pre-built artifact.**
   What ships is decided by the manifests plus whatever the base image's
   repository serves on the build date. For release, lock each version's base
   image digest and build/runtime package versions (`BUILD_PACKAGES`,
   `RUNTIME_PACKAGES`) — pinning only the PHP commit while leaving
   `libssl3`/`libmemcached`/`libzip` floating re-opens the hole the pins exist
   to close. Some bases additionally need `libonig-dev`-style build deps and
   matching runtime libraries; that is exactly what those two manifest fields
   exist for, and the effective build list is recorded in the image at
   `/opt/php/BUILD-DEPS` so a published image can be audited against the
   manifest.

The source of record for every series is
[`shivammathur/php-src-backports`](https://github.com/shivammathur/php-src-backports):
official `php/php-src` stopped releasing for all eight lines (8.0.30 in August
2023, 8.1.34 in December 2025), so the official tree no longer carries fixes for
any of them, while the fork's per-series branches do. `build.sh`, the Dockerfile
guard, and CI all reject a `PHP_SRC_REPO` that is not that fork, and both reject
a version/route mismatch. Moving a version back to official `php/php-src` is a
reviewed change to all three, not a manifest edit.

## Composer trust model

The per-series version policy that consumers see is in the
[README](README.md#composer); this is the part that only matters when you are
changing a pin. All pins were verified against upstream on 2026-10-30:

- The installer script is fetched from an **immutable git commit**
  (`composer/getcomposer.org` @ `298f4ba7b62708d16c291573e1c52811b5e494bd`,
  path `web/installer`) and must match the SHA-256 pinned in the Dockerfile
  (`aad0c40a…`). Three mirrors are tried in order — `raw.githubusercontent.com`,
  the GitHub contents API, and `getcomposer.org/installer` — because the first
  is unreachable from some networks. Every candidate is digest-checked, so
  which mirror answers cannot change what is executed. All three currently
  serve byte-identical bytes.
- The **installed phar** is digest-checked against a pinned SHA-256
  (1.10.28 → `0915af36…`, 2.11.0 → `9674f12a…`). These were cross-verified:
  1.10.28 is byte-identical to `getcomposer.org/composer-1.phar`, and 2.11.0 is
  byte-identical to the GitHub release asset `composer.phar`.
- `BUILD-COMPOSER` records the version line, pinned version, phar SHA-256,
  whether that digest was verified, and the installer commit/digest; these are
  merged into `BUILD-PROVENANCE`. The runtime stage re-checks that the copied
  phar and its reported version still match that record.
- `tests/composer.sh` re-asserts the series policy, the provenance record, and
  the phar digest in the finished image, then runs an offline
  `composer validate`.

The 2.x LTS line (2.2.31) declares `php: ^5.3.2 || ^7.0 || ^8.0` and would
technically load on 5.6/7.0/7.1. This kit deliberately does not do that: the
1.10 branch is the line maintained for EOL PHP, and Composer 2's resolver and
plugin API are an extra unreviewed variable on an unsupported runtime.
`build.sh` and CI therefore **reject** any Composer 2.x pin on 5.6/7.0/7.1;
changing that is a reviewed Dockerfile edit, not a manifest override.

A manifest may override `COMPOSER_VERSION`, and should then also set
`COMPOSER_SHA256`; overriding the version without a digest makes the build skip
the phar check and logs a notice.

PECL pins follow the same discipline: they live in the Dockerfile's "PECL
extensions" step, are recorded in each image's `BUILD-PROVENANCE`, and are
bumped only through a reviewed change that re-runs the full test chain — the
same as a source-commit pin. A pin is also bounded by the series: every PECL
release declares a PHP floor in its own `package.xml` (`<php><min>`), `pecl
install` enforces it, so a series takes the newest release whose floor admits
it rather than whatever release is current. Check that floor before bumping.

Inside this kit's own build, PECL redis/memcached are enabled through
`docker-php-ext-enable` (official naming: `conf.d/docker-php-ext-<name>.ini`),
and the commit of the vendored `docker-php-ext-*` tools is recorded in
`BUILD-PROVENANCE` alongside them, so a published image says which version of
the official tooling it carries.

`tests/extensions.sh` mirrors the per-version boundaries (e.g. the TLS 1.3
constant check only applies to PHP >= 7.4 on the openssl3 route).

## How the image stays slim without losing the audit trail

A PHP built from source on top of a distro base is easily over 1 GB, and that
in itself is not a defect — `php-fpm` plus its modules, the
OpenSSL/libzip/libpng stack and the extension headers are all real files. The
kit's job is to make the *avoidable* part of that size go away without quietly
breaking the one thing that makes the image useful to downstream builds.

The final image is produced by two `COPY --from=build` lines (`/opt/php` and
`/usr/src/php`). `COPY` cannot exclude paths, so every byte saved has to be
deleted in the build stage before those copies happen; that is what the
"Image size cleanup" step does. It removes only what is provably unusable in
the final image, which has no compiler, no `make` and no `git`:

- `/usr/src/php/.git` — `BUILD-PROVENANCE` already records repo, ref and
  commit, and reading history inside a runtime container is impossible. The
  checkout is a `--depth 1` fetch of the pinned SHA (with a full-clone fallback
  when a repository refuses shallow fetches by SHA), so the decade of history
  never arrives in the first place; what is left is the single-commit object
  store, deleted before the copy either way.
- `*/tests` under the source tree — PHPT suites need `make` plus `cc`, and
  `docker-php-ext-install` never reads them. This is the single biggest
  removable item in the tree (measured in the README).
- `/usr/src/php/.github`, PECL temp/cache contents, `/tmp`, `/var/tmp`, and
  the apt lists and package caches in the runtime stage.

Deliberately **not** removed: the configured build tree — `Makefile`,
`config.status`, the `.h/.lo` objects, `main/php_config.h`. `docker-php-ext-install`
in a `FROM ghcr.io/muffetlab/php:...` image depends on it and cannot rebuild it without a
toolchain. Trimming it file by file would trade tens of megabytes for a
silently broken extension build, which is the worse failure. If you do not
build extensions in this image at all, set `SHIP_PHP_SOURCE=0` in the manifest:
the whole tree is dropped, `/usr/src/php/SOURCE-NOT-SHIPPED` explains why in
the image, and the cost is that `docker-php-ext-install` / PECL compiles stop
working there — so build what you need in a derived stage while the toolchain
is available.

Neither state is allowed to be wrong by accident. The build writes
`/opt/php/BUILD-CLEANUP` (`source_tree_shipped`, plus the source tree's size in
KB before and after cleanup) into `BUILD-PROVENANCE`, and `verify-runtime` in
the final stage asserts the two agree: a shipped tree must have `configure`,
`Makefile` and `main/php_config.h` and must **not** contain `.git`; an omitted
tree must be documented by `SOURCE-NOT-SHIPPED` and recorded as
`source_tree_shipped=0`. A future cleanup edit that deletes something
`docker-php-ext-install` needs fails the build instead of surfacing as a broken
deploy.

The `Report image size` CI step runs `./tools/report-image-size.sh` after the
tests and writes the uncompressed size, the largest layers, an in-image `du`
breakdown and the cleanup record into the job summary. It reports and never
gates — the sensible budget depends on the base image you picked. Pass a
`size_budget_mb` string to the reusable workflow if you want an explicit
over/under line in the log.

The measured source-tree numbers in the
[README](README.md#what-the-image-weighs) are `du` block counts of an un-built
tree, which is what the Dockerfile deletes before `make`; they are not the
image's final size. The first real build (5.6 / bullseye / cli, measured on an
arm64 host — CI builds both amd64 and arm64, so treat these as the shape of the
distribution rather than the release numbers) supplied the rest:

- the tree grows to 420.7 MB during `make` and lands at 320.6 MB after the
  cleanup step, recorded in `/opt/php/BUILD-CLEANUP`;
- the image is 710.3 MB uncompressed with the tree and 320.5 MB without it
  (`SHIP_PHP_SOURCE=0`), i.e. the tree really is 44% of the artifact;
- of the remaining 320 MB, `/opt/php` is 98.8 MB (84.5 MB of that is
  `bin/php`, which carries the statically compiled extensions) and `/usr/lib`
  is 80.2 MB — the transitive closure of `libcurl4` and `libxml2`
  (icu, gnutls, krb5, openldap, brotli, …), which is what the runtime route
  list pulls in and why the list cannot be trimmed much further without
  dropping extensions.

`tools/report-image-size.sh` writes that same report into every CI job summary,
so the other seven series get measured rather than extrapolated from 5.6.

The point of the report is that these decisions get made on measured numbers
rather than on the estimates in that table.

## The Debian base and its CVEs

Every image is two things: a PHP tree and a Debian package closure. The first is
reviewed commit by commit in [manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md).
The second is not ours to patch — it is whatever the base image's suite ships — and
it is where a scanner report like `debian/curl CVE-2026-86414` comes from.

Whose choice the base is: **ours.** `BASE_IMAGE` is a manifest key, and
`tools/resolve-base-digest.sh` prints the digest a human then commits (see
*Building the images yourself*, step 1). The upstream backports fork does not pick
an OS; it only constrains it, because a series built against OpenSSL 1.1 needs a
base that still ships 1.1 — which is what `OPENSSL_ROUTE` records, and why 5.6 sits
on bullseye while 7.0–7.3 sit on bookworm and 7.4–8.1 sit on trixie (the 2026-11-03
base split; both newer bases ship OpenSSL 3.x, so the `openssl3` route spans them).
**Deployed images and manifests can disagree on the base between splits**: the
7.4/8.0/8.1 manifests moved to trixie on 2026-11-03; 7.4's trixie build was
published on 2026-11-04, while 8.0 and 8.1 kept their bookworm tags until their
next release runs. The registry keeps its own truth — the digest
of a tag changes at publish time, and SUPPORTED.md's generated "Release tags"
section reads the digests live, so a consumer anchoring on a digest cannot be
surprised by this sentence going stale. (The per-series digest records that
preceded this live-read mechanism lived in manifests/SECURITY-REVIEW.md and were
retired when the generator took over; the publications themselves are unchanged.)
Changing a base is therefore a reviewed manifest change, not a Dockerfile edit.

**A digest-pinned base freezes the OS too.** That pin is the reason a rebuild is
reproducible, and the reason a rebuild is stale: a digest-pinned `*-slim` image
names one filesystem with one set of package versions, and a security fix
Debian publishes a week later is simply not in it. So both stages of the Dockerfile
refresh the pinned filesystem before installing anything into it:

- `apt-get -o APT::Get::Always-Include-Phasing=experimental dist-upgrade -y` — the
  phasing override matters, because a fix released in the last few days can sit in
  `partial` phasing and be invisible to a plain upgrade; that is exactly the window
  a CVE report lands in.
- `-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold` — an
  unattended conffile prompt is a build that hangs, and the image's own config
  files are the ones this stage wrote.
- **Simulate first, then refuse.** The same command runs with `-s` and the removal
  count is parsed out. If the upgrade would remove a package, the build stops
  (`exit 2`) instead of letting apt take `libcurl4` or `libssl3` away to satisfy a
  dependency, which is how a refresh turns into a build that "succeeds" and links
  against something nobody reviewed. The runtime stage runs the same pair, not the
  build stage's result: two stages that assemble one image must not disagree about
  which OS versions they carry.

On bookworm the refresh moves a handful of packages; on bullseye it is a no-op —
that archive is frozen (LTS ended 2026-08-31). A refresh is not a promise of a fix:
on the `openssl11` route it does nothing, and the register below carries the weight.

**What the image says about itself.** The final stage writes
`/opt/php/RUNTIME-OS-PACKAGES`: `base_image=`, `collected_at=`, a
`format=source|package|version` header, then one line per installed package from
`dpkg-query -W -f='${source:Package}|${Package}|${Version}\n'`. Source package names,
not the multiarch binary names, because that is the key the Debian tracker and every
scanner use (`zlib1g:arm64` is `zlib`). `tools/verify-runtime.sh` re-derives the same
list on a pulled image and fails on any drift — a recorded package the image lacks,
an unrecorded package the image carries, a recorded *version* that is not installed,
a missing header, an empty file. Absent is allowed and announced, so images published
before the inventory existed stay auditable. `tests/verify-harness.sh` covers each of
those paths with a stub `dpkg-query` (`vr-osinv-*`).

**The register: `manifests/OS-CVE-STATUS.md`.** One row per
(CVE, source package, suite): what the tracker says, what our image actually has, a
disposition, an evidence link, a review date. The dispositions are the vocabulary the
gate understands — `no-candidate-in-suite`, `fixed-only-in-unstable`,
`declined-no-dsa`, `frozen-archive`, `not-in-image`, `accepted-risk` — and
`tools/scan-image.sh` rejects a row with a disposition it does not know, so the file
cannot quietly become a list of excuses.

**The gate: `tools/scan-image.sh IMAGE`.** It reads the inventory out of the image,
asks that image's own suite what it offers today (an `apt -s dist-upgrade` run inside
the container), classifies each scanner finding against the register, and fails only
on the findings that describe work this kit could have done and did not:

| Classification | Meaning | What happens |
| --- | --- | --- |
| `fixable` | the suite has a newer candidate than the image | **fail** — rebuild; do not add a register row |
| registered | a row for this CVE, package *and suite* with evidence (`*` rows count only on the suite they name) | pass, printed with its evidence |
| `package_absent` | no Debian package of that name in this image | **fail** — route to `SECURITY-REVIEW.md` or a `not-in-image` row |
| `unregistered` | no row, no fix, nothing reviewed | **fail** |
| stale row | a register row cites a version the image no longer contains | **fail** |
| probe unreachable | network/Docker prevented the currency check | the finding is reported `unverified`, never "clean" |
| no scanner | nothing scanned this image at all: no trivy on PATH, trivy could not report, or the report had zero bytes in it | **fail**, verdict `unverified` — an unscanned image is not a clean one |

There is no ignore list. A new CVE is silenced only by writing a row that states, in
terms the tracker will contradict if it is wrong, why Debian has no fix for us — which
is the whole difference between "known" and "hidden".

**The scanner is pinned like everything else the kit runs.** `tools/install-trivy.sh`
installs a reviewed `TRIVY_VERSION` from its release asset and refuses to run it
unless the download matches a committed SHA-256; `--print-pin` prints the paste-ready
lines and must run where GitHub is reachable. `scan-image.sh` never reports clean
from an unscanned run: no scanner, a failing scanner or a zero-byte report each
produce `verdict: unverified`, an explicit `scanner` field (`absent`/`trivy-failed`/
`empty-report`) and exit 1 — an unscanned image is not a clean one. Pending upgrades
are a currency fact, not a CVE answer, so `drift` and no-scanner cannot pass together
either. The verdict logic is pinned by `tests/scan-image-harness.sh` (a stub `docker`
serving the inventory, a stub `trivy` behaving absent/failing/reporting, 13 cases
against the real register, no Docker daemon needed), which runs in `validate` and in
`release.yml`'s pre-flight — the one standing between a green gate and a push.

**Trialing a newer Debian release.** A trial builds the whole suite against a
candidate base and pushes nothing: dispatch `build-and-verify.yml` with `trial_version`
(one series) and `trial_base` (a tag such as `debian:trixie-slim`, or an already
digest-pinned ref). `trial-base` resolves and re-checks the digest, then `build-trial`
calls `build-version.yml` with `base_image_override`, which runs the whole suite —
smoke, extensions, composer, the OS CVE gate, the size report — and pushes nothing;
`base_image_override` together with `push=true` is a hard failure in the build job, so
a trial cannot publish even by editing the caller. A trial dispatch suspends the
eight-version chain (see *CI*), and the workflow's concurrency group is
`${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: true`, so a second
dispatch cancels a run in flight — land a trial deliberately, not alongside a run you
need. The two numbers to compare are the trial's `os-cve-<version>-…` artifact against
the same series' regular run.

What the trixie work had to measure, in two parts:

*The package names.* Debian's 64-bit-time (`t64`) transition renamed most of the
runtime libraries this image installs. The names were read from the trixie archive
index itself — a throwaway container pointed at `trixie` + `trixie-security` and
`apt-cache policy` over every name, the same index apt reads during a build — and the
old names are *absent* there, not transitional, so no install line can quietly keep
working on them:

| Package installed today (bookworm) | trixie name | Trixie version (2026-11-03) |
| --- | --- | --- |
| `libssl3` | `libssl3t64` | `3.5.7-1~deb13u3` (bookworm: 3.0.x) |
| `libcurl4` | `libcurl4t64` | `8.14.1-2+deb13u7` (bookworm: 7.88.1) |
| `libpng16-16` | `libpng16-16t64` | `1.6.48-1+deb13u6` |
| `libmemcached11` | `libmemcached11t64` | `1.1.4-1.1+b2` |
| `libzip4` | `libzip5` | `1.11.3-2` — a soname bump, not a rename |
| `libfreetype6-dev` (build stage) | `libfreetype-dev` | the old name has no trixie candidate; `libfreetype-dev` exists on all three suites. Runtime `libfreetype6` is unchanged |
| `zlib1g`, `libjpeg62-turbo`, `libwebp7`, `libonig5`, `libxml2`, `libsqlite3-0` | unchanged | `libxml2` is 2.12.7+really2.9.14, so the old XML code paths meet 2.9.14, not 2.12 |

The Dockerfile reads `VERSION_CODENAME` from the base image itself — not from
`OPENSSL_ROUTE`, which describes what PHP needs, not what the OS is called — and picks
the release's names in two places: `${ft_dev}` in the build stage and `openssl3_rt` in
the runtime stage. `bullseye` and `bookworm` take the existing lists unchanged; only a
`trixie`/`forky`/`sid` base reaches the new branch (`forky` and `sid` join on the
assumption the t64 renames do not revert — a SONAME that moves again, `libzip5` ->
`libzip6` is the plausible one, surfaces as apt `Unable to locate package`, which is
what the channel is for). An unknown codename falls back to the bookworm spelling and
prints which release it assumed, so a wrong guess is an apt "no candidate" failure in
the build log rather than a quiet swap. Only the *packaging* names moved;
`verify-runtime.sh`'s `ldd` pass is the backstop if a library itself ever disappears.

*The 5.6 limit.* This is not a trial option. PHP 5.6 needs the `openssl11` route, and
no Debian release from bookworm onwards ships OpenSSL 1.1 — the t64 renames cannot fix
a missing major. 5.6 stays on bullseye, frozen, with the `frozen-archive` register rows
saying so.

*The compile boundary.* The package list is the part a build can be checked offline;
the compile is the part that cannot. trixie hands PHP a newer toolchain than the
current bases (from the same index: `re2c 4.1`, `autoconf 2.72`, `bison 3.8.2`,
OpenSSL 3.5.7, libxml2 headers 2.9.14), and the walls it raises sit by series —
measured on real trial builds and checked against the source each series actually
builds (`shivammathur/php-src-backports` at each manifest's `PHP_SRC_COMMIT`):

  | Series | Wall A: `ext/dom/dom_iterators.c` unconst `itemHashScanner` | Wall B: two-argument `readdir_r` in `main/reentrancy.c` |
  | --- | --- | --- |
  | 7.0 | unconditional `xmlChar *name` — **red in a trial build** | present |
  | 7.1 | guarded `#if LIBXML_VERSION >= 20908` | present (probe and file same as 7.2's) |
  | 7.2 | guarded — **clean in a trial build** | **red in a trial build** |
  | 7.3 | guarded — **clean in a trial build** | **red in a trial build** |
  | 7.4 | guarded | no `readdir_r` reference remains — **green in a trial build** |

Wall A is a const mismatch against trixie's libxml2 headers, which `gcc 14` raises as
an error; the change is const-only and emits the same code, so
`-Wno-error=incompatible-pointer-types` behind a series+codename gate would address it
without changing behaviour. Wall B is PHP's own configure probe answering `old-style`
on trixie (both generations of the probe do), producing a two-argument `readdir_r` call
that glibc's prototype rejects — an arity error, so no `-Wno-error=` of any name
compiles it. The escape is the cached probe answer (`ac_cv_what_readdir_r=POSIX`),
which switches PHP to its own `readdir()`-based wrapper that never calls the deprecated
symbol. Both are build-interface changes on a reviewed pin, so both stay human
decisions; neither is taken.

**The base decision.** Taken 2026-11-03 as a split rather than a wholesale move: 7.4,
8.0 and 8.1 moved to the measured trixie digest, 7.0–7.3 stayed on bookworm (they
compile there; on trixie they die at the walls above), and 5.6 stayed on bullseye. The
register's 2026-11-03 rows are the moved series' trixie findings, written from the
tracker pages. Still open, both human decisions the trial channel cannot take: the two
build-interface flags above (optional now — 7.0–7.3 can stay where they compile), and
building libcurl from source so its CVEs become ours to fix rather than Debian's (the
cost: an OS curl that no longer matches the image's `libcurl` and its attestations —
see the register's "decisions not taken").

**A new OS finding, in order.** Rebuild the series first: `dist-upgrade` means a
stale image often *is* the fix, and the gate's `fixable` verdict exists to catch
exactly that. If it still reports, check the tracker for the suite, and either take
the candidate (base or package change, human-reviewed) or add the row with its
evidence. If the finding names PHP rather than a Debian package, it belongs in
`manifests/SECURITY-REVIEW.md`, and the gate will say so when you get it wrong.

## CI (GitHub Actions)

- `.github/workflows/build-and-verify.yml`: static `validate` gate (triggered by
  `pull_request` and manual dispatch only — it has no `push:` trigger, and
  `tools/check-image-name.sh` asserts that, because a branch push that ran this
  chain beside release.yml's publishing run would build the same images under two
  concurrency groups that cannot cancel each other and write the same layer caches)
  (shellcheck + `bash -n` over every `*.sh` in the repo, `sh -n`/`bash -n` over
  every Dockerfile `RUN` block, the verify-script stub harness,
  the OS-gate verdict stub harness (`tests/scan-image-harness.sh`),
  the version-branch inventory drift check,
  manifest/route/repo policy including Composer overrides,
  Composer pin agreement across layers, published image address consistency
  (`tools/check-image-name.sh`), Composer installer freshness warning,
  vendored `docker-php-ext` hashes, patch SHA-256 vs review records,
  SUPPORTED.md drift check), then the sequential per-version build chain.
  Two advisory steps run alongside the gates and never fail the job:
  `tools/check-pin-drift.sh` (pin vs current upstream tag) and
  `tools/resolve-base-digest.sh --check` (base tag digests, placeholder and drift
  report). Lint targets are discovered by glob rather than listed, so a newly
  added script is checked without editing three workflow files.
  Manual dispatch takes two more inputs, `trial_version` and `trial_base`, that
  turn the run into a **base-image trial** instead of a chain: `trial-base`
  resolves the candidate tag to a digest (`tools/resolve-base-digest.sh --base
  ... --value`, re-checked there so nothing unpinned can be handed on) and
  `build-trial` calls the reusable build with `base_image_override`. Either input
  alone fails the trial job with the reason instead of quietly doing nothing. A
  trial dispatch also **suspends the chain** -- it gates the head job
  (`build-5_6`), and each later version needs the one before it -- because eight
  multi-hour builds is not how you answer a question about one base image. Note
  the concurrency group: a dispatch cancels an in-flight chain on the same ref,
  so land a trial deliberately, not alongside a run you need. Every `if` here
  spells out `needs.validate.result == 'success'`, because a job with its own
  condition no longer inherits the implicit "only if every needed job succeeded"
  gate.
- `.github/workflows/build-version.yml`: reusable per-version job. Its matrix is
  `variant × arch` (`cli`/`fpm` on `linux/amd64` via `ubuntu-24.04` and on
  `linux/arm64` via the GitHub-hosted `ubuntu-24.04-arm`, natively — no QEMU), so
  each architecture builds and runs the full `tests/smoke.sh`,
  `tests/extensions.sh` and `tests/composer.sh` suite against the image it made;
  `tools/report-image-size.sh` runs per leg (reporting only, never a gate). Each
  leg then installs the pinned scanner (`tools/install-trivy.sh`) and runs the OS
  gate (`tools/scan-image.sh`) over the image it built — **gating**, and before any
  push — with the JSON report uploaded as an `os-cve-<version>-<variant>-<arch>`
  artifact even when the step failed, because that report is the diagnosis (see
  *The Debian base and its CVEs*). In
  test mode with `release=true` (manual dispatch) it exports per-arch image
  tarballs as artifacts. Its `base_image_override` input is the trial knob: a
  digest-pinned base image that replaces the manifest's for that run only,
  refused outright (exit 1) if the caller also passed `push=true`, and announced
  as a `::warning::TRIAL BUILD` naming both the trial base and the reviewed one.
  The manifest's own pins -- source commit, route, patchset approval -- are still
  what the build consumes, and `dev.php-legacy.base-image` records the base
  actually used, so a trial image cannot be mistaken for a release. In push mode each leg uploads its image **by digest
  only**, and a `merge` job assembles the two digests into the published
  multi-arch manifest list, so a failed leg leaves no single-arch tag behind
  (see below).
- `.github/workflows/release.yml`: the only publishing workflow, and the only
  release entry point. It is `workflow_dispatch`-only -- there is no tag push
  trigger -- and runs only from the default branch (main or master, both accepted).
  Its required `version` input picks the scope (one PHP series or `all`), its
  required `revision` input is the image revision every published exact name
  carries, and its guard job refuses a dispatched commit that carries no `vX.Y.Z`
  source release tag. One run is one validate, one dynamic matrix with a build leg
  per selected series, and one mirror Overview sync.
  Re-runs the full
  validate gate, refuses empty releases, and pushes reviewed images.
- Unfilled manifests cause the corresponding build to **skip**, not fail: the
  review gates stay human decisions — for the series a release did *not* select.
  The selected series is checked before anything builds, and an unfilled or
  unapproved manifest there fails the run rather than publishing nothing quietly
  (see *Publishing images*).
- PRs and forks can never push images: the
  test caller (build-and-verify.yml) never passes `push=true`, so it never reaches
  a registry login. Conversely, `push=true` from a ref the build job may not
  publish from is a **hard failure** rather than a quiet downgrade — a caller that
  asks to publish and is refused must stop the run, not finish green with no image
  behind the tags.

## Publishing images

Registry defaults to GHCR and the published image is `ghcr.io/muffetlab/php`
(the ref is `<registry>/<namespace>/php`, namespace input defaulting to
`muffetlab`); a Docker Hub mirror is pushed automatically when
`DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets exist.

**Four things, four jobs.** Nothing in this pipeline has to do two jobs, because the
coupling is what made a full release cost eight tags:

| Question | Answered by |
| --- | --- |
| Which source is an official release? | a git tag on the dispatched commit: `vX.Y.Z` (say `v1.0.0`) |
| Which PHP series does this run build? | the `version` input of the dispatch: `8.1`, or `all` |
| Which PHP version is that series? | `SOURCE_REF` in `manifests/<series>.env` |
| Which build of that version is this image? | the `revision` input, published as `-r<N>` |
| What does a deployment pull? | Docker tags, below |

A git tag therefore selects nothing, carries no revision, and appears in no image
name -- which is what lets one tag cover a release of eight series, and what makes
`v1.1.0` next to `v1.0.0` mean "a new source release" rather than "a different PHP
version". Adding PHP 8.2 costs a manifest and a `SUPPORTED_VERSIONS` row; the
release mechanism does not change.

Tag scheme:

| Tag | Meaning |
| --- | --- |
| `<minor>-<variant>` (e.g. `8.1-fpm`) | recommended deploy tag; moves only within its own series, and every release run moves it to that run's build |
| `<full-php-version>-r<revision>-<variant>` (e.g. `8.1.34-r1-cli`, `8.1.34-r2-fpm`) | fully-qualified immutable exact tag -- `r1` is the first image built from that PHP version, `r2` the next build of it |

An OS security fix, a refreshed base digest, or a newer backports commit that does
not move `SOURCE_REF` bumps the revision and leaves the PHP version alone: `r1` ->
`r2`. Exact tags are never moved, so a deployment that pins `8.1.34-r1-fpm` keeps
that image until it moves on purpose; `<minor>-<variant>` is the name that carries a
fix to a deployment without an edit. SUPPORTED.md's generated "Release tags"
section names, per variant, the exact tag the registry currently serves behind
the floating one -- which is the highest revision it has, read live.
Re-dispatching the *same* revision does overwrite that one name; the guard asks a
human for the number rather than deriving it from the registry exactly because two
runs that each concluded "I am r1" would fight over it, so a fix ships as `r2`.

Names published before the revision existed are bare (`8.1.34-cli`); they stay in
the registry as the snapshots they are, are read as revision 0 by the generator, and
are not rewritten.

There is no `latest` tag, by design. A release run publishes the series its input
selects, so a
`latest-<variant>` tag would resolve to whichever series was released last —
neither the newest PHP nor a recommendation — and a bare
`docker pull <registry>/<namespace>/php` asks the registry for `latest`, the one
name that cannot say which variant it is. `<minor>-<variant>` is the only floating
name, and it cannot change major version. `tools/check-image-name.sh` asserts the
removal: the publish step may write exactly the two names in the table, no document
may advertise a latest tag on the published address, and README, this file and
SUPPORTED.md must each state that there is none — so the absence reads as a
decision, not an oversight.
Every one of those names resolves to a **multi-arch manifest list** covering
`linux/amd64` and `linux/arm64`; there are no architecture-suffixed tags.
Builds are native (amd64 on `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`), each
leg runs the full test suite, and the per-arch images are pushed by digest and
merged with `docker buildx imagetools create`. That merge runs **one call per
registry, GHCR first**: one call carrying both the primary and the Docker Hub
mirror would lose the GHCR tags if the mirror refused, and its error could not
say which registry did it. A refused mirror still fails the job — half a release
is not a release — but only after the primary publish is done, and the failure is
reported as an annotation naming the repository, because a publishing log is
truncated in the Actions UI while annotations are not. The merge carries each
platform's provenance/SBOM attestation manifests into the list, a step asserts
both platforms are present — a partial list fails the release instead of passing
silently — and a reporting step counts the attestation manifests the published
list actually carries, so that claim is checked out loud rather than assumed.

Counting them is format-specific: GHCR stores attestations in Docker's format —
child entries the merge adds are OCI manifests with `artifactType:
application/vnd.docker.attestation.manifest.v1+json`, `platform: unknown/unknown`,
annotated `vnd.docker.reference.type: attestation-manifest` plus
`vnd.docker.reference.digest` pointing at the platform image they attest, with the
`application/vnd.in-toto+json` layers (SPDX SBOM, SLSA provenance) *inside* those
manifests, never in the index JSON. The step greps the index for
`attestation-manifest` (falling back to the in-toto media type for other registry
formats, which can put it in an `annotations` block) and is `continue-on-error`:
the claim is checked out loud, but a wrong count is not a reason to fail a release
that already published. Read it back yourself with `docker buildx imagetools
inspect --raw <published tag>` — the workflows print the same numbers.

**A leg that reports a digest has not necessarily published anything.**
`type=image` is buildx's *local-load* exporter unless its output spec says
`push=true`: without it the leg builds the image, prints a digest and exits 0
having written nothing to the registry. That digest is `containerimage.digest`
from the buildx metadata (`build-push-action@v7` has no `metadata-file` input —
unknown inputs are ignored), and it equals `containerimage.descriptor.digest`:
the attested **index** when provenance/SBOM are on, the image manifest when they
are off — either way exactly the reference `imagetools create` needs. What the
digest does not prove is that the push happened, so `Export digest` asks the
registry: `imagetools inspect --raw <repo>@<digest>` must succeed before the leg
records it.

`ubuntu-24.04-arm` is free for **public** repositories: a private fork must use a
paid arm64 label or drop the arm64 matrix entry (producing an amd64-only list
that fails the merge's platform check — adjust that check accordingly). Runner
labels are pinned, not floating: a floating label would change the host OS, its
apt packages and its Docker engine between unattended builds, and moving a pinned
label to a newer OS is a reviewed change — run the validate gate and one full
build on the new label first. GitHub retires old runner images eventually, so the
move becomes mandatory at some point; do it deliberately, not by drift. The
runner OS never leaks into an image: bases are pinned by digest and the build
happens in containers.

Tags deliberately do not carry the OpenSSL route. The release pipeline fixes one
route per series (5.6 → `openssl11`, every other series → `openssl3`; both the
`validate` and `build-and-verify` workflows reject a manifest that disagrees), so
a `-openssl11` / `-openssl3` suffix could never express a deployment choice — it
would only make the tag differ from the `php:<full>-<variant>` shape people are
migrating off — and the suffix slot belongs to the image revision, the one number a
reader can act on (`8.1.34-r2-fpm` is later than `8.1.34-r1-fpm`; `-openssl3` says
nothing a manifest does not already say). The route stays in
`/opt/php/BUILD-PROVENANCE`, the `dev.php-legacy.openssl-route` label and the
SUPPORTED.md table. What the old scheme cost — a future route migration for the
same PHP version replacing `8.1.34-fpm` with a different libssl build — is what the
per-build revision removes: that migration is now `revision=2`, publishing
`8.1.34-r2-fpm` beside the old snapshot instead of over it. The floating `8.1-fpm`
still follows the newest build, so a route migration is still a reason to read the
label rather than guess from a name, and deployments that must not move at all pin
the digest.

Release flow: fill each `BASE_IMAGE` digest (`tools/resolve-base-digest.sh`,
committed by hand) → finish reviews and update
`manifests/SECURITY-REVIEW.md`, and update `manifests/OS-CVE-STATUS.md` for anything
reported against the Debian package closure (the base bump a rebuild takes, or a row
with tracker evidence for what it cannot) → `./tools/gen-supported.sh` and commit →
tag that commit as a source release (`git tag v1.0.0 && git push origin v1.0.0`) →
dispatch `release.yml` from the default branch with `version` (one series or `all`)
and `revision` (the image revision, `1` for the first build of what the manifests
pin). The tag is a prerequisite, not a selector: it marks the source the images were
built from, and the run refuses to publish without one. Every leg runs
`tools/scan-image.sh` over the image it built before pushing anything, so a release
cannot publish an OS finding that is neither fixed by the refresh nor registered.

**What the tag means, and what it does not.** `vX.Y.Z` marks a source release of
*this kit* — the commit whose manifests, reviews and patch trees are official. It
does not name a PHP version, does not carry the image revision, and appears nowhere
in an image name, which is why one tag covers a release of eight series and why the
tag namespace stays an append-only history of source rather than a history of builds
(that is the registry's `-r<N>` namespace, and SUPPORTED.md reads it live). Tags are
never moved or deleted, and a run whose commit has no `vX.Y.Z` tag fails in the guard
before any build starts — publishing is refused from untagged source at both ends:
`release.yml` checks `git tag --points-at`, and `build-version.yml` refuses
`push=true` unless `source_release` names such a tag.
`v1.0.0-rc1` is not a release tag and never starts a publish: the guard's regex is
`vMAJOR.MINOR.PATCH`, and a commit carrying only `v1.0` or no tag at all is refused
the same way.
The revision is the other half, and it is asked for, not derived: `revision` is a
required, positive integer, and every published exact name carries it. Two runs that
each concluded "I am r1" would fight over one published name, so the number is the
human's decision — and because the name always has one, the old failure mode where a
rebuild with no number republished the bare name over the snapshot it was supposed to
protect is gone by construction. The number is shared by every series in the run,
which is what makes `r2` a release of *this kit* rather than of one PHP version:
`5.6.40-r2-cli` and `8.1.34-r2-cli` are different PHP versions and the same second
build.
Two builds of one series must not overlap either: the concurrency group is per ref,
so a second dispatch started while the first is running queues behind it rather than
building twice — but two dispatches naming the same revision still resolve to the
same published names, so wait for the first run to finish before cutting `r2`.
**A run publishes the series its input
selects**: `version=5.6` rebuilds 5.6's `cli` and `fpm` on both
architectures and nothing else, and the series a run does not select keep their
previous images — including their previous base digest, which only a release of
*that* series picks up. The PHP version each selected series builds comes from
`SOURCE_REF` in its manifest and is carried into the matrix, so nothing between the
input and the image name is allowed to restate it. A release can
be run for one PHP series (a free string validated against the supported list, so
the list is not duplicated as a `choice` menu) or for `all` of them, and both paths
write the same exact and `<minor>-<variant>`
names — there is no `latest` tag for the two paths to differ over.

**Why a full release is one run and not eight.** A full release is one
`version=all` dispatch, and it is not a matter of convenience: eight dispatches would
each be a separate run of the same commit, and the reason that is worse than merely
wasteful is the
`SUPPORTED.md up to date` gate in `validate`, which reads the *live* registry:
inside one run every build job starts after a single read that still describes the
state the release departs from. Eight runs cannot make that claim: a run whose
`validate` starts after another series has already published reads digests that run
did not write, and fails a documentation check because some other release succeeded.
That is also why
the legs of an `all` run are siblings in one matrix rather than a chain — they
share no name to race over (`5.6-cli` … `8.1-cli` are eight different floating
names) and one series' build failure must not withhold the fixes its seven healthy
siblings published; `fail-fast: false` is what says that out loud in the workflow.
The one Overview call per run follows the same reasoning:
`<user>/php` has a single README, so it is not a build-job step at all — `release.yml`
has a `mirror-readme` job that runs once after the matrix, and the per-series
`build-version.yml` leg publishes images and nothing else.
After any release that moved a digest, `SUPPORTED.md` is stale by construction:
the run that published wrote new digests into the registry, while the committed
file recorded the ones before it. Regenerate and commit it
(`./tools/gen-supported.sh`) before the next release or the `SUPPORTED.md up to
date` gate in `validate` fails — a full release makes that bookkeeping one pass
instead of eight, because one run moves every digest and one regeneration
describes all of them. The gate compares the committed file against
generator output read from the *live* registry, and it runs on a runner because
the registry has to be reachable to answer; a registry outage therefore blocks a
release rather than publishing beside a document that cannot say what it verified.
Because a run publishes only the series it selects, an unfilled or unapproved
manifest **for a selected series fails the whole release** instead of being
skipped — the validate job checks every selected manifest is release-ready, so a
mistargeted tag cannot finish green with nothing published, and an `all` run that
found one unreviewed series pushes nothing at all. The same step also refuses a
selection that names no series once it is split: an empty list would otherwise
loop zero times, print "release-ready", and leave every build job to skip itself.
Manifests for the *unselected* series are still allowed
to be unreviewed, and `build-version.yml` still refuses to build one it is handed.
Every published image
embeds `/opt/php/BUILD-PROVENANCE` and OCI labels (base digest, source
repo/ref/commit, route, build package list, PECL pins, Composer version + phar
digest, patch digests, and — via `/opt/php/BUILD-CLEANUP` — whether the source
tree was shipped and what it weighed before and after trimming), with
provenance/SBOM attestations attached where the registry supports them — and the
dispatch checkbox is the whole decision, because there is no other way to start a
release: `attestations` defaults to `true` and `release.yml` passes the value to
every matrix leg.
Asking for them costs a build-time dependency: buildx generates the SBOM with
`docker.io/docker/buildkit-syft-scanner:stable-1`, which the leg pulls from Docker
Hub while it builds (observed locally as the exact reference it resolves before
`--sbom true` can run). A release therefore needs Docker Hub reachable even though
every image input is pinned by digest; `attestations=false` drops both the
generator pull and the attestation manifests.
The image also ships `/usr/local/bin/verify-runtime`,
so those claims can be re-checked on a pulled image without rebuilding it.

### Making the GHCR package public

GHCR packages are created **private** on first push. Two ways to publish:

- **Automated**: add a repository secret `GHCR_PAT` — a classic PAT with
  `write:packages` scope (a fine-grained token can work too, but it sends no
  `X-OAuth-Scopes` header, which is the first thing the step prints when a call
  goes wrong). The release workflow's `package-visibility` job then makes sure the
  package is public after each release.
- **Manual**: repository → Packages → `php` → Package settings →
  Change visibility → Public. Without `GHCR_PAT` the workflow prints this
  path as a notice and skips.

**The API's package name is not the registry path.** A package created from
`ghcr.io/<owner>/php` is named `php` in the packages API — PATCHing
`<namespace>%2Fphp` returns 404 even with a working token (and the packages API
answers 401 to every unauthenticated call, whichever name is asked, so the name
cannot be probed that way). The step therefore lists the owner's container
packages, tries both name forms (leaf first) against both owner kinds, and only
PATCHes a resource it has read back — and if what it reads already says `public`,
it sends nothing. The slash form stays in the list because a fork publishing a
repository-scoped name genuinely needs it.

A visibility failure is **reported, not fatal**, and that is deliberate: by the
time this job runs the tags and layers are published, and a red job at the tail of
a good release tempts someone to re-run or re-tag it — republishing image tags to
fix a metadata toggle. What a consumer can do is answered by the next step, which
reads the registry back with no credentials at all.

Anonymous pulls of public packages need no token; private packages require
`docker login ghcr.io` with a `read:packages` token.

A green visibility job is not proof the package is public: without `GHCR_PAT` the
step skips, and the package can still be private. So the job also runs *Confirm an
anonymous reader can pull the published address* — after the visibility step (even
after that step fails), with no secret of its own. It prints the tag list an
anonymous reader sees, or a warning that the release's tags exist but `docker pull`
without credentials will not reach them. It is deliberately reporting, not a gate:
the images are already published when it runs, and an unreadable package is fixed
in package settings, not by failing a release. The expected line once the package
is already public is `GHCR package php is already public; no visibility change
sent.`; `GHCR_PAT` is a classic PAT with `write:packages`, and nothing else in the
pipeline reads it.

### The Docker Hub mirror's Overview

Hub renders a repository's Overview from the `full_description` field of its own
metadata, not from the README in git. A mirror can therefore publish tags for weeks
while its page says nothing. `tools/sync-dockerhub-readme.sh` writes that field, in
two calls, with the bash and curl this repository already depends on — no SDK, no
jq, no python:

- `POST https://hub.docker.com/v2/auth/token` with
  `{"identifier": <username>, "secret": <PAT>}`, which returns `access_token`. This
  is Hub's own username-and-token exchange, not a Docker registry login.
- `PATCH https://hub.docker.com/v2/repositories/<user>/php/` with
  `{"full_description": <markdown>}` and the bearer token from the first call.

**PATCH, not PUT.** PUT replaces the whole repository descriptor, and the fields
this kit does not own — the short `description` under the repository name, the
`categories`, whatever Hub adds later — would be sent back as whatever the script
happens to know about them. The payload carries exactly one key. `description` is
left alone for the same reason it is not regenerated anywhere else: it is a
hand-tuned sentence, and overwriting it with a heading on every release would
degrade it quietly and permanently.

**The credential never reaches a command line.** Both the exchange body and the
bearer header are handed to curl as files in a `mktemp -d` removed on exit, with the
header file mode 600; argv is readable by anything on the runner, and a secret in a
`curl` invocation is a secret in the log.

**The 25000-byte limit is enforced here rather than by the Hub, because the Hub's
answer to an oversized `full_description` is a silent truncation.** The script
measures the payload and refuses to send, naming the number. README.md is ~22k today
and the rewritten version is a little larger (16 relative links become absolute
URLs); the day it exceeds the cap, the sync step goes red with the size in its
message and a maintainer decides what the Overview says instead of the Hub deciding
by cutting mid-sentence.

**Relative links are rewritten to blob URLs pinned to the commit being published.**
`[MAINTAINING.md](MAINTAINING.md)` on hub.docker.com resolves against
`hub.docker.com/r/<user>/php/` and 404s, and `…/blob/HEAD/…` describes a document
that moves while the tags on that page were built from one fixed commit. So the base
is `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/blob/${GITHUB_SHA}/`, taken from the
Actions environment, and the script refuses to invent one outside CI — a dry run is
allowed to use `HEAD` because it sends nothing. In-page anchors (`](#section)`) stay
as they are: they point inside the Overview, which is the same document.

**The write is read back with no credentials.** A 200 from the PATCH only proves the
request was accepted, so the script then does an anonymous
`GET /v2/repositories/<user>/php/` and requires `full_description` to open with
README.md's first line — marker `#` included, since the body is the file. Both
pretty-printed and compact spacings are accepted, and the comparison stops at the
first non-ASCII byte, because a JSON encoder is free to send the en dash in this
repository's title as an escape and a byte-for-byte grep would then report a
successful write as a failure.

**Where it runs.** The release path is `release.yml`'s `mirror-readme` job: one job,
after the matrix, one call. It is deliberately not a step in `build-version.yml`,
where it used to sit on the `cli` leg of each merge job — the Overview is one piece of
metadata for the whole `<user>/php` repository, and a `version=all` run starts eight
matrix legs, so a step there means eight PATCHes of an identical body with one green
leg covering seven failures. As a job of its own it also says what it covers: the
release published, then the page was synced. It is
`continue-on-error`, for the reason every tail step here has: the tags and layers are
already published, and a red job at the end of a good release invites someone to
re-run it, which repushes image tags to fix a documentation pane. The message says
what happened either way, including the no-mirror case, which is detected in the
shell because a step condition cannot see the `secrets` context at all — an `if:` on
an unset env var would skip for "secret missing" and "secret empty" identically and
silently.

`sync-dockerhub-readme.yml` is the manual half: `workflow_dispatch` only, no inputs,
and it **fails loudly** because a person pressed the button and wants an answer, not
a warning. It runs the tool's `--self-test` and a `--dry-run` (which prints the exact
payload size and link count) before it sends anything. Use it to fill the Overview
between releases, or to retry only the Overview after a release warned.

**What the token must be able to do.** `DOCKERHUB_TOKEN` is the same secret the
mirror's `docker login` uses, so its requirement grew with this feature: a personal
access token with **read and write** on the repository, not the read-only scope that
is enough to pull. The tool distinguishes where it was refused — 401/403 at
`/v2/auth/token` means the credentials themselves, 401/403 at the PATCH means a token
that authenticates but may not write this repository, and 404 means there is no
`<user>/php` to describe.

**Proven against a local stub, not the live Hub.** The seven branches above
(accepted-and-read-back, escaped read-back, `full_description` still null, body
rewritten, 401, 404, unexpected status) were exercised against a local stub of both
endpoints; the first real run's log line and the page at
`https://hub.docker.com/r/<user>/php/` are the check.

## Why this kit doesn't auto-pick latest commits

Moving branch heads make builds non-reproducible and can introduce unreviewed
source changes. Resolve and review a commit first, then pin it in the
manifest. Update pins through a reviewed change; `build.sh` rejects
placeholders, non-digest base images, and unpinned commits.

## Repository layout

- `Dockerfile`: gated source build, dual OpenSSL routes, cli/fpm variants, embedded build provenance
- `build.sh`: `./build.sh <version> [cli|fpm]` with route/manifest/variant validation
- `manifests/*.env`: per-version pins (5.6 / 7.0–7.4 / 8.0 / 8.1) — source repo, commit, route and base-image digest all filled
- `manifests/SECURITY-REVIEW.md`: CVE review matrix + backports patchset record + machine-readable status table
- `manifests/OS-CVE-STATUS.md`: per-CVE register for the **Debian** package closure (CVE, source package, suite, what the image has, disposition, evidence, review date) — the file `tools/scan-image.sh` gates against
- `patches/README.md` + `patches/REVIEW-TEMPLATE.md`: patch management and per-patch audit record
- `tests/smoke.sh`: version, extensions (`php -m` + `php --ri`), FPM config (fpm variant), ldd, route check
- `tests/extensions.sh`: functional tests — zip/gd roundtrips, OpenSSL ciphers, AES-GCM, RSA sign/verify, TLS constants, redis/memcached client checks
- `tests/composer.sh`: per-series version policy, phar digest + provenance cross-check, offline validate, best-effort diagnose
- `tests/verify-harness.sh`: runs `tools/verify-*.sh` against stub `php`/`php-fpm`/`openssl`/`ldd`/`sha256sum`/`dpkg-query` binaries — 47 positive/negative cases, no Docker or PHP compile required
- `tests/scan-image-harness.sh`: runs `tools/scan-image.sh` against a stub `docker` (serves `/opt/php/RUNTIME-OS-PACKAGES`, and for one case a pending-upgrade line in apt's own `Inst pkg [old] (new)` format) and a stub `trivy` (absent / failing / reporting) — 13 cases over the verdict, the JSON's `scanner` field and the exit code, against the real register, including the parser edges: JSON with long metadata before `Results` (`json-long-metadata`), text lines containing `|` (`text-pipes`, `csv-mixed`), an empty report (`empty-report`), and `--findings -` with the `*` frozen-archive row (`stdin-wildcard`). `jq` is needed for the trivy-JSON cases, so both static-gate jobs install it
- `tools/verify-build.sh`: build-stage assertions (`php -m`, `php --ri`, linked OpenSSL vs route, 8.x version floors); installed as `/usr/local/bin/verify-build` and called from the Dockerfile
- `tools/verify-runtime.sh`: final-image assertions (binaries run, provenance present, Composer version + phar digest match the build record, no unresolved libraries, runtime OpenSSL vs route, shipped/omitted source tree matches `BUILD-CLEANUP` and is still a usable build tree, `/opt/php/RUNTIME-OS-PACKAGES` agrees package-for-package *and version-for-version* with `dpkg-query`); shipped in the image as `/usr/local/bin/verify-runtime` so the audit can be re-run on a pulled image
- `tools/lint-dockerfile-shells.sh`: joins each Dockerfile `RUN` continuation the way the parser does and syntax-checks the result with `sh -n` and `bash -n`
- `tools/list-version-branches.sh`: inventories every `# version-branch: <tag>` marker and, with `--check`, fails if the tags and the "Version-conditional behaviour" table here disagree in either direction
- `tools/report-image-size.sh`: `./tools/report-image-size.sh <image-ref> [label]` — size, largest layers, in-image `du` breakdown and the cleanup record, appended to `$GITHUB_STEP_SUMMARY`; reports only, `BUDGET_MB` adds an advisory over/under line
- `tools/gen-supported.sh`: regenerates `SUPPORTED.md` from manifests + review statuses (CI checks drift)
- `tools/check-image-name.sh`: reads the registry/namespace defaults out of the release workflow and fails if the docs, the tag composition or the GHCR package name no longer describe the same published address (`ghcr.io/muffetlab/php`)
- `tools/resolve-base-digest.sh`: `--check` reports each base tag's current digest and flags every manifest still on `@sha256:REPLACE_WITH_DIGEST`; `--base <tag>` resolves a tag no manifest names (a candidate base) and `--value` prints only that digest-pinned reference, which is what the CI trial job captures; prints, never writes
- `tools/check-pin-drift.sh`: compares each `PHP_SRC_COMMIT` with the peeled commit of its upstream tag via `git ls-remote`; advisory only, never fails a build
- `tools/scan-image.sh`: `./tools/scan-image.sh <image> [--findings FILE|-] [--json-out FILE] [--no-probe]` — OS gate: reads `/opt/php/RUNTIME-OS-PACKAGES` out of the image, probes what that image's own Debian suite offers today, classifies findings against `manifests/OS-CVE-STATUS.md`, and fails on a fix the kit could have taken and on a run that never scanned (see *The Debian base and its CVEs*). Exit 1 = action needed **or nothing was scanned** (`verdict: unverified`, `scanner: absent|trivy-failed` — an absence is not a clean), 2 = usage or a missing prerequisite. Needs Docker; `jq` only for a trivy JSON report; `--no-probe` for an offline run
- `tools/install-trivy.sh`: installs the scanner at the pinned `TRIVY_VERSION`, verifying the release asset against a committed SHA-256 before running it, then proving the installed binary reports that version and is on the PATH later steps will use (`GITHUB_PATH` when it has to add it). The four digests are filled; an empty one is still announced rather than guessed at, but it no longer buys a quiet pass, because `scan-image.sh` verdicts an unscanned run `unverified` and exits 1. `--print-pin` prints the paste-ready lines and must run where GitHub is reachable
- `docker-php-ext/`: vendored official extension scripts (pinned commit, SHA-256 verified in CI) + integration notes
- `SUPPORTED.md`: generated support/pin/review matrix — start here as a consumer
- `.github/workflows/`: CI validate gate + sequential build chain + release pipeline
- `docker-compose.example.yml`: internal FPM + Nginx network example. The app is mounted at `./app:/var/www/html:ro` on **both** the nginx service and every FPM service, and that is not decoration: nginx sends `SCRIPT_FILENAME` as a path string and php-fpm opens it in its own container, so a different path on each side yields "Primary script unknown"
- `nginx.conf.example`: matching Nginx site config — FastCGI to one compose service (`php81:9000`), `try_files $uri =404` for the PHP location, dotfiles denied; copy it per version you expose. `$document_root` is nginx's per-request `root`/`alias` value, not a host variable, so it works in containers as long as the two mounts agree
- `LICENSE` / `DISCLAIMER.md` / `SECURITY.md`: licensing, responsibility boundary, and vulnerability reporting
