#!/usr/bin/env bash
# OS-vulnerability gate for a built or pulled image.
#
# What it decides, in one sentence: whether a scanner finding against this image is
# something Debian could have fixed for us and we did not take it (a kit defect, and
# a build failure), or something Debian publishes no fix for (a reviewed fact, and a
# row in manifests/OS-CVE-STATUS.md).
#
# Why it is not just "run a scanner": every finding this tool was written about
# (curl CVE-2026-86414 / CVE-2026-92388, plus the sqlite3 and zlib rows) is already
# at the newest version Debian ships for the suite the image is built on. A scanner
# that compares against upstream version strings will report all of them forever, and
# a gate that simply fails on High/Critical would either block every release or be
# silenced wholesale. So the decision is keyed on two things this tool can measure:
# the packages the image actually contains (/opt/php/RUNTIME-OS-PACKAGES, written by
# the runtime stage and re-checked by tools/verify-runtime.sh), and what that image's
# own suite offers today (an apt simulation run *inside* the image).
#
# Usage:
#   tools/scan-image.sh IMAGE [options]
#     --findings FILE|-   scanner output to classify: trivy JSON, or any text
#                         containing CVE ids. Repeatable. With none, the tool runs
#                         trivy from PATH; if there is no scanner at all the verdict
#                         is `unverified`, not `clean`, and the gate fails.
#     --register FILE     CVE register (default: manifests/OS-CVE-STATUS.md)
#     --severity LIST     severity filter for trivy JSON (default HIGH,CRITICAL)
#     --no-probe          skip the in-image apt currency probe (offline runs)
#     --json-out FILE     write the machine-readable report
#     --quiet             only the verdict lines
#
# Exit: 0 = nothing to fix, 1 = a finding needs action or the scan never ran
#       (verdict `unverified`), 2 = usage or a missing prerequisite.
#
# bash 3.2 (the /bin/bash macOS ships) is a supported platform: no associative
# arrays, no mapfile, and every empty-array expansion is guarded because `set -u`
# makes `${a[@]}` on an empty array a hard error there.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=""
REGISTER="${ROOT}/manifests/OS-CVE-STATUS.md"
SEVERITY="HIGH,CRITICAL"
PROBE=1
JSON_OUT=""
QUIET=0
declare -a FINDINGS=()

say()  { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
err()  { printf 'FAIL  %s\n' "$*" >&2; }
trim() { printf '%s' "$1" | sed -e 's/^ *//' -e 's/[ ]*$//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --findings) FINDINGS+=("${2:?--findings needs a file or -}"); shift 2 ;;
    --register) REGISTER="${2:?--register needs a file}"; shift 2 ;;
    --severity) SEVERITY="${2:?--severity needs a list}"; shift 2 ;;
    --no-probe) PROBE=0; shift ;;
    --json-out) JSON_OUT="${2:?--json-out needs a path}"; shift 2 ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "Unknown option: $1" >&2; exit 2 ;;
    *)          [ -z "$IMAGE" ] || { echo "One image at a time (got $IMAGE and $1)" >&2; exit 2; }
                IMAGE="$1"; shift ;;
  esac
done

[ -n "$IMAGE" ] || { echo "Usage: ${0##*/} IMAGE [--findings FILE] [--register FILE]" >&2; exit 2; }
[ -r "$REGISTER" ] || { echo "Register not readable: $REGISTER" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || {
  echo "docker is required: this gate reads the image, not the manifest." >&2
  echo "On macOS: brew install docker --cask, then start Docker Desktop." >&2
  exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "No such image locally: $IMAGE" >&2
  echo "     Build it (./build.sh <version> <variant>) or pull it first; this gate" >&2
  echo "     answers questions about a real artifact and refuses to infer them." >&2
  exit 2; }

# --- 1. what the image actually contains ---------------------------------------
INVENTORY="$(docker run --rm --entrypoint cat "$IMAGE" /opt/php/RUNTIME-OS-PACKAGES 2>/dev/null)" || INVENTORY=""
if [ -z "$INVENTORY" ]; then
  err "$IMAGE has no /opt/php/RUNTIME-OS-PACKAGES"
  echo "     The runtime stage writes that file. An image without it predates the" >&2
  echo "     inventory, so its packages can only be guessed from the base tag -- which" >&2
  echo "     is the guess this gate refuses to make. Rebuild it, or treat the result of" >&2
  echo "     any scan of this image as unverified rather than clean." >&2
  exit 1
fi
PKG_COUNT="$(printf '%s\n' "$INVENTORY" | sed -e '/^base_image=/d' -e '/^collected_at=/d' -e '/^format=/d' | grep -c .)"
BASE_IMAGE_LINE="$(printf '%s\n' "$INVENTORY" | sed -n 's/^base_image=//p' | head -1)"
# Suite, from the base reference the build recorded. A case statement rather than
# a sed alternation because macOS ships BSD sed, which does not support \| in BRE --
# the same script has to behave identically on a GNU-sed runner.
SUITE="unknown"
case "$BASE_IMAGE_LINE" in
  *bullseye*) SUITE="bullseye" ;;
  *bookworm*) SUITE="bookworm" ;;
  *trixie*)   SUITE="trixie" ;;
  *forky*)    SUITE="forky" ;;
  *buster*)   SUITE="buster" ;;
