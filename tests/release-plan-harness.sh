#!/bin/sh
# Stub harness for tools/release-plan.sh -- the version resolution every release
# entry point goes through.
#
# Why this exists: the other half of release-plan.sh (what GHCR actually serves)
# needs a network and published images, and CI's validate job has neither. The
# half that decides *what a run would publish* does not: given a fake manifests
# directory and a captured registry state, the revision arithmetic, the
# skip/complete/publish verdict and the exit code are all reproducible in
# milliseconds -- including the three verdicts that are easiest to get backwards:
# a series whose pins already match must NOT be re-published, a series whose
# published pins cannot be read must NOT be skipped, and a series that is
# half-published at its newest revision must be FINISHED at that revision rather
# than started one higher above a name somebody has already pulled.
#
# Usage: tests/release-plan-harness.sh
# Exit:  0 = every case behaved as expected, 1 = at least one did not.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RP="$ROOT/tools/release-plan.sh"
[ -r "$RP" ] || { echo "harness: missing $RP" >&2; exit 2; }
command -v jq >/dev/null || { echo "harness: jq is required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

passed=0
failed=0
case_ok=1
case_out=""
case_name=""

# --- fixtures -----------------------------------------------------------------
# Two series, one old and one current, and a scope short enough to read. The
# pins below are the contract between a manifest and a build record: the
# *values* are arbitrary, the *names* must stay the four release-plan.sh
# compares, and PHP_SRC_COMMIT is derived from the version so a moved commit and
# a moved version are distinguishable in the fixtures.
MANI="$WORK/manifests"
mkdir -p "$MANI"
BASE_MATCH='debian:trixie-slim@sha256:aaaa'
BASE_MOVED='debian:bookworm-slim@sha256:bbbb'

mk_manifest() { # <series> <php> <approved>
  cat >"$MANI/$1.env" <<EOF
BASE_IMAGE="$BASE_MATCH"
OPENSSL_ROUTE="openssl3"
PHP_SRC_REPO="https://github.com/shivammathur/php-src-backports.git"
SOURCE_REF="$2"
PHP_SRC_COMMIT="commit-$2"
BUILD_VARIANTS="cli fpm"
PATCHSET_APPROVED="$3"
EOF
}
mk_manifest 5.6 5.6.40 1
mk_manifest 8.1 8.1.34 1

# A build record that agrees with the manifest above on all four pins.
match_labels() { # <php>
  printf '{"dev.php-legacy.source-commit":"commit-%s","dev.php-legacy.source-ref":"%s","dev.php-legacy.base-image":"%s","dev.php-legacy.openssl-route":"openssl3"}' \
    "$1" "$1" "$BASE_MATCH"
}
# The same record after the base pin was moved under it -- the ordinary reason a
# series is rebuilt: the manifest changed, the published image did not.
moved_labels() { # <php>
  printf '{"dev.php-legacy.source-commit":"commit-%s","dev.php-legacy.source-ref":"%s","dev.php-legacy.base-image":"%s","dev.php-legacy.openssl-route":"openssl3"}' \
    "$1" "$1" "$BASE_MOVED"
}

# The capture shape one published name has in a state file: the build record the
# image labels into its own config, and the architecture list its manifest index
# carries. Both are read from the same index fetch by the live resolver, and a
# verdict needs both -- a name whose four pins match but which only carries amd64
# is not the build this pipeline would publish.
record() { # <labels-json>
  printf '{"labels":%s,"platforms":["linux/amd64","linux/arm64"]}' "$1"
}
# The same record with the architectures named by hand: the shorter list is the
# state of an image whose multi-arch merge published only part of the set, which
# the pins alone cannot see.
record_arch() { # <labels-json> <platform>...
  labels="$1"
  shift
  list=""
  for p in "$@"; do
    [ -z "$list" ] || list="${list},"
    list="${list}\"${p}\""
  done
  printf '{"labels":%s,"platforms":[%s]}' "$labels" "$list"
}
# Both helpers above take the labels map, so the two fixtures that name a pin
# difference keep producing exactly what they always did.
match_rec() { record "$(match_labels "$1")"; }
moved_rec() { record "$(moved_labels "$1")"; }

# state <file> [name=<record|null>]... -- a captured registry read. The tag list
# is the set of names, and each name's record is what the run fetched for it;
# `null` and "absent from the images map" both mean "the record could not be
# read", which the two of them exercise differently below.
state() {
  out="$1"
  shift
  {
    printf '{"registry":"ghcr.io","repo":"muffetlab/php","captured_at":"2026-11-06T00:00:00Z","tags":['
    first=1
    for kv in "$@"; do
      [ "$first" = 1 ] || printf ','
      printf '%s' "\"${kv%%=*}\""
      first=0
    done
    printf '],"images":{'
    first=1
    for kv in "$@"; do
      [ "$first" = 1 ] || printf ','
      printf '%s' "\"${kv%%=*}\":${kv#*=}"
      first=0
    done
    printf '}}'
  } >"$out"
  jq -e . "$out" >/dev/null || { echo "harness: built an invalid state fixture in $out" >&2; exit 2; }
}

# rp <name> <want-exit> [args...] -- run the planner over the fixture manifests
# with a short supported list, so `--scope all` means these two series.
rp() {
  name="$1"
  want="$2"
  shift 2
  case_ok=1
  case_name="$name"
  set +e
  case_out="$(SUPPORTED_VERSIONS="5.6 8.1" MANIFEST_DIR="$MANI" "$RP" "$@" 2>&1)"
  got=$?
  set -e
  if [ "$got" != "$want" ]; then
    case_ok=
    printf '     exit: want %s got %s\n' "$want" "$got"
  fi
}

# want <substring> -- must appear in the run's output
want() {
  if ! printf '%s\n' "$case_out" | grep -Fq -- "$1"; then
    case_ok=
    echo "     missing in output: $1"
  fi
}

# want_json <jq filter> -- must be true of the --json legs this run emitted
want_json() {
  if ! printf '%s\n' "$case_out" | tail -1 | jq -e "$1" >/dev/null 2>&1; then
    case_ok=
    echo "     legs JSON does not satisfy: $1"
    printf '%s\n' "$case_out" | tail -1 | sed -n 's/^/       | /p'
  fi
}

# want_not <substring> -- must NOT appear anywhere in the run's output. This is
# how the harness catches a series that was published anyway: the verdict line
# is exactly the symptom, not an absence.
want_not() {
  if printf '%s\n' "$case_out" | grep -Fq -- "$1"; then
    case_ok=
    echo "     present but must not be: $1"
  fi
}

finish() {
  if [ -n "$case_ok" ]; then
    passed=$((passed + 1))
    printf 'ok   rp-%s\n' "$case_name"
  else
    failed=$((failed + 1))
    printf 'FAIL rp-%s\n' "$case_name"
    printf '%s\n' "$case_out" | sed -n 's/^/       | /p' | tail -8
  fi
}

echo "== release-plan harness: revision arithmetic, publish/skip verdicts, scope errors"

# 1. A PHP version the registry has never served. The name is r1, not r0 and not
#    a bare name: this is the first published snapshot of that point version, so
#    there is no revision to reuse and nothing to complete.
T1="$WORK/never-published.json"
state "$T1" '8.1.34-cli=null'
rp never-published 0 --scope 5.6 --state-in "$T1"
want 'PUBLISH 5.6 (5.6.40) as r1 [first build]:'
want 'has no exact name for this PHP version'
want_not 'SKIP 5.6'
finish

# 2. Bare pre-revision names whose pins still agree. This is a tag-triggered
#    full release meeting a series that is already current: it must be skipped,
#    and the revision that would have been used has to appear in the report so
#    the reader can see *which* names were asked about.
T2="$WORK/bare-current.json"
state "$T2" \
  "5.6.40-cli=$(match_rec 5.6.40)" \
  "5.6.40-fpm=$(match_rec 5.6.40)" \
  '8.1.34-cli=null'
rp bare-current 0 --scope 5.6 --state-in "$T2"
want 'SKIP 5.6 (5.6.40): already published as the bare 5.6.40-<variant> names'
want_not 'PUBLISH 5.6'
finish

# 3. The same bare names with the base pin moved under them: r1 is the next
#    snapshot in new-build mode, because no -r name exists yet for this version
#    and what is served does not answer to this manifest.
T3="$WORK/bare-moved.json"
state "$T3" \
  "5.6.40-cli=$(moved_rec 5.6.40)" \
  "5.6.40-fpm=$(moved_rec 5.6.40)" \
  '8.1.34-cli=null'
rp bare-moved 0 --scope 5.6 --state-in "$T3"
want 'PUBLISH 5.6 (5.6.40) as r1 [new build]:'
want 'base-image published as'
want 'the manifest pins'
finish

# 4. Revision arithmetic across variants, and which verdict wins. cli is at r2
#    with a moved base pin, so the newest revision this version has is 2 and the
#    next is r3 -- never r2, which would overwrite the existing 5.6.40-r2-cli.
#    fpm has no name at r2 at all, but a moved pin anywhere outranks an absence:
#    the whole series is rebuilt one revision on, both variants, so r<N> keeps
#    meaning one reviewed build of a PHP version. The gap that leaves on the fpm
#    side is the honest cost of never rewriting a name somebody has pinned.
T4="$WORK/uneven-revisions.json"
state "$T4" \
  "5.6.40-r2-cli=$(moved_rec 5.6.40)" \
  "5.6.40-r1-fpm=$(moved_rec 5.6.40)" \
  '8.1.34-cli=null'
rp uneven-revisions 0 --scope 5.6 --state-in "$T4"
want 'PUBLISH 5.6 (5.6.40) as r3 [new build]:'
want '5.6.40-r2-cli:'
want_not '5.6.40-r2-fpm'
finish
rp uneven-revisions-json 0 --scope 5.6 --state-in "$T4" --json
want_json '.[0].revision == "3"'
want_json '.[0].mode == "publish"'
want_json '.[0].variants == "cli fpm"'
finish

# 5. One variant already current, the other moved. Any difference anywhere in
#    the series rebuilds the whole series; a per-variant skip would publish cli
#    at r3 and leave fpm pointing at an older pin under the same floating name.
T5="$WORK/split-variants.json"
state "$T5" \
  "5.6.40-r1-cli=$(match_rec 5.6.40)" \
  "5.6.40-r1-fpm=$(moved_rec 5.6.40)" \
  '8.1.34-cli=null'
rp split-variants 0 --scope 5.6 --state-in "$T5"
want 'PUBLISH 5.6 (5.6.40) as r2 [new build]:'
want '5.6.40-r1-fpm: dev.php-legacy.base-image'
want_not '5.6.40-r1-cli: dev.php-legacy'
finish

# 6. A declared variant that was never published at the newest revision while the
#    other one is already current there: the half-published release, a run that
#    merged cli's manifest list and failed before fpm's. The revision is reused,
#    not stepped past -- the pinset r1 was built from is exactly the one this
#    manifest declares, so the missing variant is built at r1 and the name
#    already served there is left alone. The mode is what tells the callee that
#    "5.6.40-r1-cli exists" is this release being finished, not a conflict.
T6="$WORK/missing-variant.json"
state "$T6" \
  "5.6.40-r1-cli=$(match_rec 5.6.40)" \
  '8.1.34-cli=null'
rp missing-variant 0 --scope 5.6 --state-in "$T6"
want 'PUBLISH 5.6 (5.6.40) as r1 [completion]:'
want 'missing at r1: 5.6.40-r1-fpm'
want 'already published and matching there: 5.6.40-r1-cli'
want_not 'as r2'
finish
rp missing-variant-json 0 --scope 5.6 --state-in "$T6" --json
want_json '.[0].revision == "1"'
want_json '.[0].mode == "complete"'
finish

# 6b. The same half-published shape among the bare pre-revision names, where
#     there is no revision to reuse. Completing it would mean writing a second
#     bare name, and every name this pipeline writes from now on carries -r<N>,
#     so the series starts its count at r1 instead -- in new-build mode, because
#     at r1 nothing is served yet.
T6B="$WORK/bare-partial.json"
state "$T6B" \
  "5.6.40-cli=$(match_rec 5.6.40)" \
  '8.1.34-cli=null'
rp bare-partial 0 --scope 5.6 --state-in "$T6B"
want 'PUBLISH 5.6 (5.6.40) as r1 [first revisioned build]:'
want 'was never published under a revision'
finish
rp bare-partial-json 0 --scope 5.6 --state-in "$T6B" --json
want_json '.[0].revision == "1"'
want_json '.[0].mode == "publish"'
finish

# 7. Both series fully current, so a tag-triggered full release publishes nothing.
#    The matrix must then be an empty array -- and the report, not silence, is
#    what tells the human that the run did its job by doing nothing.
T7="$WORK/all-current.json"
state "$T7" \
  "5.6.40-r1-cli=$(match_rec 5.6.40)" \
  "5.6.40-r1-fpm=$(match_rec 5.6.40)" \
  "8.1.34-r3-cli=$(match_rec 8.1.34)" \
  "8.1.34-r3-fpm=$(match_rec 8.1.34)"
rp all-current 0 --scope all --state-in "$T7"
want 'SKIP 5.6 (5.6.40): already published at r1'
want 'SKIP 8.1 (8.1.34): already published at r3'
want '0 to publish, 2 already current, of 2 selected (all)'
finish
rp all-current-json 0 --scope all --state-in "$T7" --json
want_json '. == []'
finish

# 8. Each point version counts on its own. 5.6 is at r1 and 8.1 has never been
#    published, so the batch is r2 for one and r1 for the other: a single
#    kit-wide revision number would either skip a version or relabel a current one.
T8="$WORK/per-version-counter.json"
state "$T8" \
  "5.6.40-r1-cli=$(moved_rec 5.6.40)" \
  "5.6.40-r1-fpm=$(moved_rec 5.6.40)"
rp per-version-counter 0 --scope all --state-in "$T8" --json
want_json 'length == 2'
want_json '.[] | select(.series == "5.6") | .revision == "2"'
want_json '.[] | select(.series == "8.1") | .revision == "1"'
want_json '[.[] | .php] | index("5.6.40") and index("8.1.34")'
want_json '.[0] | has("variants") and has("mode")'
finish

# 9. An unapproved manifest is reported and left out of the matrix. The refusal
#    itself is release.yml's readiness step, which runs before any build; the
#    planner's job is to never turn an unreviewed pinset into a leg.
mkdir -p "$WORK/unapproved"
cp "$MANI/8.1.env" "$WORK/unapproved/8.1.env"
sed 's/^PATCHSET_APPROVED=.*/PATCHSET_APPROVED="0"/' "$MANI/5.6.env" >"$WORK/unapproved/5.6.env"
case_name="unapproved"
case_ok=1
set +e
case_out="$(SUPPORTED_VERSIONS="5.6 8.1" MANIFEST_DIR="$WORK/unapproved" \
  "$RP" --scope all --state-in "$T7" 2>&1)"
got=$?
set -e
[ "$got" = 0 ] || { case_ok=; printf '     exit: want 0 got %s\n' "$got"; }
want 'SKIP 5.6 (5.6.40): PATCHSET_APPROVED=0'
want 'release.yml'
want_not 'PUBLISH 5.6'
finish

# 9b. The same selection as a leg list, over a state where the reviewed series is
#     not current: only the reviewed one is returned, so an unreviewed pinset
#     cannot reach a builder through the matrix either.
case_name="unapproved-json"
case_ok=1
set +e
case_out="$(SUPPORTED_VERSIONS="5.6 8.1" MANIFEST_DIR="$WORK/unapproved" \
  "$RP" --scope all --state-in "$T1" --json 2>&1)"
got=$?
set -e
[ "$got" = 0 ] || { case_ok=; printf '     exit: want 0 got %s\n' "$got"; }
want_json 'length == 1'
want_json '.[0].series == "8.1"'
finish

# 10. A blank scope is refused instead of read as "everything" or "nothing".
rp empty-scope 1 --scope '' --state-in "$T7"
want 'refusing to plan an empty selection'
finish

# 11. A series outside the supported list is refused, and the message names what
#     is supported so the operator does not have to go looking.
rp unknown-series 1 --scope 9.9 --state-in "$T7"
want 'not a supported PHP series'
want 'supported: 5.6 8.1'
finish

# 12. A registry that answers with no tags at all cannot be planned from. This is
#     the failure that a local note would have papered over: an empty tag list
#     looks like "nothing published yet", which would re-publish every series at
#     r1 and collide with the real names as soon as the read recovered.
T12="$WORK/no-tags.json"
printf '{"registry":"ghcr.io","repo":"muffetlab/php","tags":[],"images":{}}' >"$T12"
rp no-tags 1 --scope all --state-in "$T12"
want 'answered with no tags at all'
finish

# 13. A state file that is not a captured read is refused with its shape named,
#     not with a jq traceback.
T13="$WORK/not-a-state.json"
printf '{"tags":{"not":"an array"}}' >"$T13"
rp bad-state 1 --scope all --state-in "$T13"
want 'not a captured release-plan state'
finish
rp missing-state 1 --scope all --state-in "$WORK/does-not-exist.json"
want 'is not a file'
finish

# 14. --state-out is a registry read, so it cannot be combined with --state-in:
#     silently preferring one of the two would let a fixture decide what a real
#     release publishes.
rp both-states 1 --scope all --state-in "$T7" --state-out "$WORK/o.json"
want 'cannot be combined'
finish

# 15. A manifest without SOURCE_REF is a hard stop, not a skip: the PHP version
#     comes from the manifest and nowhere else, so a leg built from an empty
#     version would be named "-r1-cli".
mkdir -p "$WORK/no-ref"
sed 's/^SOURCE_REF=.*/SOURCE_REF=""/' "$MANI/5.6.env" >"$WORK/no-ref/5.6.env"
cp "$MANI/8.1.env" "$WORK/no-ref/8.1.env"
case_name="no-source-ref"
case_ok=1
set +e
case_out="$(SUPPORTED_VERSIONS="5.6 8.1" MANIFEST_DIR="$WORK/no-ref" "$RP" --scope 5.6 --state-in "$T7" 2>&1)"
got=$?
set -e
[ "$got" = 1 ] || { case_ok=; printf '     exit: want 1 got %s\n' "$got"; }
want 'has no SOURCE_REF'
finish

# --- the architecture set: a name is only current if it carries both ----------
# 16. The pins match on both variants and one of them is a one-architecture
#     list. The gap is a content difference, and it is not fillable in place:
#     adding arm64 means rewriting the manifest list that anybody who pulled
#     5.6.40-r1-fpm already resolved. So the series goes to r2, where a freshly
#     composed list carries both, and r1-fpm is left exactly as the registry
#     serves it.
T16="$WORK/arm-gap.json"
state "$T16" \
  "5.6.40-r1-cli=$(match_rec 5.6.40)" \
  "5.6.40-r1-fpm=$(record_arch "$(match_labels 5.6.40)" linux/amd64)" \
  '8.1.34-cli=null'
rp arch-gap 0 --scope 5.6 --state-in "$T16"
want 'PUBLISH 5.6 (5.6.40) as r2 [new build]'
want '5.6.40-r1-fpm: linux/arm64 absent from the published manifest list'
want_not 'SKIP 5.6'
finish

# 16b. The same gap on a name whose pins are otherwise perfect: no pin moved,
#      the manifest is exactly what r1 was built from, and it is still the next
#      revision, because "already published" means already published *as this
#      build* -- both variants on both architectures.
T16B="$WORK/arm-gap-only.json"
state "$T16B" \
  "5.6.40-r1-cli=$(match_rec 5.6.40)" \
  "5.6.40-r1-fpm=$(record_arch "$(match_labels 5.6.40)" linux/amd64)" \
  '8.1.34-cli=null'
rp arch-gap-only 0 --scope 5.6 --state-in "$T16B"
want 'PUBLISH 5.6 (5.6.40) as r2 [new build]'
want 'linux/arm64 absent from the published manifest list'
want_not 'dev.php-legacy'
want_not 'already published at r1'
finish

# 16c. Extra architectures are not a gap. A registry that serves more than this
#      kit declares still resolves correctly everywhere it claims to, and moving
#      the declared set down is a reviewed change to ARCHITECTURES that publishes
#      as the next revision when it matters -- it is not a reason to churn a
#      snapshot of a build that did not change.
T16C="$WORK/arch-extra.json"
state "$T16C" \
  "5.6.40-r1-cli=$(record_arch "$(match_labels 5.6.40)" linux/amd64 linux/arm64 linux/arm/v7)" \
  "5.6.40-r1-fpm=$(record_arch "$(match_labels 5.6.40)" linux/amd64 linux/arm64 unknown/unknown)" \
  '8.1.34-cli=null'
rp arch-extra 0 --scope 5.6 --state-in "$T16C"
want 'SKIP 5.6 (5.6.40): already published at r1'
want_not 'PUBLISH 5.6'
finish

# 16d. The declared set is the question the operator actually asked. One
#      architecture short of what the pipeline builds is a gap even when the
#      published list is the longer one -- so a series whose merge lost arm64 is
#      caught here rather than pulled on a Mac and noticed a week later.
case_name="arch-declared-set"
case_ok=1
set +e
case_out="$(SUPPORTED_VERSIONS="5.6 8.1" MANIFEST_DIR="$MANI" ARCHITECTURES="linux/amd64 linux/arm64 linux/arm/v7" \
  "$RP" --scope 5.6 --state-in "$WORK/arch-extra.json" 2>&1)"
got=$?
set -e
[ "$got" = 0 ] || { case_ok=; printf '     exit: want 0 got %s\n' "$got"; }
want 'PUBLISH 5.6 (5.6.40) as r2 [new build]'
want 'linux/arm/v7 absent from the published manifest list'
finish

# 16e. An empty platform list with a perfect build record: the tag resolves to a
#      single manifest rather than a list, or the merge wrote the list with
#      nothing in it. Every architecture this kit declares is then absent, which
#      is the largest gap there is -- and an empty list must not read as "no
#      opinion about architectures".
T16E="$WORK/no-platforms.json"
state "$T16E" \
  "5.6.40-r1-cli={\"labels\":$(match_labels 5.6.40),\"platforms\":[]}" \
  "5.6.40-r1-fpm=$(match_rec 5.6.40)" \
  '8.1.34-cli=null'
rp no-platforms 0 --scope 5.6 --state-in "$T16E"
want 'PUBLISH 5.6 (5.6.40) as r2 [new build]'
want '5.6.40-r1-cli: linux/amd64 absent from the published manifest list; linux/arm64 absent from the published manifest list'
want_not 'SKIP 5.6'
finish

# --- the mirror repair list ---------------------------------------------------
# 17. Every variant this run verified becomes a copy instruction: the exact name
#     as the primary spells it and the floating name that must point at it. The
#     mirror is not read here -- the list says only what the primary serves
#     correctly, which is the whole set the mirror is allowed to be brought up to
#     without building anything.
rp all-current-repair 0 --scope all --state-in "$T7" --repair
want_json 'length == 4'
want_json '[.[] | .exact] | index("5.6.40-r1-cli") and index("5.6.40-r1-fpm") and index("8.1.34-r3-cli") and index("8.1.34-r3-fpm")'
want_json '[.[] | select(.exact == "8.1.34-r3-fpm")] | length == 1'
want_json '[.[] | select(.exact == "8.1.34-r3-fpm")][0].floating == "8.1-fpm"'
want_json '[.[] | .revision] | all(. == "1" or . == "3")'
want_json '[.[] | . as $o | select(.exact | test("^" + $o.php + "-r[0-9]+-" + $o.variant + "$"))] | length == 4'
finish

# 17b. A series that publishes gets no repair entry for the variants the registry
#      could not confirm -- there is nothing verified to copy. The half that is
#      current at r2 is still owed to the mirror; the half that is not is this
#      run's own build, and its leg writes both registries.
T17B="$WORK/partial-repair.json"
state "$T17B" \
  "5.6.40-r2-cli=$(match_rec 5.6.40)" \
  '8.1.34-cli=null'
rp partial-repair 0 --scope all --state-in "$T17B" --repair
want_json 'length == 1'
want_json '.[0].exact == "5.6.40-r2-cli"'
want_json '.[0].floating == "5.6-cli"'
finish
rp partial-repair-legs 0 --scope all --state-in "$T17B" --json
want_json 'length == 2'
finish

# 17c. Nothing verified, nothing owed: a registry that has never served this PHP
#      version gives the mirror nothing to copy, so the list is empty rather than
#      absent -- an empty repair matrix is the honest answer, not a skipped job.
T17C="$WORK/first-build.json"
state "$T17C" '5.6.40-cli=null'
rp first-build-repair 0 --scope 8.1 --state-in "$T17C" --repair
want_json '. == []'
finish

# 17d. A bare pre-revision name this run confirmed is still a name the mirror can
#     be brought up to. It carries no revision, so the list says revision 0 and
#     spells the exact name as the primary does -- the copy job never recomposes
#     it, because composing it twice is how the two of them drift.
T17D="$WORK/bare-repair.json"
state "$T17D" \
  "5.6.40-cli=$(match_rec 5.6.40)" \
  "5.6.40-fpm=$(match_rec 5.6.40)" \
  '8.1.34-cli=null'
rp bare-repair 0 --scope 5.6 --state-in "$T17D" --repair
want_json 'length == 2'
want_json '.[0].revision == "0"'
want_json '.[0].exact == "5.6.40-cli"'
want_json '.[0].floating == "5.6-cli"'
finish

# 17e. Two outputs are two answers to one question. A caller that asked for both
#      would have to guess which list it was about to act on, so the resolver
#      refuses instead of printing one and dropping the other.
rp both-emits 1 --scope all --state-in "$T7" --json --repair
want 'cannot be combined'
finish

# 18. A capture written before the architecture set was compared holds a labels
#     map where a {labels, platforms} record belongs. Reading it as "no
#     platforms" would move every series to a new revision on the strength of a
#     format change, so the shape is checked and refused instead.
T18="$WORK/old-capture.json"
state "$T18" "5.6.40-r1-cli=$(match_labels 5.6.40)"
rp old-capture 1 --scope 5.6 --state-in "$T18"
want 'is not a captured release-plan state'
want 'labels, platforms'
finish


echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ] || exit 1
