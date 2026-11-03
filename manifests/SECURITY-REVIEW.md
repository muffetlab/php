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
version in scope (5.6, 7.0, 7.1, 7.2, 7.3, 7.4, 8.0, 8.1)** — backport coverage
does not transfer between minor versions — then check current PHP advisories
and OS-library advisories on the date of each release. The section below records
what was found for those two CVEs in the pinned commits; it is a patch-present
observation from upstream commit metadata, **not** the per-version code review
this file asks for, and it does not replace it.

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
| Last push observed | 2026-10-24T14:06:58Z |
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
moved since. "Head == pin" was established on 2026-10-30 by resolving the
branch head and the tag's peeled commit and comparing them.

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
3. No test targets these hunks specifically. Every series has since been built
   and put through the extension/FPM suite in CI (see *Machine-readable version
   status* below), which says the image works; it does not say the bailout
   fix works. Proving *that* needs a repro against the CVE, and none has been
   run here.

### What else the branch carries (inventory, not assessment)

`patches/<series>` on the fork's `main` branch lists the maintenance patch queue
per series, and the 5.6 branch's own history shows what actually landed. From
`PHP-5.6-security-backports-openssl11` (newest first, 2026-10-09 → 2026-10-24):
the CVE-2026-109618/109619 bailout, LDAP default host, **OpenSSL 4
compatibility backport**, libxml2 2.13.2 fixes, `register`-keyword removal for
modern compilers, `--with-pear` install fix, `ITIMER_REAL` timeouts, pthreads
detection when cross-compiling, `ZEND_SIGNED_MULTIPLY_LONG` for AArch64,
bug #79589 (`ssl3_read_n: unexpected eof`), **a minimal OpenSSL 3.0 patch**, and
ICU 70.1 support.

That last pair matters for the route gate. The openssl11-named branch history
contains an OpenSSL 3.0 patch as well, so 5.6 is not *only* OpenSSL 1.1 capable.
This kit nevertheless keeps `OPENSSL_ROUTE=openssl11` for 5.6, because upstream
calls that patch "minimal" and the compile-level evidence below is not a
functional TLS verification. Moving 5.6 onto an OpenSSL 3 base is a reviewed
change to the route gate in `build.sh`, the Dockerfile and this file — with a
build and test run behind it.

### The two PHP 5.6 branches, and what their split actually says

`git ls-remote --heads` on 2026-10-31 lists **two** branches for this series:
`PHP-5.6-security-backports` (tip `c55d0846958d4baf2c9b7a40c7543f7ccab51383`) and
`PHP-5.6-security-backports-openssl11` (tip `31b896540a30a5d170797a1171b04dd872b88c5b`,
which is what the `5.6.40` tag peels to, and what this kit pins). The plain
branch's tip carries **no tag**: the released artifact for 5.6 is the openssl11
branch. Established from a depth-600 blobless fetch of both tips, not from the
web UI.

The naive reading — "there is an openssl11 branch and no openssl3 branch, so
OpenSSL 3 is not meant for 5.6" — does not survive the commit graph:

- Both branches contain the *same* OpenSSL 3 work: Ondřej Surý's
  "Add minimal OpenSSL 3.0 patch", 2022-04-21, `ext/openssl/openssl.c`, 6 lines
  added (`48f73819` on the plain branch, `772b292c` on the pinned one). The split
  is not "1.1 branch vs 3.x branch".
- What the `-openssl11` branch uniquely adds is out-of-tree compatibility for a
  library PHP 5.6 never supported upstream: "backport needed changes for
  OpenSSL 1.1", "implement basic config support for OpenSSL 1.1.x", "use the new
  API for opaque symbol in OpenSSL 1.1.x", plus a later
  "PHP 5.6: backport OpenSSL 4 compatibility" (`2f0da727`, 2026-05-02) that the
  plain branch does not have. In other words the branch exists because *1.1* was
  the newer library requiring extra work, and it is now the branch carrying the
  most forward-looking OpenSSL support of the two.
- The divergence is not a coverage gap. The tips share no ancestry
  (`merge-base 4f0e59ad85…`; 92 commits reach the plain branch only, 156 the
  pinned one — the last merge from plain into openssl11 is `5aabe68e`, 2021-02-03,
  after which fixes were cherry-picked). Comparing commit *subjects*: all 81
  distinct subjects on plain-only commits already appear in the pinned branch,
  and the pinned branch has only 10 subjects the plain one lacks — the OpenSSL
  items above, a merge trail, `Remove the forked test…`, and
  "ext/ldap: Allow default host from ldap.conf to work." Both tips are dated
  2026-10-19 and both end at "Avoid state corruption via bailout on PHP 5.6".
  Subject-level matching is a strong signal, not a hunk-by-hunk proof; a release
  decision that depends on parity should diff the two trees.