esac
say "== inventory: ${PKG_COUNT} Debian packages on ${SUITE} (${BASE_IMAGE_LINE})"

# Binary package -> source package, from the inventory itself. A finding arrives named
# as the library (libcurl4) while the register and the Debian tracker speak of the
# source (curl); this map is what makes those the same row.
src_of() {
  printf '%s\n' "$INVENTORY" | awk -F'|' -v p="$1" '$2==p {print $1; exit}'
}

# --- 2. what the suite offers today --------------------------------------------
# Run inside the image, against the image's own sources.list: the only way to ask
# "is there a fix apt could install right now" without assuming which mirror, pocket
# or phasing state the build happened to see. The runtime stage performs the same
# refresh at build time, so a pending upgrade here means either the image predates
# the fix (normal drift; a rebuild takes it) or the refresh is not working (a defect).
declare -a UPGRADES=()
PROBE_STATE="skipped"
if [ "$PROBE" = "1" ]; then
  PROBE_RAW="$(docker run --rm --entrypoint sh "$IMAGE" -c '
    apt-get -o Acquire::Retries=3 update -qq >/dev/null 2>&1 || exit 90
    apt-get -o Acquire::Retries=3 -o APT::Get::Always-Include-Phasing=experimental \
      -s dist-upgrade -y --no-install-recommends 2>/dev/null \
      | sed -n "s/^Inst \([^ ]*\) \[\([^]]*\)\] (\([^)]*\).*/\1|\2|\3/p"
  ')"
  probe_rc=$?
  if [ "$probe_rc" = "90" ]; then
    PROBE_STATE="unreachable"
    warn "apt inside $IMAGE could not reach its ${SUITE} suite (network or archive moved); currency NOT verified"
  elif [ "$probe_rc" != "0" ]; then
    PROBE_STATE="error"
    warn "currency probe failed (exit $probe_rc); treat this result as unverified"
  else
    PROBE_STATE="ok"
    if [ -n "$PROBE_RAW" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && UPGRADES+=("$line")
      done <<< "$PROBE_RAW"
    fi
    if [ "${#UPGRADES[@]}" -gt 0 ]; then
      say "== currency: ${#UPGRADES[@]} package(s) have a newer candidate in ${SUITE} right now"
      for u in "${UPGRADES[@]}"; do
        warn "drift: $(printf '%s' "$u" | cut -d'|' -f1) $(printf '%s' "$u" | cut -d'|' -f2) -> $(printf '%s' "$u" | cut -d'|' -f3) (a rebuild takes it)"
      done
    else
      say "== currency: nothing newer in ${SUITE}; this image is as current as its suite"
    fi
  fi
else
  say "== currency: probe skipped (--no-probe)"
fi

# --- 3. findings to classify ----------------------------------------------------
# Accepted inputs: trivy JSON (this tool's own run, or CI's), another scanner's report,
# or `-` for stdin. From trivy JSON only os-pkgs results count: the PHP source side is
# manifests/SECURITY-REVIEW.md's job, and one gate should not answer two questions.
declare -a RAW=()
# SCANNER names what actually produced findings for this run, and it is part of the
# verdict, not decoration: "absent" and "trivy-failed" mean nothing was scanned, and a
# gate that called that `clean` would be the silence this tool exists to prevent.
SCANNER="absent"
if [ "${#FINDINGS[@]}" != "0" ]; then
  SCANNER="supplied"
elif command -v trivy >/dev/null 2>&1; then
  say "== no --findings given; scanning with trivy from PATH"
  TRIVY_JSON="${TMPDIR:-/tmp}/scan-image-trivy.$$.json"
  if trivy image --quiet --format json --severity "$SEVERITY" --security-checks vuln "$IMAGE" > "$TRIVY_JSON" 2>/dev/null \
     && [ -s "$TRIVY_JSON" ]; then
    FINDINGS+=("$TRIVY_JSON")
    SCANNER="trivy"
  else
    warn "trivy failed, or it exited without writing a report (its DB comes from a registry, so it needs network); the currency probe above still stands"
    PROBE_STATE="${PROBE_STATE}+trivy-failed"
    SCANNER="trivy-failed"
    rm -f "$TRIVY_JSON"
  fi
else
  warn "no trivy on PATH and no --findings: nothing was scanned (see tools/install-trivy.sh)"
fi

i=0
REPORT_HAD_BYTES=0
STDIN_FILES=""
while [ "$i" -lt "${#FINDINGS[@]}" ]; do
  f="${FINDINGS[$i]}"
  i=$((i + 1))
  if [ "$f" = "-" ]; then
    # stdin gets the same handling as a named file: it is slurped into a temp path first,
    # so that `trivy image --format json | tools/scan-image.sh IMAGE --findings -` gets the
    # JSON detection and the jq extraction below rather than being read as loose text.
    STDIN_FILE="${TMPDIR:-/tmp}/scan-image-stdin.$$.${i}.json"
    cat > "$STDIN_FILE"
    STDIN_FILES="${STDIN_FILES}${STDIN_FILE} "
    f="$STDIN_FILE"
  fi
  [ -r "$f" ] || { err "findings file not readable: $f"; exit 2; }
  # A zero-byte report is not an empty scan. trivy with no findings still writes a JSON
  # document; a file with nothing in it means the redirect failed or the scanner never
  # ran, which is the same absence of an answer as no scanner at all.
  if [ ! -s "$f" ]; then
    warn "$f is empty: no report content to classify"
    continue
  fi
  REPORT_HAD_BYTES=1
  # A trivy report is JSON, and the only safe way to tell is its *first* byte. Probing a
  # window for the "Results" key silently fails on a real report: `Metadata.ImageConfig`
  # carries the image's whole build history before Results ever appears, and a Dockerfile
  # RUN body is hundreds of bytes of text whose `|` characters would each become a
  # "finding" with the real CVEs stripped of their package names.
  leading="$(head -c 512 "$f" | tr -d '[:space:]' | cut -c1)"
  if [ "$leading" = "{" ]; then
    command -v jq >/dev/null 2>&1 || { echo "jq is required to read a trivy JSON report: brew install jq" >&2; exit 2; }
    jq -e '.Results' "$f" >/dev/null 2>&1 \
      || { err "$f starts with '{' but is not a parseable scanner report (jq failed on it)"; exit 2; }
    while IFS= read -r line; do
      [ -n "$line" ] && RAW+=("$line")
    done < <(jq -r --arg sev "$SEVERITY" '
        ($sev | split(",")) as $want
        | .Results[]?
        | select(.Class == "os-pkgs")
        | .Vulnerabilities[]?
        | select(.Severity as $s | $want | index($s) != null)
        | "\(.VulnerabilityID)|\(.PkgName)|\(.InstalledVersion)|\(.FixedVersion // "")"
      ' "$f")
  else
    while IFS= read -r line; do RAW+=("$line"); done < "$f"
  fi
done
# Word splitting is the point here: STDIN_FILES is a space-separated list of the
# temp paths created above (they contain $$ and $i, so they never hold spaces).
# shellcheck disable=SC2086
[ -n "$STDIN_FILES" ] && rm -f $STDIN_FILES

# Normalise to CVE|package|installed|scanner-reported-fix-version (empty when unknown).
# A `|` is only a field separator when the thing before it is a CVE id: build histories,
# log lines and prose are full of pipes, and treating one as a column layout invents
# findings that name no package and match no register row. Anything else is scanned for
# CVE ids and recorded as CVE-only, which the "package not stated by the scanner" branch
# already reports honestly. Deduplicated because one CVE is one finding: a JSON report
# repeats an id across its own fields, and 45 copies of a curl CVE is not 45 findings.
declare -a FINDS=()
add_find() { # $1 = CVE|pkg|installed|fixed -- appended once, or ignored as a duplicate
  local k j
  k="$1"
  j=0
  while [ "$j" -lt "${#FINDS[@]}" ]; do
    [ "${FINDS[$j]}" = "$k" ] && return 0
    j=$((j + 1))
  done
  FINDS+=("$k")
}
for line in ${RAW[@]+"${RAW[@]}"}; do
  # A pipe only means "field separator" when there is a pipe *and* the text before the
  # first pipe is a CVE id. Without both, the line is free text: a CSV row (pipes absent),
  # a Dockerfile RUN body or a log fragment (pipes present, no CVE at the head) must not be
  # split into columns, or the whole line becomes the "CVE" and the scanner's package name
  # turns into a bogus finding that no register row can cover.
  case "$line" in
    *'|'*)
      case "${line%%|*}" in
        CVE-*|'*') add_find "$line"; continue ;;
      esac
      ;;
  esac
  for cve in $(printf '%s' "$line" | grep -oE 'CVE-[0-9]{4}-[0-9]+'); do
    add_find "${cve}|||"
  done
