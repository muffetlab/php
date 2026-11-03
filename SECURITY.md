# Security policy

## Scope of support — read first

This project publishes images for PHP versions that are **all end-of-life
upstream**: official `php/php-src` made its last release for 8.0 on 2023-08-03
(8.0.30) and for 8.1 on 2025-12-18 (8.1.34), so there is no supported line in
this set. That is why every series pins a branch of
[`shivammathur/php-src-backports`](https://github.com/shivammathur/php-src-backports)
rather than the official tree. "Support" here means exactly and only:

- the pinned source commit recorded in `manifests/<version>.env`
- the CVE reviews recorded in `manifests/SECURITY-REVIEW.md`
- the patches recorded (with SHA-256) under `patches/<version>/`

There is no warranty that any image is free of vulnerabilities. See
[DISCLAIMER.md](DISCLAIMER.md). A published image is only as current as the
review date recorded for its version.

## Reporting a vulnerability in this kit

If you find a security problem **in the kit itself** — e.g. a patch recorded
as reviewed that does not match its SHA-256, a CI gate that can be bypassed
(PR-triggered push, unpinned digest accepted), a provenance record that can be
forged, or a workflow injecting untrusted input into a shell — please report
it privately via GitHub's **private vulnerability reporting** (Security →
Report a vulnerability) or to the maintainer contact listed in the repository
profile. Please do not open a public issue for kit vulnerabilities.

Include: affected file/workflow, reproduction steps, and impact. We aim to
acknowledge within 5 business days.

## Reporting a PHP CVE that affects a published image

Open an issue referencing the CVE and the affected version(s), or use the
private channel if the fix is not yet public. The expected maintainer flow:

1. Assess applicability per supported minor version (backport coverage does
   not transfer between minors).
2. Update `manifests/SECURITY-REVIEW.md` (including the machine-readable
   status table) and add any patch under `patches/<version>/` with a
   `REVIEW-*.md` record.
3. Re-pin, rebuild, re-run `tests/`, regenerate `SUPPORTED.md`, and publish a
   new immutable tag through the release workflow.

## OS package CVEs (the Debian base)

A published image is a PHP tree **and** a Debian package closure, and the two have
different owners. PHP-side CVEs follow the flow above. Everything below is about the
operating system layer — the part a scanner reports as `debian/curl`, `debian/sqlite3`,
`debian/zlib` — because the honest answer there is not the same as the PHP answer.

The base is our choice, not upstream's: `BASE_IMAGE` is a manifest key, pinned by
digest, and reviewed as a security decision (see [MAINTAINING.md](MAINTAINING.md)).
The upstream backports fork only forces an OpenSSL major, which is why 5.6 sits on
bullseye and 7.0–8.1 on bookworm.

What we do automatically, on every build: both stages run `apt dist-upgrade` against
the pinned base before installing anything into it, with Debian's phasing override
(a fix published in the last few days is still in partial phasing and invisible to a
plain upgrade) and with a **simulate-first rule** — if the refresh would remove a
package, the build fails instead of shipping an image whose `libcurl4` or `libssl3`
apt traded away for a dependency.

What we do not claim: that a refreshed base is a fixed base. On 2026-11-02 the
bookworm candidate set moved `tzdata 2026e -> 2026f` and nothing else; the bullseye
archive reported `0 upgraded` because it is frozen (its LTS window ended 2026-08-31).
So for a finding against this kit's images there are exactly three real outcomes, and
we publish which one applies:

- **A fix Debian ships for our suite and our image did not carry** — a kit defect.
  `tools/scan-image.sh` fails the build with a `fixable` verdict; the remedy is a
  rebuild or a base bump, never a register row.
- **No fix exists for the suite we build on** (curl CVE-2026-86414 /
  CVE-2026-92388 are this shape: the only repaired version is in unstable, and the
  released suite carrying them is marked `<no-dsa>`) — published as a row in
  [`manifests/OS-CVE-STATUS.md`](manifests/OS-CVE-STATUS.md) with the tracker link,
  the version installed in our image, and the review date.
- **A decision we chose not to take** (moving series to a newer base, building libcurl
  from source so its CVEs become ours) — named as such in that file rather than
  presented as a limitation of Debian. A newer base is *trialled*, not asserted:
  CI can build one series on a candidate digest and run the same gate over it,
  which is how a row citing trixie gets its numbers from an image that existed.

Every image therefore carries `/opt/php/RUNTIME-OS-PACKAGES` — every installed Debian
package by *source* name and version — and `verify-runtime`, shipped inside the image,
re-derives that list from `dpkg` and fails if the inventory and the image disagree by a
single version string. Re-run the audit yourself on a pulled image:

```sh
docker run --rm --entrypoint cat <image> /opt/php/RUNTIME-OS-PACKAGES
docker run --rm --entrypoint verify-runtime <image>
```