So the case against running 5.6 on OpenSSL 3 does not rest on branch names. It
rests on what was measured in the probe: the OpenSSL 3 work in *any* 5.6 branch
is a 6-line patch, `PHP_OPENSSL_API_VERSION` is defined nowhere so the provider
path is never compiled, 73 + 14 call sites sit on deprecated APIs, and the
protocol selection still goes through `TLSv1_*_method()` because every 3.x
number is below the pin's `0x40000000L` guards. That is enough to decline the
work on cost/benefit grounds; it is not evidence that such an image would fail
to build.

**The other reading is also wrong, and inverted.** A branch is PHP *source*; the
operating system comes from `BASE_IMAGE` and does not change when the source pin
does. Neither 5.6 branch can put an image on a newer or better-maintained OS.
Asked the opposite way — which branch is tied to the older library? — the answer
is the plain one. Counted over `ext/openssl/` at both tips on 2026-10-31
(`git grep -c` per symbol, summed; `git diff --stat` between the tips for that
directory is 460 insertions / 260 deletions over 8 files):

| Marker in `ext/openssl` | `PHP-5.6-security-backports` | `-openssl11` (pinned) |
| --- | --- | --- |
| `OPENSSL_VERSION_NUMBER` comparisons | 42 | 57 |
| guards at `0x10100000L` (OpenSSL 1.1+) | **0** | 6 |
| guards at `0x40000000L` (OpenSSL 4 anticipation) | **0** | 9 |
| guards at `0x30000000L` (OpenSSL 3-specific) | 0 | **0** |
| `RSA_get0_key` (1.1 opaque-struct accessor) | 0 | 1 |
| `TLS_client_method` (1.1.0+ generic method) | 0 | 3 |
| `OPENSSL_PROVIDER` / `EVP_CIPHER_fetch` (3.x provider API) | 0 | 0 |

The highest version thresholds the plain branch tests for are in the 1.0.x range
(`0x10000000L`, `0x10001001L`), and its `SSL_library_init()` call at
`ext/openssl/openssl.c:1148` carries no version guard at all. The plain branch is
therefore the one written for an OpenSSL 1.0-era system — in Debian terms,
stretch/buster, both long since retired — while the pinned branch is the only one
of the two that has ever been made to work against a newer library. Switching
this kit's 5.6 pin to the plain branch would buy nothing and lose the 1.1 and 4
compatibility work.

The row that matters for the route decision is the zero that both branches share:
neither contains a single `0x30000000L` guard or provider API reference. "OpenSSL
3 support" for PHP 5.6, in any branch, means *the 6-line patch that lets it
compile* — there is no 3.x-aware code path in the extension at all.

### The 5.6 base is no longer maintained, and its security pool has moved

The 5.6 manifest pins `debian:bullseye-slim@sha256:e5b6442d…` because bullseye
is the Debian release carrying OpenSSL 1.1.1w, which the `openssl11` route
requires. What that choice assumed did not survive measurement. All of it was
measured on 2026-10-31 against exactly that pinned image (`docker inspect`
reports `sha256:e5b6442dd2e9684cf5e87d8338b5968f3b348636fc0be6d7850a381e3731a2bd`,
the digest in the manifest).

- **Bullseye is out of support.** The Debian LTS page gives its window as
  "2024-08-15 - 2026-08-31", which closed two months ago. The `bullseye-security`
  `Release` file on both `deb.debian.org` and `archive.debian.org` carries the
  same `Date: Sat, 12 Sep 2026 09:27:08 UTC` and no `Valid-Until` header: the
  index stopped advancing, so no
  further 1.1.1w fix is expected. Inside the published image, `openssl version`
  says `OpenSSL 1.1.1w 11 Sep 2023`, `libssl1.1` is `1.1.1w-0+deb11u8`, and
  `apt-cache policy` reports that installed version as "Candidate" — there is
  nothing newer to move to.
