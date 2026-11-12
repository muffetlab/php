#!/usr/bin/env bash
# Release plan -- turns a release selection into the build matrix: PHP version,
# image revision and the publish/complete/skip verdict, per series.
#
# The inputs come from MAINTAINING.md "Publishing images": a source-release tag
# covers every supported series; a dispatch names one series, a list, or all.
# The PHP version is SOURCE_REF in manifests/<series>.env; the revision is one
# above the highest -r<N> the registry serves for that point version, or r1 when
# none is served. Exact names are never rewritten.
#
# The verdict asks the registry what this series owes the run, comparing the four
# build pins and the declared architectures at the newest revision:
#   SKIP      the series already is the build this run would have made;
#   COMPLETE  a revision started and some variant is missing, so finish it;
#   PUBLISH   a served name has moved pins, an unreadable record, or a missing
#             architecture, so the whole series goes one revision higher.
# The full model is in MAINTAINING.md. Each leg also carries the list of variants
# to build: every declared variant for a PUBLISH, and for a COMPLETE only the
# variants the registry does not already serve at that revision -- a current
# variant rebuilt anyway would push per-architecture digests that the callee then
# declines to name, which is compute spent to produce registry litter.
#
# Registry access is read-only and primary-only; the Docker Hub mirror is a copy
# and is never read here. --repair emits the names the primary already serves
# correctly, as a copy list for release.yml's mirror-repair job.
#
# Two registry answers are separated on purpose. A registry that will not answer
# (a refused token, a timeout, a body that is not a tag array) stops the run: a
# revision cannot be derived from a read that failed. A registry that answers
# that it has nothing (HTTP 404 NAME_UNKNOWN, or an empty tags array) is a
# readable namespace, and every selected series is then planned from r1 -- that
# is what a first release, or a package the owner deleted, looks like. The
# notice on stderr says which of the two it saw, and asks the reader to confirm
# the namespace, because a misspelled repository answers the same way.
# REGISTRY_READ_TOKEN, when the caller sets it, is used as the password of the
# pull-token exchange: release.yml passes its own job token, which is what reads
# a package that exists but is still private.
#
# Usage:
#   tools/release-plan.sh [--scope all|<series>[,<series>...]] [options]
#     --scope VAL       what this run selected (default: all)
#     --registry VAL    registry host (default: ghcr.io)
#     --namespace VAL   GHCR owner hosting the "php" image (default: muffetlab)
#     --json            emit only the legs to build, as a JSON array on stdout
#     --repair          emit only the names the primary already serves correctly,
#                       as a JSON array for the mirror repair job
#     --state-out FILE  write the registry state this run read (log and tests)
#     --state-in FILE   decide from a captured state instead of the live registry
#     -h, --help        this usage
# Environment: REGISTRY_READ_TOKEN authenticates the pull-token exchange when set.
# Exit status: 0 when every selected series was planable; 1 on a bad scope, an
# unreachable or refusing registry, a missing manifest field or an unreadable
# series.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORTED_VERSIONS="${SUPPORTED_VERSIONS:-5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1}"
# The architectures a published name must carry. build-version.yml's build
# matrix is what produces them, so this list is a restatement of that matrix
# rather than an independent choice, and tools/check-image-name.sh holds the two
# together -- drift between them would read every published image as missing an
# architecture and bump every series on every release. The value is the OCI
# platform string a manifest list entry uses, because that is what this script
# compares.
ARCHITECTURES="${ARCHITECTURES:-linux/amd64 linux/arm64}"
REGISTRY="ghcr.io"
NAMESPACE="muffetlab"
SCOPE="all"
EMIT_JSON=0
EMIT_REPAIR=0
STATE_IN=""
STATE_OUT=""
REGISTRY_TIMEOUT="${REGISTRY_TIMEOUT:-30}"
MANIFEST_DIR="${MANIFEST_DIR:-${ROOT}/manifests}"

die() { echo "release-plan: $*" >&2; exit 1; }

