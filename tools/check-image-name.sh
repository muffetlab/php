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
#   - release.yml repeats the namespace fallback in every release job
#   - the GHCR package-visibility job must name the package by the image path
#     after ghcr.io/ (namespace/php), not by an invented one
# and the local build tag (build.sh + its README examples), which is never
# pushed but is still an image name the documentation shows people.
#
# The release tag scheme and the trigger ownership are checked here too because
# they are the same class of consistency: which ref produces a published image,
# and which workflow is allowed to act on it.
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

# Release tag scheme. The "-legacy" suffix was dropped (v8.1.34, not
# v8.1.34-legacy), and the trigger glob is now the loose "v*", so the shape rule
# has to live in code: assert the trigger, the guard job and the build job agree,
# and that the docs still state the one-tag-per-version rule the user chose --
# rebuilding a version moves v8.1.34 rather than publishing v8.1.34-2.
tag_trigger="$(sed -n 's/^      - "\(v[^"]*\)"$/\1/p' "$release_wf" | head -1)"
if [ "$tag_trigger" != "v*" ]; then
  err "${release_wf}: the tag trigger is '${tag_trigger:-unset}', expected 'v*' (documented everywhere as vX.Y.Z)"
fi
# Exact form: no optional suffix. If a suffix ever comes back, that is a change
# to the release policy, and it has to be made here and in the docs together.
for site in "$release_wf" "$build_wf"; do
  if ! grep -Fq "^v[0-9]+\\.[0-9]+\\.[0-9]+\$" "$site"; then
    err "${site}: the release tag shape is no longer exactly vX.Y.Z (one tag per PHP version)"
  fi
done
if grep -Eq '\(\-\[0-9A-Za-z\]' "$release_wf" "$build_wf"; then
  err "a release tag regex accepts a suffix again; rebuilds move the existing vX.Y.Z tag instead (see MAINTAINING.md 'Publishing images')"
fi
if ! grep -Fq 'refs/tags/v[0-9]*' "$build_wf"; then
  err "${build_wf}: push is no longer restricted to version-shaped tags (refs/tags/v[0-9]*)"
fi
if ! grep -Fq 'names PHP series' "$release_wf"; then
  err "${release_wf}: the guard job no longer cross-checks the tag's PHP series against the supported list"
fi
# Trigger ownership. release.yml is the only workflow that may run on a tag push,
# because a second tag listener would build the same 8-version chain twice from
# one tag: their concurrency groups differ (build-and-verify-<ref> vs
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
# One series per release run. Every release job must gate on the series guard
# selected, and the series it gates on must be the version it builds -- a dropped
# "if:" would quietly rebuild the whole chain from one tag again, and a gate that
# names another series would never run at all. Compared as two sorted lists so
# this stays one assertion instead of a hardcoded copy of the version table.
gates="$(grep -o "if: needs.guard.outputs.series == '[0-9.]*'" "$release_wf" | sed "s/.*'\([0-9.]*\)'/\1/" | sort | tr '\n' ' ')"
built="$(grep -o 'version: "[0-9.]*"' "$release_wf" | sed 's/.*"\([0-9.]*\)"/\1/' | sort | tr '\n' ' ')"
if [ -z "${gates// /}" ] || [ "$gates" != "$built" ]; then
  err "${release_wf}: the release jobs' series gates (${gates:-none}) do not match the versions they build (${built}) -- each release-* job needs if: needs.guard.outputs.series == '<version>'"
fi
for f in README.md MAINTAINING.md SUPPORTED.md SECURITY.md; do
  if ! grep -Fq 'vX.Y.Z' "$f"; then
    err "$f: does not document the vX.Y.Z release tag scheme"
  fi
done
for f in README.md MAINTAINING.md SUPPORTED.md SECURITY.md; do
  if ! grep -Fiq 'one tag per PHP version' "$f"; then
    err "$f: no longer states that a rebuild moves the existing tag (one tag per PHP version)"
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

# The latest tag is gone: one release run publishes one PHP series, so a
# "latest-<variant>" name resolved to whichever series someone tagged last --
# neither the newest PHP nor a recommendation, and an unrelated rebuild of an
# older series moved it backwards. <minor>-<variant> is the only floating name
# the pipeline writes, and it cannot change major version. Assert both halves of
# that: the publish step writes exactly the two tags, and no document advertises
# a latest address. A pull of an advertised-but-unpublished name is the failure
# this whole script exists to prevent.
# shellcheck disable=SC2016
if grep -Fq -- '-t ${repo}:latest' "$build_wf"; then
  err "${build_wf}: the publish step writes a latest tag again; there is no latest tag (see MAINTAINING.md 'Publishing images')"
fi
# shellcheck disable=SC2016
tag_writes="$(grep -c -- '-t ${repo}:' "$build_wf")"
if [ "$tag_writes" != "2" ]; then
  err "${build_wf}: the publish step writes ${tag_writes} tags, expected 2 (<full-php-version>-<variant> and <minor>-<variant>) -- a change here is a change to the published namespace and to the docs"
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
# however many releases since with no failing job anywhere; drop the variant gate and
# both merge legs PATCH the same repository so one green leg covers the other's
# failure; give the manual workflow a push or pull_request trigger and a branch that
# is not main can write the mirror's page with the mirror's secrets. Asserted here
# for the same reason the trigger ownership above is: there is no actionlint step.
sync_tool="tools/sync-dockerhub-readme.sh"
sync_wf=".github/workflows/sync-dockerhub-readme.yml"
[ -f "$sync_tool" ] || { err "$sync_tool not found (the Overview sync is documented, so it has to exist)"; }
[ -f "$sync_wf" ] || err "$sync_wf not found (MAINTAINING.md documents a manual dispatch path for the Overview)"
if [ -f "$build_wf" ] && ! grep -Fq "./$sync_tool" "$build_wf"; then
  err "${build_wf}: no longer calls ${sync_tool}, so releases stop updating the mirror's Overview while the docs still say they do"
fi
if [ -f "$build_wf" ] && ! grep -Fq "matrix.variant == 'cli'" "$build_wf"; then
  err "${build_wf}: the Overview sync lost its matrix.variant == 'cli' gate; both merge legs would write the same repository metadata from one release"
fi
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
  printf 'Release tag scheme:      refs/tags/v[0-9]* with shape exactly vX.Y.Z, one tag per version, trigger "%s"\n' "$tag_trigger"
  printf 'Published tags:          %s:<full>-<variant> and %s:<minor>-<variant>; no latest tag\n' "$published" "$published"
  printf 'Trigger ownership:       %s is tag-only; %s has no push trigger; %s is dispatch-only\n' "$release_wf" "$ci_wf" "$sync_wf"
  printf 'Hub Overview sync:       %s, called by %s (cli leg) and %s; self-tested in both validate jobs\n' "$sync_tool" "$build_wf" "$sync_wf"
  printf 'Checked: %s, %s, build.sh, %s\n' "$build_wf" "$release_wf" "$(printf '%s' "$docs SECURITY.md" | tr '\n' ' ')"
fi
exit "$fail"