- **The committed Dockerfile could not rebuild 5.6, and now can.** `apt-get update`
  with the base's own sources succeeds (exit 0), and `deb.debian.org/debian`
  (bullseye main) still serves its pool — but every `bullseye-security` file
  now 404s. Measured: `libc-dev-bin` and `libc6-dev` `2.31-13+deb11u14`,
  `linux-libc-dev` `5.10.262-1`, `libicu67` `67.1-7+deb11u1` and
  `libssl-dev` `1.1.1w-0+deb11u8` all return `404 Not Found` from
  `http://deb.debian.org/debian-security`, `apt-get` exits 100, while the
  corresponding archive paths answer 200. That was re-measured on 2026-10-31 for
  **both** architectures CI builds for, not just the arm64 host:
  `libssl-dev_1.1.1w-0+deb11u8_arm64.deb` and `…_amd64.deb` are each 404 on
  `deb.debian.org/debian-security` and 200 on `archive.debian.org/debian-security`.
  The first 5.6 baseline build completed only because an out-of-tree copy of the
  Dockerfile inserted a rewrite of that one suite before each `apt-get update`.
  The repository now does the same thing itself (see the decision below), so this
  bullet is a record of what was broken, not of what is broken.
- **`Acquire::Check-Valid-Until=false` is not needed**, correcting a note
  carried earlier in this work. With sources pointed at
  `archive.debian.org/debian` and `archive.debian.org/debian-security`, plain
  `apt-get update` inside the published 5.6 image exits 0 both with and without
  the flag — the bullseye `Release` files carry no `Valid-Until` header — and
  `apt-get install --download-only libssl-dev` then succeeds from the archive.
- **Users were affected the same way as the build**: `apt-get install` of any
  `bullseye-security` package inside a 5.6 image failed with that 404. Because
  the redirect is applied in the runtime stage as well, it is baked into the
  image rather than being a build-time-only trick. Measured in the image built
  after the change: `/etc/apt/sources.list` reads
  `deb http://archive.debian.org/debian-security bullseye-security main`,
  `apt-get update` exits 0 in a fresh container, and
  `apt-get install --download-only libssl-dev` fetches `1.1.1w-0+deb11u8` from
  the archive. (One trap, measured: `--download-only` in a *fresh* container
  fails until `apt-get update` has run, because the image deliberately ships no
  `/var/lib/apt/lists`.)

### The 5.6 base decision: archive-backed freeze (2026-10-31)

Two options were on the table — (a) keep `openssl11` and point 5.6's apt sources
at `archive.debian.org`, or (b) move 5.6 to a maintained OpenSSL 3 base. (b) was
declined on the evidence in the probe section above, and (a) was chosen by the
maintainer on 2026-10-31. What that means, stated plainly:

- **5.6 is now reproducible and explicitly frozen.** `libssl1.1`, `libc6`,
  `libicu67`, `libxml2`, `libcurl` and the rest of that base sit at whatever
  bullseye's last security refresh shipped — OpenSSL `1.1.1w-0+deb11u8` — and
  nothing behind them will ever move again. There is no maintained security
  source for the 5.6 images. This is the single largest caveat on the release
  surface for that version and README/DISCLAIMER say so.
- **The implementation is one OS-keyed rewrite, not a route special case.** Both
  apt stages test `/etc/os-release` for `ID=debian` and `VERSION_ID=11` and
  rewrite only the `debian-security` line, guarded by a `grep` assertion so a
  base that moves its sources elsewhere fails loudly. Verified by construction
  and by test: the guard reports HIT on `debian:bullseye-slim` and SKIP on
  `debian:bookworm-slim`, so the `openssl3` route is byte-for-byte unaffected.
  It is catalogued as the `bullseye-archive-security` version-branch.
- **Measured after the change** (arm64, `./build.sh 5.6 cli` from the committed
  Dockerfile, nothing patched): build exit 0, `Get:1 http://archive.debian.org
  /debian-security bullseye-security InRelease`, zero 404s in the whole log,
  `VERIFY-BUILD OK`, `VERIFY-RUNTIME OK`, `tests/smoke.sh` passed,
  `tests/extensions.sh` 30 PASS / 0 FAIL with 5 INFO (AES-256-GCM correctly
  skipped: its arguments exist only from 7.1), image
  745 MB — the same figure as the out-of-tree baseline build, which is what
  makes the change safe to call behaviour-preserving.
- **Residual risk this does not close.** Bullseye *main* is still served from
  `deb.debian.org` today; if Debian retires that pool too, 5.6 stops building
  again until the same sed covers `deb.debian.org/debian` as well. And the amd64
  path had not been exercised end to end when this was written: the archive paths
  for amd64 are measured 200, and the CI run of 2026-10-31 has since built and
  tested amd64 (cli and fpm) from this same pin. CI now builds and tests both
  `linux/amd64` and `linux/arm64` natively, and publishes them as one manifest
  list per tag.