usage() { sed -n '/^# Usage:/,/^# Exit status:/p' "$0" | sed '1d;$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)     [ $# -ge 2 ] || die "--scope needs a value"; SCOPE="$2"; shift 2 ;;
    --registry)  [ $# -ge 2 ] || die "--registry needs a value"; REGISTRY="$2"; shift 2 ;;
    --namespace) [ $# -ge 2 ] || die "--namespace needs a value"; NAMESPACE="$2"; shift 2 ;;
    --json)      EMIT_JSON=1; shift ;;
    --repair)    EMIT_REPAIR=1; shift ;;
    --state-out) [ $# -ge 2 ] || die "--state-out needs a value"; STATE_OUT="$2"; shift 2 ;;
    --state-in)  [ $# -ge 2 ] || die "--state-in needs a value"; STATE_IN="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done
command -v jq >/dev/null || die "jq is required"
if [ -n "$STATE_IN" ] && [ -n "$STATE_OUT" ]; then
  die "--state-out and --state-in cannot be combined: a captured state is not a registry read"
fi
# Two outputs are two answers to one question, and a caller that got both would
# have to guess which one the run acted on. They are asked for by different
# callers on purpose: release.yml's matrix pass wants the legs to build, its
# mirror pass wants the names the primary already serves.
if [ "$EMIT_JSON" = 1 ] && [ "$EMIT_REPAIR" = 1 ]; then
  die "--json and --repair cannot be combined: one run emits one list, and a caller that reads both is asking the registry twice"
fi

REPO="${NAMESPACE}/php"

# --- the selection -----------------------------------------------------------
# An empty selection is refused rather than read as "everything" or "nothing":
# the first publishes eight series by accident, the second finishes green with
# no image behind it.
scope_series=()
given_scope=""
plan_scope() {
  local raw="$1" item
  given_scope="$raw"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$raw" ] ||
    die "no release scope was given ('all', or a list of PHP series); refusing to plan an empty selection"
  if [ "$raw" = "all" ]; then
    # shellcheck disable=SC2206  # splitting the supported list into words is the point
    scope_series=($SUPPORTED_VERSIONS)
    return
  fi
  raw="$(printf '%s' "$raw" | tr ',' ' ')"
  # shellcheck disable=SC2086  # splitting the caller's list into words is the point
  for item in $raw; do
    case " $SUPPORTED_VERSIONS " in
      *" $item "*) scope_series+=("$item") ;;
      *) die "scope selects '$item', which is not a supported PHP series (supported: $SUPPORTED_VERSIONS)" ;;
    esac
  done
  [ "${#scope_series[@]}" -gt 0 ] || die "scope '$given_scope' selected no PHP series"
}

# --- manifest reads ----------------------------------------------------------
manifest_field() { # <series> <KEY>
  sed -n "s/^$2=\"\(.*\)\"/\1/p" "${MANIFEST_DIR}/$1.env" | head -1
}

# --- registry reads ----------------------------------------------------------
# A pull token for the namespace this plan reads. The read is anonymous unless
# the caller supplies one: release.yml passes its own job token in
# REGISTRY_READ_TOKEN, which is what lets a run read a package that exists but
# is still private (GHCR creates every package private, and the visibility job
# runs after the matrix) or one the owner has deleted. A refused exchange stays
# a refusal: no revision is ever derived from a registry that would not answer.
# The body a refusal message quotes: bounded so a registry error page cannot
# bury the log, and cut before the newline fold so a trailing newline does not
# reach the token reader's jq.
brief_of() { # <file>
  head -c 2000 "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

pull_token() {
  local auth=() file code tok brief
  if [ -n "${REGISTRY_READ_TOKEN:-}" ]; then
    auth=(-u "getter:${REGISTRY_READ_TOKEN}")
  fi
  file="$(mktemp)"
  code="$(curl -sS --max-time "$REGISTRY_TIMEOUT" -o "$file" -w '%{http_code}' \
    ${auth[@]+"${auth[@]}"} \
    "https://${REGISTRY}/token?service=${REGISTRY}&scope=repository:${REPO}:pull" 2>&1)" || {
    rm -f "$file"
    die "the pull token request for ${REGISTRY}/${REPO} did not reach https://${REGISTRY}/token: ${code}"
  }
  brief="$(brief_of "$file")"
  case "$code" in
    2??) ;;
    401 | 403)
      rm -f "$file"
      die "the registry refused a pull token for ${REGISTRY}/${REPO} (HTTP ${code}): ${brief:-no body}. A registry that will not answer is not a reason to guess a revision" ;;
    *)
      rm -f "$file"
      die "the pull token request for ${REGISTRY}/${REPO} answered HTTP ${code}: ${brief:-no body}" ;;
  esac
  tok="$(jq -e -r '.token // empty' <"$file" 2>/dev/null)" || {
    rm -f "$file"
    die "the pull token response for ${REGISTRY}/${REPO} was not a JSON object with a token (HTTP ${code})"
  }
  rm -f "$file"
  [ -n "$tok" ] ||
    die "the pull token response for ${REGISTRY}/${REPO} carried an empty token (HTTP ${code})"
  printf '%s' "$tok"
}

