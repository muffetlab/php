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
checked against them: [DEPLOYING.md](DEPLOYING.md) ("Checking what an image
actually contains") names what an image carries and how to re-audit those claims
in place.

What is published is decided by [SUPPORTED.md](SUPPORTED.md), not by this file.
That page reads the registry at generation time, so which tags exist and what
each digest resolves to is its answer, and no date copied into this file can
keep such an answer current — a snapshot here would rot without failing anything.
Its `tested-in-CI` status claims neither more nor less than that the image passes
the project's CI build and runtime checks: it is not an approval (an
`approved-*` row needs a named reviewer, recorded in
[manifests/SECURITY-REVIEW.md](manifests/SECURITY-REVIEW.md)), it does not mean
the CVE fixes were exercised by a test, and it does not mean there is an image to
pull. Nor will a `latest` name appear later: the pipeline publishes none, for any
variant, and [MAINTAINING.md](MAINTAINING.md) ("Publishing images") records why.

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