### 5.6 + OpenSSL 3 probe — evidence only, no route change (2026-10-31)

Option (b) above asks whether the *pinned 5.6 source* could live on a maintained
OpenSSL 3 base. Two facts made that worth measuring rather than dismissing: the
pin's own history contains an OpenSSL 3.0 backport, and its `xp_ssl.c` carries
`OPENSSL_VERSION_NUMBER >= 0x40000000L` branches — which every 3.x fails,
because a 3.x version number is below `0x40000000L`.

**Method.** Not a full rebuild: that would hit the mirror problem above, and a
fresh `./configure` on bookworm would silently change dozens of unrelated
probes. Instead the already-built, pinned tree (commit `31b896540a30a5d170797a1171b04dd872b88c5b`,
extracted from the 5.6 build stage) was compiled in `debian:bookworm-slim` —
`gcc 12`, `libssl-dev 3.0.22-1~deb12u2`, runtime `OpenSSL 3.0.22 25 Aug 2026` —
using the kit's own flags (`-fpic -fstack-protector-strong`), and the two
translation units of `ext/openssl` were then asked the two questions that decide
whether such a base is even possible: does every symbol resolve, and what does
the compiler say about the API surface. Reproduce with:

```sh
gcc -c -O0 -w -fpic -fstack-protector-strong -I. -Imain -ITSRM -IZend -Iext \
    -Iext/standard -Iext/openssl -DZEND_ENABLE_STATIC_TSRMLS_CACHE=1 \
    ext/openssl/openssl.c -o /tmp/openssl.o         # and xp_ssl.c likewise
nm -u /tmp/openssl.o /tmp/xp_ssl.o | awk '{print $NF}' | sed 's/@.*//' \
  | grep -E '^(SSL|TLS|DTLS|EVP|X509|d2i_|i2d_|RSA|DSA|DH|EC|ECDSA|ECDH|ASN1|BIO|CRYPTO|OPENSSL|ERR|RAND|PEM|PKCS|ENGINE|HMAC|BN|OBJ|DES|RC4|AES|CAMELLIA|SEED|MD5|SHA|RIPEMD|COMP|SRP|CMS|CONF|UI|i2o|o2i)' \
  | sort -u > /tmp/want.txt
for lib in /usr/lib/*/libssl.so.3 /usr/lib/*/libcrypto.so.3; do
  # one library per nm call: a multi-file nm prints filename headers that would
  # otherwise be read as symbol names
  nm -D --defined-only "$lib" | awk '{print $NF}' | sed 's/@.*//'
done | sort -u > /tmp/have.txt
comm -23 /tmp/want.txt /tmp/have.txt               # referenced but not exported
gcc -shared -o /tmp/probe_ext.so /tmp/openssl.o /tmp/xp_ssl.o -lssl -lcrypto
ldd -r /tmp/probe_ext.so 2>&1 | grep "undefined symbol"
```

The `sed 's/@.*//'` is not decoration: a shared library's dynamic table names
symbols as `SSL_connect@@OPENSSL_3.0.0`, while a freshly compiled object
references them unversioned, so without it every OpenSSL symbol appears missing.
(On binutils that spells the version `name at OPENSSL_3.0.0` rather than
`name@@OPENSSL_3.0.0`, the name is column 3, not the last field — the probe
script handles both.) Two earlier attempts at this pass produced exactly that
false result, and the check now refuses to report a difference unless `SSL_new`,
`SSL_CTX_new`, `X509_new` and `EVP_CIPHER_CTX_new` are demonstrably present in
the export set.

**Results.**

| Check | Measured |
| --- | --- |
| Compile of `openssl.c` + `xp_ssl.c` against 3.0.22 | both succeed, zero errors |
| Distinct OpenSSL API symbols the objects reference | 335 (six of them `TLSv1_*_client_method` / `TLSv1_*_server_method`) |
| Symbols exported by `libssl.so.3` + `libcrypto.so.3` | 5882 |
| Referenced but **not** exported | **0** |
| Link to a shared object, then `ldd -r` | link exit 0; **0** unresolved OpenSSL symbols (only `php_*`/`zend_*`, which the PHP binary supplies) |
| Deprecated-API uses, measured with `-Wall` | 73 in `openssl.c`, 14 in `xp_ssl.c` — `EVP_PKEY_get0_RSA`/`EVP_PKEY_assign`/`DSA_get0_key` etc. ("Since OpenSSL 3.0"), and the six `TLSv1_*_method` calls ("Since OpenSSL 1.1.0") |
| `SSLv23_client_method`, `SSL_library_init`, `SSL_load_error_strings` | not exported — and not referenced either, so they are 1.0-era names this tree does not use |
| `SSLv3_client_method` | not exported; the `!defined(OPENSSL_NO_SSL3)` branches in `xp_ssl.c:951`/`:1000` are dead on this base |
| `PHP_OPENSSL_API_VERSION` (`openssl.c:58`) | defined nowhere in the tree, so `#if PHP_OPENSSL_API_VERSION >= 0x30000` is always false and `core_names.h` / `param_build.h` are never included |

