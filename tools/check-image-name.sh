#!/usr/bin/env bash
# check-image-name.sh -- keep the published image address consistent between the
# release pipeline and the documents that tell people what to pull.
#
# The published ref is <registry>/<namespace>/php, composed in
# .github/workflows/build-version.yml from its registry/namespace inputs, and
# the resulting address (ghcr.io/muffetlab/php) is what README.md, DEPLOYING.md,
# MAINTAINING.md, SUPPORTED.md, docker-compose.example.yml and
# docker-php-ext/README.md advertise. A rename that only touches one side
# produces docs pointing at a tag that was never pushed, so this gate reads the
# defaults out of the workflow and requires every document to name exactly that
# address.
#
# Also checks the two places a rename typically gets missed:
#   - release.yml repeats the namespace fallback where it calls the reusable
#     workflow and where it names the package
#   - the GHCR package-visibility job must name the package by the image path
#     after ghcr.io/ (namespace/php), not by an invented one
# and the local build tag (build.sh + its README examples), which is never
# pushed but is still an image name the documentation shows people.
#
# The release naming model is checked here too because it is the same class of
# consistency: which ref may produce a published image, what each of the four
# version-shaped things (git tag, dispatch input, manifest, Docker tag) is
# responsible for, and which workflow is allowed to act on it.
#
# And the documents' own charters, because "which file owns this content" is the
# same kind of agreement as "which file owns this address": MAINTAINING.md states one
# charter per document, README.md routes readers by it, and both are checked so a
# boundary cannot drift one paragraph at a time.
#
# Usage: ./tools/check-image-name.sh   (exit 0 = consistent, 1 = drift)
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

build_wf=".github/workflows/build-version.yml"
release_wf=".github/workflows/release.yml"
plan_tool="tools/release-plan.sh"
docs="README.md DEPLOYING.md MAINTAINING.md SUPPORTED.md docker-compose.example.yml docker-php-ext/README.md"

fail=0
err() {
  printf '::error::%s\n' "$*"
  fail=1
}

[ -f "$build_wf" ] || { err "$build_wf not found"; exit 1; }
[ -f "$release_wf" ] || { err "$release_wf not found"; exit 1; }

# Defaults are read from the workflow, not from this script, so the workflow
# stays the single source of truth for the published address.
registry="$(awk '/^      registry:/{f=1; next} f && /^        default:/{print $2; exit}' "$build_wf")"
namespace="$(awk '/^      namespace:/{f=1; next} f && /^        default:/{print $2; exit}' "$build_wf")"

[ -n "$registry" ] || err "${build_wf}: registry input default not found"
[ -n "$namespace" ] || err "${build_wf}: namespace input default not found"

if [ "$registry" != "ghcr.io" ]; then
  err "${build_wf}: registry default is '${registry}', expected ghcr.io (GHCR is the primary registry; a change here must be reflected in the docs too)"
fi
case "$namespace" in
  ""|*REPLACE*) err "${build_wf}: namespace default '${namespace}' is not a GHCR owner" ;;
esac
if ! printf '%s' "$namespace" | grep -Eq '^[a-zA-Z0-9._-]+$'; then
  err "${build_wf}: namespace default '${namespace}' is not a single GHCR path segment"
fi

published="${registry}/${namespace}/php"

# The tag composition itself. These grep patterns are literal shell text that
# must appear verbatim in the workflow, so they are single-quoted on purpose.
# shellcheck disable=SC2016
if ! grep -Fq 'repos="${REGISTRY}/${NAMESPACE}/php"' "$build_wf"; then
  err "${build_wf}: release tags no longer compose \${REGISTRY}/\${NAMESPACE}/php -- update this gate and the docs together"
fi
# shellcheck disable=SC2016
if ! grep -Fq 'repos="${repos} ${DOCKERHUB_USER}/php"' "$build_wf"; then
  err "${build_wf}: the Docker Hub mirror is no longer <dockerhub-user>/php"
fi

# release.yml must default to the same namespace, quoted or bare.
if ! grep -Eq "^[[:space:]]*default: \"?${namespace}\"?[[:space:]]*$" "$release_wf"; then
  err "${release_wf}: the namespace workflow_dispatch default is not '${namespace}'"
fi
fallbacks="$(grep -o "inputs.namespace || '[^']*'" "$release_wf" | sed "s/.*'\(.*\)'/\1/" | sort -u | tr '\n' ' ')"
if [ "$(printf '%s' "$fallbacks" | sed 's/ *$//')" != "$namespace" ]; then
  err "${release_wf}: namespace fallbacks must all be '${namespace}' (got: ${fallbacks})"
fi
# The visibility job has to keep naming the image this repo publishes, and it has
# to establish that name by reading the package back rather than asserting a URL
# shape. The packages API resource is not the registry path after ghcr.io/:
# /users/<user>/packages/container/package/php answers 200 where the
# .../package/<user>%2Fphp page 404s, so the API name is the leaf here and the
# slash form only applies to a repository-scoped package.
# What must not drift is the pair: the published path ${NAMESPACE}/php still
# appears as the thing being identified, and no package gets PATCHed before the
# step has read it back.
# shellcheck disable=SC2016
if ! grep -Fq '${NAMESPACE}/php' "$release_wf"; then
  err "${release_wf}: nothing in it still describes the published image path \${NAMESPACE}/php"
fi
if ! grep -Fq 'Resolved package resource' "$release_wf"; then
  err "${release_wf}: the visibility step no longer confirms a package resource by reading it back before changing it"
fi

for f in $docs; do
  [ -f "$f" ] || { err "$f: missing"; continue; }
  if ! grep -Fq "$published" "$f"; then
    err "$f: does not document the published address ${published}"
  fi
  if grep -Eq '(<owner>/php-legacy|your-registry/php-legacy|<namespace>/php-legacy|/php-legacy:)' "$f"; then
    err "$f: still advertises an old php-legacy image address instead of ${published}"
  fi
done

# Local build tag. It is never pushed, but MAINTAINING.md shows it in the example
# invocations and build.sh prints it as the next-step commands, so it has to be
# one name everywhere -- and deliberately not a ref of the published image, so a
# stray "docker push" cannot publish a -test tag into ghcr.io/.../php.
local_repo="php-legacy-kit"
if ! grep -Fq "IMAGE=\"${local_repo}:\${VERSION}-\${VARIANT}-test\"" build.sh; then
  err "build.sh: the local build tag is no longer ${local_repo}:\${VERSION}-\${VARIANT}-test"
fi
local_ref="${local_repo}:\${{ inputs.version }}-\${{ matrix.variant }}-test"
if ! grep -Fq "$local_ref" "$build_wf"; then
  err "${build_wf}: CI no longer tags its test build with the same name build.sh uses (${local_ref})"
