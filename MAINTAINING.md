# Maintaining this kit

[README.md](README.md) and [DEPLOYING.md](DEPLOYING.md) are for people who pull
these images; this file is for the much smaller audience that builds or
publishes them -- filling manifests, reviewing patchsets, running the CI chain
and cutting a release. Read [SECURITY.md](SECURITY.md) and
[manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md) first: they define
what "reviewed" means.

Two scripts read this file. `tools/list-version-branches.sh --check` compares
the version branches in the code with
[Version-conditional behaviour](#version-conditional-behaviour).
`tools/check-image-name.sh` is the document gate: it checks that the documents a
release depends on exist and are routed from README.md; that the load-bearing
claims are stated (the published address, the tag shapes, exact-tag
immutability, the absence of a `latest` tag, one gate row beside every
SECURITY.md guarantee); that every anchor and chapter pointer resolves; and that
no document copies live registry state. Prose is matched as a pattern, so
rewording is free; a literal is required only where the string is the contract.

## Contents

- [Task navigation](#task-navigation)
- [Building the images yourself](#building-the-images-yourself)
- [Build & verification order](#build--verification-order)
- [Version-conditional behaviour](#version-conditional-behaviour)
- [Per-version extension sets](#per-version-extension-sets)
- [Dockerfile caveats (read before trusting a build)](#dockerfile-caveats-read-before-trusting-a-build)
- [Composer trust model](#composer-trust-model)
- [How the image stays slim without losing the audit trail](#how-the-image-stays-slim-without-losing-the-audit-trail)
- [The Debian base](#the-debian-base)
- [The OS CVE register and gate](#the-os-cve-register-and-gate)
- [Trialing a newer Debian release](#trialing-a-newer-debian-release)
- [CI (GitHub Actions)](#ci-github-actions)
- [Hardening gates (what CI enforces)](#hardening-gates-what-ci-enforces)
- [Publishing images](#publishing-images)
- [Why this kit doesn't auto-pick latest commits](#why-this-kit-doesnt-auto-pick-latest-commits)
- [Repository layout](#repository-layout)

## Task navigation

The list above orders chapters; this table orders jobs. Start from the row that
matches the work in front of you; each cell names the section that holds the
procedure:

| Task | Where to read |
| --- | --- |
| Add a PHP version | [Building the images yourself](#building-the-images-yourself), then [Version-conditional behaviour](#version-conditional-behaviour) |
| Change or re-pin the base image | [Building the images yourself](#building-the-images-yourself), step 1; policy and base selection are in [The Debian base](#the-debian-base); candidate testing is in [Trialing a newer Debian release](#trialing-a-newer-debian-release) |
| Review or amend a PHP source patch | [SECURITY.md](SECURITY.md) and [manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md) — the review record lives there |
| Add or change an extension | [Per-version extension sets](#per-version-extension-sets) |
| Handle a Debian CVE | [The OS CVE register and gate](#the-os-cve-register-and-gate), with the finding registered in [manifests/OS-CVE-STATUS.md](manifests/OS-CVE-STATUS.md) |
| Change CI | [CI (GitHub Actions)](#ci-github-actions), then [Hardening gates (what CI enforces)](#hardening-gates-what-ci-enforces) |
| Publish an image release | [Publishing images](#publishing-images), starting at [Release flow](#release-flow) |
| A release run failed, skipped or published nothing | [When a release run goes wrong](#when-a-release-run-goes-wrong) |
| Repair the Docker Hub mirror | [The mirror: what it may copy and what it may not](#the-mirror-what-it-may-copy-and-what-it-may-not), whose rows are in [The verdict, and the rules behind it](#the-verdict-and-the-rules-behind-it) |

## Building the images yourself

The manifests are already filled: `BASE_IMAGE`, `PHP_SRC_REPO`, `SOURCE_REF`,
`PHP_SRC_COMMIT`, `OPENSSL_ROUTE`, `BUILD_VARIANTS` and `PATCHSET_APPROVED`
carry reviewed values, so a build needs no edit. A change to any of them goes
through the step that owns it:

1. **Base.** `BASE_IMAGE` is a resolved multi-arch index digest — 64 lowercase
   hex, never a tag — 5.6 on `debian:bullseye-slim`, 7.0–7.3 on
   `debian:bookworm-slim`, 7.4–8.1 on `debian:trixie-slim`. Resolve a candidate
   with `tools/resolve-base-digest.sh` (`--check` reports placeholders and drift,
   `--base` resolves a tag), then commit the digest it prints. A pin, a build and
   a served image are three different artifacts: the digest is manifest data, a
   build is what `verify-build` and `verify-runtime` read, and `published-image`
   is the token
   [`manifests/OS-CVE-STATUS.md`](manifests/OS-CVE-STATUS.md#evidence-types)
   gives a version read out of a serving image. 5.6 stays on bullseye because no
   later Debian ships OpenSSL 1.1; both apt stages rewrite `bullseye-security` to
   `archive.debian.org`, the `bullseye-archive-security` row of
   [Version-conditional behaviour](#version-conditional-behaviour).

2. **Source.** `PHP_SRC_REPO` must be `shivammathur/php-src-backports` and
   `PHP_SRC_COMMIT` a full 40-hex SHA, never a branch head. Official
   `php/php-src` is refused by `build.sh`, the Dockerfile guard and CI alike:
   switching source is a reviewed policy change, not a value to edit.

3. **Patch review.** Every file under `patches/<version>/` needs a record in
   `manifests/SECURITY-REVIEW.md` made from `patches/REVIEW-TEMPLATE.md`, and
   `PATCHSET_APPROVED=1` is set only for a patchset actually accepted. The
   `Patch review record check` step fails a build whose patch digest is not
   written verbatim in a `REVIEW-*.md`. The hash says which bytes ship; whether
   the patch belongs on that branch is the judgement the human record carries.

4. **Build and test, one version at a time.** `./build.sh <version> <variant>`
   tags `php-legacy-kit:<version>-<variant>-test` (a local-only name that never
   matches a published ref), then run `tests/smoke.sh`, `tests/extensions.sh`
   and `tools/scan-image.sh` against it. `BASE_IMAGE_OVERRIDE=<tag>` tries a
   candidate base without editing a reviewed pin: it replaces `BASE_IMAGE` before
   every check that reads it, so a trial obeys the same rules as a release (see
   [Trialing a newer Debian release](#trialing-a-newer-debian-release)).

The rest are optional: `BUILD_PACKAGES`, `RUNTIME_PACKAGES`, `PHP_EXTENSIONS` /
`PECL_EXTENSIONS`, `SHIP_PHP_SOURCE` and `COMPOSER_VERSION` / `COMPOSER_SHA256`.
Extensions are additive only — core
`openssl curl mysqli pdo_mysql mbstring zip gd zlib`, PECL
`apcu redis memcached`, plus `mcrypt` appended by the guard on 5.6–7.1.

## Build & verification order

The release chain runs each PHP series through:

manifest validation → patch/CVE review → build (cli + fpm) →
smoke tests → extension tests → Composer tests → OS CVE gate.

`verify-build` and `verify-runtime` run inside the Docker build; the remaining
checks run against the resulting image. Application regression and staging are
review statuses recorded in `manifests/SECURITY-REVIEW.md`, not pipeline steps.
The CI chapter documents the workflow and its enforcement gates.

## Version-conditional behaviour

The kit uses one Dockerfile for all eight series, so every place where behaviour
depends on the PHP version is marked with a `# version-branch: <tag>` comment
and listed here. `tools/list-version-branches.sh --check` is a CI gate in both
directions: a marker without a row, or a row without a marker, fails the build.
Adding a new `case "${PHP_VERSION}"` therefore cannot stay undocumented.

Run `./tools/list-version-branches.sh` for the current tag → file:line index.

| Tag | Versions affected | What differs |
| --- | --- | --- |
| `series-allowlist` | all | The set of series this kit builds at all. |
| `route-by-series` | 5.6 vs 7.0+ | 5.6 on `openssl11`, every other series on `openssl3` (*The Debian base*). |
| `bullseye-archive-security` | 5.6 (by base OS, not by PHP series) | `bullseye-security` is rewritten to `archive.debian.org` in both apt stages (*The Debian base*). |
| `patches-by-series` | all | Patches are read from `patches/<series>/`. |
| `mysqlnd-suffix` | 8.0+ | mysqli/pdo_mysql flags drop the `=mysqlnd` suffix (*Per-version extension sets*). |
| `gd-zip-spelling` | 5.6–7.1, 7.2–7.3, 7.4+ | GD/ZIP flag spellings change at the series boundaries (*Per-version extension sets*). |
| `zip-spelling` | 5.6–7.3 vs 7.4+ | The ext/zip flag changes at 7.4 (*Per-version extension sets*). |
| `pear-optional` | 7.4+ | `--with-pear` becomes opt-in (*Per-version extension sets*). |
| `freetype-config-shim` | 5.6–7.3 | `freetype-config` shim, none on 7.4+ (*Per-version extension sets*). |
| `fpm-www-conf-fallback` | 5.6 | Pool file generated where `www.conf.default` is absent. |
| `pecl-pins` | 5.6 vs 7.0/7.1 vs 7.2/7.3 vs 7.4+ | Per-series PECL pins (*Per-version extension sets*). |
| `ext-baseline` | all | Baseline definition and per-series append (*Per-version extension sets*). |
| `ext-availability` | 5.6–7.1 vs 7.2+ | Which extra extensions a series can build (*Per-version extension sets*). |
| `ext-optional-configure` | 5.6–7.1 when requested | Configure flag per extra extension (*Per-version extension sets*). |
| `ext-runtime-libs` | 5.6–7.1 when requested | Runtime library per extra extension (*Per-version extension sets*). |
| `ext-mcrypt-presence` | 5.6–7.1 | mcrypt behaviour-test gating (*Per-version extension sets*). |
| `composer-policy` | 5.6–7.1 vs 7.2+ | Default Composer pin (*Composer trust model*). |
| `composer-major-guard` | 5.6–7.1 | A 2.x override is rejected. |
| `openssl-floor-8x` | 8.0, 8.1 | Minimum 8.0.13 / 8.1.0, enforced by `verify-build`. |
| `tls13-const-74` | 7.4+ | TLS 1.3 stream constant asserted only from 7.4. |
| `aead-openssl-encrypt-71` | 7.1+ | AEAD `openssl_encrypt()` signature asserted only from 7.1. |

Extension availability, configuration, runtime dependencies and behaviour tests
are maintained in *Per-version extension sets*. This table records the existence
and scope of each version-specific branch.

## Per-version extension sets

The set is a baseline (core
`openssl curl mysqli pdo_mysql mbstring zip gd zlib`, PECL
`apcu redis memcached`), plus a per-series append the guard step itself makes
(`mcrypt` joins the core baseline on 5.6–7.1, the series that can still build
it), plus whatever a manifest adds. Every manifest currently adds nothing:

```sh
# manifests/5.6.env (empty on every series today)
PHP_EXTENSIONS=""
PECL_EXTENSIONS=""
```

The extension set is additive and availability-checked. The guard rejects
unsupported extensions before compilation, and build, runtime and external tests
verify the resolved set against the manifest's promise.

How each baseline member is wired still differs by version, and this is the
table a reviewer reads before touching a configure flag. Extension names are
validated as `[a-z0-9_]` in `build.sh`, in the Dockerfile guard and in every CI
gate that reads a manifest, because they are interpolated into build-stage
shell.

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
| apcu (PECL) | 5.6: 4.0.11 (last of the 4.0.x line, floor 5.3.0) | pinned 5.1.28 (floor 7.0.0-dev) | pinned 5.1.28 | pinned 5.1.28 |
| composer | pinned 1.10.28 (2.x requires PHP >= 7.2.5) | pinned 2.11.0 | pinned 2.11.0 | pinned 2.11.0 |

The configure spellings are measured history; the PECL and Composer versions are
current pins whose executable copies live in the Dockerfile (*Composer trust
model*).

The baseline is defined once in the guard step; helpers that also run outside a
build carry fallback copies, and `tools/check-ext-baseline.sh --check` fails CI
if any copy loses a name. `pecl-pins` is keyed `extension:series` and exits 2 on
an unknown pair. Pins are bounded by each release's `package.xml` floor, so the
table pins the newest release that admits the series; an extension outside the
standard set (`intl`, `bcmath`, `soap`) must be validated against the same
boundaries. The resolved set is computed once into `/opt/php/BUILD-EXTENSIONS`,
read by every later step, recorded in `BUILD-PROVENANCE` (`extensions_core` /
`extensions_pecl`) and rendered into SUPPORTED.md by `tools/gen-supported.sh`.

To wire a new core extension (mcrypt is the worked example), all five places
must agree:

1. the availability table in the guard step (`ext_available`, keyed by series);
2. the dev-package mapping in the build-stage apt step;
3. the configure flag in the configure step, spelled for that series;
4. the runtime library in the runtime apt step (`ext_runtime_libs`), measured on
   every base the affected routes use;
5. a behaviour test in `tests/extensions.sh`, gated on `promised("<ext>")`.

For a PECL extension, step 3 is a `pecl-pins` entry and step 4 is whatever
library it links. The vendored `docker-php-ext-*` tools must match
`docker-php-ext/SHA256SUMS` and the commit recorded in
`docker-php-ext/README.md`.

To drop an extension, delete the manifest line (or, for a baseline member like
mcrypt, the guard step's per-series append, which changes every image of that
series). `libmcrypt` has had no upstream release since 2.5.8 (2007), has no AEAD
modes and is deprecated where it exists, so shipping it on 5.6–7.1 is a
deliberate compatibility purchase, reviewed in the **libmcrypt** entry under
"Bundled third-party components" in `manifests/SECURITY-REVIEW.md`.

## Dockerfile caveats (read before trusting a build)

1. **An extension fragment has to name the file, not just the extension.** A bare
   `extension=<name>` is resolved against `extension_dir` as written, and the
   loader's second attempt at `name.so` was measured on three images:
   `php:8.1-cli` loads either form, while this kit's own 5.6.40 and `php:7.1-cli`
   report `Unable to load dynamic library '<extension_dir>/name'`. The vendored
   `docker-php-ext-enable` writes exactly the argument it is handed, so this build
   passes `redis.so` / `memcached.so`, the form every published image of this kit
   ships and the one the check below never rejects. `tools/verify-runtime.sh` fails
   any published image whose own fragments do not load. The same stripping happens
   downstream, and that is the live limitation:

   **Known limitation — `docker-php-ext-install` emits an unloadable fragment on
   the old series.**
   - *Problem*: it auto-enables what it just built by calling
     `docker-php-ext-enable <name>` with the `.so` stripped, so the extension ends
     up built but not loaded, from an ini nobody hand-wrote.
   - *Affected versions*: every series whose loader does not try the suffix; the
     measurements above are 5.6 and 7.1.
   - *Scenario*: a derived image compiling an extension in-image, e.g.
     `docker-php-ext-install intl` on a `5.6`/`7.1` base from this kit.
   - *Workaround*: re-enable with the suffix immediately after installing
     (`docker-php-ext-install intl && docker-php-ext-enable intl.so`), which is
     the form the loaders above resolve.
   - *Status*: open, and the workaround is the supported path. The fix is to make
     this kit's vendored `docker-php-ext-enable` append the suffix when the
     series' loader does not try it, version-gated and hash-pinned in
     `docker-php-ext/SHA256SUMS` like every other vendored copy, so correctness
     stops depending on downstream discipline. This caveat is rewritten when it
     lands.
2. **Build dependencies must be pinned.** One Dockerfile builds all eight
   series; what ships is decided by the manifests plus what the base image's
   repository serves on the build date. For release, lock each version's base
   digest and its build/runtime package versions (`BUILD_PACKAGES`,
   `RUNTIME_PACKAGES`): pinning only the PHP commit while leaving
   `libssl3`/`libmemcached`/`libzip` floating re-opens the hole the pins exist to
   close. Some bases need `libonig-dev`-style build deps and matching runtime
   libraries, which is what those two fields are for; the effective list is
   recorded at `/opt/php/BUILD-DEPS` so a published image can be audited against
   the manifest.

Base OS and OpenSSL routing are *The Debian base*; per-series configure
spellings, and why a passing `./configure` is not proof, are *Per-version
extension sets*; the `PHP_SRC_REPO` rule is *Building the images yourself*,
step 2.

## Composer trust model

The per-series version policy that consumers see is described in
[DEPLOYING.md](DEPLOYING.md) and in [SUPPORTED.md](SUPPORTED.md#composer); this
is the part that only matters when you are changing a pin. The table is the
current policy, and the executable copy is the Dockerfile's Composer policy pin
(version and phar SHA-256 per series), which a manifest may override under the
rule below:

| PHP series | Composer pin | Upstream release | Why this pin |
| --- | --- | --- | --- |
| 5.6 / 7.0 / 7.1 | **1.10.28** | 2026-05-13 | Final 1.x release; there is no later 1.10.x. Composer 2.11.0 declares `php: ^7.2.5 \|\| ^8.0`, so it cannot be used here at all. |
| 7.2 / 7.3 / 7.4 / 8.0 / 8.1 | **2.11.0** | 2026-10-29 | Newest 2.x release satisfying the `>= 7.2.5` floor. |

Two dates, kept apart. The column above is the day *upstream* shipped that
version; the day *this kit* last checked the pin against upstream's current
releases is 2026-10-30, and that single verification date covers both rows -- it
measures when the claim was re-read, not the age of the policy. A bump changes
the release column with the pin; only re-verifying changes this sentence:

- The installer script is fetched from an immutable git commit of
  `composer/getcomposer.org` at a pinned path, and must match the SHA-256 pinned
  beside it in the Dockerfile. Several mirrors are tried in order, because the
  first is unreachable from some networks; every candidate is digest-checked, so
  which mirror answers cannot change what is executed.
- The installed phar is digest-checked against the SHA-256 pinned for its version.
- `BUILD-COMPOSER` records the version line, pinned version, phar SHA-256, whether
  that digest was verified, and the installer commit/digest, and is merged into
  `BUILD-PROVENANCE`; the runtime stage re-checks the copied phar and its reported
  version against that record. `tests/composer.sh` re-asserts the policy, the
  record and the digest in the finished image, then runs an offline
  `composer validate`.

The 2.x LTS line (2.2.31) declares `php: ^5.3.2 || ^7.0 || ^8.0` and would
technically load on 5.6/7.0/7.1. This kit deliberately does not do that: the
1.10 branch is the line maintained for EOL PHP, and Composer 2's resolver and
plugin API are an extra unreviewed variable on an unsupported runtime.
`build.sh` and CI therefore **reject** any Composer 2.x pin on 5.6/7.0/7.1;
changing that is a reviewed Dockerfile edit; a manifest cannot override it.

A manifest may override `COMPOSER_VERSION`, and should then also set
`COMPOSER_SHA256`; overriding the version without a digest makes the build skip
the phar check and logs a notice.

PECL pins follow the same discipline. They live in the Dockerfile's PECL step
and are recorded in each image's `BUILD-PROVENANCE` along with the commit of the
vendored `docker-php-ext-*` tooling, so a published image says which version of
the official helpers it carries. They are bumped only through a reviewed change
that re-runs the full test chain, the same as a source-commit pin. The
`package.xml` floor that bounds each pin is *Per-version extension sets*' rule;
check it before bumping.

## How the image stays slim without losing the audit trail

A PHP built from source on a distro base is easily over 1 GB, and that is not a
defect: `php-fpm`, the OpenSSL/libzip/libpng stack and the extension headers are
real files. The kit removes only the *avoidable* part, without breaking the one
thing that makes the image useful to downstream builds.

The final image is two `COPY --from=build` lines (`/opt/php` and
`/usr/src/php`). `COPY` cannot exclude paths, so every byte has to be deleted in
the build stage first — that is the "Image size cleanup" step. Policy: delete
what the final image provably cannot use (it has no compiler, `make` or `git`)
and keep the configured build tree (`Makefile`, `config.status`, the `.h/.lo`
objects, `main/php_config.h`), because `docker-php-ext-install` depends on it and
cannot rebuild it without a toolchain; trimming that tree file by file trades
tens of megabytes for a silently broken extension build. Removed:
`/usr/src/php/.git` (provenance already records repo, ref and commit), `*/tests`
(PHPT needs `make` plus `cc`, and this is the biggest removable item),
`.github`, PECL temp and cache, `/tmp`, `/var/tmp`, and the runtime stage's apt
lists and package caches.

`SHIP_PHP_SOURCE=0` drops the whole tree for images that compile nothing
downstream; `/usr/src/php/SOURCE-NOT-SHIPPED` explains why in the image, and the
cost is that `docker-php-ext-install` and PECL compiles stop working there.

Neither state may be wrong by accident. The build writes `/opt/php/BUILD-CLEANUP`
into `BUILD-PROVENANCE`, and `verify-runtime` asserts that record and the
filesystem agree: a shipped tree has its configure and build files and no `.git`;
an omitted tree is documented by `SOURCE-NOT-SHIPPED` with
`source_tree_shipped=0`. A cleanup edit that deletes something
`docker-php-ext-install` needs fails the build.

`./tools/report-image-size.sh` (the `Report image size` CI step) records the
uncompressed size, largest layers, an in-image `du` breakdown and the cleanup
record per build; it reports and never gates, with an optional `size_budget_mb`
line. The shipped tree is close to half of the image, and `bin/php` plus the
runtime route's `/usr/lib` closure account for most of the rest — which is why
the route list cannot be trimmed much further without dropping extensions.

## The Debian base

Each image is a PHP tree plus a Debian package closure. The tree is reviewed
commit by commit in
[manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md). The closure is not
ours to patch: it is whatever the base image's suite ships, and it is where a
scanner report like `debian/curl CVE-2026-86414` comes from.

The base is our choice. `BASE_IMAGE` is a manifest key, and
`tools/resolve-base-digest.sh` prints the digest a human then commits (see
*Building the images yourself*, step 1). Changing a base is therefore a reviewed
manifest change.

The upstream backports fork does not pick an OS; it only constrains it, because
a series built against OpenSSL 1.1 needs a base that still ships 1.1. That is
what `OPENSSL_ROUTE` records, and why 5.6 sits on bullseye while 7.0–7.3 sit on
bookworm and 7.4–8.1 sit on trixie (both newer bases ship OpenSSL 3.x, so the
`openssl3` route spans them). A base whose OpenSSL major does not match the
declared route (`openssl11` ⇒ 1.1.x, `openssl3` ⇒ 3.x) fails the build, and
`verify-runtime` re-asserts the pair on the final image.

*Deployed images and manifests can disagree on the base between a base move and
the next release.* A manifest change republishes nothing: a series whose
manifest moved under an already published revision takes the next revision
(*Publishing images*), so its served tags keep the closure they were built from
until that release runs. Which base an image was built from is read off the
image itself, which carries `dev.php-legacy.base-image`. The digest a tag
resolves to is the registry's own answer, copied by no document here
(`docker buildx imagetools inspect`, see
[DEPLOYING.md](DEPLOYING.md#choosing-a-tag)).

A digest-pinned base freezes the OS too. The pin is the reason a rebuild is
reproducible, and the reason a rebuild is stale: a digest-pinned `*-slim` image
names one filesystem with one set of package versions, and a security fix Debian
publishes a week later is simply not in it. So both stages of the Dockerfile
refresh the pinned filesystem before installing anything into it:

- A `dist-upgrade` with phasing forced on. A fix released in the last few days can
  sit in `partial` phasing and be invisible to a plain upgrade, which is exactly
  the window a CVE report lands in.
- Conffile prompts resolved non-interactively. An unanswered prompt is a build
  that hangs, and the config files in question are the ones this stage wrote.
- Simulate first, then refuse. The same command is run in simulation and the
  removal count is read out of it; if the upgrade would remove a package the build
  stops (`exit 2`) rather than let apt take `libcurl4` or `libssl3` away to
  satisfy a dependency, which is how a refresh turns into a build that "succeeds"
  while linking against something nobody reviewed. The runtime stage runs its own
  refresh rather than trusting the build stage's result: two stages that assemble
  one image must not disagree about which OS versions they carry.

The exact `apt-get` and `dpkg` options are the Dockerfile's; what a maintainer
reviews here is that the three behaviours above are still what it does.

On bookworm the refresh moves a handful of packages; on bullseye it is a no-op,
that archive being frozen (the `bullseye-archive-security` row). A refresh is
not a promise of a fix: on the `openssl11` route it does nothing, and the
register carries the weight — the next chapter's.

**What the image says about itself.** The final stage writes
`/opt/php/RUNTIME-OS-PACKAGES`, one line per installed package keyed by *source*
package name, because that is the key the Debian tracker and every scanner uses
(`zlib1g:arm64` is `zlib`). `tools/verify-runtime.sh` re-derives the same list
on a pulled image and fails on any drift, in either direction and on version as
well as presence. An absent file is allowed and announced, so tags published
before the inventory was written stay auditable, and `tests/verify-harness.sh`
covers each of those paths with a stub `dpkg-query`.

## The OS CVE register and gate

The base policy above fixes what is installed; this chapter fixes what happens
when a scanner reports on it.

The register is [manifests/OS-CVE-STATUS.md](manifests/OS-CVE-STATUS.md): one row
per (CVE, source package, answer) with what the tracker says, what each measured
base actually has, which artifact each of those versions came from, a
disposition, an evidence link, and a review date. Two of those columns are
vocabulary the gate reads. A disposition is one of `no-candidate-in-suite`,
`fixed-only-in-unstable`, `declined-no-dsa`, `frozen-archive`, `not-in-image`,
`accepted-risk`, and `tools/scan-image.sh` rejects a row that names anything
else, so the file cannot quietly become a list of excuses. Image evidence is one
of `published-image`, `trial-image`, `test-build`, `install-log`, `suite-index`,
and it names the kind of artifact a version was read from, so a measurement taken
on a build nobody can pull never reads as a property of a published image. An
evidence token the gate does not know is warned about and the row still matches:
an uncited version is a gap in the evidence rather than a claim to reject.

Both of those columns are keyed by suite, one `; `-separated group per measured
base: ``bookworm `libsqlite3-0 3.40.1-2+deb12u2`; trixie
`libsqlite3-0 3.46.1-7+deb13u2` ``. One row can then answer two bases without
lending one base's measurement to the other, which is why a second base for a CVE
already in the register is a new group rather than a new row, while a different
*answer* is a new row -- the disposition is one word per row. *Suites* is a
matching field, not a reading aid: it scopes the first matching pass and the
stale-row check, and that check compares the group keyed to the image's own
suite. The gate warns when a group is keyed to a suite the row does not claim,
and when a version group has no evidence group of its own. A base whose suite
this gate does not recognise turns scoping off, warned, so a row reviewed on one
release can answer a finding on another.

The gate is `tools/scan-image.sh IMAGE`. It reads the inventory out of the
image, asks that image's own suite what it offers at scan time (an
`apt -s dist-upgrade` run inside the container), classifies each scanner finding
against the register, and fails only on the findings that describe work this kit
could have done and did not:

| Classification | Meaning | What happens |
| --- | --- | --- |
| `fixable` | the suite has a newer candidate than the image | **fail** — rebuild; do not add a register row |
| registered | a row for this CVE and package with evidence, scoped to the image's suite (`*` rows count only on the suite they name; a named row answered from another suite is a warned fallback) | pass, printed with its evidence and the citation for this suite |
| `package_absent` | no Debian package of that name in this image | **fail** — route to `SECURITY-REVIEW.md` or a `not-in-image` row |
| `unregistered` | no row, no fix, nothing reviewed | **fail** |
| stale row | a register row's group for this suite cites a version the image no longer contains | warn — the row was reviewed against another build, so re-read it; the verdict is still decided by the findings |
| probe unreachable | network/Docker prevented the currency check | the finding is reported `unverified`, never "clean" |
| no scanner | nothing scanned this image at all: no trivy on PATH, trivy could not report, or the report had zero bytes in it | **fail**, verdict `unverified` — an unscanned image is not a clean one |

The gate has no ignore list. A new CVE is silenced only by writing a row that
states, in terms the tracker will contradict if it is wrong, why Debian has no
fix for us; that is the whole difference between "known" and "hidden".

A report is read on fixed terms: a file is JSON only when it begins with `{` and
jq can parse it, a text line is a record only when a CVE id precedes its first
`|`, and anything else is mined for CVE ids and reported package-less. Every
finding object `--json-out` writes carries the same fields beside its verdict --
CVE, the binary the scanner named, its source package, the version this image was
measured with, the version the scanner says fixes it -- whatever that verdict is,
because a reader of the artifact cannot tell an absent field from an empty one.
`tests/scan-image-harness.sh` pins the table above, those two readings and the
suite scoping rules, in `validate` and in `release.yml`'s pre-flight: the one
standing between a green gate and a push.

The scanner is pinned like everything else the kit runs: `TRIVY_VERSION` and a
per-asset SHA-256 table, both in `tools/install-trivy.sh`, which refuses a
download that does not match what it lists. Fill a bump from its `--print-pin`
and change nothing here -- this chapter copies no version number. An `unverified`
finding names its cause in the report's `scanner` field
(`absent`/`trivy-failed`/`empty-report`), and `drift` cannot pass together with
no scanner: pending upgrades are a currency fact, not a CVE answer.

A new OS finding, in order: rebuild the series first. `dist-upgrade` means a
stale image often *is* the fix, and the gate's `fixable` verdict exists to catch
exactly that. If it still reports, read the tracker for the suite and draft the
row with `tools/os-cve-draft.sh`: CVEs on the command line (an inventory and
`--evidence` say what the version was measured against), or `--from-artifact`
pointed at the failed leg's `os-cve-...` report, which reads the measured binary
and version out of the artifact and implies its own evidence token. Either way
the tool prints a row and edits nothing, and what is left for a human is the
disposition and the date it was read. A placeholder disposition is one the gate
does not know, so it will not match and an unsigned draft fails the run rather
than quieting it. Then either take the candidate (base or package change,
human-reviewed) or paste the row as printed, keyed to the suite the finding was
measured on. A finding that names PHP rather than a Debian package belongs in
`manifests/SECURITY-REVIEW.md`, and the gate will say so when you get it wrong.

## Trialing a newer Debian release

A trial builds the whole suite against a candidate base and pushes nothing:
dispatch `build-and-verify.yml` with `trial_version` (one series) and
`trial_base` (a tag such as `debian:forky-slim`, or an already digest-pinned
ref). The trial job resolves and re-checks the digest, then calls
`build-version.yml` with `base_image_override`, which runs the whole suite
(smoke, extensions, composer, the OS CVE gate, the size report).
`base_image_override` together with `push=true` is a hard failure in the build
job, so a trial cannot publish even by editing the caller.

A trial dispatch suspends the eight-version chain and cancels a run in flight on
the same ref, using the concurrency rules *CI (GitHub Actions)* states. Land a
trial deliberately, not alongside a run you need.

The two numbers to compare are the trial's `os-cve-<version>-…` artifact against
the same series' regular run. Those artifacts answer 403 to an anonymous read,
so the run page's **Download log** zip is the equivalent evidence: it carries
the same lines the artifact does, the inventory count, the currency verdict,
each stale-row warning and the final `== scan-image:` summary. A leg that dies
in `make` stops before the gate and publishes no `os-cve-*` artifact; the step
log names that absence, and the compiler diagnostic in the log is the evidence
for a wall in PHP's source.

The trixie migration is settled. The current rule, not the history:

* **Package names.** The Dockerfile's two package lists are keyed by
  `VERSION_CODENAME` read from the base image. `bullseye` and `bookworm` keep the
  existing lists; `trixie`, `forky` and `sid` take the renamed (`t64`) ones. An
  unknown codename falls back to the bookworm spelling and prints which release it
  assumed, so a wrong guess is a build-log failure rather than a quiet swap.
* **The 5.6 limit.** Not a trial option: no Debian release from bookworm onwards
  ships OpenSSL 1.1, so 5.6 stays on bullseye, frozen, with the `frozen-archive`
  register rows saying so.
* **The compile boundary.** It sits at 7.4: 7.4, 8.0 and 8.1 build on trixie;
  7.0–7.3 stay on bookworm, where they fail on a libxml2 const mismatch or a
  `readdir_r` arity mis-detection. Both have a build-flag escape
  (`-Wno-error=incompatible-pointer-types`, `ac_cv_what_readdir_r=POSIX`) and both
  are *declined*: each would put a build-interface patch between the reviewed pin
  and the compiler, on a series bookworm still maintains. No such patch is added to
  the pipeline.
* **Building libcurl from source.** *Declined*: it leaves an OS curl that no
  longer matches the image's libcurl and its attestations, and it puts this kit in
  the business of rebuilding curl on every release Debian ships. The curl rows stay
  `declined-no-dsa` for the suites we build on, and a Debian fix is taken when it
  reaches the suite index.

## CI (GitHub Actions)

- `.github/workflows/build-and-verify.yml`: static `validate` gate, triggered by
  `pull_request` and manual dispatch only; it has no `push:` trigger, and
  `tools/check-image-name.sh` asserts that. A branch push that ran this chain
  beside release.yml's publishing run would build the same images under two
  concurrency groups that cannot cancel each other and write the same layer
  caches. Its checks are four families, one line each in the workflow: **lint**:
  shellcheck + `bash -n` over every `*.sh` and `sh -n`/`bash -n` over every
  Dockerfile `RUN` block, targets found by glob so a newly added script is checked
  without editing three workflow files; **stub harnesses**: verify scripts,
  OS-gate verdicts and the release-plan resolver (`tests/verify-harness.sh`,
  `tests/scan-image-harness.sh`, `tests/release-plan-harness.sh`), no Docker or
  network; **drift**: version-branch inventory, SUPPORTED.md, published-address
  consistency (`tools/check-image-name.sh`); **policy**: manifest/route/repo
  including Composer overrides, Composer pin agreement across layers, vendored
  `docker-php-ext` hashes, patch SHA-256 vs review records. Composer installer
  freshness is a warning, not a gate. Two advisory steps never fail the job:
  `tools/check-pin-drift.sh` (pin vs current upstream tag) and
  `tools/resolve-base-digest.sh --check` (base tag digests, placeholder and drift
  report), then the sequential per-version build chain. Manual dispatch takes two
  more inputs, `trial_version` and `trial_base`, that turn the run into a
  **base-image trial** (mechanism in *Trialing a newer Debian release*); either
  input alone fails the trial job. A trial dispatch also suspends the chain (it
  gates the head job `build-5_6`, and each later version needs the one before it),
  because eight multi-hour builds is not how you answer a question about one base
  image. The concurrency group is `${{ github.workflow }}-${{ github.ref }}` with
  `cancel-in-progress: true`: a dispatch cancels an in-flight chain on the same
  ref, so land a trial deliberately, away from runs you need. Every `if` here
  spells out `needs.validate.result == 'success'`, because a job with its own
  condition no longer inherits the implicit "only if every needed job succeeded"
  gate.
- `.github/workflows/build-version.yml`: reusable per-version job. Its matrix is
  `variant × arch` (`cli`/`fpm` on `linux/amd64` via `ubuntu-24.04` and on
  `linux/arm64` via the GitHub-hosted `ubuntu-24.04-arm`, natively, no QEMU), so
  each architecture builds and runs the full `tests/smoke.sh`,
  `tests/extensions.sh` and `tests/composer.sh` suite against the image it made,
  then installs the pinned scanner and runs the OS gate over it. That gate is
  enforced here, before any push, and the JSON report is uploaded as an
  `os-cve-<version>-<variant>-<arch>` artifact even when the step failed, because
  that report is the diagnosis (*The OS CVE register and gate*).
  `tools/report-image-size.sh` also runs per leg and never gates. Its
  `base_image_override` input is the trial knob of *Trialing a newer Debian
  release*; a trial still consumes the manifest's own pins and the image records
  the base it was actually built from, so it cannot be mistaken for a release. In
  push mode each leg uploads its image by digest only and a `merge` job assembles
  the digests into the published multi-arch manifest list, so a failed leg leaves
  no single-arch tag behind (*How the merge publishes*). The plan's variant list
  narrows that matrix from above, too: `tools/release-plan.sh` hands each leg only
  the variants the release still needs at its revision, so a variant the registry
  already serves is skipped before its build starts rather than compiled and then
  refused a name (*How the verdict reaches the builder*).
- `.github/workflows/release.yml`: the only publishing workflow and the only
  release entry point. Its triggers are the three release entries (a `push:` of
  tags filtered on `v*.*.*` and a `workflow_dispatch` with the required `version`
  input), and one run is one validate, one resolver pass, one dynamic matrix with
  a build leg per selected series that has something to publish, and one mirror
  Overview sync. It re-runs the full validate gate, refuses empty releases, and
  pushes reviewed images. What each entry selects, why there is no `revision`
  input, why the whole run shares one `release` concurrency group, and what the
  guard refuses are *Publishing images*' model; the CI-side rules are the three
  bullets below.
- Unfilled manifests cause the corresponding build to skip, not fail: the review
  gates stay human decisions for the series a release did *not* select. What
  happens when a *selected* series' manifest is unfilled or unapproved is
  *Publishing images*' rule.
- PRs and forks can never push images: the test caller (build-and-verify.yml)
  never passes `push=true`, so it never reaches a registry login. Conversely,
  `push=true` from a ref the build job may not publish from is a hard failure
  rather than a quiet downgrade: a caller that asks to publish and is refused must
  stop the run, not finish green with no image behind the tags.
- Runner labels are pinned, not floating: a floating label would change the host
  OS, its apt packages and its Docker engine between unattended builds. Moving a
  pinned label to a newer OS is a reviewed change -- run the validate gate and one
  full build on the new label first -- and GitHub retires old images eventually,
  so the move becomes mandatory at some point; do it deliberately. The runner OS
  never leaks into an image: bases are pinned by digest and the build happens in
  containers. `ubuntu-24.04-arm` is free for public repositories, so a private
  fork must use a paid arm64 label or drop the arm64 matrix entry, which produces
  an amd64-only list that fails the merge's platform check; adjust that check
  accordingly.

## Hardening gates (what CI enforces)

[SECURITY.md](SECURITY.md) states one line per guarantee — what a deployer or an
auditor may rely on. This is the other half of the same list: for each
guarantee, the gate that enforces it and the chapter here that owns the
mechanism. One mechanism is explained once, in its chapter; this table only
maps, so it reads as an index rather than a second explanation of machinery
documented elsewhere. `tools/check-image-name.sh` walks the two lists against
each other in both directions, so a guarantee no gate backs and a gate no
guarantee claims both fail CI. The names are the join, which is what makes them
one agreement rather than two documents that happen to agree.

| Guarantee | Enforced by | Mechanism documented in |
| --- | --- | --- |
| Manifest pins are shape-checked | shape checks in `build.sh`, the Dockerfile guard and CI | *Building the images yourself* |
| Unselected or unapproved manifests cannot be published | selection-aware validation and per-version release guards | *CI (GitHub Actions)* |
| A base-image trial cannot publish | `push=true` together with `base_image_override` is a hard failure | *Trialing a newer Debian release* |
| A patch ships only with its review record | the `Patch review record check` step (`sha256sum` vs `REVIEW-*.md`) | *Building the images yourself*, step 3 |
| Vendored extension scripts are hash-verified | `docker-php-ext/SHA256SUMS` and the Dockerfile's pinned commit | *Per-version extension sets* |
| Composer is fetched and verified by digest | pinned installer and phar digests, agreement across layers | *Composer trust model* |
| The base cannot disagree with the OpenSSL route | the route-vs-OpenSSL-major assertion at build time and in `verify-runtime` | *The Debian base* |
| Nothing is published that failed verify-build or verify-runtime | both gates run inside the image build, before any tag exists | *Build & verification order* |
| Per-version behaviour is enumerated or CI fails | `tools/list-version-branches.sh --check`, both directions | *Version-conditional behaviour* |
| No pull request or branch push can reach a registry | `push=true` is only ever passed by `release.yml` | *CI (GitHub Actions)* |
| Publishing requires tagged source | the release guard and the callee's `source_release` check | *What a release run refuses* |
| The Hub token's tier is set by the Overview write | mirror secrets present only in the release and sync jobs | *The Docker Hub mirror's Overview* |
| Every published image carries its provenance | `/opt/php/BUILD-PROVENANCE`, OCI labels, attestation merge and count | *Publishing images* |
| The Debian layer is refreshed, inventoried and self-checking | simulated `apt dist-upgrade` plus `RUNTIME-OS-PACKAGES` re-derivation | *The Debian base* |
| An OS finding is fixed, registered, or it fails the build | `tools/scan-image.sh` over every image, before any push | *The OS CVE register and gate* |
| Slimming the image never loses audit evidence | the cleanup allowlist, re-checked by `verify-runtime` against `BUILD-CLEANUP` | *How the image stays slim without losing the audit trail* |

## Publishing images

Registry defaults to GHCR and the published image is `ghcr.io/muffetlab/php`
(the ref is `<registry>/<namespace>/php`, namespace input defaulting to
`muffetlab`); a Docker Hub mirror is pushed automatically when
`DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets exist.

### The release model

Source release, series, PHP version, revision and what a deployment pulls are
decided independently — which is why one tag can release eight series:

| Question | Answered by |
| --- | --- |
| Is this source an official release? | a git tag on the built commit: `vX.Y.Z` |
| Which series does this run build? | the entry, below |
| Which PHP version is a series? | `SOURCE_REF` in `manifests/<series>.env` |
| Which build of that version is this image? | the registry: one above its highest `-r<N>` for that PHP version, or that same number when finishing a release a previous run started |
| What does a deployment pull? | the Docker tags, below |

A git tag names no series, carries no revision and appears in no image name.
Tags are never moved or deleted: `release.yml` proves the tag with `git tag
--points-at`, `build-version.yml` refuses `push=true` unless `source_release`
names one, and `v1.0.0-rc1` matches GitHub's `v*.*.*` glob but is ended before
any checkout by the guard's `^v[0-9]+\.[0-9]+\.[0-9]+$` regex.

| Entry | How it is started | What it publishes |
| --- | --- | --- |
| A | push a `vX.Y.Z` source release tag | every supported series not already current |
| B | dispatch `release.yml`, `version` = `8.1` | that series |
| C | dispatch `release.yml`, `version` = `8.1,7.4` or `all` | those series, in one run |

All three enter one pipeline — the same guard, validate gate, `release-plan.sh`,
registry read and dynamic matrix — so version, revision and verdict are decided
once per run wherever it started. An empty `version` is refused rather than read
as `all`, and unselected series keep their previous images and base digest. A
full release is one run rather than eight dispatches because the plan fixes one
registry read for the whole matrix; the legs are siblings with
`fail-fast: false`.

### Tags, and where the revision comes from

| Tag | Meaning |
| --- | --- |
| `<minor>-<variant>` (e.g. `8.1-fpm`) | recommended deploy tag; points to the latest published build within its PHP series |
| `<full-php-version>-r<revision>-<variant>` (e.g. `8.1.34-r1-cli`, `8.1.34-r2-fpm`) | fully-qualified exact tag, immutable by pipeline rule: `r1` is the first image built from that PHP version, `r2` the next build of it |

An OS security fix, a refreshed base digest, or a newer backports commit that
does not move `SOURCE_REF` bumps the revision and leaves the PHP version alone:
`r1` -> `r2`. A deployment that pins `8.1.34-r1-fpm` keeps that image until it
moves on purpose; `<minor>-<variant>` is the name that carries a fix to it
without an edit. Which exact tag the floating name serves right now is the
registry's own answer, read the way
[SUPPORTED.md](SUPPORTED.md#checking-what-the-registry-serves) says.

The revision is typed by nobody and stored nowhere here; it is read from the
registry. `tools/release-plan.sh` lists the names `ghcr.io/<namespace>/php`
serves, finds the highest `-r<N>` for the PHP version the manifest pins --
counted across every declared variant, because cli and fpm are one build -- and
proposes one more; a PHP version with no revisioned name is planned as `r1`.
Each point version counts on its own: `5.6.40` at `r2` and `8.1.34` at `r1` are
both correct. A name with no `-r<N>` is ignored by the count and left served.

The read that answers this is authenticated when the caller supplies a token,
and `release.yml` does: the plan and mirror-repair jobs pass their own job
token, so a package that exists but is still private is readable -- GHCR
creates every package private, and *Making the GHCR package public* runs after
the matrix. Two registry answers mean the namespace publishes nothing, and both
are reads that succeeded: `HTTP 404 NAME_UNKNOWN`, which is the registry saying
it knows no such repository, and an empty tag list, which is it saying the
repository has no tags. Either one plans every selected series from `r1` and
prints a notice naming the repository it read, because a deleted or freshly
created package is what a first release starts from. The notice asks the reader
to confirm that namespace, because a misspelled repository answers the same way
and the run would then create that one instead of reading this one. A registry
that will not answer at all -- a refused token, a timeout, a body that is not a
tag list -- is none of these, and the run stops there.

Deriving the number from the registry makes a re-run safe rather than lucky: a
second run reads the served revision and asks for the next one, so a fix cannot
ship as a moved `r1`; when the first run left a variant unpublished the second
finishes it at the revision it stopped at, and when it left nothing nameable the
second moves the series on. That is why the recovery in
[What a release run refuses](#what-a-release-run-refuses) and
[When a release run goes wrong](#when-a-release-run-goes-wrong) is the same
action everywhere -- re-run the scope -- and nobody is asked to choose a number
by hand.

Two consequences are machine-checked: the whole workflow
shares one `release` concurrency group with `cancel-in-progress: false` (a
cancelled run can leave per-arch digests with no manifest list merged), and
`--state-out` / `--state-in` replay one registry read across the log and the
matrix.

### The verdict, and the rules behind it

The verdict has three answers, because a release can fail halfway. The resolver
reads the four OCI labels each published image carries (source commit, source
ref, base image digest and OpenSSL route) and the architecture list each
published manifest list carries, and compares them with the manifest, per
declared variant, at the highest revision the registry serves for that PHP
version. Each variant is one of three things there, and telling them apart is
what makes a retry of a failed release reuse its revision instead of
incrementing past it:

* **current**: served, all four pins equal, and its manifest list carries every
  architecture this pipeline builds. This variant already is the build this
  release would have made.
* **absent**: the name is not served at all; the half of a release that never
  merged, which is what a retry is for.
* **unusable**: served, but a pin differs from the manifest, its build record
  cannot be read at all, or its manifest list is short of a declared architecture.
  "The pins are unknown" is not "the pins match", and a one-architecture list is
  not a smaller copy of the same build: it is a content difference, because adding
  the missing architecture means rewriting the manifest list of a name somebody
  has already pulled. An image built from inputs the manifest no longer declares
  is not this build under another number either.

A series of nothing but current variants is **SKIP**: no build, and the report
line names the revision the registry is already at.

A series with any unusable variant is **PUBLISH** at the next revision for
*every declared variant*, not just the one that looks different, so `r<N>` keeps
meaning one reviewed build of a PHP version rather than a per-variant counter
nobody can read off a name.

A series of current and absent variants only is **COMPLETE** at the revision it
stopped at: the number stays, the missing variants are built at it, and the
names already served there are left exactly as they are. The failed release is
finished under the revision it began with, which is also the answer to "why not
just increment". A series with no revisioned name at all is not in that case: it
has no number to stop at, so it is the first build above.

The three verdicts are the authoritative statement of publish behaviour; the
table adds only the boundaries they do not settle:

| Situation | The revision |
| --- | --- |
| GHCR published, the Docker Hub mirror did not (or was unreachable) | unchanged; only the mirror is repaired, by copying what GHCR already serves, never by rebuilding |
| GHCR serves the exact tag with fewer architectures than the pipeline builds | the whole series +1; the served name is never rewritten (see *The verdict, and the rules behind it*) |
| The mirror is missing a variant tag, or one of its exact tags is missing an architecture | unchanged; a missing tag is copied from GHCR, an existing incomplete one is never patched in place -- the repair job refuses, a human deletes the tag, the re-run re-syncs it whole |
| An exact tag's content differs from the manifest, on GHCR | the whole series +1; this is the plan's `unusable` verdict |
| An exact tag on the mirror carries images GHCR does not | unchanged on GHCR; the repair job refuses and names the fix: delete the mirror's tag, re-run the same scope, and the next pass copies GHCR's into it |

One rule is not about the registries: the four manifest pins are the build
inputs a revision was made from, so a manifest that moved under a published
revision is the whole series +1.

Exact names are immutable by pipeline rule: every filling rule stops at an
existing tag, and the only write this pipeline makes to an existing exact name
is a refusal. Neither registry offers a server-side immutability setting, so the
guarantee is what the pipeline controls. GHCR is the record; Docker Hub is a
repairable copy, which is why mirror rows move no revision while GHCR rows do. A
missing *variant* is a name that does not exist and can be written where it
stopped; a missing *architecture* lives inside an existing name and is filled at
the next revision, never amended.

### How the verdict reaches the builder

Each matrix leg carries the verdict as `mode` and the variant list the plan
resolved with it: a `publish` builds every variant the manifest declares, a
`complete` builds only the ones the registry does not already serve at that
revision. Both jobs in `build-version.yml` gate on that list, so a completion
never recompiles a snapshot it is forbidden to rewrite, and never pushes the
per-architecture digests of that recompile to a name it will not claim.

The exact name is asked twice on the way out. The build leg asks the primary
registry before it pushes its per-architecture digests, so a publish the registry
will not take costs the registry nothing; the merge job asks again, per registry,
immediately before it writes tags, because that read is the closest one to the
names and it is also the one that decides a mirror. On `publish`, a served name
means the registry moved under the run and both asks refuse it. On `complete`,
the served name is expected and only `<minor>-<variant>` is re-pointed at it,
leaving the snapshot untouched. That per-write check keeps the exact-name rule
true even when the plan raced.

### The mirror: what it may copy and what it may not

The plan never reads the Docker Hub mirror, so a name the mirror already serves
is residue from a run that published to the primary and failed here; that
registry is skipped and the others still publish, so a retry can finish the
release. Before a mirror takes this run's digests, the publish step asks the
primary whether it already serves that exact name and, when it does, copies the
primary's image instead -- a PHP compile is not reproducible, so a mirror filled
from this run would differ behind the same snapshot.

What the matrix cannot reach is a series the plan skipped: GHCR is current, no
leg runs, yet the mirror may miss an older name. `release.yml`'s `mirror-repair`
job fills that gap from the resolver's `--repair` list: it reads both
registries, reduces each name to `os/arch -> digest`, copies what is missing,
reports what is equal, and refuses what differs (a subset of GHCR's platforms,
or a child digest GHCR does not serve) while naming which. It runs after the
matrix whatever its result and reads the registry afresh.

Registries are read only where a read changes what a run does:
`tools/release-plan.sh` lists tags and manifests in a single pass (that read is
both the verdict and the revision each name carries), and fails any served name
beginning `latest`; [Tags, and where the revision comes from](#tags-and-where-the-revision-comes-from)
says how that read is authenticated and what an empty namespace means.
`tools/gen-supported.sh` reads no registry, so `SUPPORTED.md` states no live
state and its `up to date` gate compares the committed page against the tree
alone.

### What a name says, and what it deliberately does not

There is no `latest` tag: a `latest-<variant>` would follow release order rather
than code, could move backwards, and cannot name a variant.
`<minor>-<variant>` is the only floating name and cannot change major version.
`tools/check-image-name.sh` holds all three halves: the publish step writes
exactly two shapes, no document advertises a latest address, and every document
that names a tag states there is none.

Every published name is a multi-arch manifest list covering `linux/amd64` and
`linux/arm64`; there are no architecture-suffixed tags, and the merge asserts
both platforms. Tags carry no OpenSSL route either: the pipeline fixes one route
per series, so the suffix slot belongs to the revision — a route migration is
`8.1.34-r2-fpm` beside `8.1.34-r1-fpm`, and the floating `8.1-fpm` follows the
newest.

### How the merge publishes

The mechanics live in `.github/workflows/build-version.yml`: each leg uploads its
image by digest, and a `merge` job composes the list with one
`docker buildx imagetools create` call per registry, GHCR first -- one call
covering both would lose the GHCR tags if the mirror refused, and its error could
not say which registry did it. A refused mirror still fails the job, but only
after the primary publish, and the failure is an annotation naming the repository
because a publishing log is truncated in the Actions UI.

Three facts before reading a green log: a leg that prints a digest need not have
published anything (buildx's `type=image` is a local load unless its output
pushes, so the export step asks the registry to confirm the digest); a published
list carries attestation manifests (`unknown/unknown` children the resolver drops
when it counts architectures); and the registry's untagged list is not a report of
what a release did. Four things separate it:

* **Normal structure** — most of it. A tag names the manifest list, never its
  children, so every per-architecture image and every attestation belongs there,
  and where a registry has no referrers index buildx embeds the attestations in
  the list instead of attaching them. Deleting one breaks a published tag.
* **Residue** — a digest this flow pushed and never tagged, and it has three
  named causes: a completion that rebuilt a variant already served, a publish
  that found its exact name taken only after pushing, a leg that pushed and lost
  its merge job.
* **Handled by the flow** — the first two causes, closed off upstream by the
  plan's variant list and the build leg's pre-push check, so a run with nothing
  to publish writes nothing. The third is what `fail-fast: false` pays for a
  partial release, and re-dispatching the same scope is what finishes it.
* **Human work** — the untagged entries themselves. Nothing deletes registry
  content and no second repository holds a refused build's digests, by decision;
  emptying the list is a console action.

### Release flow

The steps are the short part; what the run may and may not write is decided by
the model above. Read [The release model](#the-release-model) for what each entry
selects and where the revision comes from, and
[What a release run refuses](#what-a-release-run-refuses) for the states that end
the run red on purpose, before the first dispatch.

Fill each `BASE_IMAGE` digest (`tools/resolve-base-digest.sh`, committed by
hand) → finish the reviews and update `manifests/SECURITY-REVIEW.md`, and
`manifests/OS-CVE-STATUS.md` for anything reported against the Debian package
closure → `./tools/gen-supported.sh` and commit → push a `vX.Y.Z` tag (entry A),
or dispatch `release.yml` from the default branch naming `version` (entries B
and C).

`npm run release` cuts that tag: it bumps the version in `package.json` and
`package-lock.json`, writes `CHANGELOG.md` from the commits since the last tag,
commits both and tags the commit `v<version>`. Push with
`git push --follow-tags` when the tree is ready.

Two consequences of that tool's arithmetic. While the version is below `1.0.0`
every bump is capped -- a `feat` yields a patch and a `BREAKING CHANGE` a minor,
never `1.0.0` -- so the first release is cut explicitly, `npm run release --
--release-as 1.0.0`. And `CHANGELOG.md` cites commits, which means a history
reset invalidates it: delete the file before wiping history and let the next
release regenerate it from the history that actually exists.

There is no `revision` input, and the tag is a prerequisite even for a dispatch:
a run that cannot name a `vX.Y.Z` tag on the commit it is building fails in the
guard before any build starts. The PHP version comes from `SOURCE_REF` in the
manifest and is carried into the matrix.

`SUPPORTED.md` goes stale when this repository changes, not when the registry
does: regenerate it with a manifest, base, variant or review-status change or
the `SUPPORTED.md up to date` gate fails. A release that only published new
images is not a documentation edit.

After a release rebuild, re-read the rows for the series it touched and replace
a version or an evidence group only from that read; `tools/scan-image.sh`'s
stale-row check names every row whose recorded group no longer matches the
image, so the follow-up does not depend on someone remembering it.

### What a release run refuses

Each of these is a case where the honest outcome is a red run rather than a
green one with nothing published, so the refusal is written into the guard, the
validate step or the publish step instead of left to a reviewer's memory:

| Refused | Because |
| --- | --- |
| a dispatch whose `version` is empty | read as `all` it would be a full release nobody asked for |
| a run standing on a tag like `v1.0.0-rc1` | GitHub's filter is a glob and cannot say "digits only", so the guard's own regex ends the run before a checkout |
| publishing from a commit that names no `vX.Y.Z` source release tag | the image would carry a source no review record describes |
| an unfilled or unapproved manifest for a *selected* series | a mistargeted tag would otherwise finish green; an `all` run that found one unreviewed series pushes nothing at all |
| a selection that names no series once it is split | an empty list loops zero times, prints "release-ready", and leaves every build job to skip itself |
| `push=true` from a ref the build job may not publish from | a caller that asks to publish and is refused must stop the run, not finish green with no image behind the tags |
| a `publish` leg whose exact name the primary already serves | this is the immutability rule met at the write rather than in the plan: the registry moved under the run. Asking before the by-digest push is what makes the refusal cost the registry nothing |

Manifests for *unselected* series may stay unreviewed, and `build-version.yml`
still refuses to build one it is handed. Every leg runs `tools/scan-image.sh`
before pushing anything; the Overview is synced once per run by `release.yml`'s
`mirror-readme` job because `<user>/php` has one README for the whole
repository.

### When a release run goes wrong

| What the run said | What it means | What to do |
| --- | --- | --- |
| `the release plan could not be resolved` and the plan job failed with every later job skipped | the resolver's own read failed -- a refused pull token, an unreachable registry, or a body that is not a tag list -- and the line above it names which read and what the registry answered | re-run the same scope once the registry answers again: no build job ran, so there is nothing to clean. A namespace that answers it has *nothing* is not this failure -- see *Tags, and where the revision comes from* |
| the plan printed `SKIP` for every selected series | the registry already matches every manifest, so there is no build to make | nothing. A mirror left behind by an older run is the `mirror-repair` job's work, and it ran after the matrix |
| `an exact published name is never rewritten` on a `publish` leg | another run published that exact name after the plan read the registry. Whichever of the two asks said it, the refused name gains no digest from this run | re-dispatch the same scope: the plan now sees the served revision and answers `complete` for the missing variants or the next revision for the series |
| the run was cancelled partway | per-architecture digests may be pushed with no manifest list merged | re-run the same scope |
| the mirror-repair job refused | the mirror serves an exact tag that is an incomplete copy of GHCR's, or carries a child digest GHCR does not serve | delete that mirror tag, then re-run the same scope; the next pass finds the name free and copies GHCR's whole. Nothing here moves a GHCR revision |
| the OS CVE gate failed on one leg | that image has a finding against its package closure | read the `os-cve-<version>-<variant>-<arch>` artifact from the run, then *The OS CVE register and gate*. `fail-fast: false` means the healthy siblings still published |
| `SUPPORTED.md is stale` in `validate` | a manifest, base, variant list or review status moved and the generated page did not | `./tools/gen-supported.sh` and commit; [Which document owns what](#which-document-owns-what) names that generator and the page it owns |
| the package-visibility step skipped | no `GHCR_PAT` secret, or the token cannot write packages | see *Making the GHCR package public* |

### What a published image records

Every image embeds `/opt/php/BUILD-PROVENANCE` and the OCI labels, with
provenance/SBOM attestations where the registry supports them, and ships
`/usr/local/bin/verify-runtime`. What each field means to a deployer is
[DEPLOYING.md](DEPLOYING.md#checking-what-an-image-actually-contains); on top of
that, the record carries the `patches/` SHA-256 list (step 3 of
[Building the images yourself](#building-the-images-yourself)) and the cleanup
record (`/opt/php/BUILD-CLEANUP`), so a patch decision is auditable after the
image exists.

The `attestations` dispatch input defaults to `true`. Asking for them costs one
build-time dependency: buildx pulls `docker/buildkit-syft-scanner` from Docker
Hub, so a release needs Hub reachable even though every image input is
digest-pinned; `attestations=false` drops both the pull and the attestation
manifests.

### Making the GHCR package public

GHCR packages are created private on first push. The release workflow's
`package-visibility` job makes the package public after each release when a
`GHCR_PAT` secret (classic PAT, `write:packages`) is present; without it the job
prints the manual path (repository → Packages → `php` → Package settings →
Change visibility) and skips. The package is named `php` in the packages API,
not the registry path, so the job PATCHes only a resource it has read back.

A visibility failure is reported but does not fail the release: the tags and
layers are already published, and a red tail job invites a re-run of a good
release to fix a metadata toggle. The job also reads the registry back
anonymously, because a green job is not proof a credential-less pull works.
Nothing else in the pipeline reads `GHCR_PAT`: a public pull needs no token, and
the release plan's own reads need only the job token's `packages: read`, so a
package this job never made public still plans -- see
*Tags, and where the revision comes from*.

### The Docker Hub mirror's Overview

Hub renders a repository's Overview from the `full_description` field of its own
metadata, not from the README in git, so a mirror can publish tags for weeks
while its page says nothing. `tools/sync-dockerhub-readme.sh` writes that field
with the bash and curl this repository already depends on; its comments carry
the detail. What a maintainer has to know:

- *PATCH, not PUT*, so fields this kit does not own are not sent back as guesses;
  the payload carries one key and `description` stays hand-tuned.
- *The credential never reaches argv*: the token body and bearer header are
  restricted-mode files.
- *The 25000-byte cap is enforced here*, because the Hub silently truncates an
  oversize `full_description`; the script refuses and names the size, and the
  Overview is the consumer README alone so the cap is not reached quietly.
- *Relative links become commit-pinned blob URLs*, because a relative link 404s on
  hub.docker.com and a `HEAD` link would describe a moving document.

The write is read back anonymously, because a 200 only proves acceptance. It
runs as `release.yml`'s `mirror-readme` job (one call for one repository), is
`continue-on-error` because the images are already published, and
`sync-dockerhub-readme.yml` is the dispatch-only manual half. `DOCKERHUB_TOKEN`
is the same secret as the mirror's login, at a higher tier than the push needs:
the Hub answers the Overview PATCH with a 403 for anything below
read+write+delete, so the shared secret carries that tier. The tool's error lines
distinguish a token-exchange refusal, a PATCH refusal and a missing repository.

## Why this kit doesn't auto-pick latest commits

Moving branch heads make builds non-reproducible and can introduce unreviewed
source changes. Resolve and review a commit first, then pin it in the manifest.
Update pins through a reviewed change; `build.sh` rejects placeholders,
non-digest base images, and unpinned commits.

## Repository layout

This names where things live and nothing more: every entry's mechanism has its
own chapter, linked from the Contents map, and what each document is responsible
for is the table below.

- `Dockerfile`, `build.sh`: the image recipe and the local build entry point
- `manifests/`: the per-series pins (5.6 through 8.1) and the two evidence registers
- `patches/`: the patch set and its per-patch audit records
- `tests/`: the runtime checks and the no-Docker harnesses for the tools
- `tools/`: the gates, generators and release readers
- `docker-php-ext/`: the vendored official extension scripts
- `.github/workflows/`: the validate gate, the build chain, the release pipeline
- `docker-compose.example.yml`, `nginx.conf.example`: the worked FPM + Nginx example
- `README.md`, `DEPLOYING.md`, `SUPPORTED.md`, `SECURITY.md`, `LICENSE`: consumer documents; `MAINTAINING.md` is this one

### Which document owns what

The list names the files; this names the boundaries. This is the single place a
charter is written: other documents point here instead of restating one. Prose
in a row stays free to reword; the third column is the one with teeth — content
belonging to another document moves there.

Dated facts follow one convention. A *current pin or policy* is stated as
current, names the file holding the executable copy, and carries a dated
verification (the date says when it was last checked, not when it expires). A
*measurement* belongs to the artifact that produced it -- the build's CI summary
and `os-cve-...` artifact, the evidence registers, or git history for a
concluded experiment. A mechanism chapter carries the conclusion and names the
tool that re-measures it. *Live registry state* is copied by no document: the
registry is read the way
[SUPPORTED.md](SUPPORTED.md#checking-what-the-registry-serves) says.

| Document | Owns | Does not own (and where that goes) |
| --- | --- | --- |
| `README.md` | project introduction, quick use, and the security warnings a puller needs before pulling | build, review or publish mechanics → `MAINTAINING.md`; per-version state → `SUPPORTED.md`; running and configuration detail → `DEPLOYING.md` |
| `SUPPORTED.md` | support policy: what each version is actually built from — pins, base, route, review status — and what the names a release writes mean; it states no registry state, because which tags exist is the registry's answer | why a pin or a base was chosen → `manifests/SECURITY-REVIEW.md`; how a release run works → `MAINTAINING.md`; which tags exist and what each resolves to → the registry itself, the way this page says. Generated by `tools/gen-supported.sh`, so this prose has an owner: a charter change here is a generator change, and a hand edit is a drift-gate failure |
| `SECURITY.md` | security policy, known vulnerabilities, coverage, and the responsibility boundary: what the project does not promise, and the decisions a deployer owns | the CI steps that enforce a policy → [MAINTAINING.md](MAINTAINING.md#hardening-gates-what-ci-enforces); per-CVE evidence → `manifests/OS-CVE-STATUS.md` and `manifests/SECURITY-REVIEW.md`; the operative warranty terms → `LICENSE` |
| `DEPLOYING.md` | running, configuring, extending and deploying an image | how images are built, reviewed or published → `MAINTAINING.md`; which tags the registry serves → the registry itself, the way `SUPPORTED.md` says |
| `MAINTAINING.md` | build, review and publish processes, and the gates that enforce them | the policy claim a gate protects → [SECURITY.md](SECURITY.md#what-the-pipeline-guarantees); what a deployer should choose → `DEPLOYING.md` |
| `manifests/SECURITY-REVIEW.md` | the PHP-side evidence register: pin-by-pin review records, CVE dispositions, and the decisions behind them | policy → `SECURITY.md`; the summary a consumer reads → `SUPPORTED.md` |
| `manifests/OS-CVE-STATUS.md` | the Debian-side evidence register: one row per OS CVE and answer, with the measurements keyed by suite, a disposition, evidence and a review date | the scanner that gates against it and how its verdicts work → `MAINTAINING.md`; the policy the register serves → `SECURITY.md` |

Document ownership is enforced by the generator and `tools/check-image-name.sh`;
move misplaced requirements together with their corresponding checks.