done

# A scanner that wrote no report bytes at all is the same absence of an answer as no
# scanner at all: `--findings /dev/null`, or a `trivy > file` whose redirect failed, must
# not read as "scanned, found nothing". A well-formed report with no vulnerabilities in
# it does have bytes, and stays a genuine clean.
if [ "$SCANNER" != "absent" ] && [ "$SCANNER" != "trivy-failed" ] && [ "$REPORT_HAD_BYTES" = "0" ]; then
  warn "the scanner produced no report bytes -- nothing was scanned, so nothing was found"
  SCANNER="empty-report"
fi

# --- 4. the register ------------------------------------------------------------
# Rows are markdown table lines with columns
#   CVE | Source package | Suites | Installed in our image | Debian status | Disposition | Evidence | Reviewed
# A row whose CVE is "*" covers every CVE reported for that source package on the
# listed suite -- it exists for the frozen bullseye archive, where the honest
# statement is "nothing can arrive on this base", not a per-CVE claim about a tracker
# table that no longer lists the release.
declare -a REG_CVE=() REG_PKG=() REG_SUITES=() REG_DISP=() REG_EVID=() REG_VER=() REG_REVIEWED=()
while IFS= read -r row; do
  case "$row" in
    '| CVE |'*|'| --- |'*|'|-'*) continue ;;
    '| '*) ;;
    *) continue ;;
  esac
  IFS='|' read -r _f0 r_cve r_pkg r_suites r_installed _r_status r_disp r_evid r_reviewed _rest <<EOF
