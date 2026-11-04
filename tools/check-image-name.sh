#!/usr/bin/env bash
# check-image-name.sh -- keep the published image address consistent between the
# release pipeline and the documents that tell people what to pull.
#
# The published ref is <registry>/<namespace>/php, composed in
# .github/workflows/build-version.yml from its registry/namespace inputs, and
# the resulting address (ghcr.io/muffetlab/php) is what README.md,
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
# Usage: ./tools/check-image-name.sh   (exit 0 = consistent, 1 = drift)
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

build_wf=".github/workflows/build-version.yml"
release_wf=".github/workflows/release.yml"
docs="README.md MAINTAINING.md SUPPORTED.md docker-compose.example.yml docker-php-ext/README.md"

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

# Release naming model. Four version-shaped things, four separate jobs: a git tag
# marks a source release (vMAJOR.MINOR.PATCH), the workflow_dispatch input picks
# the scope (one series or all), manifests/<series>.env holds the PHP version, and
# the Docker tag names the image that came out (<minor>-<variant> floating,
# <full>-r<revision>-<variant> immutable). The assertions below are what keeps that
# division from sliding back: a tag push trigger or a build number inside a tag
# would put "which PHP version" and "which build" into the git ref again, which is
# the coupling that made a full release cost eight tags.

# release.yml is dispatch-only. A tag listener would have to parse the ref to know
# what to build, and the only thing a ref can say is a version.
if grep -Eq '^  push:' "$release_wf"; then
  err "${release_wf}: has a push: trigger again; the scope of a release is a workflow_dispatch input, not a git tag -- a tag trigger puts PHP version selection back into refs/tags (see MAINTAINING.md 'Publishing images')"
fi
if ! grep -Eq '^  workflow_dispatch:' "$release_wf"; then
  err "${release_wf}: has no workflow_dispatch trigger; this is the only release entry point"
fi

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
for site in "$release_wf" "$build_wf"; do
  grep -Fq -- '^[1-9][0-9]*$' "$site" || err "${site}: no longer requires a positive integer image revision before it can become part of a published name"
done
# Publishing is only allowed from the default branch, and only with a source
# release tag: a tag ref may not publish anything, because the ref no longer says
# what to build. Both halves are the callee's own gate, not just release.yml's.
# shellcheck disable=SC2016
for want in \
  'refs/heads/main|refs/heads/master) allowed=1 ;;' \
  'SOURCE_RELEASE: ${{ inputs.source_release }}' \
  'is not a source release tag'
do
  grep -Fq -- "$want" "$build_wf" || err "${build_wf}: no longer contains \`${want}\` -- push=true must require the default branch and a vMAJOR.MINOR.PATCH source release tag, so an image can never be published from untagged source"
done
if grep -Fq -- 'refs/tags/v[0-9]' "$build_wf"; then
  err "${build_wf}: gates publishing on a tag ref again; releases dispatch from the default branch and the source tag is checked by content, not by github.ref (see MAINTAINING.md 'Publishing images')"
