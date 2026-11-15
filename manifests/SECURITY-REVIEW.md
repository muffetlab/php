# Security review matrix

Do not mark a CVE fixed solely because a source branch is named "security-backports".

For each PHP version and each relevant CVE, record:
- upstream advisory URL and affected version range
- upstream fixing commit (if any)
- backport repository commit containing the change
- exact files/hunks reviewed
- whether a version-specific patch was added
- PHPT or equivalent regression test and result
- build/test date and reviewer
- remaining known limitations

At minimum, explicitly assess CVE-2026-109618 and CVE-2026-109619 **for every
version in scope (5.6, 7.0, 7.1, 7.2, 7.3, 7.4, 8.0, 8.1)**, because backport
coverage does not transfer between minor versions, then check current PHP
advisories and OS-library advisories on the date of each release. The section
below records what upstream commit metadata says about those two CVEs. That is a
patch-present observation, **not** the per-version code review this file asks
for, and its three caveats state what it leaves unassessed.

## Backports patchset

Every series builds from [`shivammathur/php-src-backports`][backports], and the
reviewed unit is the **pinned commit** — not a patch stack kept here. This
section records what could be established about that patchset from outside the
build, and, just as importantly, what could not.

### Source of record and verification method

| Item | Value |
| --- | --- |
| Repository | `https://github.com/shivammathur/php-src-backports.git` |
| Licence | MIT |
| Archived / disabled | no / no |
| Upstream activity | no timestamp in this row: whether a branch head still equals its pin is the pin table below, dated there by its own verification, and `tools/check-pin-drift.sh` re-resolves head and tag peel on every CI run and warns on drift |
| Per-series branches | `PHP-<series>-security-backports` (note: `PHP-7.2-Security-backports` capitalises `S`), plus `PHP-5.6-security-backports-openssl11` |
| Tag style | one annotated tag per series, named after **official PHP's last release** for that series (5.6.40, 7.0.33, 7.1.33, 7.2.34, 7.3.33, 7.4.33, 8.0.30, 8.1.34) |
| Verification method | `git ls-remote --tags` and the GitHub commits/branches API. A manifest pins the **peeled** commit (`refs/tags/<tag>^{}`), which is the object the build checks out by SHA. `tools/check-pin-drift.sh` repeats this comparison on every CI run. |
| Verified on | 2026-10-30 |

Official `php/php-src` made its last release for all eight series: 5.6.40 and
7.0.33 (2019-01-10), 7.1.33 (2019-10-24), 7.2.34 (2020-10-01), 7.3.33
(2021-11-18), 7.4.33 (2022-11-03), 8.0.30 (2023-08-03), 8.1.34 (2025-12-18).
Nothing in that tree receives security fixes any more, which is why this kit
builds from the backports branch even for 8.0 and 8.1.

### Pin table

Each row states the pin, the branch it comes from, and whether that branch has
moved since. "Head == pin" was established on 2026-10-30 by resolving the branch
head and the tag's peeled commit and comparing them.

| Version | Tag | Pinned commit (peeled) | Branch | Head == pin | Head commit date |
| --- | --- | --- | --- | --- | --- |
| 5.6 | 5.6.40 | `31b896540a30a5d170797a1171b04dd872b88c5b` | `PHP-5.6-security-backports-openssl11` | yes | 2026-10-24 |
| 7.0 | 7.0.33 | `67a075e9b509891ae7b95e8ff48e73c16f63a19d` | `PHP-7.0-security-backports` | yes | 2026-10-24 |
| 7.1 | 7.1.33 | `b170cdd5baaf5c6b1efd4e78f9a668f10acebc28` | `PHP-7.1-security-backports` | yes | 2026-10-24 |
| 7.2 | 7.2.34 | `591bc8d42c53199ad7fe8298dce65701006a2abf` | `PHP-7.2-Security-backports` | yes | 2026-10-24 |
| 7.3 | 7.3.33 | `34456d7558a6a1741fab48074c0c42d89b4834ac` | `PHP-7.3-security-backports` | yes | 2026-10-24 |
| 7.4 | 7.4.33 | `9f3f6763497aa556d3fc56df7e66f44b8de49815` | `PHP-7.4-security-backports` | yes | 2026-10-19 |
| 8.0 | 8.0.30 | `190a0202b4601d3066088ba913c2f1bda921ad8c` | `PHP-8.0-security-backports` | yes | 2026-10-19 |
| 8.1 | 8.1.34 | `ae65ef4b9ede39ef9923643b741a89c23a2e1c7a` | `PHP-8.1-security-backports` | yes | 2026-10-19 |