fi
if ! grep -Fq "${local_repo}:<version>-<variant>-test" MAINTAINING.md; then
  err "MAINTAINING.md: does not document the local build tag ${local_repo}:<version>-<variant>-test"
fi

# Release naming model. Five version-shaped things, five separate jobs: a git tag
# marks a source release (vMAJOR.MINOR.PATCH), the entry picks the scope (a tag
# push names every supported series, a dispatch names one, a list, or all),
# manifests/<series>.env holds the PHP version, the registry holds the image
# revision, and the Docker tag names the image that came out (<minor>-<variant>
# floating, <full>-r<revision>-<variant> immutable). The assertions below are what
# keeps that division from sliding back: what a tag must never decide again is
# *which PHP version* and *which build* -- that was the coupling that made a full
# release cost eight tags, and a tag trigger is only safe here because the tag
# names this repository's source and nothing else.
#
# Three entries, one pipeline: A pushes a conforming tag and publishes every
# supported series, B dispatches one series, C dispatches several or all. All
# three run the same guard, the same validate gate, the same resolver and the same
# matrix, so "which version, which revision, publish, complete or skip" is
# answered once per run wherever it was asked from -- and the answer is three
# verdicts rather than two, because a release can fail after publishing one of a
# series' two variants, which is a different situation from a pin that moved and
# gets a different revision because of it.
if ! grep -Eq '^  push:' "$release_wf"; then
  err "${release_wf}: has no tag push trigger; entry A -- a conforming vMAJOR.MINOR.PATCH publishing every supported series -- is one of the three documented release entries (see MAINTAINING.md 'Publishing images')"
fi
if ! grep -Eq '^  workflow_dispatch:' "$release_wf"; then
  err "${release_wf}: has no workflow_dispatch trigger; entries B and C (one series, a list, or all) are how a targeted or batch release is started"
fi
# GitHub's tag filter is a glob, not a regex, so `v*.*.*` is the closest thing to
# the shape that is writable here, and it therefore also matches v1.0.0-rc1. What
# decides is the guard's own check -- asserted below by the literal it prints --
# because a filter that cannot say "digits only" must not be mistaken for the
# gate. A broader glob (v*) would start a run for every tag in the repository,
# and no glob at all would start one for refs/tags that name nothing.
if ! grep -Fq -- "- 'v*.*.*'" "$release_wf"; then
  err "${release_wf}: the tag trigger no longer filters on 'v*.*.*' -- the widest honest glob, and the reason the guard has to check the shape itself"
fi
# A tag-triggered run has no form, so nothing it publishes may depend on a value
# nobody typed: the scope for that entry is said in the workflow, not defaulted
# from an empty input.
# shellcheck disable=SC2016
if ! grep -Fq -- 'if [ "$EVENT" = push ]; then' "$release_wf"; then
  err "${release_wf}: the guard no longer branches on the event, so a tag-triggered run would take its scope from a dispatch input that does not exist"
fi
# The three labels are the pipeline saying which entry it served, and they are
# counted rather than typed: A is the tag, B is one series, C is several or all.
for entry in A B C; do
  grep -Fq -- "entry=${entry}" "$release_wf" ||
    err "${release_wf}: no longer labels release entry ${entry}; the three documented entries have to be distinguishable in the log, or a run that published the wrong scope cannot be told apart from one that published the right one"
done

# The source release tag shape, as one literal in both files that check it: the
# guard that reads the dispatched commit and the callee that refuses push=true.
# Third number, then end of string -- a suffix group here is a build number living
# in a git tag again, which is the model this gate just retired.
src_tag_shape='^v[0-9]+\.[0-9]+\.[0-9]+$'
for site in "$release_wf" "$build_wf"; do
  if ! grep -Fq -- "$src_tag_shape" "$site"; then
    err "${site}: no longer requires exactly ${src_tag_shape} for a source release tag (a git tag marks source, nothing else)"
  fi
done
# shellcheck disable=SC2016
if grep -Fq -- '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$' "$release_wf" "$build_wf"; then
  err "a workflow still accepts vX.Y.Z-<N> as a release tag; the build number belongs in the image name (-r<revision>), not the git tag"
fi

# The image revision is what distinguishes two builds of the same PHP version, and
# it is part of every published exact name.
# These are literal workflow text, single-quoted because nothing here may expand.
# shellcheck disable=SC2016
if ! grep -Fq -- 'exact="${full}-r${REVISION}-${VARIANT}"' "$build_wf"; then
  err "${build_wf}: the immutable name is no longer composed as <full>-r<revision>-<variant>, so a rebuild would overwrite the snapshot the revision exists to protect"
fi
# shellcheck disable=SC2016
for site in "$build_wf" "$plan_tool"; do
  grep -Fq -- '^[1-9][0-9]*$' "$site" || err "${site}: no longer requires a positive integer image revision before it can become part of a published name"
done
# The revision is read out of the registry and never typed. A workflow that still
# had a revision input would have two answers to "which build is this" -- the one
# a human remembered and the one the registry serves -- and the one that gets
# published is whichever step ran last.
if grep -Fq -- 'inputs.revision' "$release_wf"; then
  err "${release_wf}: reads a revision input again; the image revision is derived per PHP point version by ${plan_tool} from the exact names the registry already serves (see MAINTAINING.md 'Publishing images')"
fi
# What is asserted is the call, not the name: build-version.yml may explain where
# its revision came from, and a comment that names the resolver is documentation
# of the hand-off rather than a second resolver.
if ! grep -Fq -- './'"${plan_tool}" "$release_wf"; then
  err "${release_wf}: does not call ${plan_tool}, so the version, the revision and the publish/complete/skip verdict are composed somewhere else -- and a second reading of those facts is how two entries publish different things from the same manifest"
fi
if grep -Fq -- './'"${plan_tool}" "$build_wf"; then
  err "${build_wf}: resolves the release plan itself; the callee publishes the revision the caller derived, it does not derive a second one per matrix leg"
fi
# The verdict travels with the leg. A revision number alone cannot say which of
# the three situations it is: r3 the registry has partly served is a release being
# finished, r3 it has not served at all is a new build, and the write that follows
# is the opposite of what the other one means. So the assertion is at all three
# ends -- the resolver's report text, the matrix field, the callee's branch -- not
# in a comment that can say anything at all.
# shellcheck disable=SC2016
for want in 'mode: ${{ matrix.mode }}' ', verdict \(.mode)'; do
  grep -Fq -- "$want" "$release_wf" ||
    err "${release_wf}: no longer carries \`${want}\` to the log and the build job -- a leg that arrives without its verdict cannot tell the callee whether an already-served exact name is a conflict or the release being already half-published"