$row
EOF
  r_cve="$(trim "$r_cve")"; r_pkg="$(trim "$r_pkg")"; r_suites="$(trim "$r_suites")"
  r_disp="$(trim "$r_disp")"; r_evid="$(trim "$r_evid")"
  case "$r_cve" in CVE-*|'*') ;; *) continue ;; esac
  case "$r_disp" in
    no-candidate-in-suite|fixed-only-in-unstable|declined-no-dsa|frozen-archive|not-in-image|accepted-risk) ;;
    *) warn "register row for ${r_cve} has disposition '${r_disp}', which the gate does not know; it will not match"
       continue ;;
  esac
  REG_CVE+=("$r_cve"); REG_PKG+=("$r_pkg"); REG_SUITES+=("$r_suites")
  REG_DISP+=("$r_disp"); REG_EVID+=("$r_evid")
  REG_REVIEWED+=("$(trim "$r_reviewed")")
  # The version the row claims to have reviewed, when it states one as `pkg version`.
  # The backticks are markdown delimiters in the register text, not command
  # substitution: single quotes are the point.
  # shellcheck disable=SC2016
  REG_VER+=("$(printf '%s' "$r_installed" | grep -oE '`[a-z0-9][a-z0-9.+-]* [0-9][^`]*`' | tr -d '`' | head -1)")
done < "$REGISTER"
say "== register: ${#REG_CVE[@]} row(s) read from ${REGISTER##*/}"

# Does a register row speak to *this* image? Rows are suite-scoped: the zlib row
# that names bullseye says nothing about a bookworm build, and treating it as a
# mismatch would turn a correct ledger into a wall of false warnings.
suite_matches() { # $1 = a row's Suites cell
  [ "$SUITE" = "unknown" ] && return 0
  printf '%s' "$1" | grep -qw "$SUITE"
}