### CVE-2026-109618 / CVE-2026-109619 in the pinned commits

All eight pins are the tip of their series branch, and the head commit of every
one is the bailout/state-corruption fix. Read from upstream commit metadata:

| Version | Head commit subject | Stated provenance | Files touched |
| --- | --- | --- | --- |
| 5.6 | Avoid state corruption via bailout on PHP 5.6 | "Apply the Sury Debian source patch for CVE-2026-109618 and CVE-2026-109619 to PHP 5.6" | 13 |
| 7.0 | … on PHP 7.0 | same, Sury Debian source patch | 16 |
| 7.1 | … on PHP 7.1 | same, Sury Debian source patch | 16 |
| 7.2 | … on PHP 7.2 | same, Sury Debian source patch | 16 |
| 7.3 | … on PHP 7.3 | same, Sury Debian source patch | 17 |
| 7.4 | Avoid state corruption via bailout | "Minimal mitigation for EOL version"; `Fix GHSA-w8hw-w9fx-j79w (CVE-2026-109618)`, `Fix GHSA-6wmf-4rv5-p3rp (CVE-2026-109619)`; cherry-picked from upstream `1d7dec178a094e6e75b229ce22754045f8c6070a` | 17 |
| 8.0 | as 7.4 | as 7.4 | 17 |
| 8.1 | as 7.4 | as 7.4 | 23 (under `Zend/` and `ext/opcache/`) |

Both co-author lines name upstream fix authors (Arnaud Le Blanc, Ilija Tovilo),
so this is the same work as the official fix, carried by two different routes:
5.6–7.3 take it from Debian/Sury's patch queue, 7.4+ cherry-pick php/php-src
directly. Three caveats that must survive into any release decision:

1. Upstream labels the 7.4+ variant a **minimal mitigation**, and the 5.6–7.3
   variant is a downstream (distro) patch rather than the php/php-src commit
   itself. Whether either is sufficient for a given deployment is a reviewer's
   call, not something this table can settle.
2. "Present in the commit" was established from commit messages, `GHSA`/CVE
   identifiers and file lists. No hunk here was read line by line.
3. No test targets these hunks specifically. Every series has since been built and
   put through the extension/FPM suite in CI (see *Machine-readable version status*
   below), which says the image works; it does not say the bailout fix works.
   Proving *that* needs a repro against the CVE, and none has been run here.

### What else the branch carries (inventory, not assessment)

`patches/<series>` on the fork's `main` branch lists the maintenance patch queue
per series, and the 5.6 branch's own history shows what actually landed. From
`PHP-5.6-security-backports-openssl11` (newest first, 2026-10-09 → 2026-10-24):
the CVE-2026-109618/109619 bailout, LDAP default host, **OpenSSL 4 compatibility
backport**, libxml2 2.13.2 fixes, `register`-keyword removal for modern
compilers, `--with-pear` install fix, `ITIMER_REAL` timeouts, pthreads detection
when cross-compiling, `ZEND_SIGNED_MULTIPLY_LONG` for AArch64, bug #79589
(`ssl3_read_n: unexpected eof`), **a minimal OpenSSL 3.0 patch**, and ICU 70.1
support.