**What that means.** The failure mode that would rule option (b) out — an
extension that cannot link, or a PHP binary that dies at startup with an
undefined OpenSSL symbol — is not present in this pin. Equally, the last row is
the concrete shape of what upstream means by "minimal": the backport makes 5.6
build and resolve against OpenSSL 3, it does not give it OpenSSL 3's provider
APIs, so key inspection keeps going through the deprecated engine-style getters
that OpenSSL 3 exists to retire.

**What it does not mean, and what a route change would still need.**

1. No functional TLS was tested: no handshake, no `stream_socket_client`, no
   `crypto_method` negotiation, no cipher-suite or security-level behaviour.
   The version-specific methods resolve, but whether 5.6's
   `TLSv1_*_method()` + `SSL_OP_NO_*` combinations produce the protocol ranges
   users expect under OpenSSL 3's default security level is unmeasured.
2. This is `ext/openssl` only, compiled against 3.0 headers without running
   `./configure` on a bookworm base; configure's own OpenSSL probes would meet
   3.x for the first time in a real build.
3. A base change moves the whole runtime closure (`libssl1.1`→`libssl3` and
   friends), so curl, zip, gd and libxml2 would each need re-verification, and
   the `RUNTIME_PACKAGES`/route lists in the Dockerfile would need re-measuring
   the way the current names were.
4. The `>= 0x40000000L` branches are OpenSSL **4** anticipation and were never
   reached here, so they remain untested code.
5. Local, arm64, ad hoc. Not CI, and not amd64.

Nothing was changed for this probe: `manifests/5.6.env` still declares
`OPENSSL_ROUTE=openssl11`, `build.sh`'s route gate is untouched, and the images
described by this kit are unaffected. It is evidence for the base decision in
the section above, recorded so that whoever makes that decision does not have to
re-derive it.


### Limits of this record

- One image has been built and tested *locally*: 5.6 on the `openssl11` route,
  `cli` and `fpm`, on 2026-10-31, with `verify-build` and `verify-runtime`
  passing and the extension/FPM tests green — and, after the
  `bullseye-archive-security` redirect was committed, `cli` built again from the
  repository's own Dockerfile with the same 745 MB result and the same green
  tests. That was arm64-only evidence on a host that cannot pull the other
  series' base image.
- As of 2026-11-01 **all eight series have built and passed their tests in CI**,
  on both architectures: the sequential `build-and-verify` chain — 8 series ×
  `cli`/`fpm` × `amd64`/`arm64` = 32 legs, every one successful, each leg
  running `tests/smoke.sh` for its own
  variant, `tests/extensions.sh` and `tests/composer.sh` against the image it
  built, after the `validate` gate. That chain runs in test mode, so all the
  `merge` jobs were skipped and **nothing was published to a registry**: a green
  CI row is evidence the image builds and behaves, not evidence that a tag
  exists to pull.