# Stale-row check: a row citing an installed version this image no longer has was
# reviewed against a different build, and must be re-read before it is trusted.
i=0
while [ "$i" -lt "${#REG_VER[@]}" ]; do
  stated="${REG_VER[$i]}"
  this_index=$i
  i=$((i + 1))
  [ -n "$stated" ] || continue
  suite_matches "${REG_SUITES[$this_index]}" || continue
  name="${stated%% *}"; ver="${stated#* }"
  have="$(printf '%s\n' "$INVENTORY" | awk -F'|' -v p="$name" '$2==p {print $3; exit}')"
  if [ -n "$have" ] && [ "$have" != "$ver" ]; then
    warn "register row for ${REG_CVE[$this_index]} cites ${name} ${ver}, this image has ${have} -- re-review that row"
  fi
done

# Ageing check: every row above is a claim about what Debian publishes *today*. A
# frozen archive stays true, but "no candidate in this suite" is the kind of statement
# a future upload silently falsifies -- so rows are datestamped and reported once they
# go stale rather than quietly staying green.
epoch_of() { # YYYY-MM-DD -> unix seconds, GNU date or BSD date, empty if neither
  local d="$1"
  [ -n "$d" ] || return 0
  date -d "$d 00:00:00 UTC" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S %z" "$d 00:00:00 +0000" +%s 2>/dev/null || true
}
now_epoch="$(date -u +%s)"
review_due=$((90 * 86400))
i=0
while [ "$i" -lt "${#REG_REVIEWED[@]}" ]; do
  reviewed="${REG_REVIEWED[$i]}"
  this_index=$i
  i=$((i + 1))
  rev_epoch="$(epoch_of "$reviewed")"
  [ -n "$rev_epoch" ] || continue
  if [ $((now_epoch - rev_epoch)) -gt "$review_due" ]; then
    warn "register row for ${REG_CVE[$this_index]} was reviewed on ${reviewed}; re-check it against the tracker (evidence: ${REG_EVID[$this_index]})"
  fi
done

in_register() { # $1 = CVE, $2 = source package -> prints disposition|suites|evidence
  local j
  # Two passes: a row written for this image's suite is the right answer, and a row
  # that names this CVE for a *different* suite is only a fallback worth warning
  # about. Without the ordering, a bookworm-scoped curl row would swallow a finding
  # on the bullseye image and the ledger's frozen-archive row would never be read.
  j=0
  while [ "$j" -lt "${#REG_CVE[@]}" ]; do
    if { [ "${REG_CVE[$j]}" = "$1" ] || { [ "${REG_CVE[$j]}" = "*" ] && [ "${REG_PKG[$j]}" = "$2" ]; }; } \
       && suite_matches "${REG_SUITES[$j]}"; then
      printf '%s|%s|%s' "${REG_DISP[$j]}" "${REG_SUITES[$j]}" "${REG_EVID[$j]}"
      return 0
    fi
    j=$((j + 1))
  done
  j=0
  while [ "$j" -lt "${#REG_CVE[@]}" ]; do
    # A `*` row is deliberately excluded from this fallback pass. It reads "everything
    # reported against this source package on *that* suite", which is only a defensible
    # claim where the archive is frozen -- so letting it match across suites would
    # absorb an unknown bookworm or trixie curl/zlib/sqlite3 finding into a bullseye
    # row and downgrade the failure to a warning. Named rows keep the fallback because
    # a row written for another suite is still a statement about that CVE.
    if [ "${REG_CVE[$j]}" = "$1" ] && [ "${REG_CVE[$j]}" != "*" ]; then
      printf '%s|%s|%s' "${REG_DISP[$j]}" "${REG_SUITES[$j]}" "${REG_EVID[$j]}"
      return 0
    fi
    j=$((j + 1))
  done
  return 1
}

upgrade_for() { # $1 = package name -> prints "old|new" when the suite offers one
  local u j
  [ "${#UPGRADES[@]}" -gt 0 ] || return 1
  j=0
  while [ "$j" -lt "${#UPGRADES[@]}" ]; do
    u="${UPGRADES[$j]}"
    case "$u" in
      "$1|"*) printf '%s' "${u#*|}"; return 0 ;;
    esac
    j=$((j + 1))
  done
  return 1
}

