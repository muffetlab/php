#!/usr/bin/env bash
# sync-dockerhub-readme.sh -- put README.md where the mirror's consumers are:
# the Docker Hub repository's Overview, which is the `full_description` field of
# the repository's own metadata (not of any tag, and not the registry).
#
# Why this is a script and not the usual third-party action: every publish path in
# this kit is bash + curl so that a maintainer can read exactly what the release
# does and run any single step of it against a stub. The reference action
# (peter-evans/dockerhub-description) makes the same two calls:
#
#   POST https://hub.docker.com/v2/auth/token
#        body {"identifier": <username>, "secret": <password-or-PAT>}
#        -> {"access_token": ...}
#   PATCH https://hub.docker.com/v2/repositories/<namespace>/<name>
#        header Authorization: Bearer <access_token>
#        body {"full_description": "<markdown>"}
#
# PATCH, not PUT: this is a partial update of repository metadata. Sending a PUT
# body that omits the other fields would be a guess about what the omitted ones
# default to, and this file has a standing rule against guessing at a write.
#
# The content is README.md with its relative links rewritten to absolute blob URLs
# at the exact commit being released. Docker Hub resolves a relative link against
# hub.docker.com, so an unmodified README shows a page of broken links -- and the
# links that break are the ones to DISCLAIMER.md and SECURITY.md, which are the
# two documents a consumer of legacy-PHP images most needs to be able to open.
# Pinning the rewrite to a commit SHA (not a branch name) is deliberate: the
# Overview a release leaves behind then points at the README that release used.
#
# The Hub caps `full_description` at 25000 bytes and truncates above it, so the
# size is measured and rejected before anything is sent rather than discovered in
# the rendered page afterwards.
#
# The short summary (`description`) is left alone. It is already set on this
# repository and is a different, hand-tuned sentence; overwriting it from a
# heading would silently degrade it on every release.
#
# Usage:
#   ./tools/sync-dockerhub-readme.sh                 # requires the two env vars below
#   ./tools/sync-dockerhub-readme.sh --dry-run       # no network, no credentials
#   ./tools/sync-dockerhub-readme.sh --print-payload # JSON body to stdout, nothing sent
#   ./tools/sync-dockerhub-readme.sh --help
#
# Environment:
#   DOCKERHUB_USERNAME  Hub account that owns the mirror; the namespace of the
#                       repository that gets written. Required unless --dry-run.
#   DOCKERHUB_TOKEN     PAT for that account. Needs the Hub's repository write, so
#                       an account token with read+write; a token that can only
#                       `docker login` gets a 403 here and says so.
#   HUB_REPO            <namespace>/<name>; defaults to ${DOCKERHUB_USERNAME}/php,
#                       which is the mirror name build-version.yml pushes to.
#   README_FILE         default README.md (relative to the repository root).
#   GH_BLOB_BASE        prefix for rewritten links; defaults to
#                       ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/blob/${GITHUB_SHA}/
#   HUB_MAX_BYTES       default 25000 (the Hub's own cap).
#   HUB_BASE_URL        default https://hub.docker.com (override for a stub).
#
# Exit 0 = the Overview now says what README.md said at this commit (checked by
# reading the repository back with no credentials). Non-zero = nothing was
# confirmed; the reason is on stderr as a ::error:: annotation.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

HUB_BASE_URL="${HUB_BASE_URL:-https://hub.docker.com}"
HUB_MAX_BYTES="${HUB_MAX_BYTES:-25000}"
README_FILE="${README_FILE:-README.md}"

dry_run=0
print_payload=0
self_test=0
mode=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --print-payload) print_payload=1 ;;
    --self-test) self_test=1 ;;
    -h|--help) mode="help" ;;
    *) printf 'unknown argument: %s (see --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$mode" = help ]; then
  sed -n '2,/^set -eu$/p' "$0" | sed '$d'
  exit 0
fi

fail=0
err() {
  printf '::error::%s\n' "$*" >&2
  fail=1
}
note() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- link rewrite
# Rewrite ](<path>.md) and ](<path>.md#anchor) to ](<blob-base><path>.md#anchor).
# A URL containing ":" (a scheme) can never match the character class, so absolute
# links pass through untouched, and so do in-page anchors like ](#section) --
# those still point inside the rendered Overview.
# Rewritten with | as the sed delimiter because the pattern itself contains a
# literal # (the anchor) and the base URL contains a / and a :.
rewrite_links() { # <blob-base>
  local base="$1"
  sed -E "s|]\(([A-Za-z0-9_./-]+\.md(#[A-Za-z0-9_-]+)?)\)|](${base}\1)|g"
}