That last pair matters for the route gate. The openssl11-named branch history
contains an OpenSSL 3.0 patch as well, so 5.6 is not *only* OpenSSL 1.1 capable.
This kit nevertheless keeps `OPENSSL_ROUTE=openssl11` for 5.6, because upstream
calls that patch "minimal" and the compile-level evidence below is not a
functional TLS verification. Moving 5.6 onto an OpenSSL 3 base is a reviewed
change to the route gate in `build.sh`, the Dockerfile and this file — with a
build and test run behind it.

### The two PHP 5.6 branches, and what their split says

`git ls-remote --heads` lists two branches: `PHP-5.6-security-backports` and
`PHP-5.6-security-backports-openssl11`. The openssl11 tip is what `5.6.40` peels
to and what this kit pins; the plain branch carries no tag.

Measured on both tips (2026-10-31), the split is not "OpenSSL 1.1 vs 3.x": both
carry the same six-line OpenSSL 3.0 compile patch, and neither contains a
`0x30000000L` guard or provider API reference. What `-openssl11` uniquely adds
is the out-of-tree OpenSSL 1.1 backport (opaque-struct accessors, config
handling) and OpenSSL 4 anticipation; the plain branch's newest thresholds are
1.0.x and its `SSL_library_init()` call is unguarded. The tips share no
ancestry, but every plain-only commit subject also appears on the pinned side.
Subject-level parity is strong signal, not a hunk-by-hunk proof. Switching to
the plain branch would buy nothing and lose the newer-library work, so the pin
stays.

### The 5.6 base is no longer maintained, and its security pool has moved