fi
# The callee must be *told* what it is publishing: release.yml feeds the guard's
# outputs to the matrix leg, and the PHP version comes out of the manifest.
# shellcheck disable=SC2016
for want in \
  'source_release: ${{ needs.guard.outputs.release }}' \
  'revision: ${{ needs.guard.outputs.revision }}' \
  'version: ${{ matrix.series }}'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: no longer passes \`${want}\` to the release matrix -- the scope, revision and source tag are one hand-off from guard to the build job"
done
# shellcheck disable=SC2016
for want in \
  's/^SOURCE_REF=' \
  '"manifests/${series}.env"'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: the matrix no longer reads the PHP version out of \`${want}\` -- the reviewed manifest, not a tag or an input, is what says which PHP version this release builds"
done
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
  'steps.dispatch.outputs.selected' \
  'echo "selected=,$series," >> "$GITHUB_OUTPUT"' \
  'if [ "$series" = "all" ]; then' \
  'steps.srctag.outputs.release'
do
  grep -Fq -- "$want" "$release_wf" || err "${release_wf}: no longer contains \`${want}\` -- guard turns the dispatch input into the selected series list and the source release tag into the release output, and the matrix is built from both"
done
# An empty selection must be refused twice: validate's readiness step and the plan
# job that would otherwise emit a zero-entry matrix. Without either, a guard that
# emits only separators loops zero times, prints its success line for nothing, and
# the run goes green with no image published.
# shellcheck disable=SC2016
empty_refusals="$(grep -cF -- '[ "$#" -gt 0 ]' "$release_wf" || true)"
if [ "$empty_refusals" != 2 ]; then
  err "${release_wf}: ${empty_refusals} empty-selection refusals, expected 2 (the 'Selected series are release-ready' step and the plan job) -- a run with nothing selected must fail, not finish green with no image published"
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
# wrapped across a line break. Four things each doc must still state:
#   vX.Y.Z                    -- the shape of a source release tag
#   source release tag        -- what a git tag is for (it selects nothing)
#   8.1.34-r1                 -- an immutable image name, by example
#   Exact tags are never moved -- why pinning one is safe
# A doc that drops the second invites a maintainer to cut another tag for the second
# build of that PHP version, which is the model this project retired: the tag marks
# source, the input picks the scope, the manifest holds the version, and the image
# name carries the revision. Dropping the last one invites a reader to pin an exact
# name and wait for a fix that will never arrive under it.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
for f in README.md MAINTAINING.md SUPPORTED.md SECURITY.md; do
  [ -f "$f" ] || { err "$f: missing"; continue; }
  for want in 'vX.Y.Z' 'source release tag' '8.1.34-r1' 'Exact tags are never moved'; do
    if ! flat "$f" | grep -Fq -- "$want"; then
      err "$f: no longer states \`${want}\` -- see the release model in MAINTAINING.md ('Publishing images'): a git tag marks source (vX.Y.Z), the dispatch input picks the series or all, manifests/<series>.env holds the PHP version, and the image name carries the revision (-r<N>, and exact tags are never moved)"
    fi
  done
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

# The latest tag is gone: a release run publishes the series it selects -- one
# series for a single-series dispatch, all of them for version=all -- so
# a "latest-<variant>" name resolved to whichever series was released last --
# neither the newest PHP nor a recommendation, and an unrelated rebuild of an
# older series moved it backwards. A full release would move every latest name at
# once, which is the same silent-major-jump argument a single-series release cannot
# escape.
# <minor>-<variant> is the only floating name
# the pipeline writes, and it cannot change major version. Assert both halves of
# that: the publish step writes exactly the two tags, and no document advertises
# a latest address. A pull of an advertised-but-unpublished name is the failure
# this whole script exists to prevent.
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
# an oversight to anyone who expected the php:latest convention.
for f in README.md MAINTAINING.md SUPPORTED.md; do
  # shellcheck disable=SC2016
  if ! grep -Fq 'no `latest` tag' "$f"; then
    err "$f: no longer states that no latest tag is published (and why)"
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

if [ "$fail" = 0 ]; then
  printf 'Published image address: %s\n' "$published"
  printf 'Local build tag:         %s:<version>-<variant>-test (never pushed)\n' "$local_repo"
  printf 'Source release tag:      vX.Y.Z (vMAJOR.MINOR.PATCH) marks the dispatched commit; it selects no series and carries no revision\n'
  printf 'Release scope:           workflow_dispatch version=all or one series; PHP versions from manifests/<series>.env\n'
  printf 'Published tags:          %s:<full>-r<revision>-<variant> (immutable) and %s:<minor>-<variant> (floating); no latest tag\n' "$published" "$published"
  printf 'Trigger ownership:       %s is dispatch-only and the only release entry point; %s has no push trigger; %s is dispatch-only\n' "$release_wf" "$ci_wf" "$sync_wf"
  printf 'Hub Overview sync:       %s, called once per release by %s (mirror-readme) and by %s for a README-only change; self-tested in both validate jobs\n' "$sync_tool" "$release_wf" "$sync_wf"
  printf 'Checked: %s, %s, build.sh, %s\n' "$build_wf" "$release_wf" "$(printf '%s' "$docs SECURITY.md" | tr '\n' ' ')"
fi
exit "$fail"