- The **7.4** series was published on 2026-11-01, as two multi-arch manifest
  lists:

  | Tag | Digest (both `7.4.33-*` and `7.4-*` resolve to it) |
  | --- | --- |
  | `ghcr.io/muffetlab/php:7.4-cli` / `:7.4.33-cli` | `sha256:fe4f7774a85a74e3dc843c15a73885dccefca326bed9bb91bc2e1e175f8472fd` |
  | `ghcr.io/muffetlab/php:7.4-fpm` / `:7.4.33-fpm` | `sha256:a048017bcc95d4de0450ccba8673d666330c7dfab6247c2cc3f2fb4da2b2ea61` |

  Each list carries `linux/amd64` and `linux/arm64` plus one attestation manifest
  per platform, and each attestation manifest holds an SPDX SBOM and a SLSA
  provenance v1 statement — read back off the registry, not inferred from the
  workflow. The published `7.4-cli` list was then pulled anonymously on 2026-11-01
  and run on `linux/arm64`: `php -r 'echo PHP_VERSION, PHP_SAPI'` reported
  `7.4.33cli`, and the image's own `/usr/local/bin/verify-runtime` returned
  `VERIFY-RUNTIME OK` (all promised modules load, no unresolved libraries, runtime
  OpenSSL 3.0.22 on the `openssl3` route) against the digest in the table above.
  Public visibility is recorded the same way, and **not** as something the run
  achieved: its `package-visibility` job passed while printing
  `GHCR_PAT secret not set - skipping visibility change.` — that secret is absent
  from this repository, so the package became public by the manual route. What an
  unauthenticated reader gets today is an anonymous `GET /v2/muffetlab/php/tags/list`
  answering HTTP 200 with exactly `7.4.33-cli`, `7.4-cli`, `7.4.33-fpm`, `7.4-fpm`
  and nothing else. No `latest-<variant>` was written: this run was a manual
  dispatch, and at that commit only an exact `vX.Y.Z` tag run could move `latest`.
  That name has since left the pipeline — on 2026-11-02 the publish step was
  reduced to `<full>-<variant>` and `<minor>-<variant>`, so no run writes a latest
  tag at all now (MAINTAINING.md, "Publishing images"). Deploy the digest,
  not the floating tag, if you need this record to bind to what you actually run.
- 5.6's base digest is pinned, and the local image ID matches that digest. The
  other seven manifests pin the same `debian:bookworm-slim` index digest
  (`sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3`,
  resolved from the registry on 2026-10-31), and that closure is now exercised:
  all seven built from it on both architectures in the CI run above.
  **On 2026-11-03 this changed for three of the seven: 7.4, 8.0 and 8.1 moved to
  `debian:trixie-slim@sha256:f6b08b09…` by the base split** (the trials that
  measured it are in MAINTAINING.md; the published images named above are still
  the bookworm builds, so this paragraph's deploy digests stay valid for what is
  on the registry today — the next release build of those three series publishes
  from trixie). 7.0–7.3 keep the bookworm digest; they do not compile on trixie.
  `tools/resolve-base-digest.sh --check` reports it if a tag moves.

### The remaining six series' releases (verified against the registry 2026-11-03)

These facts were verified directly on the date in the heading — an
anonymous registry token, `GET /v2/muffetlab/php/tags/list` (28 tags, 5.6 the
only one missing), and `GET /v2/muffetlab/php/manifests/<tag>` per variant
above — not copied from run logs. Series-to-run mapping comes from each run's
series-gated `merge` job names.

**Run numbers predate a repository reset.** The release-run numbers and the CI
chain that earned the `tested-in-CI` rows ran on the repository instance that
existed before the reset; reconstructed from the public run list on 2026-11-04.
If that instance is re-created, the numbers and the logs behind them stop
resolving. What stays independently verifiable here is the registry side: every
digest in this file can be re-read today from `ghcr.io/muffetlab/php` (an
anonymous token plus `GET /v2/muffetlab/php/manifests/<tag>` returns the list
digest in `Docker-Content-Digest`), and the `tested-in-CI` statuses are
re-established empirically by dispatching `build-and-verify` against the
re-created instance — when that run lands, add its date here.

| Series | Release run (number) | Run date (UTC) | Note |
| --- | --- | --- | --- |
| 8.0 | 41308384375 | 2026-11-01 | |
| 8.1 | 41308677246 | 2026-11-01 | |
| 7.3 | 41379484915 | 2026-11-02 | |
| 7.2 | 41381808799 | 2026-11-02 | its only failing job is `package-visibility`, as with 7.4 above; all four builds and both `merge` jobs passed, and the digests below were read from the registry |
| 7.1 | 41388688262 | 2026-11-02 | |
| 7.0 | 41396869463 | 2026-11-02 | |