If you report an OS-layer CVE: naming the CVE and the series is enough. We will rebuild
first (a stale base digest is the most common cause), then answer either "fixed in tag
X" or with the register row that says why no fix is available to us. A report we cannot
match to a rebuild or a row is a missing row, and adding one is a public, evidenced
change — there is no ignore list in this pipeline, so a finding cannot be silenced by
editing configuration.

## Known-limit CVEs

Dedicated backport projects exist for recent legacy CVEs (e.g. the targeted
patches for CVE-2026-109618 / CVE-2026-109619). Those projects state their
fix scope is limited. This kit treats them as candidate inputs to review, not
as complete remediation, and never applies a patch that is already contained
in the pinned commit.

## Advisory sources to watch

- PHP advisories: https://www.php.net/security/
- Backports repository activity: https://github.com/shivammathur/php-src-backports
- Base image OS advisories: Debian LTS/ELTS security trackers for the pinned
  base (bullseye-derived for the openssl11 route, bookworm-derived for openssl3)
- OpenSSL: https://openssl-library.org/news/vulnerabilities/

## This kit's own hardening gates (what CI enforces)

- Manifests must pin the base image by digest and the source by commit. The
  digest has to be 64 lowercase hex — `@sha256:REPLACE_WITH_DIGEST` merely
  looks pinned and `build.sh` rejects it — and `PHP_SRC_COMMIT` has to be a full
  40-hex SHA, never a branch head. `PHP_SRC_REPO` must be
  `shivammathur/php-src-backports` for every series; pointing a manifest at
  official `php/php-src` is refused by `build.sh`, the Dockerfile guard and CI
  alike, because switching source is a reviewed policy change rather than a
  value to edit.
- A manifest whose base digest is still a placeholder is *not* a broken build:
  the per-version CI jobs skip it, and `tools/resolve-base-digest.sh --check`
  reports what to fill in. Two further advisory reports never gate a build:
  the same tool warns when a pinned digest no longer matches what the tag now
  resolves to, and `tools/check-pin-drift.sh` warns when a pinned commit no
  longer matches the tip of its upstream tag.
- `PATCHSET_APPROVED=1` is a human decision; unfilled manifests cause builds
  to skip, never to force-release.
- A base-image trial cannot publish. `build-version.yml` rejects `push=true`
  together with `base_image_override` as a hard failure, requires the override to
  carry a 64-hex digest, and prints which two bases it was offered; the only
  caller that passes `push=true` is `release.yml`, which never passes the
  override. A reviewed `BASE_IMAGE` in `manifests/<version>.env` changes only by
  a human commit — the same rule that keeps `tools/resolve-base-digest.sh` a
  printer.
- Every patch under `patches/` must have a review record containing its
  current SHA-256; mismatches fail CI.
- The vendored `docker-php-ext-*` scripts must match `docker-php-ext/SHA256SUMS`
  and the commit pinned in the Dockerfile must be the one recorded in
  `docker-php-ext/README.md`.
- The Composer installer is fetched from an immutable git commit and must match
  a pinned SHA-256; the installed phar is digest-verified too, and the resulting
  image must still report the recorded version. Composer pins are checked for
  agreement across the Dockerfile, `build.sh`, CI, the docs and `SUPPORTED.md`,
  and Composer 2.x is rejected on PHP 5.6/7.0/7.1. A non-blocking job warns when
  upstream rotates the installer away from the pin.
- Build dependencies are chosen per OpenSSL route, and the build fails early if
  the base image's OpenSSL major does not match the route the manifest declares
  (`openssl11` ⇒ 1.1.x, `openssl3` ⇒ 3.x). A wrong base therefore cannot
  produce a "successful" image linked against an unexpected library.
- An image cannot be produced unless `verify-build` passes in the build stage
  (every required extension present in `php -m`, resolvable via `php --ri`,
  linked OpenSSL matching the route, and the 8.0.13 / 8.1.0 native-OpenSSL-3
  floors) and `verify-runtime` passes in the final stage (binaries execute,
  provenance present, Composer phar still equal to its recorded SHA-256, no
  unresolved shared libraries). Both scripts are covered by
  `tests/verify-harness.sh`, so a weakened assertion fails CI even though the
  image build itself is never exercised there.
- Every place where build behaviour depends on the PHP series carries a
  `# version-branch: <tag>` marker and must have a matching row in the
  "Version-conditional behaviour" table in [MAINTAINING.md](MAINTAINING.md).
  `tools/list-version-branches.sh --check`
  fails CI in both directions, so per-version divergence cannot accumulate
  undocumented — which matters because "backport coverage does not transfer
  between minor versions".
