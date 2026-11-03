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

1. Never copy an unverified community patch into `patches/`. The filename
   mentioning a CVE is not evidence of a correct fix.
2. For recent-CVE hotfix patches (e.g. the dedicated backport projects for
   CVE-2026-109618 / CVE-2026-109619): those projects state their fix scope
   is limited. They are not a substitute for full security maintenance, and
   if the fix is already contained in the pinned source commit, the patch
   must not be applied again.
3. A patch designed for a different PHP minor release must be re-derived, not
   copied.
4. Record the SHA-256 above from the actual file that will be built, not from
   a download page.
