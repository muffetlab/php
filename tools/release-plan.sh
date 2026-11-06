#!/usr/bin/env bash
# Release plan -- the one place that turns a release selection into a concrete
# build matrix: the PHP version, the image revision and the publish, complete
# or skip verdict, per series.
#
# Three entries feed it (MAINTAINING.md, "Publishing images"): a source release
# tag (every supported series), a single-series dispatch, and a multi-series or
# `all` dispatch. All three come through here so no published name is ever
# composed from two different readings of the same fact.
#
# Where each part of a published name comes from:
#   - the PHP version is SOURCE_REF in manifests/<series>.env -- never a git tag
#     name and never a dispatch input;
#   - the image revision is read out of the registry: one higher than the
#     highest -r<N> already published for that PHP *point version*, counted
#     across every variant the series declares. Each point version counts on its
#     own, because a revision distinguishes two builds of one version, not two
#     releases of this kit. A bare <full>-<variant> name -- published before the
#     revision existed -- reads as 0, so the first name proposed for it is r1;
#   - the exact name is a snapshot: a revision is never reused for a second build
#     of the same inputs, and a name the registry already serves is never
#     rewritten -- not here when the revision is picked, and not again by the
#     callee at write time.
#
# The verdict answers "what does this series owe this run?" by asking the
# registry, not a local note: the four pins every build labels into its config
# (dev.php-legacy.source-commit, dev.php-legacy.source-ref,
# dev.php-legacy.base-image, dev.php-legacy.openssl-route) and the architecture
# set its manifest list carries are compared with the manifest per declared
# variant, at the newest revision this PHP point version has. There are three answers, and telling them apart is what makes a failed
# release safe to retry:
#   SKIP      -- every declared variant is served at that revision with all four
#               pins equal and every declared architecture in its manifest list,
#               so this series already is the build this run would have made and
#               is left alone;
#   COMPLETE  -- some declared variant is not served at all, and none that is
#               served has a moved pin or a missing architecture. That is a run
#               that died after publishing part of one revision, so the revision
#               it failed under is the revision it is finished at: the missing
#               variants are built at it and the names already served there are
#               not touched;
#   PUBLISH   -- a served name whose pins differ from the manifest, or whose
#               build record cannot be read at all ("unknown" is not "equal"),
#               or whose manifest list does not carry every architecture this
#               pipeline builds. A one-architecture name cannot be completed in
#               place: writing the second architecture means rewriting the list
#               that somebody has already pulled by that name, and an exact name
#               is never rewritten. So the gap is read as the content difference
#               it is, and the whole series -- both variants, not just the one
#               that looks different -- goes one revision higher, where a freshly
#               composed list carries both. r<N> keeps meaning one reviewed build
#               rather than a per-variant counter.
# A tag-triggered release whose inputs have not moved therefore publishes
# nothing and says so per series, instead of churning a new snapshot of an image
# that is already current.
#
# Registry access here is read-only, and it is access to ONE registry: the
# primary. A pull-scope anonymous token, manifest and config GETs. Nothing in
# this script writes to a registry, and it never replaces a review gate -- an
# unapproved manifest is reported as skipped, and release.yml's readiness step is
# what refuses the run.
#
# The Docker Hub mirror is deliberately not asked anything here. It is a copy, so
# it can be behind the primary without that changing what the primary should
# publish; comparing the two is a separate, non-building job (release.yml's
# mirror-repair). What that job needs is the same answer this script already
# computes -- which names the primary serves correctly -- so --repair emits them:
# every variant this run found current, with the exact name and the floating name
# that points at it. A mirror repair is a copy list, not a second verdict, and
# both passes read the one captured state rather than the registry twice.
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
# Exit status: 0 when every selected series was planable; 1 on a bad scope, an
# unreachable registry, a missing manifest field or an unreadable series.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORTED_VERSIONS="${SUPPORTED_VERSIONS:-5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1}"
# The architectures a published name must carry. build-version.yml's build matrix
# is what produces them, so this list is a restatement of that matrix rather than
# an independent choice, and tools/check-image-name.sh holds the two together --
# drift between them would read every published image as missing an architecture
# and bump every series on every release. The value is the OCI platform string a
# manifest list entry uses, because that is what this script compares.
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
pull_token() {
  curl -fsSL --max-time "$REGISTRY_TIMEOUT" \
    "https://${REGISTRY}/token?scope=repository:${REPO}:pull" | jq -e -r .token
}

