# Security policy

## Contents

- [Scope of support — read first](#scope-of-support--read-first)
- [Responsibility boundary](#responsibility-boundary)
- [Known limits — read before deploying](#known-limits--read-before-deploying)
- [Reporting a vulnerability in this kit](#reporting-a-vulnerability-in-this-kit)
- [Reporting a PHP CVE that affects a published image](#reporting-a-php-cve-that-affects-a-published-image)
- [OS package CVEs (the Debian base)](#os-package-cves-the-debian-base)
- [Known-limit CVEs](#known-limit-cves)
- [Advisory sources to watch](#advisory-sources-to-watch)
- [What the pipeline guarantees](#what-the-pipeline-guarantees)

## Scope of support — read first

This project publishes images for PHP versions that are **all end-of-life
upstream**: official `php/php-src` made its last release for 8.0 on 2023-08-03
(8.0.30) and for 8.1 on 2025-12-18 (8.1.34), so there is no supported line here.
Every series pins a branch of
[`shivammathur/php-src-backports`](https://github.com/shivammathur/php-src-backports)
rather than the official tree. "Support" means exactly: the pinned source commit
in `manifests/<version>.env`; the CVE reviews in `manifests/SECURITY-REVIEW.md`;
and the patches recorded (with SHA-256) under `patches/<version>/`. There is no
warranty that any image is free of vulnerabilities.

## Responsibility boundary

All eight series are end-of-life, so nothing upstream ships fixes for them: an
image carries only what was backported, reviewed and recorded. The absence of a
known CVE in a review record is not evidence that no vulnerability is present,
and a published image is only as current as the review date for its version -- a
release calls for re-reading those records, not trusting a copied date.

These images are a migration waypoint, not a destination: the durable answer to
running EOL PHP is to stop running EOL PHP.

A backported source is not upstream PHP; behavior, performance and extension
compatibility must be validated by you against your workload before production.
CI proves the extension surface and the FPM pool, not the backported hunks, so a
green build is not an approval -- an approval is a named reviewer's record.

You own the risk assessment, network exposure, patch cadence and compliance
posture. Nothing here is security, legal or compliance advice. The operative
warranty terms are the MIT clause in [`LICENSE`](LICENSE), which covers the
build kit and says nothing in favor of an image built with it.

For an internet-facing deployment, three things are yours: serve FPM on an
internal network behind a proxy rather than exposing port 9000
([DEPLOYING.md](DEPLOYING.md#runtime-network-model)); take the next published
revision rather than staying on an old one, since the audited OS refresh happens
in a rebuild; and watch the [advisory sources](#advisory-sources-to-watch),
including the Debian tracker for your series.

## Known limits — read before deploying

The six limits below are the ones a deployer has to decide about. The
consumer-facing summary is the "Security notice" in [README.md](README.md); this
is the full statement of each.

1. **Every series here is end-of-life upstream** (5.6–7.4 long since, 8.0 in 2023
   and 8.1 in December 2025). A successful build does not make any of them fully
   supported or secure.
2. `shivammathur/php-src-backports` is the source of record for every series, not a
   guarantee that every CVE is fixed. Its head commit for each series carries the
   current bailout / CVE-2026-109618 / CVE-2026-109619 work (see the review
   record), but coverage is what the pinned commit says it is — verify it per minor
   version and with a build and test run.
3. CVE-2026-109618 and CVE-2026-109619 (public since Oct 2026) need separate
   verification for **every** version in scope. Dedicated legacy-backport projects
   publish targeted patches for them, but those projects state their fix scope is
   limited and does not replace full security maintenance. If the fix is already in
   the pinned commit, do not apply the patch again.
4. This kit does **not** include unverified CVE patches. Do not add a patch merely
   because its filename mentions a CVE. Two things are claimed when a patch ships,
   and only one is mechanical. *The hash* is mechanical: the bytes an image
   carries are the bytes a human looked at, and that equivalence is
   machine-checkable
   ([MAINTAINING.md](MAINTAINING.md#hardening-gates-what-ci-enforces) names the
   check). *The judgement* is not: whether the patch belongs on that branch, is a
   correct backport rather than a textual collision, and regresses nothing. That
   is a human decision recorded in a `patches/REVIEW-*.md`, and no hash check
   substitutes for it.
5. PHP 5.6's OpenSSL compatibility and its base are a separate engineering problem.
   The 5.6 image is built on Debian bullseye because that release carries OpenSSL
   1.1.1w; bullseye reached the end of its Debian LTS window on 2026-08-31 and its
   `-security` pool has moved to `archive.debian.org`, so OpenSSL inside a 5.6
   image is frozen at `1.1.1w-0+deb11u8` with no maintained security source behind
   it. Do not run it internet-facing without accepting that freeze. The freeze is
   deliberate, not a broken mirror: the build redirects that suite to the archive,
   so 5.6 builds reproducibly and `apt-get` still works inside a running image. The
   rewrite is MAINTAINING.md's `bullseye-archive-security` row; the measured
   evidence and the decision are in
   [manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md).
6. The Dockerfile uses `BASE_IMAGE` as both build and runtime base to avoid
   silently copying binaries across incompatible libc/OpenSSL environments. This is
   safer as a starting point, but it is not a multi-stage minimal runtime yet.

## Reporting a vulnerability in this kit

If you find a security problem **in the kit itself** — e.g. a patch recorded as
reviewed that does not match its SHA-256, a CI gate that can be bypassed
(PR-triggered push, unpinned digest accepted), a provenance record that can be
forged, or a workflow injecting untrusted input into a shell — please report it
privately via GitHub's **private vulnerability reporting** (Security → Report a
vulnerability) or to the maintainer contact listed in the repository profile.
Please do not open a public issue for kit vulnerabilities.

Include: affected file/workflow, reproduction steps, and impact. We aim to
acknowledge within 5 business days.

## Reporting a PHP CVE that affects a published image

Open an issue referencing the CVE and the affected version(s), or use the
private channel if the fix is not yet public. The expected maintainer flow:

1. Assess applicability per supported minor version (backport coverage does not
   transfer between minors).
2. Update `manifests/SECURITY-REVIEW.md` (including the machine-readable status
   table) and add any patch under `patches/<version>/` with a `REVIEW-*.md` record.
3. Re-pin, rebuild, re-run `tests/`, regenerate `SUPPORTED.md`, and publish a new
   image through the release workflow at the next image revision, under an exact
   tag that is immutable by pipeline rule: `8.1.34-r2-fpm` beside `8.1.34-r1-fpm`.
   The PHP version does not change for an OS or patchset fix; the revision does.
   The release pipeline treats exact tags as immutable, so the build you reported
   keeps its own name and digest while the floating `8.1-fpm` moves to the fixed
   one. A deployment that pinned the minor tag receives the fix without editing
   anything; one that pinned `8.1.34-r1-fpm` has to move to `8.1.34-r2-fpm`.
   How the next revision is worked out, and how the run that publishes it is
   started, is [MAINTAINING.md](MAINTAINING.md#publishing-images).

## OS package CVEs (the Debian base)

A published image is a PHP tree **and** a Debian package closure, and the two
have different owners. Everything below is the OS layer -- what a scanner
reports as `debian/curl`, `debian/sqlite3`, `debian/zlib`.

The base is our choice: `BASE_IMAGE` is a manifest key, pinned by digest and
reviewed as a security decision. The backports fork only forces an OpenSSL
major, which is why 5.6 sits on bullseye, 7.0–7.3 on bookworm and 7.4–8.1 on
trixie.

Every build runs `apt dist-upgrade` against the pinned base in both stages, with
Debian's phasing override and a **simulate-first rule**: if the refresh would
remove a package, the build fails rather than trading away `libcurl4` or
`libssl3`.

That does not make a refreshed base a fixed base. A refresh moves whatever
Debian has published, and on a frozen archive it moves nothing; what each base
offered is recorded with the versions it was read from in
[`manifests/OS-CVE-STATUS.md`](manifests/OS-CVE-STATUS.md#how-the-versions-were-collected).

For a finding there are exactly three real outcomes, and we publish which applies:

- **A fix Debian ships and our image did not carry** -- a kit defect.
  `tools/scan-image.sh` fails the build with a `fixable` verdict; the remedy is a
  rebuild or a base bump, never a register row.
- **No fix exists for our suite** (curl CVE-2026-86414 / CVE-2026-92388: the only
  repaired version is in unstable, and the released suite is `<no-dsa>`) -- a row
  in [`manifests/OS-CVE-STATUS.md`](manifests/OS-CVE-STATUS.md) with the tracker
  link, measured versions, their evidence tokens and the review date.
- **A decision we chose not to take** (moving to a newer base, building libcurl
  from source) -- declined and dated in the register, not presented as a Debian
  limitation. A newer base is *trialled*, not asserted: CI builds one series on a
  candidate digest and runs the same gate over it.

Every image carries `/opt/php/RUNTIME-OS-PACKAGES`; `verify-runtime`, shipped
inside the image, re-derives it from `dpkg` and fails if the inventory disagrees
by a single version string. Re-run the audit yourself:

```sh
docker run --rm --entrypoint cat <image> /opt/php/RUNTIME-OS-PACKAGES
docker run --rm --entrypoint verify-runtime <image>
```

If you report an OS-layer CVE, naming the CVE and series is enough. We rebuild
first, then answer either "fixed in tag X" or with the register row that says
why no fix is available. A finding cannot be silenced by editing configuration.

## Known-limit CVEs

Dedicated legacy-backport patches for recent CVEs are candidate inputs to
review, not remediation, and a patch is never applied on top of a fix the pinned
commit already carries. Limit 3 above names the CVEs this applies to; what each
pinned commit actually carries for them is
[manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md)'s per-series table.

## Advisory sources to watch

- PHP advisories: https://www.php.net/security/
- Backports repository activity: https://github.com/shivammathur/php-src-backports
- Base image OS advisories: Debian LTS/ELTS security trackers for the pinned base
  (bullseye for the openssl11 route; on openssl3, bookworm for 7.0–7.3 and trixie
  for 7.4–8.1)
- OpenSSL: https://openssl-library.org/news/vulnerabilities/

## What the pipeline guarantees

Each row is a policy claim: something a deployer or an auditor may rely on, with
no how. The mechanism is
[MAINTAINING.md](MAINTAINING.md#hardening-gates-what-ci-enforces), which carries
one bullet per row under the same name; `tools/check-image-name.sh` compares
both lists in both directions, so a guarantee with no gate and a gate no
guarantee claims both fail CI. The table cannot quietly grow a claim the
pipeline does not enforce.

| Guarantee | What it claims | Enforced by (MAINTAINING.md) |
| --- | --- | --- |
| Manifest pins are shape-checked | No image is built from a floating ref or a digest that merely looks pinned: the base is pinned by 64-hex digest, the source by a full commit, and the source repository is the reviewed fork. | *Building the images yourself* |
| Unselected or unapproved manifests cannot be published | An unreviewed series is never published by accident: a selected series whose manifest is unfilled or unapproved fails the whole release instead of being skipped, and an unselected series is not published by that run at all. | *CI (GitHub Actions)* |
| A base-image trial cannot publish | Experimenting with a candidate base cannot reach a registry, even when a caller asks it to. | *Trialing a newer Debian release* |
| A patch ships only with its review record | What ships is the bytes a human looked at — and the hash is not the review itself, which is why limit 4 above distinguishes the two. | *Building the images yourself* |
| Vendored extension scripts are hash-verified | The scripts that add extensions to your image, here and downstream, are the reviewed upstream ones. | *Per-version extension sets* |
| Composer is fetched and verified by digest | The dependency installer inside the image is pinned twice over, and a legacy series cannot silently receive a version it cannot run. | *Composer trust model* |
| The base cannot disagree with the OpenSSL route | A wrong base fails the build rather than shipping PHP linked against a library nobody declared. | *The Debian base* |
| Nothing is published that failed verify-build or verify-runtime | Every promised extension is present, loadable and linked as declared, and the provenance inside the image is there — as build preconditions, not post-release hopes. | *Build & verification order* |
| Per-version behaviour is enumerated or CI fails | A rule that applies to one series only is documented in the maintainer inventory or the build is refused, so per-version divergence cannot accumulate silently. | *Version-conditional behaviour* |
| No pull request or branch push can reach a registry | Review is not a path to publishing an image: the only paths are a human act — pushing a tag that marks a source release, or starting the release workflow from the default branch — and neither a pull request nor a branch push counts as one. | *CI (GitHub Actions)* |
| Publishing requires tagged source | Every published image comes from a commit marked as a source release, and a git tag is never a PHP version or an image revision. | *Publishing images* |
| The Hub token's tier is set by the Overview write | The one Docker Hub secret is shared by the mirror's `docker login` and the Overview sync. The sync's write is one `full_description` PATCH, which the Hub refuses below the read+write+delete tier (the push alone would accept read+write). It runs only where a pull request, fork or branch push cannot. | *The Docker Hub mirror's Overview* |
| Every published image carries its provenance | What an image is made of is checkable where it runs: `/opt/php/BUILD-PROVENANCE`, matching OCI labels, and attestations attached to the released manifest list. | *Publishing images* |
| The Debian layer is refreshed, inventoried and self-checking | The OS closure is upgraded before anything is installed, is never allowed to trade away a security library, and re-counts itself against its own package inventory on a pulled image. | *The Debian base* |
| An OS finding is fixed, registered, or it fails the build | There is no ignore list to widen: a finding the image's own suite could have fixed fails the build, and a finding it cannot is published with its evidence and its review date. | *The OS CVE register and gate* |
| Slimming the image never loses audit evidence | A smaller image is not a less auditable one, and a cleanup that breaks extension builds fails rather than ships broken. | *How the image stays slim without losing the audit trail* |