| Tag | Digest (both `<full>-*` and `<minor>-*` resolve to it) |
| --- | --- |
| `ghcr.io/muffetlab/php:7.0-cli` / `:7.0.33-cli` | `sha256:e0803ef8dafcb942a1c2ccdec3f74e185ea7775f56ba2084104b36a2aedd4180` |
| `ghcr.io/muffetlab/php:7.0-fpm` / `:7.0.33-fpm` | `sha256:d258bc3b271145ed7d4cc568f800effb27f05016b1c3c42cd06b616d1da68dee` |
| `ghcr.io/muffetlab/php:7.1-cli` / `:7.1.33-cli` | `sha256:9c5b838338a3f33e588b9d62a0abde268bee7dc198f30f4ccbc28c6628833440` |
| `ghcr.io/muffetlab/php:7.1-fpm` / `:7.1.33-fpm` | `sha256:b7ed1e71f1bb8f24d6a05cce22f992adf7bba0b74972a3c86ceb1cf063594f0e` |
| `ghcr.io/muffetlab/php:7.2-cli` / `:7.2.34-cli` | `sha256:a1865f96a8355ba01a0248c4cea12b9437c41e12f3e08d52e0d05cde1146ea31` |
| `ghcr.io/muffetlab/php:7.2-fpm` / `:7.2.34-fpm` | `sha256:cc57e47f79691a5b3d9f380637a3fc6a77159fd3f9573eb9916ef68e9b48d687` |
| `ghcr.io/muffetlab/php:7.3-cli` / `:7.3.33-cli` | `sha256:024779fa3a14df6c9ca93f790bfd5eafa13a63e4cb5fcafc69a99fa4bab021b8` |
| `ghcr.io/muffetlab/php:7.3-fpm` / `:7.3.33-fpm` | `sha256:53473a98763cdc84de6a789aa6be910cf8913673ddef6138c918fc0c3ad12b82` |
| `ghcr.io/muffetlab/php:8.0-cli` / `:8.0.30-cli` | `sha256:9bf17071e6e1e4802f0906e57fa7dc1445c672ecbd4565e879b95fe6093f9a45` |
| `ghcr.io/muffetlab/php:8.0-fpm` / `:8.0.30-fpm` | `sha256:867fc65dab7add2220b99b9c614e274c17e9ae19be18ad22399d8baefaff8b0b` |
| `ghcr.io/muffetlab/php:8.1-cli` / `:8.1.34-cli` | `sha256:5d0f628b4205839f6b664c23f66712e7ba7eccf5f7d1042f031d38b46b9aa36f` |
| `ghcr.io/muffetlab/php:8.1-fpm` / `:8.1.34-fpm` | `sha256:011d26068187d4501e7cd65094c01259de0cdf9228338079b4e3a5ab5948ee54` |

5.6 alone has no tags and no release run as of the date in this heading. These
rows, like the 7.4 record above, name the **publish** digest; they do not claim
an in-image `verify-runtime` pass for these six series until it is that series'
own record (the registry date is the only thing this section vouches for).
- No CVE other than the two named above has been assessed for any series. A
  release decision must re-check current PHP and OS-library advisories on the
  release date.
- `PATCHSET_APPROVED=1` in a manifest records the human decision to treat this
  pinned commit as the reviewed unit. It is not a claim of per-CVE coverage, and
  it does not survive a pin change: moving `PHP_SRC_COMMIT` means a new record
  here and a fresh approval.

[backports]: https://github.com/shivammathur/php-src-backports


Status should be one of:
- `unreviewed`
- `patch-present-not-tested`
- `tested-in-CI`
- `approved-for-staging`
- `approved-for-production`

Only the last status should permit production release under your release process.

## Bundled third-party components

The PHP source review above does not cover the other software these images
ship. Each of these is pinned in the Dockerfile and must be reviewed as part of
the same release decision — record the pin, the upstream advisory page checked,
the review date and the reviewer:

- **PECL redis / memcached** — pinned per PHP series (redis 4.3.0 on 5.6, 5.3.7
  on 7.0/7.1, 6.0.2 on 7.2/7.3, 6.1.0 from 7.4; memcached 2.2.0 on 5.6 and
  3.3.0 on every later series). The split is forced by each release's declared
  PHP floor, not preference: redis 6.1.0 requires PHP >= 7.4.0 and 6.0.2
  requires >= 7.2.0, and `pecl install` refuses a series below the floor. Old
  pins on EOL PHP may themselves carry unfixed issues; note any that you accept
  knowingly.
- **PECL apcu** — 4.0.11 on 5.6 (last of the 4.0.x line, floor 5.3.0) and
  5.1.28 on 7.0+ (floor 7.0.0-dev, read from its package.xml on 2026-11-03).
  Joins the kit baseline with this change, so it ships on every series like
  redis/memcached do. Links no external library (uses PHP's own memory
  allocator); the shared-memory store is per-process, which is why the test
  suite exercises a store/fetch roundtrip without a server. Same caveat as the
  pins above: 4.0.11 on EOL PHP 5.6 is accepted knowingly, note any unfixed
  issues you accept.
