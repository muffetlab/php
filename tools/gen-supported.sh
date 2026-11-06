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

pinned_php() {
  # $1 = series. What this repository's manifest pins as the PHP version --
  # SOURCE_REF, the release tag the manifest also records the peeled commit of.
  # Plain sed, because sourcing the whole manifest to obtain one field would run
  # project configuration for a string.
  sed -n 's/^SOURCE_REF=//p' "${ROOT}/manifests/${1}.env" 2>/dev/null | head -1 | tr -d '"'
}

upstream_last() {
  # $1 = series -> "<last official release> <released> <announced end of life>".
  # php.net's own record, read from its unsupported-versions table and each
  # series' changelog and news archive on 2026-11-05. These are closed facts -- a
  # branch php.net has stopped cannot gain another release -- so they are carried
  # as data rather than scraped on every run, and a status page that could rewrite
  # its own history is not a status page. The columns are deliberately not assumed
  # to be in order: php.net announced 5.6's end of life on 2018-12-31 and shipped
  # 5.6.40 on 2019-01-10, and shipped 7.0.33 on 2018-12-06 before announcing 7.0's
  # end of life on 2019-01-10.
  case "$1" in
    5.6) printf '5.6.40 2019-01-10 2018-12-31' ;;
    7.0) printf '7.0.33 2018-12-06 2019-01-10' ;;
    7.1) printf '7.1.33 2019-10-24 2019-12-01' ;;
    7.2) printf '7.2.34 2020-10-01 2020-11-30' ;;
    7.3) printf '7.3.33 2021-11-18 2021-12-06' ;;
    7.4) printf '7.4.33 2022-11-03 2022-11-28' ;;
    8.0) printf '8.0.30 2023-08-03 2023-11-26' ;;
    8.1) printf '8.1.34 2025-12-18 2025-12-31' ;;
    *)   printf '? - -' ;;
  esac
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
  echo "repository at generation time. This page is state and nothing else: why a pin"
  echo "or a base was chosen is in \`manifests/SECURITY-REVIEW.md\` and"
  echo "[manifests/OS-CVE-STATUS.md](manifests/OS-CVE-STATUS.md), and how a build or a"
  echo "release run works is in [MAINTAINING.md](MAINTAINING.md)."
  echo
  echo "| Version | OpenSSL route | Debian base | Base pin | Source repo | Variants | Composer | Patches | Security review | Extensions |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  for v in $SUPPORTED_VERSIONS; do
    f="${ROOT}/manifests/${v}.env"
    if [ ! -f "$f" ]; then
      # Ten columns, same order as the header: a series with no manifest is a row
      # that says so rather than a row that is short.
      echo "| ${v} | — | — | — | manifest missing | — | — | — | unreviewed | — |"
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
      # Which Debian a series is built on is a separate fact from whether that
      # choice is pinned, and a status table that printed only the second left the
      # reader to compare base images in another document. The ref is printed
      # without its digest: the digest is in the manifest and in the image, and a
      # 64-hex column here would make every row unreadable.
      base_ref="${BASE_IMAGE:-}"
      base_ref="${base_ref%%@sha256:*}"
      [ -n "$base_ref" ] || base_ref="—"
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
      echo "| ${v} | ${route} | ${base_ref} | ${base} | ${repo} | ${variants} | ${composer} | ${patches} | $(status_for "$v") | ${ext_cell} |"
    )
  done
  echo
  echo "How to read a row. \`Debian base\` is the OS the image is built on and \`Base"
  echo "pin\` says whether that ref is pinned by digest -- a placeholder or an unpinned"
  echo "ref is stated as it is, never rounded up to \"pinned\". \`Source repo\` is the"
  echo "source of record the manifest points at, \`Variants\` what a release publishes"
  echo "for the series, and \`Composer\` the release the image installs. \`Patches\` is"
  echo "the human patchset decision (\`PATCHSET_APPROVED=1\` reads \`approved\`); a row"
  echo "reading \`pending review\` is never built or published. \`Security review\` is"
  echo "the status recorded in \`manifests/SECURITY-REVIEW.md\`: \`tested-in-CI\` means"
  echo "the image passes the project's CI build and runtime checks, which is not an"
  echo "approval and not a claim that a tag exists. Whether a tag exists is answered"
  echo "only by \"What the registry serves right now\" below."
  echo
  echo "## Upstream end of life"
  echo
  echo "Every series above is end-of-life upstream: \`php/php-src\` stopped releasing for"
  echo "these lines, which is why the source of record is a backports fork and not PHP"
  echo "itself. The dates are php.net's own record (its unsupported-versions table plus"
  echo "each series' changelog and news archive, read 2026-11-05) and they are closed"
  echo "facts, so they are stored here rather than fetched at generation time."
  echo
  echo "| Series | Last official release | Released | Announced end of life | Pinned here |"
  echo "| --- | --- | --- | --- | --- |"
  for v in $SUPPORTED_VERSIONS; do
    read -r u_last u_rel u_eol <<<"$(upstream_last "$v")"
    u_pin="$(pinned_php "$v")"
    if [ -z "$u_pin" ]; then
      u_cell="no manifest"
    elif [ "$u_pin" = "$u_last" ]; then
      u_cell="\`${u_pin}\`"
    else
      # Saying so is the point: a series pinned below php.net's final release is
      # one more version behind than the row above implies.
      u_cell="\`${u_pin}\` -- below the last official release"
    fi
    echo "| ${v} | \`${u_last}\` | ${u_rel} | ${u_eol} | ${u_cell} |"
  done
  echo
  echo "The release and EOL columns are not in order on every row, and that is what"
  echo "php.net published: 5.6's end of life was announced on 2018-12-31 and \`5.6.40\`"
  echo "arrived on 2019-01-10, while \`7.0.33\` came on 2018-12-06, before 7.0's announced"
  echo "end of life on 2019-01-10, with nothing after it. \"Pinned here\" is this"
  echo "repository's own \`PHP_VERSION\`, read from the manifest at generation time --"
  echo "every series sits on php.net's final release today, and a row that stops saying"
  echo "so means the pin is behind it."
  echo
  echo "## Composer"
  echo
  echo "The Composer column is the release each image installs. Composer"
  echo "2.x requires PHP >= 7.2.5, so PHP 5.6/7.0/7.1 stay on the final 1.x release"
  echo "(1.10.28) and 7.2–8.1 ship 2.11.0. A manifest that overrides the policy pin"
  echo "without also pinning a digest is labelled as unverified in its row. Where"
  echo "those two numbers come from and how the built image verifies them is"
  echo "MAINTAINING.md (\"Composer trust model\"); the digests themselves are recorded"
  echo "in \`/opt/php/BUILD-PROVENANCE\` inside the image."
  echo
  echo "## Release tags"
  echo
  echo "Published images are \`ghcr.io/muffetlab/php\`, and a release writes two names"
  echo "per series and variant -- no third name, and no other registry:"
  echo
  echo "- \`ghcr.io/muffetlab/php:<minor>-<variant>\` — the recommended deploy tag; it floats, and only within its own series"
  echo "- \`ghcr.io/muffetlab/php:<full-php-version>-r<revision>-<variant>\` — the immutable exact tag; \`8.1.34-r1-fpm\` is the first image built from PHP 8.1.34, \`8.1.34-r2-fpm\` the next build of it"
  echo
  echo "There is no \`latest\` tag published for any variant: neither name above is one, and"
  echo "\`<minor>-<variant>\` is the only name that moves -- it cannot change major"
  echo "version. Choose the series from the table above."
  echo "MAINTAINING.md (\"Publishing images\") holds the rest of the model: why no"
  echo "\`latest\` is published, what each of the four release inputs carries, and how a"
  echo "run decides which series to build."
  echo
  echo "Exact tags are never moved, so the highest revision the registry serves is also"
  echo "the newest image: a deployment that pinned an exact name has to move to a newer"
  echo "revision -- or to \`<minor>-<variant>\` -- to receive a fix."
  echo
  reg_tok="$(ghcr_token)"
  tags_list="$(registry_tags_list "$reg_tok")"
  if [ -z "$(printf '%s' "$tags_list" | tr -d '[:space:]')" ]; then
    echo "::error::${GHCR_HOST}/${GHCR_REPO}: reachable but serves no tags; the Release tags section would be silently empty, so generation stops here" >&2
    exit 1
  fi
  gen_stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  # Every document that names a tag to pull states that no `latest` tag is published, and
  # that sentence is about the registry as much as about the pipeline: a `latest-<variant>`
  # left in the namespace by a manual push would make it false while every job stayed
  # green, because no release writes or moves such a name. The tag list is already in
  # hand, so the claim is checked where it is made rather than asserted -- and a real
  # `latest` is a different thing from an unexpected name, so it stops the run instead of
  # being disclosed as a row a reader might mistake for a published series.
  stray_latest="$(printf '%s\n' "$tags_list" | grep -E '^latest(-|$)' | LC_ALL=C sort | tr '\n' ' ' || true)"
  if [ -n "${stray_latest// /}" ]; then
    echo "::error::${GHCR_HOST}/${GHCR_REPO} serves ${stray_latest}; README, DEPLOYING.md, SUPPORTED.md and MAINTAINING.md all state that no latest tag is published, so either the name goes or the documents stop saying that -- generation stops rather than write a page contradicted by the registry" >&2
    exit 1
  fi
  # Names outside the two published shapes are disclosed instead of failing: they are the
  # registry's answer to a question the documents do not make, and the section below
  # would otherwise read as complete while leaving them out.
  other_names="$(printf '%s\n' "$tags_list" \
    | grep -Ev '^[0-9]+\.[0-9]+-(cli|fpm)$|^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?-(cli|fpm)$' \
    | LC_ALL=C sort | tr '\n' ' ' || true)"
  listed_any=0
  echo "### What the registry serves right now"
  echo
  echo "Which tags exist is a registry fact, not a repository one, so this section is"
  echo "the registry's own answer to the question, read at the time stamped below. A"
  echo "series appears when the registry serves its variants; for each variant the row"
  echo "names the floating tag, the exact tag of the highest image revision, and the"
  echo "digest both names resolve to. A series with no row here has not been published"
  echo "by a release run that selected it -- a complete, approved manifest is a"
  echo "precondition for a release, not a claim that one happened."
  echo
  echo "What it answered, per series and variant:"
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
  if [ -z "${other_names// /}" ]; then
    echo
    echo "The same list holds no other name: what the registry answered at the timestamp"
    echo "above is exactly the two names per series and variant printed here. That is read,"
    echo "not asserted -- a \`latest\`-shaped name stops this generator, and any other name"
    echo "outside these two shapes would be listed rather than left out."
  else
    echo
    echo "The same list also serves: ${other_names}. No release run writes a name of that"
    echo "shape, so none of those is what a deployment should pull; the two names a run"
    echo "does write are the ones listed above, and MAINTAINING.md (\"Publishing images\")"
    echo "describes them."
  fi
  echo
  echo "Each tag is a multi-arch manifest list covering \`linux/amd64\` and"
  echo "\`linux/arm64\`; \`docker pull\` selects the matching platform automatically."
  echo "There are no architecture-suffixed tags."
  echo
  echo "The OpenSSL route is not part of a tag name either: one route is fixed per"
  echo "series, so a suffix could express no choice a deployment makes. The"
  echo "\`OpenSSL route\` column above is the answer, and the image carries it in"
  echo "\`/opt/php/BUILD-PROVENANCE\` and the \`dev.php-legacy.openssl-route\` label."
  echo
  echo "Every row above is a claim about an image, and every claim is checkable in the"
  echo "image: [DEPLOYING.md](DEPLOYING.md) (\"Checking what an image actually"
  echo "contains\") names the files to read, and"
  echo "[MAINTAINING.md](MAINTAINING.md) (\"Publishing images\") records what writes them"
  echo "and what is attested to the registry."
} > "${OUT}.tmp"

mv "${OUT}.tmp" "$OUT"
echo "Generated ${OUT}"