# ------------------------------------------------------------------ status code
# curl's -w prints the status code even when the transfer then fails, so
# "code=$(curl ... || echo 000)" can capture BOTH: "405000" for a server that
# answered 405 and dropped the connection mid-read, which matches no case and
# turns a precise error into a mystery. The same trap is spelled out in the
# anonymous read-back step of release.yml. So: keep the digits curl printed and
# fall back to 000 only when it printed nothing, i.e. it failed before a response.
# Measured, not theorised: a stub that answered PATCH with 405 and reset produced
# exactly the "405000" string this function now collapses to 405.
http_code() { # <raw output of curl -w '%{http_code}'>
  local digits="${1//[^0-9]/}"
  if [ "${#digits}" -lt 3 ]; then
    printf '000'
  else
    printf '%s' "${digits:0:3}"
  fi
}

# ------------------------------------------------------------ read-back probe
# Whether the write landed is judged against the README's first line, and that
# comparison has to survive two things a server is free to do to the same bytes:
# pretty-print (both "key": " and "key":" shapes, handled where the probe is used)
# and escape non-ASCII -- emit this README's en dash as an escape sequence instead
# of the three bytes it is on disk. So the probe is the first line cut at its first
# non-ASCII byte. Shorter than 20 characters would prove too little (a page that
# merely contains "Legacy" is not evidence of a write), so a first line that is
# already ASCII is compared whole, and only a non-ASCII opening is shortened.
readback_probe() { # <readme-file>
  local first_line probe
  first_line="$(head -1 "$1" | tr -d '\r')"
  [ -n "$first_line" ] || return 1
  probe="$(printf '%s' "$first_line" | LC_ALL=C sed -E 's/[^ -~].*$//')"
  if [ "${#probe}" -ge 20 ]; then
    printf '%s' "$probe"
  else
    printf '%s' "$first_line"
  fi
}

# --------------------------------------------------------------------- escaper
# JSON string escaping for the markdown: backslash and double quote first, then
# the few control characters this repository's README can actually contain. UTF-8
# (em-dashes, arrows) is passed through as bytes, which is valid JSON.
json_escape() {
  awk '
    {
      line = $0; out = ""; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if      (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\t") out = out "\\t"
        else                out = out c
      }
      lines[++count] = out
    }
    END {
      for (i = 1; i <= count; i++) printf "%s%s", (i > 1 ? "\\n" : ""), lines[i]
    }
  '
}

build_payload() { # <blob-base> -- writes the JSON body to stdout
  local base="$1"
  {
    printf '{"full_description": "'
    rewrite_links "$base" < "$README_FILE" | json_escape
    printf '"}\n'
  }
}

if [ "$self_test" = 1 ]; then
  # The escaper and the rewriter are the two places a silent corruption would be
  # invisible until someone read the live page, so both are pinned here. No
  # network, no credentials: this runs in the validate gate.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  printf '# Title\n\n[DISCLAIMER](DISCLAIMER.md), [security](SECURITY.md#policy),\n[a site](https://example.com/x.md) and [top](#using-the-images).\n\nuse "quotes" and a \\ backslash\n' > "$tmp/README.md"
  README_FILE="$tmp/README.md"
  out="$(build_payload 'https://github.com/o/r/abcdef/')"
  printf '%s\n' "$out" > "$tmp/payload.json"
  check() { # <label> <fixed-string>
    if printf '%s' "$out" | grep -Fq -- "$2"; then note "  ok: $1"; else err "$1: not found in payload: $2"; fi
  }
  refuse() { # <label> <string that must NOT appear>
    if printf '%s' "$out" | grep -Fq -- "$2"; then err "$1: unexpected text in payload: $2"; else note "  ok: $1"; fi
  }
  check "relative .md link rewritten"        '](https://github.com/o/r/abcdef/DISCLAIMER.md)'
  check "anchor inside file rewritten"       '](https://github.com/o/r/abcdef/SECURITY.md#policy)'
  refuse "absolute URL untouched"            '](https://github.com/o/r/abcdef/https://example.com'
  check "absolute URL kept"                  '](https://example.com/x.md)'
  check "in-page anchor kept"                '](#using-the-images)'
  check "quotes escaped"                     '\"quotes\"'
  check "backslash escaped"                  'a \\ backslash'
  check "lines joined with \\n"              '\n[a site]'
  # The status-code reader is pinned too: every failure branch of the network path
  # keys off its output, and the bug it prevents produced a string that matched no
  # branch at all. A code shorter than three digits is not a status line (an error
  # message with a number in it, e.g. "curl: (7)"), so it reads as unreachable.
  hc() { # <label> <raw curl output> <expected code>
    if [ "$(http_code "$2")" = "$3" ]; then
      note "  ok: $1"
    else
      err "$1: http_code of '$2' gave '$(http_code "$2")', expected '$3'"
    fi
  }
  hc "plain code passes through"                      '405'    '405'
  hc "curl -w plus a failed transfer collapses to the code" '405000' '405'
  hc "no output means unreachable"                    ''       '000'
  hc "a stray number is not a status code"            'curl: (7)' '000'
  # The read-back probe, pinned on this repository's real first line and on the two
  # rules that keep it from crying wolf: keep the "# " marker (the body is the file),
  # and stop at the first non-ASCII byte so an escaped en dash cannot fail a write
  # that succeeded. The real title is pure ASCII, so the non-ASCII rule needs its own
  # input: the second fixture is the scope-carrying title form ("... (PHP 5.6 – 8.1,
  # CLI + FPM)") that the probe had to survive, kept here even though README.md no
  # longer uses it, because that is the case the rule exists for.
  probe_is() { # <label> <file> <expected>
    local got
    got="$(readback_probe "$2")"
    if [ "$got" = "$3" ]; then
      note "  ok: $1"
    else
      err "$1: probe was '$got', expected '$3'"
    fi
  }
  printf '# Legacy PHP Security Images\n\nbody\n' > "$tmp/real.md"
  printf 'Short ASCII title\nbody\n' > "$tmp/short.md"
  printf '# Legacy PHP Security Images (PHP 5.6 – 8.1, CLI + FPM)\n\nbody\n' > "$tmp/dash.md"
  printf '\nbody, no title at all\n' > "$tmp/blank.md"
  probe_is "the real title is used whole, marker and all"           "$tmp/real.md" '# Legacy PHP Security Images'
  probe_is "a scope-carrying title stops at the en dash"            "$tmp/dash.md" '# Legacy PHP Security Images (PHP 5.6 '
  probe_is "an already-ASCII line is used whole even when short"    "$tmp/short.md" 'Short ASCII title'
  if readback_probe "$tmp/blank.md" >/dev/null 2>&1; then
    err "a README with an empty first line should be refused, and was not"
  else
    note "  ok: an empty first line is refused rather than matched trivially"
  fi
  [ "$fail" = 0 ] && note 'sync-dockerhub-readme self-test OK'
  exit "$fail"