done
# shellcheck disable=SC2016
for want in 'MODE: ${{ inputs.mode }}' 'default: publish' '"$MODE" = complete' '"$role" = mirror' 'publish_one "$r" "$role"'; do
  grep -Fq -- "$want" "$build_wf" ||
    err "${build_wf}: no longer contains \`${want}\` -- publishing has to know the verdict it was handed and which registry is answering, or every already-served name becomes a refusal, a half-published release can never be retried, and the mirror that did fail is re-published beside its own snapshot"
done
# The stricter default is the one that must be written down: a callee that read an
# absent verdict as "complete" would turn a genuine clash with the registry into a
# silent skip, which is the failure mode the revision exists to prevent -- so the
# literal above is asserted in the input block, where a default belongs.
# shellcheck disable=SC2016
for want in 'current="" absent="" unusable=""' '[first build]' '[new build]' '"$max" complete' 'mode: .[4]'; do
  grep -Fq -- "$want" "$plan_tool" ||
    err "${plan_tool}: no longer emits \`${want}\` -- the three variant states, the three verdicts they add up to, and the verdict in the leg record are what keeps a series that needs nothing, one that needs finishing and one whose inputs moved from being read as the same question"
done
# The inverse half: one bucket for "anything that is not a match" is the reading
# that made a retry either rewrite a served name or invent a revision, and it is
# back the moment absences and moved pins are compared together again.
# shellcheck disable=SC2016  # the literal is shell text to be found, not expanded
if grep -Fq -- 'mismatch="${mismatch}' "$plan_tool"; then
  err "${plan_tool}: lumps a missing published variant and a moved pin into one mismatch bucket again -- the first is the release being finished at its revision, the second is a new revision, and one bucket can only answer one of them"
fi
# A served name is compared for its architecture set as well as its pins, because
# a one-architecture image under a multi-arch name is a content difference, and it
# is not fillable: adding the second architecture means rewriting the manifest
# list of a name somebody has already pulled. The declared set is stated once in
# the resolver and the pipeline that produces it must carry exactly that, or every
# published image reads as missing an architecture and every release bumps every
# series. So both ends of the agreement are asserted.
# shellcheck disable=SC2016
for want in \
  'ARCHITECTURES="${ARCHITECTURES:-linux/amd64 linux/arm64}"' \
  'compare_platforms' \
  'compare_record' \
  'fetch_record' \
  'absent from the published manifest list'
do
  grep -Fq -- "$want" "$plan_tool" || err "${plan_tool}: no longer contains \`${want}\` -- the architecture set a published manifest list carries is part of the verdict, because a short list is a content difference the four pins cannot see and the only fix that does not rewrite a served name is the next revision"
done
# shellcheck disable=SC2016
if ! grep -Fq -- 'select((.platform.architecture // "unknown") != "unknown")' "$plan_tool"; then
  err "${plan_tool}: no longer drops unknown/unknown entries when it reads a manifest list's platforms -- buildx attaches provenance and SBOM manifests to the index, they are not architectures, and counting them lets a one-architecture image pass as current"
fi
# shellcheck disable=SC2016
for want in 'arch: [amd64, arm64]' 'for arch in amd64 arm64; do'; do
  grep -Fq -- "$want" "$build_wf" || err "${build_wf}: no longer builds ${want} -- the architecture matrix and the exact names the merge step refuses to publish partially are the pipeline end of the architecture set ${plan_tool} compares, and the two lists may not drift apart"
done
# The mirror is a copy of the primary registry, never a second place that builds
# the same thing: a PHP compile is not reproducible, so this run's digests differ
# from a published one even when the pins match, and the mirror writing them under
# a name the primary already serves would put two contents behind one exact name.
# The callee must therefore ask the primary before it pushes, and take the
# primary's name when it is there.
# shellcheck disable=SC2016
for want in \
  'primary_repo="${REGISTRY}/${NAMESPACE}/php"' \
  'copied_from="$(docker buildx imagetools inspect "${primary_repo}:${exact}" 2>&1)"' \
  '-t "${repo}:${VERSION}-${VARIANT}" "${primary_repo}:${exact}"'
do
  grep -Fq -- "$want" "$build_wf" || err "${build_wf}: no longer contains \`${want}\` -- a mirror registry is filled by copying the primary's published image, so one exact name cannot come to hold this run's fresh digests beside the snapshot the primary already serves"
done
# Mirror repair is its own job, and it is a copy list, not a second verdict: the
# plan reads one registry, and the names the mirror is owed are the names the plan
# verified. The hand-offs are asserted at both ends -- the scope travels as a plan
# output rather than being recomposed, and the repair job asks the resolver rather
# than making up names.
# shellcheck disable=SC2016
if ! grep -Eq '^  mirror-repair:' "$release_wf"; then
  err "${release_wf}: has no mirror-repair job -- the mirror is brought up to the primary by the repair job from the resolver's verified names, and a release whose GHCR half succeeded and whose mirror half failed must be finishable without moving a revision or building again"