- **Composer** — 1.10.28 for 5.6/7.0/7.1, 2.11.0 for 7.2+. The 1.10 branch is
  no longer receiving feature work, so check its advisory history before
  relying on it in a build pipeline. Installer commit and both phar digests are
  pinned and CI-warned on upstream drift.
- **Vendored `docker-php-ext-*` scripts** — pinned docker-library/php commit,
  hash-verified in CI (see `docker-php-ext/README.md`).
- **libmcrypt (PHP 5.6–7.1 images)** — pulled in because `mcrypt` is part of the
  core baseline on the series that can still build it (the Dockerfile guard step
  appends it for 5.6–7.1; it used to be requested by `manifests/5.6.env` before
  it joined the baseline), so `--with-mcrypt` compiles the in-core
  `ext/mcrypt` and the runtime stage installs `libmcrypt4`. This is the one
  component in the image whose upstream is not merely unpinned but inactive:
  2.5.8 (2007) is the last release, the library has no AEAD modes, and PHP itself
  deprecated the extension in 7.1 and removed it in 7.2 — which is also why it
  cannot reach the other series (the guard's availability table refuses it, and
  the PECL replacement floors at PHP 7.2.0).
  It is accepted knowingly, for one purpose: a legacy application that calls
  `mcrypt_*` has no other source for it on 5.6. Version is whatever the pinned
  base ships (Debian names the dev package `libmcrypt-dev`; measured
  2026-10-31: bullseye 2.5.8-3.4, bookworm 2.5.8-7, trixie 2.5.8-8), and because
  the base is a freeze on bullseye, it gets no security updates either. Removing
  `mcrypt` from the guard step's 5.6–7.1 core baseline in the Dockerfile removes
  both the extension and the library from the attack surface — a reviewed
  Dockerfile change now that it is baseline; record it as a review decision if
  you make it.
- **Base image packages** — `BUILD_PACKAGES`, `RUNTIME_PACKAGES` and the
  Dockerfile's per-route defaults. Pinning only the PHP commit while leaving
  `libssl3`/`libmemcached`/`libzip` floating re-opens the exact supply-chain
  hole this kit exists to close. The effective build list is recorded in the
  image at `/opt/php/BUILD-DEPS`; review it against the OS advisories for the
  chosen base on the release date.

## Machine-readable version status

`tools/gen-supported.sh` parses the table below (rows of the form
`| <version> | <status> |`, first match wins) to generate `SUPPORTED.md`.
Keep one row per supported version and update it as reviews complete; CI fails
if `SUPPORTED.md` drifts from this table plus the manifests.

All eight rows are at `tested-in-CI`. The backports evidence above places the
reviewed fixes inside each pinned commit, and on 2026-11-01 the CI chain built
all eight series — `cli` and
`fpm`, `amd64` and `arm64`, 32 legs — with `tests/smoke.sh` for each variant,
`tests/extensions.sh` and `tests/composer.sh` passing on the image every leg
built. That is precisely the condition this file set for the value: a real build
with the extension and FPM assertions passing.

What `tested-in-CI` does **not** claim, and what no row should be read as:

- **A published tag is a separate fact from a green row.** The verification chain
  that earned these rows runs in test mode, so its `merge` jobs were skipped and
  nothing it built reached a registry. Two release runs have happened since: the
  first (`v7.4.33`, 2026-11-01) failed — its four 7.4 legs built and tested green
  but handed the merge a digest for an image they had loaded locally rather than
  pushed, so the registry had no such manifest — and the second (a
  `workflow_dispatch`, same day) published **7.4 only**:
  `7.4.33-cli`/`7.4-cli`/`7.4.33-fpm`/`7.4-fpm` exist, no `latest` name does (the
  pipeline publishes none — see MAINTAINING.md, "Publishing images"), and none of
  the other seven series had a tag at that run's date. A green CI row is evidence
  the image builds and behaves; it has never been evidence that a tag exists.
- **The CVE hunks are still untested.** The suite exercises the extension surface
  and the FPM pool, not the bailout fix; see the caveats under the CVE table.
- **It is not an approval.** Moving a row to an `approved-*` status still needs a
  named reviewer and a date on this file.

5.6's row additionally has the 2026-10-31 local arm64 build behind it (see
"Limits of this record"), which on its own was never enough to claim
`tested-in-CI` — a local run is not a CI run, and this vocabulary has no value
meaning "built and tested locally, pending CI". The CI run above is what
justifies the value, for all eight rows.

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