fi

blob_base="${GH_BLOB_BASE:-}"
if [ -z "$blob_base" ]; then
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ]; then
    blob_base="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/blob/${GITHUB_SHA}/"
  elif [ "$dry_run" = 1 ] || [ "$print_payload" = 1 ]; then
    blob_base="https://github.com/muffetlab/php/blob/HEAD/"
  else
    err "cannot build the blob URL base: set GH_BLOB_BASE, or run where GITHUB_REPOSITORY and GITHUB_SHA are set"
    exit 1
  fi
fi

[ -f "$README_FILE" ] || { err "$README_FILE not found at $(pwd)"; exit 1; }

payload="$(build_payload "$blob_base")"
size="$(printf '%s' "$payload" | wc -c | tr -d ' ')"

if [ "$print_payload" = 1 ]; then
  printf '%s\n' "$payload"
  exit 0
fi

note "Blob link base:     $blob_base"
note "README source:      $README_FILE"
note "Payload size:       ${size} bytes (Hub cap ${HUB_MAX_BYTES})"

if [ "$size" -gt "$HUB_MAX_BYTES" ]; then
  err "the rewritten README is ${size} bytes, over the Hub's ${HUB_MAX_BYTES}-byte full_description cap; the Hub truncates silently above it, so nothing was sent. Shorten README.md or point README_FILE at a shorter document."
  exit 1
fi

# How many relative links the rewrite touched, as a count of the base URL in the
# payload -- a release that quietly restructured README.md would otherwise show up
# only as a page of dead links.
rewritten="$(printf '%s' "$payload" | grep -o "$blob_base" | wc -l | tr -d ' ')"
note "Relative links:     ${rewritten} rewritten to absolute blob URLs"

if [ "$dry_run" = 1 ]; then
  note "Dry run: nothing sent."
  exit 0
fi

[ -n "${DOCKERHUB_USERNAME:-}" ] || { err "DOCKERHUB_USERNAME is not set (the mirror namespace)"; exit 1; }
[ -n "${DOCKERHUB_TOKEN:-}" ]    || { err "DOCKERHUB_TOKEN is not set (a PAT that may write repository metadata)"; exit 1; }
hub_repo="${HUB_REPO:-${DOCKERHUB_USERNAME}/php}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The token never goes on a command line (argv is readable by anything on the
# runner) and never appears in a log line. Both the body and the header are
# handed to curl through files.
cat > "$tmp/auth.json" <<EOF
{"identifier": "$(printf '%s' "$DOCKERHUB_USERNAME" | sed 's/\\/\\\\/g; s/"/\\"/g')", "secret": "$(printf '%s' "$DOCKERHUB_TOKEN" | sed 's/\\/\\\\/g; s/"/\\"/g')"}
EOF
printf '%s' "$payload" > "$tmp/body.json"