- Pushes to registries are only possible from `main`/`master` (manual dispatch,
  with the PHP series named by the required `version` input) or from a release
  tag, and only through `release.yml`: it is the sole caller
  that passes `push=true` to the reusable build job. Each run publishes exactly
  one series — the one the tag or the input names — and its validate job fails the
  run if that series' manifest is not pinned and approved, so a mistargeted tag
  cannot end as a green release that published nothing. `build-and-verify.yml` runs
  on `pull_request` and manual dispatch, never on a push, and always calls that
  job in test mode — so no PR, fork or branch push can reach a registry login,
  and one tag starts exactly one chain. The tag trigger is `v*`, and the release
  workflow's
  guard job then requires exactly `vX.Y.Z` — one tag per PHP version, a rebuild
  moves that tag instead of adding `vX.Y.Z-<rev>` — *and* that the named PHP
  series is in the supported list, so a mistyped, unrelated or suffixed tag stops
  before any image is built or pushed. The pipeline publishes no `latest` tag at
  all — the two names a run writes are `<full-php-version>-<variant>` and
  `<minor>-<variant>` — so no tag shape can move a `latest` for a series you did
  not release.
- The Docker Hub mirror secret is used for more than a registry login now.
  `DOCKERHUB_TOKEN` must be a read+write personal access token, because
  `tools/sync-dockerhub-readme.sh` (run by the release's merge job and by
  `sync-dockerhub-readme.yml`) PATCHes the mirror repository's `full_description`
  so its Overview matches README.md. The blast radius of that wider scope is
  bounded the same way the rest of the pipeline is: the write happens only in a job
  that already has the mirror secrets, i.e. never for a `pull_request`, a fork or a
  branch push; it changes documentation text on one Hub repository and cannot move,
  sign or delete an image tag; the payload is README.md's own bytes with its
  relative links rewritten, so nothing the workflow knows about the token is in it;
  and the token is passed to curl through files in a `mktemp -d` rather than argv,
  so it does not land in a log or a process list. What it *can* do if abused is
  deface the mirror's Overview, which is why the read-back is part of the step: a
  silent failure would look like a synced page.
- Published images embed `/opt/php/BUILD-PROVENANCE` and OCI provenance
  labels; release pushes attach provenance/SBOM attestations.
- The Debian layer of the image is refreshed, inventoried and gated. Both stages
  run `apt dist-upgrade` against the pinned base before installing anything, with
  `APT::Get::Always-Include-Phasing=experimental` (so a fix still in partial phasing
  is taken) and noninteractive conffile handling — and the upgrade is *simulated
  first*: if it would remove any package the build stops rather than letting apt drop
  `libcurl4`/`libssl3` to satisfy a dependency. The final stage writes
  `/opt/php/RUNTIME-OS-PACKAGES` (every installed package by source name and version)
  and `verify-runtime` re-derives it from `dpkg` on a pulled image, failing on a
  recorded package that is absent, an unrecorded package that is present, a version
  that differs, a missing `format=` header or an empty file; images predating the
  inventory are announced, not failed. `tests/verify-harness.sh` drives each of those
  paths with a stub `dpkg-query`, and `tests/scan-image-harness.sh` drives the gate's
  verdicts with a stub `docker` and a stub `trivy`.
- Every build leg then runs `tools/scan-image.sh` over the image it produced, **before**
  anything is pushed, and classifies scanner findings against
  `manifests/OS-CVE-STATUS.md`: a CVE the image's own Debian suite could have fixed is a
  `fixable` failure (the remedy is a rebuild, not a register row), a finding naming no
  Debian package in the image is routed to `manifests/SECURITY-REVIEW.md`, and an
  unregistered or stale-evidence finding fails the leg. The register is the only way a
  finding stops gating, and a disposition the tool does not recognise is rejected — so
  there is no ignore list to quietly widen. When the currency probe cannot run the
  finding is reported `unverified`, never clean. The scanner itself is fetched by
  `tools/install-trivy.sh` at a pinned version whose release asset must match a
  committed SHA-256, and the installed binary is re-checked against that version before
  the gate runs. If no scanner reaches the gate — an unfilled digest, a trivy that
  cannot reach its database, a scanner that writes a zero-byte report — the verdict is
  `unverified` and the leg fails: an image nobody scanned is not an image with no CVEs,
  and the JSON report says which of the three it was (`"scanner":"absent"` /
  `"trivy-failed"` / `"empty-report"`). A report is read as JSON only when the file
  actually begins with `{` and jq can parse it, and a line is treated as a record only
  when a CVE id precedes its first `|`; anything else is mined for CVE ids and reported
  as package-less. Both rules exist because run 41568823708 showed the alternative: a real
  report read as text invented 318 findings out of 25 and named no packages at all.
- The image-size cleanup removes build residue (`.git`, PHPT `tests/`, PECL and
  apt caches, `/tmp`) but no audit evidence: repo/ref/commit, the effective
  build package list, PECL and Composer pins, patch digests and the
  before/after source-tree sizes stay in `/opt/php/BUILD-*`, and
  `verify-runtime` re-checks on a pulled image that whatever the manifest said
  about shipping the source tree is what the image actually contains. Slimming
  is therefore never a way to lose traceability — and a cleanup change that
  deletes something `docker-php-ext-install` needs fails the build rather than
  shipping an image whose extension builds are broken.