# --- 5. verdicts ----------------------------------------------------------------
declare -a OUT=()
fail_count=0
allow_count=0
for entry in ${FINDS[@]+"${FINDS[@]}"}; do
  [ -n "$entry" ] || continue
  cve="${entry%%|*}"; rest="${entry#*|}"; pkg="${rest%%|*}"; rest="${rest#*|}"
  installed="${rest%%|*}"; scanner_fixed="${rest#*|}"
  source_pkg=""
  if [ -n "$pkg" ]; then
    source_pkg="$(src_of "$pkg")"
    [ -n "$source_pkg" ] || source_pkg="$pkg"
  fi
  if reg="$(in_register "$cve" "${source_pkg:-}")"; then
    disp="${reg%%|*}"; rest2="${reg#*|}"; suites="${rest2%%|*}"; evid="${rest2#*|}"
    if ! suite_matches "$suites"; then
      warn "$cve is registered for '${suites}', this image is on '${SUITE}' -- re-check the row"
    fi
    allow_count=$((allow_count + 1))
    if [ -n "$pkg" ]; then
      said="${cve} ${pkg} -> ${source_pkg}: ${disp} (installed ${installed})"
    else
      said="${cve} (package not stated by the scanner): ${disp}"
    fi
    say "ok    $said"
    say "      evidence: ${evid}"
    OUT+=("{\"cve\":\"${cve}\",\"package\":\"${pkg}\",\"source\":\"${source_pkg}\",\"installed\":\"${installed}\",\"scanner_fixed\":\"${scanner_fixed}\",\"verdict\":\"registered\",\"disposition\":\"${disp}\",\"evidence\":\"${evid}\"}")
    continue
  fi
  cand=""
  for name in "$pkg" "$source_pkg"; do
    [ -n "$name" ] || continue
    if up="$(upgrade_for "$name")"; then
      cand="${name} ${up}"; break
    fi
  done
  fail_count=$((fail_count + 1))
  # A finding naming something this image does not contain is not a Debian-package
  # question at all (trivy calls the shipped PHP tree that way), so it is answered
  # before the suite logic: the PHP side belongs to manifests/SECURITY-REVIEW.md.
  package_absent=0
  if [ -n "$pkg" ] && ! printf '%s\n' "$INVENTORY" | awk -F'|' -v p="$pkg" '$2==p {found=1} END {exit !found}'; then
    package_absent=1
  fi
  if [ "$package_absent" = "1" ]; then
    err "$cve ($pkg): this image contains no Debian package by that name"
    echo "     A finding about PHP itself (the tree in /usr/src/php, the binaries under" >&2
    echo "     /opt/php) is reviewed in manifests/SECURITY-REVIEW.md, not here: this gate" >&2
    echo "     covers the Debian package closure. Record it there, or add a \`not-in-image\`" >&2
    echo "     row here when the scanner is simply wrong about what ships." >&2
    OUT+=("{\"cve\":\"${cve}\",\"package\":\"${pkg}\",\"verdict\":\"not-an-os-package\"}")
  elif [ -n "$cand" ]; then
    err "$cve${pkg:+ ($pkg)}: ${SUITE} publishes a fix this image does not have -- ${cand}"
    echo "     The runtime stage refreshes OS packages at build time, so this is a stale build" >&2
    echo "     (or a base whose lists were not refreshed). Rebuild. Do not add a register row" >&2
    echo "     for something apt can install." >&2
    OUT+=("{\"cve\":\"${cve}\",\"package\":\"${pkg}\",\"verdict\":\"fixable\",\"candidate\":\"${cand}\"}")
  elif [ "$PROBE_STATE" != "ok" ]; then
    err "$cve${pkg:+ ($pkg)}: not registered and the suite could not be probed (${PROBE_STATE}) -- unverified, not clean"
    OUT+=("{\"cve\":\"${cve}\",\"package\":\"${pkg}\",\"verdict\":\"unverified\"}")
  else
    err "$cve${pkg:+ ($pkg)}: not in the register"
    echo "     ${SUITE} offers no newer candidate for ${pkg:-this package}, so this is a Debian" >&2
    echo "     limitation, not a build defect. Add a row to ${REGISTER##*/} with the tracker's" >&2
    echo "     own wording and its URL, or remove the package from the image. Silent" >&2
    echo "     acceptance -- or silencing the scanner -- is the failure mode this gate exists" >&2
    echo "     to prevent." >&2
    OUT+=("{\"cve\":\"${cve}\",\"package\":\"${pkg}\",\"verdict\":\"unregistered\"}")
  fi
