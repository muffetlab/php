#!/usr/bin/env bash
# Regenerates SUPPORTED.md from manifests/*.env, the machine-readable
# status table in manifests/SECURITY-REVIEW.md, and the live registry:
# which tags exist and their deploy digests are read from ghcr.io at
# generation time, so the generated "Release tags" section is the
# registry's own answer and can never drift from it.
# SUPPORTED.md is generated — do not edit it by hand. CI fails if the
# committed file drifts from the generator output, and the generator fails
# loudly (exit non-zero) if the registry is unreachable: no output at all
# is better than an output that cannot say what it verified.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/SUPPORTED.md"
# version-branch: series-allowlist
SUPPORTED_VERSIONS="5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1"
# The published address the release workflow composes. A fork regenerates
# against its own registry namespace by overriding this.
GHCR_HOST="${GHCR_HOST:-ghcr.io}"
GHCR_REPO="${GHCR_REPO:-muffetlab/php}"

REGISTRY_TIMEOUT="${REGISTRY_TIMEOUT:-30}"

ghcr_token() {
  # Pull-scope anonymous token, exactly as the release records verified the
  # registry with; jq -e makes an unparseable answer a hard failure.
  curl -fsS --max-time "$REGISTRY_TIMEOUT" \
    "https://${GHCR_HOST}/token?scope=repository:${GHCR_REPO}:pull" \
    | jq -e -r .token
}

registry_tags_list() {
  # $1 = pull token. One full tag name per line. This list IS the "which tags
  # exist" fact; the generator's Release tags section only re-states it.
  curl -fsS --max-time "$REGISTRY_TIMEOUT" \
    -H "Authorization: Bearer ${1}" \
    "https://${GHCR_HOST}/v2/${GHCR_REPO}/tags/list" \
    | jq -e -r '.tags[]'
}

registry_has_tag() {
  # $1 = tag. jq renders one tag per argument-free line, so membership is an
  # exact whole-line match.
  grep -Fqx -- "$1" <<<"$tags_list"
}

digest_for_tag() {
  # $1 = pull token, $2 = tag. The manifest GET's Docker-Content-Digest
  # response header IS the list digest the release records verified by hand
  # on 2026-11-03.
  curl -fsS --max-time "$REGISTRY_TIMEOUT" -D- -o /dev/null \
    -H "Authorization: Bearer ${1}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://${GHCR_HOST}/v2/${GHCR_REPO}/manifests/${2}" \
    | awk 'tolower($1)=="docker-content-digest:"{sub(/\r$/, "", $2); print $2; exit}'
}

status_for() {
  # Parse rows of the form: | <version> | <status> |  from SECURITY-REVIEW.md.
  # A version may appear in other tables in that file (the pin table does), so
  # only a row whose second column is one of the known status words counts --
  # otherwise the first matching version line wins and reports a tag name as a
  # review status.
  local ver="$1" st
  st="$(awk -F'|' -v ver="$ver" '
    BEGIN {
      split("unreviewed patch-present-not-tested tested-in-CI approved-for-staging approved-for-production", ok, " ")
      for (i in ok) valid[ok[i]] = 1
    }
    { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3) }
    $2 == ver && ($3 in valid) { print $3; exit }
  ' "${ROOT}/manifests/SECURITY-REVIEW.md" 2>/dev/null || true)"
  case "$st" in
    unreviewed|patch-present-not-tested|tested-in-CI|approved-for-staging|approved-for-production)
      printf '%s' "$st"; return ;;
  esac
  printf 'unreviewed'
}

published_for() {
  # Which variants of this series the registry currently serves, as a sorted
  # "cli fpm" list (empty when none). $2 carries the manifest's BUILD_VARIANTS
  # list, so the names asked for are exactly the series' declared variants --
  # a stray tag naming something else can never widen this. The source is the
  # registry itself: /v2/<repo>/tags/list read with an anonymous pull-scope
  # token at generation time.
  local ver="$1" out=""
  for variant in ${2:-}; do
    if registry_has_tag "${ver}-${variant}"; then
      out="${out}${variant} "
    fi
  done
  printf '%s' "${out% }"
}