fi
# shellcheck disable=SC2016
for want in \
  '--repair' \
  'scope: ${{ steps.matrix.outputs.scope }}' \
  'needs.plan.outputs.scope'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: no longer contains \`${want}\` -- the mirror is brought up to the primary by the repair job from the resolver's verified names, and a release whose GHCR half succeeded and whose mirror half failed must be finishable without moving a revision or building again"
done
# The boundary the repair job enforces is two facts, not one: a mirror tag that is
# missing is filled by copying, but a mirror tag that exists is never written --
# an incomplete copy (a subset of GHCR's platforms) and a foreign image (a child
# GHCR does not serve) are separately diagnosed and both refused, because the
# human who deletes the tag has to know which one they are deleting, and because
# "patch an existing tag in place" and "overwrite an existing tag" are the same
# act under either name.
# shellcheck disable=SC2016
for want in \
  'exists but is an incomplete copy' \
  'rewriting the name to a wider list is the same act as rewriting it to a different image' \
  'carries images ${primary}:${exact} does not' \
  'incomplete copies,'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: no longer contains \`${want}\` -- the repair job has to tell an incomplete copy of this build from a foreign image under the same name: both are refused because an existing exact tag is never written on either registry, and the refusal names which one it found so the human deletion knows what it deletes"
done
# And the asymmetry the whole table rests on, stated where the rules live: GHCR is
# the record of what was published, the mirror is a repairable copy, and no mirror
# failure moves a GHCR revision.
# shellcheck disable=SC2016
for want in \
  'immutable on both registries' \
  'Docker Hub exact tags are immutable' \
  'mirror-repair must fail without modifying it' \
  'repairable' \
  'not a rebuild, and not a new version'
do
  grep -Fq -- "$want" MAINTAINING.md || err "MAINTAINING.md: no longer states \`${want}\` -- the exact name's immutability is the top rule of the whole model on both registries: creation can be automated, an existing exact tag is never overwritten, GHCR records what was published while Docker Hub is a copy that can be repaired, and a mirror that is missing, unreachable or wrong never moves a revision"
done
# shellcheck disable=SC2016
for want in 'emit_repair' 'exact: .[4]' 'floating: .[5]'; do
  grep -Fq -- "$want" "$plan_tool" || err "${plan_tool}: no longer contains \`${want}\` -- the resolver composes the names it verified and hands them over whole, because a repair that re-derived an exact name could end up pointing a mirror at a name the plan never checked"
done
# shellcheck disable=SC2016
if grep -Fq -- 'cannot be combined: one run emits one list' "$plan_tool"; then
  : # --json and --repair stay mutually exclusive in the resolver itself
else
  err "${plan_tool}: no longer refuses --json and --repair together; two callers with two lists would each have to guess which answer it was about to act on"
fi
# The repair job copies; it does not build. Any build step in release.yml is a
# second pipeline with a second idea of what a published name is.
# shellcheck disable=SC2016
for forbid in 'build-push-action' 'docker buildx build'; do
  if grep -Fq -- "$forbid" "$release_wf"; then
    err "${release_wf}: contains ${forbid}; the release workflow composes, publishes and repairs by reading registries and calling ${build_wf}, and building in a second place is how a second reading of the same manifest gets published"
  fi
done
# And the multi-series scope, which is where the resolver's separator and the
# guard's padded list have to agree. Deleting the padding rather than joining the
# words turns ",8.1,5.6," into "8.15.6": not a series, and an error no reader of
# the log can account for.
# shellcheck disable=SC2016
if ! grep -Fq -- 'scope="$(IFS=,; printf '"'"'%s'"'"' "$*")"' "$release_wf"; then
  err "${release_wf}: no longer rebuilds the resolver's scope by joining the selected series with commas, which is the only form in which a list of them survives the guard's padding"
fi
# shellcheck disable=SC2016
if grep -Fq -- 'SELECTED" | tr -d ' "$release_wf"; then
  err "${release_wf}: converts the guard's padded selection by deleting its commas again -- a two-series dispatch then asks the resolver for one series named 8.15.6"
fi
# Publishing is allowed from two refs and no others: the default branch, where a
# dispatch runs, and a tag whose name is exactly a source release, where entry A
# runs. The source tag is still checked by content as well, so a tag-triggered leg
# cannot label itself with a release other than the ref it stands on. Both halves
# are the callee's own gate, not just release.yml's.
# shellcheck disable=SC2016
for want in \
  'refs/heads/main | refs/heads/master) refkind=branch ;;' \
  'refs/tags/*)' \
  'SOURCE_RELEASE: ${{ inputs.source_release }}' \
  'is not a source release tag' \
  'a tag-triggered release publishes the source its own ref names'
do
  grep -Fq -- "$want" "$build_wf" || err "${build_wf}: no longer contains \`${want}\` -- push=true must require the default branch or a conforming tag ref, and a vMAJOR.MINOR.PATCH source release tag either way, so an image can never be published from untagged source"
done
if ! grep -Fq -- 'may not publish' "$build_wf"; then
  err "${build_wf}: no longer refuses a push=true caller standing on a ref it does not accept; a pull request, a branch push and a non-release tag all have to be refused here as well as by release.yml"
fi
# The callee must be *told* what it is publishing: release.yml feeds the guard's
# outputs to the matrix leg, and the PHP version comes out of the manifest.
# shellcheck disable=SC2016
for want in \
  'source_release: ${{ needs.guard.outputs.release }}' \
  'revision: ${{ matrix.revision }}' \
  'version: ${{ matrix.series }}'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: no longer passes \`${want}\` to the release matrix -- the scope, the resolved revision and the source tag are one hand-off from guard and plan to the build job"
done
# The PHP version has one source -- the reviewed manifest -- and since the
# resolver composes the name it is read in one place too. release.yml's job is to
# hand the resolver the selection and pass the answer to the matrix, not to grep
# the manifest a second way.
# shellcheck disable=SC2016
for want in 'SOURCE_REF' 'BUILD_VARIANTS' 'highest_revision' 'dev.php-legacy.base-image' \
  'PATCHSET_APPROVED'
do
  grep -Fq -- "$want" "$plan_tool" || err "${plan_tool}: no longer reads \`${want}\` -- the PHP version, the variants, the revision, the pins the verdict turns on and the review flag are the resolver's job and nowhere else"
done
# The report a human reads and the matrix that publishes are the same answer: the
# run asks the registry once, captures what it heard, and rebuilds the legs from
# the capture rather than from a second read that could disagree.
# shellcheck disable=SC2016
for want in '--state-out' '--state-in' '--json'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: no longer passes \`${want}\` to ${plan_tool}, so the log and the matrix would come from two separate registry reads -- and the log is the only thing a reader can check the matrix against"
done
# An exact name is written once. The resolver picks a revision the registry has
# not served; the callee refuses the write if that name exists anyway, which is
# what turns "8.1.34-r1-cli is that build forever" from a habit into a property of
# the pipeline.
if ! grep -Fq -- 'already exists, and an exact published name is never rewritten' "$build_wf"; then
  err "${build_wf}: no longer asks the registry whether the exact name it is about to write is taken; a re-run would move a digest out from under a name somebody has pinned"
fi
# Trigger ownership. release.yml is the only workflow that publishes, and it is
# dispatch-only, so build-and-verify.yml must not grow a push trigger either: a
# branch push that built and pushed would write the same floating tags outside the
# guard's checks. Their concurrency groups differ (build-and-verify-<ref> vs
# release-<ref>) so they cannot cancel each other, and both write the same
# php-<version>-<variant>-<arch> layer-cache scopes. Nothing else here can catch
# a re-added push trigger -- there is no actionlint step -- so it is asserted.
ci_wf=".github/workflows/build-and-verify.yml"
[ -f "$ci_wf" ] || { err "$ci_wf not found"; exit 1; }
if grep -Eq '^  push:' "$ci_wf"; then
  err "${ci_wf}: has a push: trigger again; tags belong to ${release_wf} and branch pushes cost a full chain -- keep this workflow on pull_request + workflow_dispatch"
fi
if ! grep -Eq '^  (pull_request|workflow_dispatch):' "$ci_wf"; then
  err "${ci_wf}: lost its pull_request/workflow_dispatch triggers"
fi
# One entry point, one matrix. The release is a single job that calls the reusable
# workflow once per selected series, so adding a PHP series costs a manifest and an
# allowlist row rather than a new block of eight near-identical YAML. Assert the
# matrix is fed by the plan job's JSON, that nothing publishes on its own terms
# (push=true only where the matrix leg asks for it), and that the retired per-series
# jobs have not come back -- eight static jobs would again mean eight places to
# forget a fix.
# shellcheck disable=SC2016
for want in \
  'include: ${{ fromJSON(needs.plan.outputs.matrix) }}' \
  'uses: ./.github/workflows/build-version.yml' \
  'fail-fast: false' \
  'push: true'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: no longer contains \`${want}\` -- the release is one dynamic matrix job that calls ${build_wf} for each series guard selected"
done
per_series_jobs="$(grep -c '^  release-[0-9_]*:' "$release_wf" || true)"
if [ "$per_series_jobs" != 0 ]; then
  err "${release_wf}: ${per_series_jobs} static per-series release job(s) are back; one matrix job selects the scope, so a new PHP series must not need a YAML edit"
fi
matrix_uses="$(grep -c 'uses: ./.github/workflows/build-version.yml' "$release_wf" || true)"
if [ "$matrix_uses" != 1 ]; then
  err "${release_wf}: ${matrix_uses} jobs call ${build_wf}, expected 1 (a second caller is a second release entry point, and they would race over the same floating tags)"
fi
# Guard emits the selection both run types need -- one series, or all of them --
# and the plan job turns it into the matrix. A guard that stops writing it selects
# nothing, and every job downstream reads as skipped while the run still looks
# green.
# These are literal lines of the workflow file, quoted as-is: nothing here is
# meant to expand, which is why the patterns are single-quoted.
# shellcheck disable=SC2016
for want in \
  'steps.scope.outputs.selected' \
  'selected=",$listed,"' \
  'steps.srctag.outputs.release' \
  'steps.scope.outputs.entry'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: no longer contains \`${want}\` -- guard turns the entry (tag, one series, a list, or all) into the selected series list, the source release tag and the entry label, and the matrix is built from all three"
done
# The dispatched branch still has to carry a source release tag; entry A gets one
# from the ref it is standing on, and both then prove the same thing of git.
for want in 'git tag --points-at' 'does not point at commit'; do
  grep -Fq -- "$want" "$release_wf" ||
    err "${release_wf}: no longer contains \`${want}\` -- the source release is proved against the commit being built, not taken from the event that started the run"
done
# An empty selection must be refused three times: the guard that reads the form,
# validate's readiness step, and the plan job that would otherwise emit a
# zero-entry matrix. Without the first two, a dispatch that typed nothing becomes
# either "everything" or "nothing" by accident. Without the third, a guard that
# emits only separators loops zero times, prints its success line for nothing, and
# the run goes green with no image published.
# A resolved-to-nothing selection -- every series already current -- is the one
# case that is NOT an error, and it is reported rather than refused; that is the
# resolver's answer, not a missing lock.
# shellcheck disable=SC2016
empty_refusals="$(grep -cF -- '[ "$#" -gt 0 ]' "$release_wf" || true)"
if [ "$empty_refusals" != 3 ]; then
  err "${release_wf}: ${empty_refusals} empty-selection refusals, expected 3 (the guard's scope step, the 'Selected series are release-ready' step and the plan job) -- a run with nothing selected must fail, not finish green with no image published"
fi
# One Overview sync per run, and it is a job, not a leg. The Docker Hub Overview is
# one document for the whole <user>/php repository, so a version=all run must write
# it once: the mirror-readme job owns the call, and the per-series build job must
# not make it at all -- with eight matrix legs, a call there is eight PATCHes of the
# same page, and one green leg hides the other seven failures.
sync_tool="tools/sync-dockerhub-readme.sh"
overview_jobs="$(grep -c '^  mirror-readme:' "$release_wf" || true)"
if [ "$overview_jobs" != 1 ]; then
  err "${release_wf}: ${overview_jobs} mirror-readme jobs, expected exactly 1 (the Overview is one document per repository; a full release needs one owner for the call)"
fi
if ! grep -Fq "./${sync_tool}" "$release_wf"; then
  err "${release_wf}: nothing calls ./${sync_tool}, so releases stop updating the mirror's Overview while the docs still say they do"
fi
if grep -Fq "./${sync_tool}" "$build_wf"; then
  err "${build_wf}: a publish leg calls ./${sync_tool} again; the Overview belongs to release.yml's mirror-readme job, and every matrix leg writing it means one PATCH per series per variant"
fi
# What the documents have to say about the model, matched against a whitespace-
# flattened copy of each file so a claim is not "missing" merely because the prose
# wrapped across a line break. The four claims split by audience, because a person
# pulling an image and a person cutting a release need different halves:
#   8.1.34-r1                  -- an immutable image name, by example
#   Exact tags are never moved -- why pinning one is safe
#       Everyone reads these: they are the reason a deployer may pin a name.
#   vX.Y.Z                     -- the shape of a source release tag
#   source release tag         -- what a git tag is for (it selects nothing)
#       Release mechanics, so MAINTAINING.md alone carries them. This was widened to
#       DEPLOYING.md, SUPPORTED.md and SECURITY.md before the charters were written
#       down, and the widening is what put a git-tag paragraph in the running guide
#       and a release model in the status page: a document the gate pins is a
#       document that keeps the content, however little its readers need it.
#       The same two literals are now refused in the consumer documents instead of
#       required there, so the paragraph cannot arrive back through a good edit.
# A maintainer-facing doc that drops the second invites cutting another tag for the
# second build of that PHP version, which is the model this project retired: the tag
# marks source, the input picks the scope, the manifest holds the version, and the
# image name carries the revision. Dropping the first pair invites a reader to pin an
# exact name and wait for a fix that will never arrive under it.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
require_flat() {
  file="$1"; reason="$2"; shift 2
  [ -f "$file" ] || { err "$file: missing"; return; }
  body="$(flat "$file")"
  for want in "$@"; do
    if ! printf '%s' "$body" | grep -Fq -- "$want"; then
      err "$file: no longer states \`${want}\` -- ${reason}"
    fi
  done
}
forbid_flat() { # <file> <charter reason> <literal>...
  file="$1"; reason="$2"; shift 2
  [ -f "$file" ] || { err "$file: missing"; return; }
  body="$(flat "$file")"
  for unwanted in "$@"; do
    if printf '%s' "$body" | grep -Fq -- "$unwanted"; then
      err "$file: carries \`${unwanted}\`, which is not its content -- ${reason}"
    fi
  done
}
model_reason="see the release model in MAINTAINING.md ('Publishing images'): a git tag marks source (vX.Y.Z), the entry picks the scope (a conforming tag is every series, a dispatch is one series, a list, or all), manifests/<series>.env holds the PHP version, the registry holds the revision, and the image name carries it (-r<N>, and exact tags are never moved)"
for f in README.md DEPLOYING.md MAINTAINING.md SUPPORTED.md SECURITY.md; do
  require_flat "$f" "$model_reason" '8.1.34-r1' 'Exact tags are never moved'
done
# Only the maintainer document states them, which is why they are not in the loop
# above: README/DEPLOYING need the image names, not the source tag.
require_flat MAINTAINING.md "$model_reason" 'vX.Y.Z' 'source release tag'
# The three verdicts are release mechanics like the four inputs are, so they live
# in one document and one section. Asserting the section's own words -- the
# distinction, the hand-off and the mirror rule -- is what catches a verdict being
# re-derived in a workflow comment while the runbook still says something else.
verdict_reason="MAINTAINING.md ('Publishing images') is the one place the three verdicts are stated, with the revision model that surrounds them; see its 'The verdict has three answers, because a release can fail halfway'"
# shellcheck disable=SC2016  # these are document sentences, one of them holds shell text
require_flat MAINTAINING.md "$verdict_reason" \
  'The verdict has three answers, because a release can fail halfway' \
  'Each matrix leg carries it as `mode`' \
  'A Docker Hub mirror is never read by the plan'
# The inverse half, widened as each out-of-charter paragraph is moved out (see
# MAINTAINING.md 'Which document owns what'). SECURITY.md lost its copy when its CI
# gate inventory moved to MAINTAINING.md ("Hardening gates (what CI enforces)") and
# its reporting flow stopped describing the tag scheme. SUPPORTED.md lost its copy
# when tools/gen-supported.sh stopped emitting a release-model paragraph and a
# generator-mechanics section, which is what moved the four-inputs model, the
# namespace composition and the read-out-of-the-registry details to MAINTAINING.md
# ("Publishing images"). DISCLAIMER.md is refused on the same terms: its charter is the
# responsibility boundary, and the tag scheme is not a boundary claim. All five documents
# are refused now, so nothing is left to relocate: a future edit that puts such a
# paragraph back has to delete something first.
charter_reason="MAINTAINING.md ('Which document owns what') assigns release mechanics to MAINTAINING.md; route the reader there instead of restating it"
# The two names of the release inputs themselves, refused alongside the model: a
# document that tells a reader what to click has become the release runbook, which is
# the same drift as a document that explains why the runbook is shaped that way.
input_reason="MAINTAINING.md ('Publishing images') is the runbook that names the release inputs; a consumer or policy document that names them is describing a dispatch instead of routing to the one that does"
for f in README.md DEPLOYING.md SUPPORTED.md SECURITY.md DISCLAIMER.md; do
  forbid_flat "$f" "$charter_reason" 'vX.Y.Z' 'source release tag'
  forbid_flat "$f" "$input_reason" 'workflow_dispatch' 'version=all'
done

# And the specific way DISCLAIMER.md rots, which its charter calls out by name: it is the
# one document whose own reason for existing ("what is published is decided by
# SUPPORTED.md, not by this file") a copied sentence contradicts, because a dated
# statement of this project's state -- which tags existed, when CI last went green, what
# the registry answered at the last generation -- is exactly the snapshot that goes false
# quietly. Upstream dates are not state and belong here when the argument needs them;
# this rule is about the ISO form this repository uses for its own records, and today
# the file needs no date at all.
snap="$(grep -nE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' DISCLAIMER.md 2>/dev/null | tr '\n' ' ' || true)"
if [ -n "$snap" ]; then
  err "DISCLAIMER.md carries a dated snapshot of this project's own state (${snap}); SUPPORTED.md reads that out of the registry and manifests/SECURITY-REVIEW.md records the dated evidence -- a copied date here is a claim no gate can re-check"
fi

# The status page is the only place that says what an image is built ON, and both
# halves of that answer are columns: a row reading "pinned by digest" without a base
# names an OS nobody can check, and a base name without its pin says nothing about
# whether the bytes are reproducible. A column that disappears here disappears from
# the generated file, from the generator, and from the reader's argument for trusting
# a digest, all at once and with nothing failing -- so the header is pinned in the
# committed file AND in the script that writes it.
for f in SUPPORTED.md tools/gen-supported.sh; do
  [ -f "$f" ] || { err "$f: missing"; continue; }
  if ! flat "$f" | grep -Fq -- 'Debian base | Base pin'; then
    err "$f: no longer carries the \`Debian base\` / \`Base pin\` columns -- the base image and its pin are what SUPPORTED.md answers for a series, and tools/gen-supported.sh is the only thing that writes them"
  fi
done

# Nothing in the repository may address an image as "php-legacy:" -- that was
# both the old published name and the old local tag, and every remaining user
# would be a ref that no longer exists. This script is excluded because it
# quotes that very name in the pattern and message it greps for.
stale="$(grep -rl --exclude-dir=.git --exclude="$(basename "$0")" 'php-legacy:' . 2>/dev/null | sed 's|^\./||' | sort | tr '\n' ' ')"
if [ -n "$stale" ]; then
  err "these files still reference the removed php-legacy: image name: ${stale}"
fi
# Same for the release tag: vX.Y.Z-legacy is no longer a trigger, and a document
# telling a maintainer to push it produces a run that never happens.
stale_tag="$(grep -rl --exclude-dir=.git --exclude="$(basename "$0")" -e 'v\*-legacy' -e 'X\.Y\.Z-legacy' . 2>/dev/null | sed 's|^\./||' | sort | tr '\n' ' ')"
if [ -n "$stale_tag" ]; then
  err "these files still reference the removed v*-legacy tag scheme: ${stale_tag}"
fi
# And for the retired image name: an exact name whose revision is a bare integer
# (8.1.34-1-cli) was published by no release and is published by no release now --
# a rebuild is 8.1.34-r2-cli. A document showing that shape tells someone to pull a
# tag that does not exist, and a workflow composing it would overwrite the bare
# 8.1.34-cli snapshot that is in the registry.
old_rev='[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-(cli|fpm)'
stale_rev="$(grep -rlE --exclude-dir=.git --exclude="$(basename "$0")" -e "$old_rev" . 2>/dev/null | sed 's|^\./||' | sort | tr '\n' ' ')"
if [ -n "$stale_rev" ]; then
  err "these files still use the retired <full>-<N>-<variant> image name (a revision is spelled -r<N>): ${stale_rev}"
fi

# The latest tag is gone, and the argument for it is MAINTAINING.md's prose ("Publishing
# images"), not this comment: a "latest-<variant>" would resolve to whichever series was
# released last, which records release order rather than code. What this script asserts is
# the mechanical half of that: the publish step writes exactly the two names, no document
# advertises a latest address, and the documents a reader chooses a tag from state that
# there is none. A pull of an advertised-but-unpublished name is the failure this whole
# script exists to prevent.
# shellcheck disable=SC2016
if grep -Fq -- '-t ${repo}:latest' "$build_wf"; then
  err "${build_wf}: the publish step writes a latest tag again; there is no latest tag (see MAINTAINING.md 'Publishing images')"
fi
# shellcheck disable=SC2016
tag_writes="$(grep -c -- '-t ${repo}:' "$build_wf" || true)"
if [ "$tag_writes" != "2" ]; then
  err "${build_wf}: the publish step writes ${tag_writes} tags, expected 2 (the immutable <full>-r<revision>-<variant> and the floating <minor>-<variant>) -- a change here is a change to the published namespace and to the docs"
fi
stale_latest="$(grep -rl --exclude-dir=.git --exclude="$(basename "$0")" 'php:latest' . 2>/dev/null | sed 's|^\./||' | sort | tr '\n' ' ')"
if [ -n "$stale_latest" ]; then
  err "these files advertise a latest tag on the published address, which the pipeline does not publish: ${stale_latest}"
fi
# And the removal has to be stated, not just absent -- a silent omission reads as
# an oversight to anyone who expected the php:latest convention. The claim is the
# consumer-facing half (a pull of "php:latest" answers "manifest unknown", so a reader
# choosing a tag has to be told there is nothing to choose), and the four documents that
# name a tag to pull state it: README and DEPLOYING for the person deploying, SUPPORTED
# because the namespace it lists is the registry's, and MAINTAINING because it owns the
# reason there is none, which the three above route here rather than restate.
for f in README.md DEPLOYING.md MAINTAINING.md SUPPORTED.md; do
  # shellcheck disable=SC2016
  if ! grep -Fq 'no `latest` tag' "$f"; then
    err "$f: no longer states that no latest tag is published -- the claim belongs here, the argument for it belongs in MAINTAINING.md ('Publishing images')"
  fi
done

# The Docker Hub mirror's Overview is written by a tool in this repository, but the
# promise a maintainer reads ("a release syncs it") is a promise about a workflow
# step, and every way that rots is silent: drop the call and the page goes stale by
# however many releases since with no failing job anywhere; put the call back in the
# per-series build job and a version=all run PATCHes the same document once per leg;
# give the manual workflow a push or pull_request trigger and a branch that
# is not main can write the mirror's page with the mirror's secrets. Asserted here
# for the same reason the trigger ownership above is: there is no actionlint step.
sync_wf=".github/workflows/sync-dockerhub-readme.yml"
[ -f "$sync_tool" ] || { err "$sync_tool not found (the Overview sync is documented, so it has to exist)"; }
[ -f "$sync_wf" ] || err "$sync_wf not found (MAINTAINING.md documents a manual dispatch path for the Overview)"
if [ -f "$sync_wf" ]; then
  if grep -Eq '^  (push|pull_request|schedule):' "$sync_wf"; then
    err "${sync_wf}: has a trigger beyond workflow_dispatch; only a human on the default branch may write the mirror's Overview"
  fi
  if ! grep -Fq "./$sync_tool" "$sync_wf"; then
    err "${sync_wf}: no longer calls ${sync_tool}"
  fi
fi
# Both validate jobs run the payload builder's self-test, so the release that writes
# an Overview has already executed the assertions about that text on the same image.
for f in "$ci_wf" "$release_wf"; do
  if ! grep -Fq -- '--self-test' "$f"; then
    err "$f: no longer runs ${sync_tool} --self-test"
  fi
done
# The default target has to be the repository the mirror actually pushes to, or a
# release writes an Overview for a name nobody pulls from. Both names are read out of
# their files rather than hardcoded here.
if [ -f "$sync_tool" ]; then
  # The mirror's name is read from the compose line that builds the push target
  # ("${DOCKERHUB_USER}/php"), and the tool's from its HUB_REPO default -- both
  # extracted rather than hardcoded, so a rename on either side trips this instead of
  # silently pointing the Overview at a repository nobody pulls from.
  # These are literal patterns matched against the workflows' own ${...} text; the
  # whole point is that they do not expand here.
  # shellcheck disable=SC2016
  mirror_name="$(grep -o '\${DOCKERHUB_USER}/[a-z0-9._-]*' "$build_wf" | sed 's|.*/||' | head -1)"
  # shellcheck disable=SC2016
  tool_name="$(grep -o 'HUB_REPO:-\${DOCKERHUB_USERNAME}/[a-z0-9._-]*' "$sync_tool" | sed 's|.*/||' | head -1)"
  if [ -z "$mirror_name" ] || [ -z "$tool_name" ] || [ "$mirror_name" != "$tool_name" ]; then
    err "the Overview sync targets '${tool_name:-nothing}' but the mirror pushes to '${mirror_name:-nothing}'; they must be the same Hub repository"
  fi
fi
# And it has to be documented as a mirror write, in the file that tells a maintainer
# what the secrets are for.
for f in MAINTAINING.md SECURITY.md; do
  if ! grep -Fq 'full_description' "$f"; then
    err "$f: no longer documents the Docker Hub Overview write (full_description)"
  fi
done

# Document charters. One table in MAINTAINING.md ("Which document owns what") is the
# single place a document's charter is written; every other document points at it
# instead of restating one. Asserted here because each way ownership rots is silent:
# a mechanism paragraph lands in SECURITY.md because that is where an auditor already
# was, a hand-copied registry fact lands in DISCLAIMER.md because it read better
# inline, and a release-model sentence lands in SUPPORTED.md because a gate demanded
# the literal in that file. Checking the rows keeps a charter from quietly widening --
# a document can be reworded, not redefined, without this gate saying so.
charter="$(awk '/^### Which document owns what/{f=1;next} f&&/^#{1,3} /{f=0} f' MAINTAINING.md)"
if [ -z "$charter" ]; then
  err "MAINTAINING.md: no 'Which document owns what' charter section -- that table is where a document's ownership is defined, and README.md's link table routes readers by it"
fi
charter_row() { # <document> <role literal>...
  doc="$1"; shift
  row="$(printf '%s\n' "$charter" | grep -F -- "| \`$doc\` |" | head -1 || true)"
  if [ -z "$row" ]; then
    err "MAINTAINING.md: the charter table has no row for \`$doc\` -- each document gets exactly one, and a document without one has no defined scope"
    return
  fi
  for want in "$@"; do
    if ! printf '%s' "$row" | grep -Fq -- "$want"; then
      err "MAINTAINING.md: the \`$doc\` charter no longer states \`${want}\` -- reword a charter deliberately, not by dropping a term from it"
    fi
  done
}
charter_row 'README.md' 'project introduction' 'quick use' 'security warnings'
charter_row 'SUPPORTED.md' 'actually built from' 'actually published' 'gen-supported.sh'
charter_row 'SECURITY.md' 'security policy' 'known vulnerabilities' 'coverage'
charter_row 'DEPLOYING.md' 'running, configuring, extending and deploying'
charter_row 'MAINTAINING.md' 'build, review and publish processes' 'gates that enforce'
charter_row 'DISCLAIMER.md' 'responsibility boundary'
charter_row 'manifests/SECURITY-REVIEW.md' 'PHP-side evidence register'
charter_row 'manifests/OS-CVE-STATUS.md' 'Debian-side evidence register'

# SECURITY.md's guarantee table and MAINTAINING.md's gate index are one agreement
# written across two documents: the table is what an auditor may rely on, the index
# is how CI earns the claim. Both halves rot silently -- a gate added with no
# guarantee beside it, a guarantee reworded until it names a gate that does not
# exist -- and no build fails on its own account, so the two name lists are
# compared in both directions here, the way tools/list-version-branches.sh compares
# markers against the version-branch inventory. The join is the exact name: a bullet
# `- **Name** ...` in MAINTAINING.md, a row `| Name | ... |` in SECURITY.md.
gates_section="$(awk '/^## Hardening gates \(what CI enforces\)/{f=1;next} f&&/^## /{f=0} f' MAINTAINING.md)"
if [ -z "$gates_section" ]; then
  err "MAINTAINING.md: no 'Hardening gates (what CI enforces)' section -- that index is where the mechanism behind each SECURITY.md guarantee is written, and without it the table below promises what nothing enforces"
fi
guarantee_section="$(awk '/^## What the pipeline guarantees/{f=1;next} f&&/^## /{f=0} f' SECURITY.md)"
if [ -z "$guarantee_section" ]; then
  err "SECURITY.md: no 'What the pipeline guarantees' section -- the policy claims belong there, one row per gate in MAINTAINING.md, and the mechanism belongs in MAINTAINING.md rather than in the security policy"
fi
if ! printf '%s' "$guarantee_section" | grep -Fq 'Hardening gates (what CI enforces)'; then
  err "SECURITY.md: the guarantee section no longer names MAINTAINING.md's 'Hardening gates (what CI enforces)' -- a reader has to be routed to the mechanism, not left with the claim alone"
fi
gates="$(printf '%s\n' "$gates_section" | sed -n 's/^- \*\*\([^*]*\)\*\*.*$/\1/p' | LC_ALL=C sort)"
guarantees="$(printf '%s\n' "$guarantee_section" | awk -F'|' '/^\|/ { c=$2; gsub(/^[ \t]+|[ \t]+$/, "", c); if (c == "" || c == "---" || c == "Guarantee") next; print c }' | LC_ALL=C sort)"
join_names() { sed -e '1!s/^/; /' | tr -d '\n'; }
unclaimed="$(comm -23 <(printf '%s\n' "$guarantees") <(printf '%s\n' "$gates") | sed '/^$/d' || true)"
if [ -n "$unclaimed" ]; then
  err "SECURITY.md guarantees with no gate bullet of that name in MAINTAINING.md ('Hardening gates (what CI enforces)'): $(printf '%s\n' "$unclaimed" | join_names)"
fi
unwritten="$(comm -13 <(printf '%s\n' "$guarantees") <(printf '%s\n' "$gates") | sed '/^$/d' || true)"
if [ -n "$unwritten" ]; then
  err "MAINTAINING.md gates with no guarantee row of that name in SECURITY.md ('What the pipeline guarantees'): $(printf '%s\n' "$unwritten" | join_names)"
fi
gate_n="$(printf '%s\n' "$gates" | sed '/^$/d' | wc -l | tr -d ' ')"
guar_n="$(printf '%s\n' "$guarantees" | sed '/^$/d' | wc -l | tr -d ' ')"
pairing_note=''
if [ -z "$unclaimed" ] && [ -z "$unwritten" ] && [ "$gate_n" -gt 0 ] && [ "$gate_n" = "$guar_n" ]; then
  pairing_note="Guarantee/gate pairing: ${guar_n} SECURITY.md claims, each with a MAINTAINING.md gate of the same name"
fi

# The routing table a reader actually uses has to cover the same set, or a charter
# becomes a list nobody can reach: adding a document to the table without a route
# leaves consumers to guess which file holds the answer.
routes="$(awk '/^## Documentation links/{f=1;next} f&&/^## /{f=0} f' README.md)"
if [ -z "$routes" ]; then
  err "README.md: no 'Documentation links' section -- the charters have to be reachable from the entry point"
fi
for d in DEPLOYING.md SUPPORTED.md SECURITY.md DISCLAIMER.md MAINTAINING.md manifests/SECURITY-REVIEW.md manifests/OS-CVE-STATUS.md; do
  if ! printf '%s' "$routes" | grep -Fq -- "$d"; then
    err "README.md: the Documentation links table no longer routes to $d, which MAINTAINING.md's charter table names as a document a reader needs"
  fi
done

if [ "$fail" = 0 ]; then
  printf 'Published image address: %s\n' "$published"
  printf 'Local build tag:         %s:<version>-<variant>-test (never pushed)\n' "$local_repo"
  printf 'Source release tag:      vX.Y.Z (vMAJOR.MINOR.PATCH) marks the commit built from; it names no series and carries no revision\n'
  printf 'Release entries:         A push v*.*.* -> every supported series | B dispatch one series | C dispatch a list or all\n'
  printf 'Release scope:           the entry (tag = all, dispatch = version input); PHP versions from manifests/<series>.env\n'
  printf 'Image revision:          derived by %s per PHP point version from the exact names the registry serves, which also decides publish/complete/skip; no revision input\n' "$plan_tool"
  printf 'Published tags:          %s:<full>-r<revision>-<variant> (immutable: a publish leg refuses one already served, a complete leg reuses it) and %s:<minor>-<variant> (floating); no latest tag\n' "$published" "$published"
  printf 'Trigger ownership:       %s publishes (tag push + dispatch, one concurrency group); %s has no push trigger; %s is dispatch-only\n' "$release_wf" "$ci_wf" "$sync_wf"
  printf 'Hub Overview sync:       %s, called once per release by %s (mirror-readme) and by %s for a README-only change; self-tested in both validate jobs\n' "$sync_tool" "$release_wf" "$sync_wf"
  printf 'Document charters:       MAINTAINING.md ("Which document owns what") states one per document, README.md routes to all of them\n'
  [ -z "$pairing_note" ] || printf '%s\n' "$pairing_note"
  printf 'Checked: %s, %s, build.sh, %s\n' "$build_wf" "$release_wf" "$(printf '%s' "$docs SECURITY.md" | tr '\n' ' ')"
fi
exit "$fail"