done

if [ "${#FINDS[@]}" = "0" ]; then
  case "$SCANNER" in
    trivy|supplied) say "== findings: the scanner ran and reported nothing at the selected severities" ;;
    *) say "== findings: none, because no scanner ran -- inventory and currency only"
       echo "   Install trivy (tools/install-trivy.sh, whose digest pins must be filled)" >&2
       echo "   or pass --findings -. This run is UNVERIFIED, not clean, and the gate says" >&2
       echo "   so instead of claiming an absence nobody measured." >&2 ;;
  esac
fi

# --- 6. summary -----------------------------------------------------------------
verdict="clean"
[ "${#UPGRADES[@]}" -gt 0 ] && verdict="drift"
[ "$fail_count" -gt 0 ] && verdict="action-needed"
# Nothing scanned + nothing needing action is not a pass: it is the absence of an
# answer. The exit code follows, so a runner without a working scanner is red rather
# than quietly green. It applies to a `drift` run too: pending upgrades with no scan is
# still an image nobody looked at, and the pending list stays in the summary line and
# the JSON, so nothing measured is lost by calling the verdict what it is.
unscanned=0
if [ "$fail_count" = "0" ]; then
  case "$SCANNER" in
    trivy|supplied) ;;
    *) verdict="unverified"; unscanned=1 ;;
  esac
fi
printf '\n== scan-image: %s -- %d finding(s), %d registered, %d needing action, %d pending upgrade(s), currency: %s, scanner: %s\n' \
  "$verdict" "${#FINDS[@]}" "$allow_count" "$fail_count" "${#UPGRADES[@]}" "$PROBE_STATE" "$SCANNER"

if [ -n "$JSON_OUT" ]; then
  {
    printf '{"image":"%s","base":"%s","suite":"%s","currency":"%s","scanner":"%s","pending_upgrades":[%s],"findings":[%s],"verdict":"%s","failures":%s}\n' \
      "$IMAGE" "$BASE_IMAGE_LINE" "$SUITE" "$PROBE_STATE" "$SCANNER" \
      "$(printf '%s;' "${UPGRADES[@]:-}" | tr ';' '\n' | sed -e '/^$/d' -e 's/^/"/' -e 's/|/:/g' -e 's/$/",/' | tr -d '\n' | sed 's/,$//')" \
      "$(printf '%s;' "${OUT[@]:-}" | tr ';' '\n' | sed -e '/^$/d' -e 's/$/,/' | tr -d '\n' | sed 's/,$//')" \
      "$verdict" "$((fail_count + unscanned))"
  } > "$JSON_OUT"
  say "== report written: $JSON_OUT"
fi

# The CI job keeps this on the run page, so "what does the published image contain and
# what did we decide about it" is answerable without re-running anything.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # The backticks in these markdown lines are formatting, not command
  # substitution, and printf's own %s markers must stay literal.
  # shellcheck disable=SC2016
  {
    printf '### OS vulnerability gate — `%s`\n\n' "$IMAGE"
    printf -- '- base: `%s` (suite %s)\n- packages inventoried: %s\n- currency probe: %s, pending upgrades: %s\n- scanner: %s\n- findings: %s, registered: %s, needing action: %s\n\n' \
      "$BASE_IMAGE_LINE" "$SUITE" "$PKG_COUNT" "$PROBE_STATE" "${#UPGRADES[@]}" "$SCANNER" "${#FINDS[@]}" "$allow_count" "$fail_count"
    if [ "$fail_count" -gt 0 ]; then
      printf '**Verdict: action needed.** Each finding is in the step log with what Debian says about it.\n'
    elif [ "$unscanned" = "1" ]; then
      printf '**Verdict: unverified.** No scanner ran (`scanner: %s`), so this image has no CVE answer -- only an inventory and a currency probe. Fill the trivy digest pins in `tools/install-trivy.sh` or pass `--findings`.\n' "$SCANNER"
    else
      printf '**Verdict: nothing to fix.** Registered findings and their evidence live in `manifests/OS-CVE-STATUS.md`.\n'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$fail_count" = "0" ] && [ "$unscanned" = "0" ] || exit 1