# ------------------------------------------------------------------ 1. exchange
tok_raw="$(curl -sS --max-time 60 -o "$tmp/token.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data @"$tmp/auth.json" \
  "${HUB_BASE_URL}/v2/auth/token" || true)"
tok_http="$(http_code "$tok_raw")"
case "$tok_http" in
  200|201) : ;;
  401|403) err "Docker Hub refused the credentials (HTTP ${tok_http}) at /v2/auth/token: wrong username, or a token whose scope does not include the repository write."; exit 1 ;;
  000)     err "could not reach ${HUB_BASE_URL} at all (curl failed); the Overview was not updated."; exit 1 ;;
  *)       err "unexpected HTTP ${tok_http} from /v2/auth/token: $(head -c 200 "$tmp/token.json" 2>/dev/null || true)"; exit 1 ;;
esac
# The response is one JSON object; the token is its access_token field. Parsed
# with grep/sed because no JSON tool is a dependency of this repository.
access_token="$(grep -o '"access_token":"[^"]*"' "$tmp/token.json" | sed 's/^"access_token":"//; s/"$//' || true)"
[ -n "$access_token" ] || { err "Docker Hub answered HTTP ${tok_http} with no access_token field; nothing was written."; exit 1; }

# ------------------------------------------------------------------- 2. write
printf 'header = "Authorization: Bearer %s"\n' "$access_token" > "$tmp/curlrc"
chmod 600 "$tmp/curlrc"
patch_raw="$(curl -sS --max-time 120 --config "$tmp/curlrc" -o "$tmp/patch.json" -w '%{http_code}' \
  -X PATCH \
  -H 'Content-Type: application/json' \
  --data @"$tmp/body.json" \
  "${HUB_BASE_URL}/v2/repositories/${hub_repo}/" || true)"
patch_http="$(http_code "$patch_raw")"
case "$patch_http" in
  200|201|204) : ;;
  401|403) err "Docker Hub refused the metadata write for ${hub_repo} (HTTP ${patch_http}): the token authenticates but may not write this repository. The images are unaffected; the Overview is simply still the old one."; exit 1 ;;
  404) err "no Docker Hub repository at ${hub_repo} (HTTP 404): the mirror has never been pushed under this namespace, so there is nothing to describe. Push a release with the mirror secrets set, or create the repository first."; exit 1 ;;
  000) err "could not reach ${HUB_BASE_URL} for the metadata write (curl failed); the Overview may or may not have changed -- read it before retrying." ; exit 1 ;;
  *) err "unexpected HTTP ${patch_http} from PATCH /v2/repositories/${hub_repo}/: $(head -c 200 "$tmp/patch.json" 2>/dev/null || true)"; exit 1 ;;
esac

# ------------------------------------------------------------ 3. read it back
# Same rule as every other publish claim in this kit: ask the service whether it
# took, with no credentials this time, because the mirror is public. Matching the
# README's own first line inside full_description is what proves the body landed --
# a 200 alone only proves the request was accepted.
get_raw="$(curl -sS --max-time 60 -o "$tmp/repo.json" -w '%{http_code}' \
  "${HUB_BASE_URL}/v2/repositories/${hub_repo}/" || true)"
get_http="$(http_code "$get_raw")"
if [ "$get_http" != 200 ]; then
  err "write accepted (HTTP ${patch_http}) but the read-back failed (HTTP ${get_http}); check the Overview at https://hub.docker.com/r/${hub_repo}/ before trusting this run."
  exit 1
fi
# What counts as "the body landed": full_description opens with README.md's first
# line, "# " marker and all, because that is what the file starts with and the body
# is the file. An earlier version of this check stripped the marker off the heading
# and then required the value to begin with the stripped text, which failed against
# a perfectly good write -- caught by the stub, not by reading. Both spacings are
# accepted for the same reason; readback_probe explains the non-ASCII rule.
probe="$(readback_probe "$README_FILE")" || { err "$README_FILE starts with an empty line, so there is no title to verify the write against"; exit 1; }
escaped_probe="$(printf '%s' "$probe" | sed 's/\\/\\\\/g; s/"/\\"/g')"
if grep -Fq "\"full_description\": \"${escaped_probe}" "$tmp/repo.json" || grep -Fq "\"full_description\":\"${escaped_probe}" "$tmp/repo.json"; then
  note "Docker Hub Overview for ${hub_repo} opens with README.md's first line (matched on '${probe}'); read back without credentials at HTTP ${get_http}."
else
  err "the write was accepted (HTTP ${patch_http}) but the read-back of ${hub_repo} does not open with '${probe}'. Check https://hub.docker.com/r/${hub_repo}/ -- the Hub may have rewritten the body, or full_description is still null."
  exit 1
fi

exit "$fail"
