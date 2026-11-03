#!/bin/sh
# Report what a built image is actually made of, in bytes you can act on.
#
# Why this exists: every size decision in this kit (ship the source tree or not,
# keep the configured build tree, delete .git) has a trade-off, and none of it
# can be measured on a machine without Docker -- which is most of the review
# loop. This runs in CI right after the build, so the numbers land in the job
# summary next to the decision they belong to instead of being guessed.
#
# It reports, it does not gate: a threshold would just encode a guess about the
# base image someone chose. Set BUDGET_MB to get an explicit over/under line.
#
# Usage: tools/report-image-size.sh <image-ref> [label]
# Env:   BUDGET_MB            optional uncompressed-size budget in MB (warning only)
#        GITHUB_STEP_SUMMARY  written when present (CI job summary)
set -eu

IMAGE="${1:-}"
LABEL="${2:-$IMAGE}"
[ -n "$IMAGE" ] || { echo "usage: tools/report-image-size.sh <image-ref> [label]" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "size-report: docker is not available" >&2; exit 2; }

mb() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1048576 }'; }

# docker image inspect prints 0 rather than failing when the image or the
# daemon is unavailable, so downstream arithmetic always has a number to work
# with; the report says so explicitly instead of aborting mid-table.
total="$(docker image inspect --format '{{.Size}}' "$IMAGE" 2>/dev/null || echo 0)"
case "$total" in '' | *[!0-9]*) total=0 ;; esac

# One container run covers the whole interior breakdown: largest directories,
# the build's own cleanup record, the shipping decision, and the warnings.
# Starting a container per question was needlessly slow, and each extra run was
# another chance for an unusual base image to break the report.
# -w / so an image whose WORKDIR does not exist yet still starts (docker refuses
# otherwise), and the probe must never be the reason a build looks broken.
breakdown="$(docker run --rm -i -w / -e TOTAL_BYTES="$total" --entrypoint /bin/sh "$IMAGE" <<'EOS' 2>/dev/null || true
total="${TOTAL_BYTES:-0}"
kb() { du -sk "$1" 2>/dev/null | cut -f1; }

for d in /usr/src/php /opt/php /opt/php/bin /opt/php/lib /opt/php/include \
         /usr/local /usr/lib /usr/share /var /etc; do
  [ -e "$d" ] || continue
  s="$(kb "$d")"
  [ -n "$s" ] || s=0
  printf '%10.1f MB  %s\n' "$(awk -v k="$s" 'BEGIN { print k / 1024 }')" "$d"
done
echo "--- top-level ---"
for d in /*; do
  s="$(kb "$d")"
  [ -n "$s" ] || continue
  printf '%10.1f MB  %s\n' "$(awk -v k="$s" 'BEGIN { print k / 1024 }')" "$d"
done | sort -rn | head -8

if [ -s /opt/php/BUILD-CLEANUP ]; then
  echo "--- build cleanup record (KB measured inside the build stage) ---"
  cat /opt/php/BUILD-CLEANUP
else
  echo "--- no /opt/php/BUILD-CLEANUP record (image built before the cleanup step?) ---"
fi

if [ -f /usr/src/php/SOURCE-NOT-SHIPPED ]; then
  echo "--- source tree omitted (SHIP_PHP_SOURCE=0): docker-php-ext-install is unavailable ---"
fi

if [ -d /usr/src/php/.git ]; then
  echo "WARNING: /usr/src/php/.git is present in the final image; the build must delete it"
fi

src="$(kb /usr/src/php)"
[ -n "$src" ] || src=0
if [ "$total" -gt 0 ] && [ "$src" -gt 0 ]; then
  share="$(awk -v s="$src" -v t="$total" 'BEGIN { printf "%.0f", s * 1024 / t * 100 }')"
  echo "--- /usr/src/php is ${share}% of the uncompressed image ---"
  if [ "$share" -ge 30 ]; then
    echo "HINT: that is what in-image docker-php-ext-install pays for."
    echo "HINT: set SHIP_PHP_SOURCE=0 in the manifest if this deployment never builds extensions."
  fi
fi
EOS
)"

{
  echo "## Image size: ${LABEL}"
  echo
  echo "Uncompressed size: **$(mb "$total") MB** (${total} bytes)"
  if [ -n "${BUDGET_MB:-}" ]; then
    case "$BUDGET_MB" in
      *[!0-9]* | '') echo "(BUDGET_MB='${BUDGET_MB}' is not a whole number of MB; budget line skipped)" ;;
      *)
        budget_bytes=$((BUDGET_MB * 1048576))
        if [ "$total" -gt "$budget_bytes" ]; then
          echo "Over the ${BUDGET_MB} MB budget by $(mb "$((total - budget_bytes))") MB."
        else
          echo "Within the ${BUDGET_MB} MB budget ($(mb "$((budget_bytes - total))") MB spare)."
        fi
        ;;
    esac
  fi
  echo

  echo "### Largest layers"
  echo '```'
  layers="$(docker history --no-trunc --format "$(printf '{{.Size}}\t{{.CreatedBy}}')" "$IMAGE" 2>/dev/null \
    | awk -F'\t' '{ printf "%s\t%s\n", $1, substr($2, 1, 76) }' | head -12 || true)"
  if [ -n "$layers" ]; then
    printf '%s\n' "$layers"
  else
    echo "(docker history unavailable for this image)"
  fi
  echo '```'
  echo

  echo "### Where the bytes are inside the image"
  echo '```'
  if [ -n "$breakdown" ]; then
    printf '%s\n' "$breakdown"
  else
    echo "(no output from the in-image probe: the image has no /bin/sh, or docker run failed)"
  fi
  echo '```'
} 2>&1 | tee /tmp/size-report.$$

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat /tmp/size-report.$$ >> "$GITHUB_STEP_SUMMARY"
fi
rm -f /tmp/size-report.$$
