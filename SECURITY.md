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

## Known limits — read before deploying

The six limits below are the ones a deployer has to decide about. The
consumer-facing summary is the "Security notice" in [README.md](README.md); this
is the full statement of each.

1. **Every series here is end-of-life upstream** (5.6–7.4 long since, 8.0 in
   2023 and 8.1 in December 2025). A successful build does not make any of them
   fully supported or secure.
2. `shivammathur/php-src-backports` is the source of record for every series,
   not a guarantee that every CVE is fixed. Its head commit for each series
   carries the current bailout / CVE-2026-109618-109619 work (see the review
   record), but coverage is what the pinned commit says it is — verify it per
   minor version, and verify with a build and test run before treating it as
   production evidence.
3. CVE-2026-109618 and CVE-2026-109619 (public since Oct 2026) need separate
   verification for **every** version in scope. Dedicated legacy-backport
   projects publish targeted patches for them, but those projects state their fix
   scope is limited and does not replace full security maintenance. If the fix is
   already in the pinned commit, do not apply the patch again.
4. This kit does **not** include unverified CVE patches. Do not add a patch merely
   because its filename mentions a CVE. Two separate things are being claimed when a
   patch ships, and only one of them is mechanical:
   *the hash* — the bytes an image carries are the bytes a human looked at, and that
   equivalence is what a machine can check; the check, and the review record it
   reads, are described in [MAINTAINING.md](MAINTAINING.md)
   ("Hardening gates (what CI enforces)").
   *the judgement* — whether the patch belongs on that target branch, is a correct
   backport rather than a textual collision, whether it is already in the pinned
   commit, and whether it regresses anything. That is a human decision recorded in
   a `patches/REVIEW-*.md`, and no hash check can substitute for it. A recorded
   digest on a patch nobody reviewed is exactly the failure this rule exists to stop.
5. PHP 5.6's OpenSSL compatibility is a separate engineering problem, and so is
   its base. The 5.6 image is built on Debian bullseye because that is the Debian
   release carrying OpenSSL 1.1.1w; bullseye reached the end of its Debian LTS
   window on 2026-08-31 and
   its `-security` pool has moved to `archive.debian.org`, so the OpenSSL inside a
   5.6 image is frozen at `1.1.1w-0+deb11u8` and there is no maintained security
   source behind it. Do not run that in an internet-facing production workload
   without accepting the freeze explicitly. The Dockerfile redirects that suite to
   the archive in both stages, so 5.6 builds reproducibly and users can still
   `apt-get` inside the image — the freeze is deliberate, not a broken mirror. The
   measured evidence and the decision are recorded in
   [manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md).
6. The Dockerfile uses `BASE_IMAGE` as both build and runtime base to avoid
   silently copying binaries across incompatible libc/OpenSSL environments. This
   is safer as a starting point, but it is not a multi-stage minimal runtime yet.

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
   new immutable image through the release workflow at the next image revision —
   `8.1.34-r2-fpm` beside the `8.1.34-r1-fpm` that is already published. The PHP
   version does not change for an OS or patchset fix; the revision does. Exact tags
   are never moved, so the build you reported keeps its own name and digest while
   the floating `8.1-fpm` moves to the fixed one: a deployment that pinned the minor
   tag receives the fix without editing anything, and one that pinned
   `8.1.34-r1-fpm` has to move to `8.1.34-r2-fpm`. Which revision a fix ships under,
   and how the run that publishes it is dispatched, is
   [MAINTAINING.md](MAINTAINING.md) ("Publishing images").

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
archive reported `0 upgraded` because it is frozen (bullseye reached the end of its
Debian LTS window on 2026-08-31).
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

## What the pipeline guarantees

Each row is a policy claim: something a deployer or an auditor may rely on, with
no description of how it is enforced. The mechanism — the step, the tool, the
flag, and the harness that pins it — is
[MAINTAINING.md](MAINTAINING.md) ("Hardening gates (what CI enforces)"), which
carries one bullet per row under the same name. `tools/check-image-name.sh`
compares the two lists in both directions, so a guarantee with no gate behind it
and a gate no guarantee claims both fail CI. This table cannot quietly grow a
claim the pipeline does not enforce, and a new gate cannot ship unclaimed.

| Guarantee | What it claims | Enforced by (MAINTAINING.md) |
| --- | --- | --- |
| Manifest pins are shapes, not intentions | No image is built from a floating ref or a digest that merely looks pinned: the base is pinned by 64-hex digest, the source by a full commit, and the source repository is the reviewed fork. | *Building the images yourself* |
| Unapproved manifests skip, never force-release | An unreviewed series is never published by accident; a series whose manifest is unfilled or unapproved is a skipped build, not a forced release. | *CI (GitHub Actions)* |
| A base-image trial cannot publish | Experimenting with a candidate base cannot reach a registry, even when a caller asks it to. | *Trialing a newer Debian release* |
| A patch ships only with its review record | What ships is the bytes a human looked at — and the hash is not the review itself, which is why limit 4 above distinguishes the two. | *Hardening gates* |
| Vendored extension scripts are hash-verified | The scripts that add extensions to your image, here and downstream, are the reviewed upstream ones. | *Hardening gates* |
| Composer is fetched and verified by digest | The dependency installer inside the image is pinned twice over, and a legacy series cannot silently receive a version it cannot run. | *Composer trust model* |
| The base cannot disagree with the OpenSSL route | A wrong base fails the build rather than shipping PHP linked against a library nobody declared. | *Hardening gates* |
| Nothing is published that failed verify-build or verify-runtime | Every promised extension is present, loadable and linked as declared, and the provenance inside the image is there — as build preconditions, not post-release hopes. | *Build & verification order* |
| Per-version behaviour is enumerated or CI fails | A rule that applies to one series only is documented in the maintainer inventory or the build is refused, so per-version divergence cannot accumulate silently. | *Version-conditional behaviour* |
| No pull request or branch push can reach a registry | Review is not a path to publishing an image: only a human dispatching the release workflow from the default branch is. | *CI (GitHub Actions)* |
| Publishing requires tagged source | Every published image comes from a commit marked as a source release, and a git tag is never a PHP version or an image revision. | *Publishing images* |
| The Hub token writes documentation text only | The one secret with a scope wider than a registry login changes the mirror repository's `full_description` and nothing else: it cannot move, sign or delete an image tag, and it is never used for a pull request or a fork. | *The Docker Hub mirror's Overview* |
| Every published image carries its provenance | What an image is made of is checkable where it runs: `/opt/php/BUILD-PROVENANCE`, matching OCI labels, and attestations attached to the released manifest list. | *Publishing images* |
| The Debian layer is refreshed, inventoried and self-checking | The OS closure is upgraded before anything is installed, is never allowed to trade away a security library, and re-counts itself against its own package inventory on a pulled image. | *The Debian base and its CVEs* |
| An OS finding is fixed, registered, or it fails the build | There is no ignore list to widen: a finding the image's own suite could have fixed fails the build, and a finding it cannot is published with its evidence and its review date. | *The Debian base and its CVEs* |
| Slimming the image never loses audit evidence | A smaller image is not a less auditable one, and a cleanup that breaks extension builds fails rather than ships broken. | *How the image stays slim without losing the audit trail* |