current_exact_tag() {
  # $1 = SOURCE_REF (the PHP version this manifest pins), $2 = variant. Among the
  # exact names the registry serves for that version -- <version>-r<revision>-
  # <variant>, the shape the release pipeline writes -- print the one with the
  # highest image revision.
  #
  # A bare <version>-<variant> is read as revision 0. Those are the names published
  # before a revision was mandatory, when a rebuild of the same PHP version had
  # nothing to leave behind; every release from here on writes -r<N>, so the bare
  # name stays in the registry as the snapshot it is and never gains a sibling with
  # the same number.
  #
  # The floating name has to agree with *this* one. Every earlier exact name is
  # still in the registry as the snapshot it was published as, so comparing
  # <minor>-<variant> against the newest one would fail from the second build of
  # any version onwards -- and would have been describing the wrong image all
  # along.
  local ver="$1" variant="$2" best="" bestn=-1 t n
  # Newline-separated registry tags; no tag name can contain a space or a glob
  # character, so plain word splitting is the intended read here.
  # shellcheck disable=SC2086
  for t in $tags_list; do
    case "$t" in
      "${ver}-${variant}") n=0 ;;
      "${ver}-r"*"-${variant}")
        n="${t#"${ver}-r"}"
        n="${n%"-${variant}"}"
        printf '%s' "$n" | grep -Eq '^[0-9]+$' || continue
        n="$((10#$n))" ;;
      *) continue ;;
    esac
    if [ "$n" -gt "$bestn" ]; then
      bestn="$n"
      best="$t"
    fi
  done
  printf '%s' "$best"
}

