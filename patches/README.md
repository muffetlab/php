# Additional patches

Put only reviewed, version-specific patches in `patches/<version>/`, for example:
- `patches/5.6/`
- `patches/7.0/` … `patches/7.4/`
- `patches/8.0/`, `patches/8.1/` (rare — prefer pinning a newer official commit instead of patching)

Every patch must have a review record next to it, created from
`patches/REVIEW-TEMPLATE.md`, recording at minimum: CVE, patch source
(upstream commit or backport repo), target source version, patch SHA-256,
review result, and test result.

Rules:
1. Pin the upstream/backport commit first and inspect its full diff.
2. Check whether the fix is already included in the pinned commit — if it is,
   do not add the patch (never apply a fix twice).
3. Record source URL, commit, SHA-256, CVE, target PHP version, and tests via
   `patches/REVIEW-TEMPLATE.md`, and mirror the CVE-level status in
   `manifests/SECURITY-REVIEW.md`.
4. Test each patch with `patch --dry-run`; the Docker build fails if it does not apply.
5. Never blindly apply a patch designed for a different PHP minor release, and do
   not put unreviewed patches in production: a filename mentioning a CVE is not
   evidence.
6. Dedicated hotfix patches for recent CVEs (e.g. CVE-2026-109618 /
   CVE-2026-109619 backport projects) explicitly have limited fix scope; they
   do not replace full security maintenance for an EOL PHP version.
