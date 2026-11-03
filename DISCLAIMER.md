# Disclaimer

**Read this before pulling, building, or deploying any image from this project.**

## What this project is

A set of PHP CLI and PHP-FPM images for legacy PHP versions (5.6, 7.0, 7.1,
7.2, 7.3, 7.4, 8.0, 8.1), built from explicitly pinned, human-reviewed source
commits on [`shivammathur/php-src-backports`][backports] — the repository that
keeps backporting fixes onto these version numbers after official PHP stopped
releasing them — with a documented patch/CVE review trail
([SUPPORTED.md](SUPPORTED.md), [manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md)).

The images are what this project is for. The build framework, the pins and the
review records are here so that any image claiming to be one of these can be
checked against them: every published image embeds
`/opt/php/BUILD-PROVENANCE` and ships `/usr/local/bin/verify-runtime` to
re-audit those claims in place.

What is published is decided by [SUPPORTED.md](SUPPORTED.md), not by this
README. Every manifest is pinned and approved, so none is skipped for being
unready, and as of 2026-11-01 every series has been built and tested in CI on
both architectures, which is what its `tested-in-CI` review status claims. That
status claims neither more nor less than that: it is not an approval
(`approved-*` needs a named reviewer), it does not mean the CVE fixes were
exercised by a test, and it does not mean there is an image to pull. As of
2026-11-01 the only series with tags in the registry is **7.4**
(`ghcr.io/muffetlab/php:7.4.33-cli`, `:7.4-cli`, `:7.4.33-fpm`, `:7.4-fpm`); the
other seven have none, and there is no `latest` tag in the registry or in the
pipeline for them to acquire later.

[backports]: https://github.com/shivammathur/php-src-backports

## What this project is not

1. **Not a security guarantee.** All eight versions here are end-of-life
   upstream: official `php/php-src` made its last release for 8.0 in August
   2023 and for 8.1 in December 2025. Images built from a backport repository
   carry only the fixes that were actually backported, reviewed, and recorded
   here — and the maintainer labels at least one of them a "minimal mitigation".
   Absence of a known CVE in the review matrix is not proof of absence of
   vulnerabilities.
2. **Not upstream PHP.** Backported sources differ from official releases.
   Behavior, performance, and extension compatibility must be validated by
   you, for your workload, before any production use.
3. **Not a substitute for upgrading.** Every version supported here is a
   migration waypoint, not a destination. The only durable fix for running
   EOL PHP is to stop running EOL PHP.
4. **PHP 8.0/8.1 caveat:** official support for these ended before the
   others (8.0.30 in August 2023, 8.1.34 in December 2025), so they are built
   from the same backports repository as 5.6–7.4 and carry exactly the same
   exposure. Nothing in this set has a vendor shipping fixes for it.

## Responsibility

You are responsible for your own risk assessment, network exposure, patch
cadence, and compliance posture when running any image from this project.
Nothing published here constitutes security, legal, or compliance advice.
Images tagged from unfilled or unreviewed manifests are never published — but
a published image is only as current as its recorded review date.

If you deploy these images internet-facing, at minimum: run behind a WAF or
reverse proxy, keep the base OS security-updated, subscribe to the CVE feeds
referenced in SECURITY.md, and re-verify the review matrix on every release.
