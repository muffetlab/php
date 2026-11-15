# Patch review record — TEMPLATE

Copy this file to `patches/<version>/REVIEW-<NNN>-<short-name>.md` (one record
per patch) and fill in every field before the patch may enter a build.
The patch itself lives at `patches/<version>/<NNN>-<short-name>.patch`.

| Field | Value |
| --- | --- |
| CVE | CVE-YYYY-NNNNN (or "non-CVE fix") |
| Patch source | official upstream commit URL, or community backport repo + commit URL |
| Target source | e.g. PHP 5.6.40 (pinned commit `<40-hex>` from shivammathur/php-src-backports) |
| Patch SHA-256 | `shasum -a 256 <file>.patch` output, recorded verbatim |
| Already in pinned commit? | yes/no — if yes, DO NOT add this patch (no duplicate application) |
| Review result | files/hunks inspected, reviewer name, date |
| Test result | build OK / PHPT `<test names>` / application regression summary |
| Decision | approved / rejected / needs-follow-up |

## Rules

Apply [patches/README.md](README.md)'s rules before recording a decision here.
Record the SHA-256 from the actual file that will be built, not from a download
page or a tracker description.