{
  echo "# Supported versions"
  echo
  echo "<!-- GENERATED by tools/gen-supported.sh — do not edit by hand. -->"
  echo "<!-- Source of truth: manifests/*.env + manifests/SECURITY-REVIEW.md status table + the live registry (tags and digests read at generation time). -->"
  echo
  echo "Read [DISCLAIMER.md](DISCLAIMER.md) and [SECURITY.md](SECURITY.md) before using"
  echo "any image from this project. A row below being filled in does **not** mean the"
  echo "version is secure; it means the pins and review statuses recorded in this"
  echo "repository at generation time."
  echo
  echo "| Version | OpenSSL route | Source repo | Variants | Composer | Base image | Patches | Security review | Extensions |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  for v in $SUPPORTED_VERSIONS; do
    f="${ROOT}/manifests/${v}.env"
    if [ ! -f "$f" ]; then
      echo "| ${v} | — | — | — | — | manifest missing | — | unreviewed |"
      continue
    fi
    # Trusted project configuration, not untrusted input.
    # shellcheck source=/dev/null
    ( . "$f"
      route="${OPENSSL_ROUTE:-?}"
      case "${PHP_SRC_REPO:-}" in
        # The backports fork is the source of record for every series; the
        # official tree is a policy violation (build.sh and the Dockerfile both
        # refuse it), so label it as such rather than presenting it as a choice.
        # Match the allowed fork first so a repo string that happens to contain
        # both patterns can never be mislabelled as a violation.
        *php-src-backports*) repo="shivammathur/php-src-backports" ;;
        *php/php-src*) repo="official php/php-src — policy violation" ;;
        "") repo="unset" ;;
        *) repo="custom (see manifest)" ;;
      esac
      variants="${BUILD_VARIANTS:-none}"
      # Composer policy default; the Dockerfile is the authoritative source for
      # these pins (keep in sync with its Composer step).
      # version-branch: composer-policy
      case "$v" in
        5.6|7.0|7.1) policy_composer="1.10.28" ;;
        *)           policy_composer="2.11.0" ;;
      esac
      composer="${COMPOSER_VERSION:-$policy_composer}"
      if [ -n "${COMPOSER_VERSION:-}" ] && [ "${COMPOSER_VERSION}" != "$policy_composer" ] \
         && [ -z "${COMPOSER_SHA256:-}" ]; then
        composer="${composer} (override, digest unverified)"
      fi
      # "@sha256:" alone is not a pin — an unfilled manifest ships
      # "@sha256:REPLACE_WITH_DIGEST", and calling that "pinned by digest" in a
      # status table would be exactly the false claim this file exists to avoid.
      case "${BASE_IMAGE:-}" in
        REPLACE_WITH*|"") base="template (unpinned)" ;;
        *@sha256:*)
          if printf '%s' "${BASE_IMAGE##*@sha256:}" | grep -Eq '^[0-9a-f]{64}$'; then
            base="pinned by digest"
          else
            base="digest placeholder — not buildable"
          fi
          ;;
        *) base="UNPINNED — invalid" ;;
      esac
      if [ "${PATCHSET_APPROVED:-0}" = "1" ]; then
        patches="approved"
      else
        patches="pending review"
      fi
      # Extension set = the kit baseline plus whatever this manifest adds. The
      # baseline is restated here because SUPPORTED.md is what a reader compares
      # versions with; the authoritative copy lives in the Dockerfile's guard
      # step (ext_baseline_core / ext_baseline_pecl), and the validate gate runs
      # tools/check-ext-baseline.sh to fail CI if the two disagree. The cell
      # shows the baseline, then this series' additions in parentheses, so
      # "ships more" is distinguishable from "ships the same thing".
      ext_core="openssl curl mysqli pdo_mysql mbstring zip gd zlib"
      ext_pecl="apcu redis memcached"
      # mcrypt is baseline core on exactly the series that can build it (in core
      # through 7.1; the PECL replacement floors at PHP 7.2.0), mirroring the
      # Dockerfile guard step's version-conditional append.
      case "$v" in
        5.6|7.0|7.1) ext_core="${ext_core} mcrypt" ;;
      esac
      # set -f around the unquoted expansions: a list that is empty or padded
      # with spaces must split into words without the names being globbed
      # against the filesystem.
      set -f
      # shellcheck disable=SC2086
      set -- ${PHP_EXTENSIONS:-} ${PECL_EXTENSIONS:-}
      ext_added="$*"
      set +f
      ext_cell="${ext_core} ${ext_pecl}"
      if [ -n "$ext_added" ]; then
        ext_cell="${ext_cell} (+${ext_added})"
      fi
      echo "| ${v} | ${route} | ${repo} | ${variants} | ${composer} | ${base} | ${patches} | $(status_for "$v") | ${ext_cell} |"
    )
  done
  echo
  echo "## Composer"
  echo
  echo "The Composer column shows the pinned release each image installs. Composer"
  echo "2.x requires PHP >= 7.2.5, so PHP 5.6/7.0/7.1 stay on the final 1.x release"
  echo "(1.10.28). The installer script is fetched from an immutable git commit and"
  echo "digest-verified, and the installed phar is digest-verified too; both digests"
  echo "are recorded in \`/opt/php/BUILD-PROVENANCE\`. See MAINTAINING.md"
  echo "(\"Composer trust model\") for the full trust model and how to override the pin."
  echo
  echo "## Release tags"
  echo
  echo "Published images are \`ghcr.io/muffetlab/php\` (the release workflow's"
  echo "registry/namespace inputs compose \`<registry>/<namespace>/php\`; a fork passes"
  echo "its own namespace) and carry:"
  echo
  echo "- \`ghcr.io/muffetlab/php:<minor>-<variant>\` — recommended deploy tag; moves only within its own series"
  echo "- \`ghcr.io/muffetlab/php:<full-php-version>-r<revision>-<variant>\` — immutable exact tag; \`8.1.34-r1-fpm\` is the first image built from PHP 8.1.34, \`8.1.34-r2-fpm\` the rebuild after an OS CVE fix"
  echo
  echo "Four things each carry one job, and none of them is \"which PHP version to"
  echo "build\": a git tag (\`v1.0.0\`) marks the source commit a release was made from,"
  echo "the workflow_dispatch \`version\` input picks the scope (\`all\` or one series),"
  echo "\`manifests/<series>.env\` holds the PHP version, and the Docker tag names the"
  echo "image that came out. Adding a series is a new manifest plus a new row in the"
  echo "allowlist -- the release mechanism does not change."
  echo
  echo "There is no \`latest\` tag, and none is published for any variant: a release run"
  echo "publishes the series it selects -- one series for a single-series dispatch,"
  echo "every supported series at once for \`version=all\` -- so a \`latest\` name"
  echo "would resolve to whichever series was released last: not the newest, and an"
  echo "unrelated rebuild of one series could move it backwards. \`<minor>-<variant>\` is"
  echo "the only floating name and it cannot change major version. Choose the series"
  echo "from the table above; MAINTAINING.md (\"Publishing"
  echo "images\") records why."
  echo
  echo "Every name above is written by one release run -- a manual dispatch of"
  echo "\`release.yml\` that names the scope (\`all\` or a series) and the image revision,"
  echo "from a commit that carries a \`vX.Y.Z\` source release tag. Both names are"
  echo "written by the same run for each series it publishes."
  echo
  reg_tok="$(ghcr_token)"
  tags_list="$(registry_tags_list "$reg_tok")"
  if [ -z "$(printf '%s' "$tags_list" | tr -d '[:space:]')" ]; then
    echo "::error::${GHCR_HOST}/${GHCR_REPO}: reachable but serves no tags; the Release tags section would be silently empty, so generation stops here" >&2
    exit 1
  fi
  gen_stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  listed_any=0
  echo "Which tags exist is a live registry fact: this generator reads \`/tags/list\`"
  echo "with an anonymous pull-scope token and records what it answers, at the"
  echo "time stamped below. A series appears when the registry serves its"
  echo "variants; for each variant the row names the floating tag and the exact"
  echo "tag with the highest image revision the registry serves, and the two must"
  echo "resolve to the same digest (an older revision for the same version may"
  echo "still be in the registry as the snapshot it is, and is not compared). The"
  echo "generator fails the run if they do not:"
  echo
  echo "<!-- generated at ${gen_stamp} -->"
  for v in $SUPPORTED_VERSIONS; do
    f="${ROOT}/manifests/${v}.env"
    [ -f "$f" ] || continue
    # Trusted project configuration, same source the table above reads.
    # shellcheck source=/dev/null
    . "$f"
    pub="$(published_for "$v" "${BUILD_VARIANTS:-}")"
    [ -n "$pub" ] || { unset SOURCE_REF BUILD_VARIANTS; continue; }
    listed_any=1
    set -f
    # shellcheck disable=SC2086
    row=""
    for variant in $pub; do
      exact="$(current_exact_tag "$SOURCE_REF" "$variant")"
      if [ -z "$exact" ]; then
        echo "::error::${v}: the registry serves \`${v}-${variant}\` but no exact tag for the PHP version this manifest pins (\`${SOURCE_REF}\`) -- expected \`${SOURCE_REF}-r<N>-${variant}\`, or the bare \`${SOURCE_REF}-${variant}\` a pre-revision release published; the generator cannot say which build the floating tag points at" >&2
        exit 1
      fi
      d_minor="$(digest_for_tag "$reg_tok" "${v}-${variant}")"
      d_full="$(digest_for_tag "$reg_tok" "$exact")"
      if [ "$d_minor" != "$d_full" ]; then
        echo "::error::${v}: \`${v}-${variant}\` and the highest-revision exact tag \`${exact}\` resolve to different digests (${d_minor:?} vs ${d_full:?})" >&2
        exit 1
      fi
      row="${row}\`${variant}\` \`${v}-${variant}\` / \`${exact}\` → \`${d_minor}\`, "
    done
    set +f
    echo "- ${v}: ${row%, }"
    unset SOURCE_REF BUILD_VARIANTS
  done
  if [ "$listed_any" = 0 ]; then
    echo "- No tags for any series at generation time."
  fi
  echo
  echo "Each tag is a multi-arch manifest list covering \`linux/amd64\` and"
  echo "\`linux/arm64\`; \`docker pull\` selects the matching platform automatically."
  echo "There are no architecture-suffixed tags."
  echo
  echo "The OpenSSL route is not part of a tag name: the release pipeline fixes one"
  echo "route per series (5.6 -> \`openssl11\`, everything else -> \`openssl3\`), so a"
  echo "suffix could not express a choice. It is in \`BUILD-PROVENANCE\` and the"
  echo "\`dev.php-legacy.openssl-route\` label instead, and the per-version table above"
  echo "lists it."
  echo
  echo "Exact tags are never moved, and there is one per image built from a PHP"
  echo "version: \`8.1.34-r1-cli\` is the first, and \`8.1.34-r2-cli\` the rebuild that"
  echo "carries an OS security fix -- the PHP version did not change, the image"
  echo "revision did. Reading the highest revision out of the registry is therefore"
  echo "the same as reading the newest image, and a deployment can pin an exact name"
  echo "knowing it will always mean the bytes it was first pushed as. The name that"
  echo "moves is \`<minor>-<variant>\`, which every release run repoints at that run's"
  echo "build, so a deployment that pinned an exact name has to move to the newer"
  echo "revision (or to \`<minor>-<variant>\`) to receive a fix."
  echo
  echo "A git tag is not part of an image name and does not pick a PHP version:"
  echo "\`v1.0.0\` marks the source commit a release was made from, and a run refuses"
  echo "to publish from a commit that carries no such tag."
  echo
  echo "Every published image embeds \`/opt/php/BUILD-PROVENANCE\` (base image digest,"
  echo "source repo/ref/commit, OpenSSL route and version, PECL extension pins,"
  echo "Composer version + phar digest, patch tree SHA-256 list, build date) plus"
  echo "\`/opt/php/BUILD-DEPS\` and \`/opt/php/BUILD-CLEANUP\` (the effective build package"
  echo "list, and whether the PHP source tree was shipped and what it weighed), and"
  echo "matching OCI labels; release pushes attach provenance/SBOM attestations where"
  echo "the registry supports them."
  echo
  echo "Only rows whose manifest is fully pinned **and** \`PATCHSET_APPROVED=1\` are ever"
  echo "built and published. A release run publishes the series it selects -- one for a"
  echo "single-series dispatch, all supported series for a \`version=all\`"
  echo "dispatch -- and a selected series whose manifest is unpinned or unapproved fails"
  echo "the whole run rather than publishing part of a release quietly; a full release"
  echo "checks every selected manifest before it pushes any image."
  echo "Series a release did not select are skipped, not force-released."
} > "${OUT}.tmp"

mv "${OUT}.tmp" "$OUT"
echo "Generated ${OUT}"