# Every tag, following a Link: rel="next" if the registry paginates the list.
# Registries emit that Link as either an absolute path
# (/v2/<repo>/tags/list?...) or a full https://host/path, so both are reduced to
# one path on the registry this run is already talking to; anything else is
# ignored rather than followed.
#
# Two answers mean "this namespace publishes nothing": HTTP 404 NAME_UNKNOWN on
# the first page, which is the registry saying it knows no such repository, and
# HTTP 200 with an empty tags array, which is it saying the repository has no
# tags. Both leave REPO_UNKNOWN/empty tags for the caller to report, and both are
# reads that succeeded -- a deleted or freshly created package is the normal
# state a first release starts from, and the revision rule ("one above the
# highest -r<N> served, r1 when none is served") answers it directly. Any other
# code, an unreadable body, or a 404 that does not name NAME_UNKNOWN is a failed
# read and dies: the difference between "nothing is published" and "I was not
# told" is the whole rule, so only the exact answer is accepted as the first one.
fetch_tags() { # <token>
  local tok="$1" path="/v2/${REPO}/tags/list" hdr body link next code first=1
  hdr="$(mktemp)"
  body="$(mktemp)"
  while :; do
    code="$(curl -sS -L --max-time "$REGISTRY_TIMEOUT" -D "$hdr" -o "$body" \
      -w '%{http_code}' -H "Authorization: Bearer ${tok}" \
      "https://${REGISTRY}${path}" 2>&1)" || {
      rm -f "$hdr" "$body"
      die "could not list tags at https://${REGISTRY}/${REPO}: ${code}"
    }
    case "$code" in
      200) ;;
      404)
        if [ "$first" = 1 ] &&
          jq -e -r '.errors[]?.code' "$body" 2>/dev/null | grep -qx NAME_UNKNOWN; then
          REPO_UNKNOWN=1
          rm -f "$hdr" "$body"
          return 0
        fi
        rm -f "$hdr" "$body"
        die "the tag list for ${REGISTRY}/${REPO} answered HTTP 404 without naming NAME_UNKNOWN: $(brief_of "$body")" ;;
      *)
        rm -f "$hdr" "$body"
        die "the tag list for ${REGISTRY}/${REPO} answered HTTP ${code}: $(brief_of "$body")" ;;
    esac
    jq -e '(.tags | type) == "array"' <"$body" >/dev/null || {
      rm -f "$hdr" "$body"
      die "the tag list from ${REGISTRY}/${REPO} did not carry a tags array (HTTP ${code}): $(brief_of "$body")"
    }
    jq -r '.tags[]?' <"$body" >>"$TAGS_FILE"
    link="$(tr -d '\r' <"$hdr" |
      awk 'BEGIN{IGNORECASE=1} tolower($1)=="link:"{sub(/^[^:]*:[ \t]*/,""); print; exit}')"
    first=0
    case "$link" in *'rel="next"'*) ;; *) break ;; esac
    next="$(printf '%s' "$link" | sed -n 's|.*<\([^>]*\)>;[ \t]*rel="next".*|\1|p')"
    [ -n "$next" ] || break
    next="${next#https://}"
    next="${next#http://}"
    next="${next#"$REGISTRY"}"
    case "$next" in /*) ;; *) break ;; esac
    path="$next"
  done
  rm -f "$hdr" "$body"
}

# One read of one published tag: what its build record says and what
# architectures its manifest list carries. The index picks an amd64 leg (every
# published name is a multi-arch list and each leg carries one build record),
# that leg's manifest points at the config blob, and the blob's Labels map holds
# the pins. Every read follows redirects: the object storage behind GHCR answers
# a manifest or blob GET with a 307 to another host, and without -L that answer
# is a zero-byte body -- which would read here as "this image has no build
# record" and re-publish a current series. The platform list is taken from the
# same index read as the labels on purpose. Attestation entries are dropped:
# buildx attaches provenance and SBOM manifests to the index with a platform of
# unknown/unknown, and they are not architectures a puller can resolve, so
# counting them would let a one-architecture image pass. An empty answer means
# "nothing readable", which the caller treats as a difference, not as an
# agreement.
fetch_record() { # <token> <tag>
  local tok="$1" tag="$2" doc cfg platforms labels
  doc="$(curl -fsSL --max-time "$REGISTRY_TIMEOUT" -H "Authorization: Bearer ${tok}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://${REGISTRY}/v2/${REPO}/manifests/${tag}" 2>/dev/null)" || return 0
  platforms="$(printf '%s' "$doc" | jq -c '[.manifests[]? | select(.platform != null) |
      select((.platform.architecture // "unknown") != "unknown") |
      "\(.platform.os)/\(.platform.architecture)"]' 2>/dev/null)" || platforms=""
  [ -n "$platforms" ] || platforms='[]'
  cfg="$(printf '%s' "$doc" | jq -r '
    if .manifests then
      ([.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest
       // .manifests[0].digest)
    else .config.digest end // empty')" || cfg=""
  [ -n "$cfg" ] || return 0
  doc="$(curl -fsSL --max-time "$REGISTRY_TIMEOUT" -H "Authorization: Bearer ${tok}" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://${REGISTRY}/v2/${REPO}/manifests/${cfg}" 2>/dev/null)" || return 0
  cfg="$(printf '%s' "$doc" | jq -r '.config.digest // empty')" || cfg=""
  [ -n "$cfg" ] || return 0
  labels="$(curl -fsSL --max-time "$REGISTRY_TIMEOUT" -H "Authorization: Bearer ${tok}" \
    -H 'Accept: application/vnd.oci.image.config.v1+json, application/vnd.docker.container.image.v1+json' \
    "https://${REGISTRY}/v2/${REPO}/blobs/${cfg}" 2>/dev/null |
    jq -c '.config.Labels // .config.labels // {}' 2>/dev/null)" || return 0
  case "$labels" in
    '' | 'null') labels='{}' ;;
  esac
  printf '%s' "$labels" | jq -e 'type == "object"' >/dev/null || labels='{}'
  jq -cn --argjson labels "$labels" --argjson platforms "$platforms" \
    '{labels: $labels, platforms: $platforms}'
}

# --- the decision ------------------------------------------------------------
# Highest published revision for one PHP point version across the declared
# variants: -1 when the version has never been published under a revision at
# all, otherwise the highest -r<N> seen. A name without -r<N> in it is not a
# revision and is not counted: the pipeline writes no such name, so reading one
# would put the plan's answer somewhere the counting rule cannot reach again.
highest_revision() { # <php> <variant>...
  local php="$1"
  shift
  local max=-1 esc v n
  esc="$(printf '%s' "$php" | sed 's/\./\\./g')"
  for v in "$@"; do
    while IFS= read -r n; do
      if [ -n "$n" ] && [ "$n" -gt "$max" ]; then max="$n"; fi
    done < <(sed -n "s|^${esc}-r\([0-9][0-9]*\)-${v}\$|\1|p" "$TAGS_FILE")
  done
  printf '%s\n' "$max"
}

PIN_KEYS="dev.php-legacy.source-commit dev.php-legacy.source-ref dev.php-legacy.base-image dev.php-legacy.openssl-route"

# Compare the architectures a published manifest list carries with the ones this
# pipeline builds. Prints nothing when every declared platform is there, and one
# named gap per missing one. Extra platforms are not a gap: a name that carries
# an architecture this kit no longer builds still resolves correctly everywhere
# it claims to, and moving the declared set down is a reviewed change to
# ARCHITECTURES that will be published as the next revision anyway.
compare_platforms() { # <platforms-json>
  local have="$1" arch out=""
  case "$have" in
    '' | 'null') have='[]' ;;
  esac
  # shellcheck disable=SC2086  # the declared platforms are a space-separated list
  for arch in $ARCHITECTURES; do
    if ! printf '%s' "$have" | jq -e --arg p "$arch" 'index($p) != null' >/dev/null 2>&1; then
      out="${out}${arch} absent from the published manifest list; "
    fi
  done
  printf '%s' "$out"
}

# Compare one published image with the manifest: its build record and its
# architecture set, in that order, as one difference string. Empty means the
# published name is the build this run would have made.
compare_record() { # <record-json> <series>
  local rec="$1" series="$2" labels platforms
  case "$rec" in
    '' | 'null') printf 'no readable build record\n'; return ;;
  esac
  labels="$(printf '%s' "$rec" | jq -c '.labels // {}' 2>/dev/null)" || labels='{}'
  platforms="$(printf '%s' "$rec" | jq -c '.platforms // []' 2>/dev/null)" || platforms='[]'
  printf '%s\n' "$(compare_pins "$labels" "$series")$(compare_platforms "$platforms")"
}

# Compare one published image's build record with the manifest. Prints nothing
# when they agree, and a named difference when they do not; an absent record is
# its own answer, because "the pins are unknown" is not "the pins match".
compare_pins() { # <labels-json> <series>
  local labels="$1" series="$2"
  case "$labels" in
    '' | 'null' | '{}') printf 'no build record\n'; return ;;
  esac
  local k want have diff=""
  for k in $PIN_KEYS; do
    case "$k" in
      *source-commit) want="$(manifest_field "$series" PHP_SRC_COMMIT)" ;;
      *source-ref)    want="$(manifest_field "$series" SOURCE_REF)" ;;
      *base-image)    want="$(manifest_field "$series" BASE_IMAGE)" ;;
      *openssl-route) want="$(manifest_field "$series" OPENSSL_ROUTE)" ;;
    esac
    have="$(printf '%s' "$labels" | jq -r --arg k "$k" '.[$k] // empty')"
    if [ -z "$have" ]; then
      diff="${diff}${k} absent from the published image; "
    elif [ "$have" != "$want" ]; then
      diff="${diff}${k} published as ${have} but the manifest pins ${want}; "
    fi
  done
  printf '%s\n' "$diff"
}

# One matrix leg: series, PHP version, the variants this leg is to build, image
# revision and the verdict that chose it. A `publish` leg is handed every variant
# the manifest declares; a `complete` leg is handed only the ones the registry does
# not already serve at that revision, because rebuilding a current variant would
# push digests the callee is going to decline. Both come through here, and the
# revision is checked on the way in because it is what makes the exact name
# immutable by pipeline rule. An empty value, a zero or a leading zero would name a
# build that the next run cannot count past, so it is refused rather than corrected
# -- the alternative is a published name whose successor is ambiguous. The mode
# travels with it because the same revision number means two different things to
# the callee: `publish` says the exact name at it must not exist, `complete`
# says an exact name that does exist there is a variant this release has already
# published.
emit_leg() { # <series> <php> <variants> <revision> <mode>
  case "$5" in
    publish | complete) ;;
    *) die "refusing to plan $1: unknown leg mode '$5'" ;;
  esac
  if ! printf '%s' "$4" | grep -Eq '^[1-9][0-9]*$'; then
    die "refusing to plan $1: the derived revision '$4' is not a positive integer, and <php>-r$4-<variant> would not be a name a later run can count on"
  fi
  leg_lines+=("$1	$2	$3	$4	$5")
  publish_count=$((publish_count + 1))
}

# One mirror repair: a name the primary serves correctly, with the floating name
# that should point at it. This is not a verdict and it asks for no build -- it
# is the list of things the mirror is allowed to be brought up to by copying,
# which is exactly the set of names this run checked and found equal to the
# manifest. A name this run could not verify is deliberately absent: the mirror
# is not sent to copy an image whose inputs are in question, and the leg that
# republishes it writes both registries anyway.
emit_repair() { # <series> <php> <variant> <revision> <exact>
  repair_lines+=("$1	$2	$3	$4	$5	${1}-${3}")
  repair_count=$((repair_count + 1))
}

plan_scope "$SCOPE"

if [ -n "$STATE_IN" ]; then
  [ -f "$STATE_IN" ] || die "--state-in '$STATE_IN' is not a file"
  jq -e '(.tags | type == "array") and (.images | type == "object") and
    all(.images[]; . == null or (type == "object" and has("labels") and has("platforms")))' \
    "$STATE_IN" >/dev/null ||
    die "--state-in '$STATE_IN' is not a captured release-plan state: it needs a .tags array and an .images object whose every value is null or a {labels, platforms} record -- a capture from before the architecture set was compared cannot decide a platform gap, so it is refused rather than read as one"
fi

TAGS_FILE="$(mktemp)"
trap 'rm -f "$TAGS_FILE"' EXIT
CAPTURED_IMAGES='{}'
STATE_IMAGES='{}'
REPO_UNKNOWN=0
CAPTURED_ANSWER=""
TOK=""
if [ -n "$STATE_IN" ]; then
  jq -r '.tags[]' "$STATE_IN" >"$TAGS_FILE"
  STATE_IMAGES="$(jq -c '.images' "$STATE_IN")"
  CAPTURED_ANSWER="$(jq -r '.registry_state // empty' "$STATE_IN")"
else
  TOK="$(pull_token)"
  fetch_tags "$TOK"
fi

# An empty namespace is a readable answer, not a failed read: it is what a first
# release to a name looks like, and what a package the owner deleted leaves
# behind. The old refusal here made that state unplannable, and the pipeline
# could not come back from a wipe because making the registry readable again is
# the publish this step gates. The two answers that mean it are separated above
# (an unknown repository, an empty tag list) from the ones that do not (a
# refusal, a timeout, a body that is not a tag array), and the rule the write
# side holds -- a publish leg asks the primary whether it already serves the
# exact name before it pushes -- is what makes a wrong "empty" here cost compute
# rather than names.
REGISTRY_EMPTY=""
if [ "$REPO_UNKNOWN" = 1 ]; then
  REGISTRY_EMPTY="${REGISTRY}/${REPO} answered HTTP 404 NAME_UNKNOWN: the registry knows no such repository, so it serves no names"
elif [ -n "$CAPTURED_ANSWER" ] && [ "$CAPTURED_ANSWER" != served ]; then
  REGISTRY_EMPTY="${REGISTRY}/${REPO} was captured answering ${CAPTURED_ANSWER}, so it served no names"
elif [ ! -s "$TAGS_FILE" ]; then
  REGISTRY_EMPTY="${REGISTRY}/${REPO} answered with an empty tag list: it serves no names"
fi
if [ -n "$REGISTRY_EMPTY" ]; then
  printf 'release-plan: NOTICE %s. Every selected series is therefore planned from r1. Before letting the run push, check that %s is the namespace this release means: a misspelled one answers the same way, and the run would then create that package instead of reading this one\n' \
    "$REGISTRY_EMPTY" "${REGISTRY}/${REPO}" >&2
fi

# The shape of the namespace belongs to the verdict, not to a document: every
# document that names a tag to pull states that no `latest` tag is published, so
# a name a manual push left behind has to stop the run instead of sitting under
# that claim. The tag list is already here, read once whether live or captured,
# so the claim is checked where the read happens and a replayed capture answers
# the same question about the same namespace.
stray_latest="$(grep -E '^latest(-|$)' "$TAGS_FILE" | LC_ALL=C sort | tr '\n' ' ' || true)"
if [ -n "${stray_latest// /}" ]; then
  die "${REGISTRY}/${REPO} serves ${stray_latest}; no release writes a name of that shape, and README, DEPLOYING.md, SUPPORTED.md and MAINTAINING.md all state that no latest tag is published, so either the name goes or the documents stop saying that -- the plan stops rather than hand a matrix to a run beside a contradicted claim"
fi

leg_lines=()
repair_lines=()
report=()
publish_count=0
skip_count=0
repair_count=0

for series in "${scope_series[@]}"; do
  [ -f "${MANIFEST_DIR}/${series}.env" ] || die "manifests/${series}.env is missing"
  php="$(manifest_field "$series" SOURCE_REF)"
  variants_raw="$(manifest_field "$series" BUILD_VARIANTS)"
  approved="$(manifest_field "$series" PATCHSET_APPROVED)"
  [ -n "$php" ] || die "manifests/${series}.env has no SOURCE_REF; the PHP version must come from the manifest"
  [ -n "$variants_raw" ] || die "manifests/${series}.env declares no BUILD_VARIANTS"
  # shellcheck disable=SC2206  # the declared variants are a space-separated list
  variants=($variants_raw)

  if [ "$approved" != "1" ]; then
    report+=("SKIP ${series} (${php}): PATCHSET_APPROVED=${approved:-unset} -- the review gate is human, and release.yml's readiness step refuses a run that selects this series")
    skip_count=$((skip_count + 1))
    continue
  fi

  max="$(highest_revision "$php" "${variants[@]}")"
  if [ "$max" = "-1" ]; then
    report+=("PUBLISH ${series} (${php}) as r1 [first build]: ${REGISTRY}/${REPO} has no exact name for this PHP version")
    emit_leg "$series" "$php" "$variants_raw" 1 publish
    continue
  fi

  where="at r${max}"

  # One verdict per declared variant, taken at the newest revision this PHP
  # version has. The three states are not interchangeable, and reading them as a
  # single "does everything match" question is what made a retry of a
  # half-published release either rewrite a name that is already served or invent
  # a revision nobody asked for:
  #   current  -- the name is served, its four pins equal the manifest's and its
  #               manifest list carries every declared architecture, so this
  #               variant is already the product of this release;
  #   absent   -- the name is not served at all, which is the half of a release
  #               that failed after another half had already merged. The number
  #               it failed under is the number it is finished at;
  #   unusable -- the name is served, but its pins differ from the manifest, its
  #               build record cannot be read, or it does not carry every
  #               declared architecture. "unknown" is not "equal", a missing
  #               architecture is not a smaller image of the same build, and an
  #               image whose inputs moved is not this build under another number
  #               -- it is the next build, so this is the one state that ends a
  #               revision and starts a new one.
  current="" absent="" absent_variants="" unusable=""
  for v in "${variants[@]}"; do
    name="${php}-r${max}-${v}"
    if ! grep -Fqx -- "$name" "$TAGS_FILE"; then
      absent="${absent}${name} "
      absent_variants="${absent_variants}${v} "
      continue
    fi
    if [ -n "$STATE_IN" ]; then
      rec="$(printf '%s' "$STATE_IMAGES" | jq -c --arg t "$name" '.[$t] // empty')"
    else
      rec="$(fetch_record "$TOK" "$name")"
    fi
    if [ -n "$STATE_OUT" ]; then
      # A capture keeps the shape the live read returns, or the next pass -- the
      # matrix, the mirror list, the tests -- would be deciding from a record
      # that cannot answer the architecture question it is asked. An unreadable
      # name is captured as null, which is the same answer both paths give it:
      # not equal.
      CAPTURED_IMAGES="$(printf '%s' "$CAPTURED_IMAGES" |
        jq -c --arg t "$name" --arg l "${rec:-null}" '
          . + {($t): (if $l == "null" then null else
             ($l | fromjson? // {}) as $r
             | {labels: ($r.labels // {}), platforms: ($r.platforms // [])}
           end)}')"
    fi
    one="$(compare_record "$rec" "$series")"
    if [ -z "$one" ]; then
      current="${current}${name} "
      emit_repair "$series" "$php" "$v" "$max" "$name"
    else
      unusable="${unusable}${name}: ${one}"
    fi
  done

  if [ -z "$absent" ] && [ -z "$unusable" ]; then
    report+=("SKIP ${series} (${php}): already published ${where} -- source commit, source ref, base digest and route all match on ${variants_raw}")
    skip_count=$((skip_count + 1))
    continue
  fi

  # A moved pin, or a build record that cannot be read, means the inputs behind
  # this revision are no longer the inputs the manifest declares. The whole
  # series is rebuilt one revision on -- both variants, not just the one that
  # looks different -- so r<N> keeps meaning one reviewed build of a PHP version
  # rather than a per-variant counter nobody can read off a name.
  if [ -n "$unusable" ]; then
    next=$((max + 1))
    report+=("PUBLISH ${series} (${php}) as r${next} [new build]: ${unusable% }")
    emit_leg "$series" "$php" "$variants_raw" "$next" publish
    continue
  fi

  # Absences only, so this run finishes the release that revision started: the
  # number stays where it is, the missing variants are built at it, and the
  # names already served there are left exactly as they are. The callee is told
  # this is a completion, which is what turns "that exact name exists" from a
  # conflict into that variant being already done.
  #
  # The leg is handed the missing variants and nothing else. Handing it the whole
  # declared list would rebuild the variant this read just called current, push
  # its per-architecture digests, and then watch the callee decline them -- an
  # exact name is never rewritten -- so the run would spend a full PHP compile to
  # leave behind two digests no tag will ever point at. What the completion needs
  # from the registry is already there; this builds only what is not.
  report+=("PUBLISH ${series} (${php}) as r${max} [completion]: missing at r${max}: ${absent% } -- already published and matching there: ${current% } -- this run finishes that revision instead of starting the next")
  emit_leg "$series" "$php" "${absent_variants% }" "$max" complete
done

if [ "$EMIT_REPAIR" = 1 ]; then
  if [ "${#repair_lines[@]}" = 0 ]; then
    printf '[]\n'
  else
    printf '%s\n' "${repair_lines[@]}" |
      jq -Rsc '[split("\n")[] | select(. != "") | split("\t") |
        {series: .[0], php: .[1], variant: .[2], revision: .[3], exact: .[4], floating: .[5]}]'
  fi
elif [ "$EMIT_JSON" = 1 ]; then
  if [ "${#leg_lines[@]}" = 0 ]; then
    printf '[]\n'
  else
    printf '%s\n' "${leg_lines[@]}" |
      jq -Rsc '[split("\n")[] | select(. != "") | split("\t") | {series: .[0], php: .[1], variants: .[2], revision: .[3], mode: .[4]}]'
  fi
else
  if [ "${#report[@]}" != 0 ]; then
    printf '%s\n' "${report[@]}"
  fi
  printf 'release-plan: %d to publish, %d already current, of %d selected (%s)\n' \
    "$publish_count" "$skip_count" "${#scope_series[@]}" "$given_scope"
  if [ "$repair_count" != 0 ]; then
    printf 'release-plan: %d name(s) the primary serves correctly -- --repair lists them for the mirror, which copies them instead of rebuilding anything\n' "$repair_count"
  fi
fi

if [ -n "$STATE_OUT" ]; then
  ANSWER_KIND=served
  if [ "$REPO_UNKNOWN" = 1 ]; then
    ANSWER_KIND=unknown
  elif [ ! -s "$TAGS_FILE" ]; then
    ANSWER_KIND=empty
  fi
  jq -n --arg registry "$REGISTRY" --arg repo "$REPO" --arg answer "$ANSWER_KIND" \
    --argjson images "$CAPTURED_IMAGES" \
    --slurpfile tags <(jq -Rsc 'split("\n") | map(select(. != ""))' <"$TAGS_FILE") \
    '{registry: $registry, repo: $repo, registry_state: $answer, captured_at: (now | todate), tags: $tags[0], images: $images}' >"$STATE_OUT"
  echo "release-plan: captured the registry state this run read into ${STATE_OUT}" >&2
fi