# Every tag, following a Link: rel="next" if the registry paginates the list.
# Registries emit that Link as either an absolute path (/v2/<repo>/tags/list?...)
# or a full https://host/path, so both are reduced to one path on the registry
# this run is already talking to; anything else is ignored rather than followed.
fetch_tags() { # <token>
  local tok="$1" path="/v2/${REPO}/tags/list" headers link next body
  while :; do
    body="$(mktemp)"
    headers="$(curl -fsSL --max-time "$REGISTRY_TIMEOUT" -D- -o "$body" \
      -H "Authorization: Bearer ${tok}" "https://${REGISTRY}${path}")" || {
      rm -f "$body"
      die "could not list tags at https://${REGISTRY}/${REPO}"
    }
    jq -e -r '.tags[]?' <"$body" >>"$TAGS_FILE" || {
      rm -f "$body"
      die "the tag list from ${REGISTRY}/${REPO} did not parse as a tag array"
    }
    rm -f "$body"
    link="$(printf '%s\n' "$headers" | tr -d '\r' |
      awk 'BEGIN{IGNORECASE=1} tolower($1)=="link:"{sub(/^[^:]*:[ \t]*/,""); print; exit}')"
    case "$link" in *'rel="next"'*) ;; *) break ;; esac
    next="$(printf '%s' "$link" | sed -n 's|.*<\([^>]*\)>;[ \t]*rel="next".*|\1|p')"
    [ -n "$next" ] || break
    next="${next#https://}"
    next="${next#http://}"
    next="${next#"$REGISTRY"}"
    case "$next" in /*) ;; *) break ;; esac
    path="$next"
  done
}

# One read of one published tag: what its build record says and what
# architectures its manifest list carries. The index picks an amd64 leg (every
# published name is a multi-arch list and each leg carries one build record),
# that leg's manifest points at the config blob, and the blob's Labels map holds
# the pins. Every read follows redirects: the object storage behind GHCR answers
# a manifest or blob GET with a 307 to another host, and without -L that answer is
# a zero-byte body -- which would read here as "this image has no build record"
# and re-publish a current series.
# The platform list is taken from the same index read as the labels on purpose.
# Attestation entries are dropped: buildx attaches provenance and SBOM manifests
# to the index with a platform of unknown/unknown, and they are not architectures
# a puller can resolve, so counting them would let a one-architecture image pass.
# An empty answer means "nothing readable", which the caller treats as a
# difference, not as an agreement.
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
# variants: -1 when the version has never been published at all, 0 when only the
# bare pre-revision names exist, otherwise the highest -r<N> seen.
highest_revision() { # <php> <variant>...
  local php="$1"
  shift
  local max=-1 esc v n
  esc="$(printf '%s' "$php" | sed 's/\./\\./g')"
  for v in "$@"; do
    if grep -Fqx -- "${php}-${v}" "$TAGS_FILE"; then
      [ "$max" -gt 0 ] || max=0
    fi
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

# One matrix leg: series, PHP version, declared variants, image revision and the
# verdict that chose it. Both publish paths come through here, and the revision is
# checked on the way in because it is what makes the exact name immutable. An
# empty value, a zero or a leading zero would name a build that the next run
# cannot count past, so it is refused rather than corrected -- the alternative is
# a published name whose successor is ambiguous. The mode travels with it because
# the same revision number means two different things to the callee: `publish`
# says the exact name at it must not exist, `complete` says an exact name that
# does exist there is a variant this release has already published.
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
# that should point at it. This is not a verdict and it asks for no build -- it is
# the list of things the mirror is allowed to be brought up to by copying, which
# is exactly the set of names this run checked and found equal to the manifest. A
# name this run could not verify is deliberately absent: the mirror is not sent to
# copy an image whose inputs are in question, and the leg that republishes it
# writes both registries anyway.
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
TOK=""
if [ -n "$STATE_IN" ]; then
  jq -r '.tags[]' "$STATE_IN" >"$TAGS_FILE"
  STATE_IMAGES="$(jq -c '.images' "$STATE_IN")"
else
  TOK="$(pull_token)"
  fetch_tags "$TOK"
fi
[ -s "$TAGS_FILE" ] ||
  die "${REGISTRY}/${REPO} answered with no tags at all; nothing can be planned from an empty answer"

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

  if [ "$max" = "0" ]; then
    where="as the bare ${php}-<variant> names, published before revisions existed"
  else
    where="at r${max}"
  fi

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
  current="" absent="" unusable=""
  for v in "${variants[@]}"; do
    if [ "$max" = "0" ]; then
      name="${php}-${v}"
    else
      name="${php}-r${max}-${v}"
    fi
    if ! grep -Fqx -- "$name" "$TAGS_FILE"; then
      absent="${absent}${name} "
      continue
    fi
    if [ -n "$STATE_IN" ]; then
      rec="$(printf '%s' "$STATE_IMAGES" | jq -c --arg t "$name" '.[$t] // empty')"
    else
      rec="$(fetch_record "$TOK" "$name")"
    fi
    if [ -n "$STATE_OUT" ]; then
      # A capture keeps the shape the live read returns, or the next pass -- the
      # matrix, the mirror list, the tests -- would be deciding from a record that
      # cannot answer the architecture question it is asked. An unreadable name is
      # captured as null, which is the same answer both paths give it: not equal.
      CAPTURED_IMAGES="$(printf '%s' "$CAPTURED_IMAGES" |
        jq -c --arg t "$name" --arg l "${rec:-null}" '
          + {($t): (if $l == "null" then null else
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
  # number stays where it is, the missing variants are built at it, and the names
  # already served there are left exactly as they are. The callee is told this is
  # a completion, which is what turns "that exact name exists" from a conflict
  # into that variant being already done.
  #
  # The bare names are the one exception, and it is arithmetic rather than
  # judgement: there is no revision to reuse, and writing another bare name is
  # not available -- every name this pipeline writes from now on carries -r<N>.
  # So a half-finished pre-revision release is completed as r1, the first build
  # whose number exists.
  if [ "$max" = "0" ]; then
    report+=("PUBLISH ${series} (${php}) as r1 [first revisioned build]: ${absent% } was never published under a revision, and completing ${where} would mean writing a second bare name")
    emit_leg "$series" "$php" "$variants_raw" 1 publish
    continue
  fi

  report+=("PUBLISH ${series} (${php}) as r${max} [completion]: missing at r${max}: ${absent% } -- already published and matching there: ${current% } -- this run finishes that revision instead of starting the next")
  emit_leg "$series" "$php" "$variants_raw" "$max" complete
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
  jq -n --arg registry "$REGISTRY" --arg repo "$REPO" --argjson images "$CAPTURED_IMAGES" \
    --slurpfile tags <(jq -Rsc 'split("\n") | map(select(. != ""))' <"$TAGS_FILE") \
    '{registry: $registry, repo: $repo, captured_at: (now | todate), tags: $tags[0], images: $images}' >"$STATE_OUT"
  echo "release-plan: captured the registry state this run read into ${STATE_OUT}" >&2
fi