The 5.6 manifest pins `debian:bullseye-slim` because bullseye carries OpenSSL
1.1.1w, which the `openssl11` route needs. Bullseye's Debian LTS window closed
on 2026-08-31; its `bullseye-security` index is dated 2026-09-12 and carries no
`Valid-Until`, and the image holds `OpenSSL 1.1.1w` /
`libssl1.1 1.1.1w-0+deb11u8` with no candidate above it. For CVEs published
after the freeze, the register's
[frozen-archive chapter](OS-CVE-STATUS.md#bullseye-is-a-frozen-archive-and-that-is-the-whole-answer-for-56)
is the whole answer.

`deb.debian.org` still serves bullseye main but its `bullseye-security` paths
404; the matching `archive.debian.org` paths answer 200, so plain
`apt-get update` works without `Check-Valid-Until=false`. The redirect is
applied in both build and runtime stages, so pulls of `bullseye-security`
packages inside a 5.6 image work too. The committed Dockerfile now rebuilds 5.6
from scratch; the earlier 404 failure is history, not a current limitation.

### The 5.6 base decision: archive-backed freeze (2026-10-31)

Two options were on the table: (a) keep `openssl11` and point 5.6's apt sources
at `archive.debian.org`, or (b) move to a maintained OpenSSL 3 base. (b) was
declined on the probe below; (a) was chosen. Consequences:

- **5.6 is reproducible and explicitly frozen.** Its whole base sits at bullseye's
  last refresh (`OpenSSL 1.1.1w-0+deb11u8`) and will never move again; there is no
  maintained security source for these images. `SECURITY.md`'s fifth known limit
  states this.
- **The implementation is one OS-keyed rewrite**, not a route special case: both
  apt stages test `/etc/os-release` for Debian 11 and rewrite only the
  `debian-security` line, with a `grep` assertion that fails loudly if a base
  moves its sources. It is the `bullseye-archive-security` version-branch.
- **Measured after the change** (arm64, `./build.sh 5.6 cli`): build exit 0, zero
  404s, `VERIFY-BUILD`/`VERIFY-RUNTIME` OK, smoke passed, extensions 30 PASS / 0
  FAIL, image 745 MB -- the same as the previous baseline build.
- **Residual risk:** bullseye *main* still comes from `deb.debian.org`; if that
  pool retires, 5.6 stops building until the same rewrite covers it.

### 5.6 + OpenSSL 3 probe: conclusions (2026-10-31)

The pinned tree's `ext/openssl` was compiled against `libssl-dev 3.0.22` in
`debian:bookworm-slim` with the kit's flags. Both translation units compiled;
all 335 referenced OpenSSL symbols were exported by
`libssl.so.3`/`libcrypto.so.3`; the shared object linked with zero unresolved
OpenSSL symbols. The "minimal" backport therefore makes 5.6 build and resolve
against OpenSSL 3 -- but it does not provide OpenSSL 3's provider APIs, and key
inspection still uses deprecated engine-style getters.

What this does **not** establish, and what a route change would need:

1. functional TLS (handshakes, `crypto_method` negotiation, cipher suites, security
   level) was never exercised;
2. `./configure`'s own OpenSSL probes were not run on a bookworm base;
3. the runtime closure (`libssl1.1` -> `libssl3`, curl, zip, gd, libxml2) would
   need re-verification;
4. the `>= 0x40000000L` OpenSSL 4 branches remain untested;
5. the probe was local, arm64 and ad hoc, not CI.

Nothing changed for the probe: `manifests/5.6.env` still declares
`OPENSSL_ROUTE=openssl11` and the route gate is untouched.


### Limits of this record

- One image has been built and tested *locally*: 5.6 on the `openssl11` route,
  `cli` and `fpm`, on 2026-10-31. It was arm64-only, on a host that cannot pull
  the other series' base image, and what it measured is recorded in *The 5.6 base
  decision*.
- All eight series have since built and passed their tests in CI on both
  architectures (2026-11-01), which is what the status table rests on; its legs,
  and what that chain does and does not prove, are recorded there rather than
  twice.
- This file copies no registry state. Which tags exist, and the digest each
  resolves to, is the registry's own answer, and
  [SUPPORTED.md](../SUPPORTED.md#checking-what-the-registry-serves) says how to
  read what the namespace serves today.
- What base a series builds from is the manifest's copy, generated into
  `SUPPORTED.md`; the 2026-11-03 split is recorded in
  [MAINTAINING.md](../MAINTAINING.md#trialing-a-newer-debian-release). Which base
  a *served* tag was built from is read from that image's
  `dev.php-legacy.base-image` label, and `tools/resolve-base-digest.sh --check`
  reports a pin that has moved. Whether a version read from a trial image has
  become `published-image` evidence is the register's own *Image evidence* column,
  per suite group, and nothing in this file tracks it.
- No CVE other than the two named above has been assessed for any series. A
  release decision must re-check current PHP and OS-library advisories on the
  release date.
- `PATCHSET_APPROVED=1` in a manifest records the human decision to treat this
  pinned commit as the reviewed unit. It is not a claim of per-CVE coverage, and
  it does not survive a pin change: moving `PHP_SRC_COMMIT` means a new record
  here and a fresh approval.

[backports]: https://github.com/shivammathur/php-src-backports

## Bundled third-party components

The PHP source review above does not cover the other software these images ship.
Each of these has one executable copy that owns its versions, and this file's
job is to record what a reviewer looked at and what was accepted, not to hold a
second copy of a version number. Each entry therefore names the copy that owns
its numbers and the upstream fact those numbers were measured against.

- **PECL redis, memcached and apcu** — the per-series versions, and the PHP floor
  that forces each split, are `Dockerfile`'s PECL lookup table and the comment
  above it; [MAINTAINING.md](../MAINTAINING.md#per-version-extension-sets)
  documents the same set from the build side, and `SUPPORTED.md`'s `Extensions`
  column shows what each series promises. The floors are upstream declarations,
  read from each release's own `package.xml`, which is why they live beside the
  pins they constrain rather than in a changelog summary. What this file adds is
  the review consequence: a pin old enough to run on EOL PHP may itself carry
  unfixed issues, each of the three is accepted knowingly, and a release decision
  re-reads the three advisory pages. apcu links no external library (it uses PHP's
  own allocator) and its shared-memory store is per-process, which is why the
  suite checks it with a store/fetch roundtrip and no server.
- **Composer** — the policy pin and its two phar digests are held by `build.sh`
  and `tools/gen-supported.sh`, both workflows' validate jobs compare the copies,
  and `SUPPORTED.md` renders the resulting version per series. The 1.10 branch no
  longer receives feature work, so check its advisory history before relying on it
  in a build pipeline. The installer commit and both phar digests are pinned and
  CI-warned on upstream drift.
- **Vendored `docker-php-ext-*` scripts** — pinned docker-library/php commit,
  hash-verified in CI (see `docker-php-ext/README.md`).
- **libmcrypt (5.6–7.1 images)** — present because `mcrypt` is in the core
  baseline of every series that can still build it, so the runtime stage installs
  the library that extension links; the baseline, the availability guard and the
  package names are held by the `Dockerfile` and by the `ext-runtime-libs` row of
  MAINTAINING's version-branch table, which also carries the version each
  candidate suite ships. This file records only the judgement. It is the one
  component in the image whose upstream is not merely unpinned but inactive: 2.5.8
  (2007) is the last release, the library has no AEAD modes, and PHP deprecated
  the extension in 7.1 and removed it in 7.2, which is also why the PECL
  replacement cannot reach the older series. It is accepted knowingly for one
  purpose: a legacy application that calls `mcrypt_*` has no other source for it
  on 5.6. It is not a good way to encrypt anything new, where ext openssl or ext
  sodium are baseline and no dead library is involved. On 5.6 the base is a
  freeze, so this library gets no security updates either. Removing `mcrypt` from
  the guard step's baseline takes the extension and the library out of the attack
  surface in one change; that is a reviewed `Dockerfile` edit, and worth recording
  here as a decision if it is made.
- **Base image packages** — `BUILD_PACKAGES`, `RUNTIME_PACKAGES` and the
  Dockerfile's per-route defaults. Pinning only the PHP commit while leaving
  `libssl3`/`libmemcached`/`libzip` floating re-opens the exact supply-chain hole
  this kit exists to close. The effective build list is recorded in the image at
  `/opt/php/BUILD-DEPS`; review it against the OS advisories for the chosen base
  on the release date.

## Machine-readable version status

`tools/gen-supported.sh` parses the table below (rows of the form
`| <version> | <status> |`, first match wins) to generate `SUPPORTED.md`. Keep
one row per supported version and update it as reviews complete; CI fails if
`SUPPORTED.md` drifts from this table plus the manifests.

All eight rows are at `tested-in-CI`. The backports evidence above places the
reviewed fixes inside each pinned commit, and on 2026-11-01 the CI chain built
all eight series — `cli` and `fpm`, `amd64` and `arm64`, 32 legs — with
`tests/smoke.sh` for each variant, `tests/extensions.sh` and `tests/composer.sh`
passing on the image every leg built. That is precisely the condition this file
set for the value: a real build with the extension and FPM assertions passing.

What `tested-in-CI` does **not** claim, and what no row should be read as:

- **It is not a published tag.** `SUPPORTED.md`'s generated "How to read a row"
  says the consumer-facing version of this: a green row is evidence the image
  passes the project's CI build and runtime checks, which is neither an approval
  nor a claim that a tag exists.
- **The CVE hunks are still untested.** The suite exercises the extension surface
  and the FPM pool, not the bailout fix; the second and third caveats under the
  two-CVE table in *Backports patchset* own that limit.
- **It is not an approval.** Moving a row to an `approved-*` status still needs a
  named reviewer and a date on this file.

5.6's row additionally has a 2026-10-31 local arm64 build behind it, which on
its own was never enough to claim `tested-in-CI`: a local run is not a CI run,
and this vocabulary has no value meaning "built and tested locally, pending CI".
What that run measured belongs to *The 5.6 base decision*.

| Version | Status |
| --- | --- |
| 5.6 | tested-in-CI |
| 7.0 | tested-in-CI |
| 7.1 | tested-in-CI |
| 7.2 | tested-in-CI |
| 7.3 | tested-in-CI |
| 7.4 | tested-in-CI |
| 8.0 | tested-in-CI |
| 8.1 | tested-in-CI |
