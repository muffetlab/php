#!/bin/sh
# Stub harness for tools/scan-image.sh -- the OS CVE gate's verdict logic.
#
# Why this exists: scan-image.sh's other half (what a Debian suite offers today)
# needs a real image and a real apt, and CI's validate job has neither. The half
# that decides *how a run is reported* does not: given a fake `docker` that
# prints an inventory and a fake `trivy` that behaves in one of three ways, the
# verdict, the JSON and the exit code are all reproducible in milliseconds,
# including the verdict that a run with no scanner is `unverified` and fails
# rather than reporting `clean`.
#
# Usage: tests/scan-image-harness.sh
# Exit:  0 = every case behaved as expected, 1 = at least one did not.
#
# What the cases cover: the verdict table against the real register, the JSON's
# `scanner` field and the exit code, and the parser edges -- JSON with long
# metadata before `Results` (json-long-metadata), text lines containing `|`
# (text-pipes, csv-mixed), an empty report (empty-report), and `--findings -`
# with the `*` frozen-archive row (stdin-wildcard). Two groups are about the
# register's own columns. The evidence columns: a group whose token is unknown
# or missing is warned about and still matched, a version group with no evidence
# group is a version cited to nothing, and the real register is shown to carry a
# keyed, cited token in every group (evidence-tokens, evidence-real-register,
# suite-group-keys). The Suites field, which is a matching field and not a
# reading aid: the per-suite stale comparison on a row that answers two bases,
# the warning that names the suite whose group went stale, the named row's
# warned cross-suite fallback, the row that answers a suite it has never
# measured, and the unnameable base where scoping is off and the gate says so
# (suite-groups-trixie, suite-groups-bookworm, suite-group-stale, suite-scope,
# suite-unnameable). The stub `docker` serves `/opt/php/RUNTIME-OS-PACKAGES`
# and, for one case, a pending-upgrade line in apt's own `Inst pkg [old] (new)`
# format; the stub `trivy` behaves absent, failing or reporting. jq is needed
# for the trivy-JSON cases, so both static-gate jobs install it.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SI="$ROOT/tools/scan-image.sh"
REGISTER="$ROOT/manifests/OS-CVE-STATUS.md"
for f in "$SI" "$REGISTER"; do
  [ -r "$f" ] || { echo "harness: missing $f" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

passed=0
failed=0
case_ok=1
case_out=""

# A bookworm inventory, so the register's bookworm rows are the ones in play.
# Bookworm has named rows plus a few `*` rows, but none for openssl, which is
# what makes the unknown-CVE case below genuinely unregistered rather than
# absorbed by a register row.
cat > "$WORK/inventory" <<'EOF'
base_image=debian:bookworm-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000
collected_at=2026-11-03T00:00:00Z
format=source|package|version
curl|libcurl4|7.88.1-10+deb12u15
sqlite3|libsqlite3-0|3.40.1-2+deb12u2
zlib|zlib1g|1:1.2.13.dfsg-1
openssl|libssl3|3.0.17-1~deb12u4
EOF

# The two docker calls scan-image.sh makes with --no-probe: inspect, then read
# the inventory the runtime stage wrote. When a case runs the real probe
# (SI_PROBE below) the same stub answers the `--entrypoint sh` call with
# STUB_PENDING's apt-style lines, so a pending upgrade can be asserted without
# an apt anywhere.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/sh
[ "$1" = "image" ] && exit 0
if [ "$1" = "run" ]; then
  for a in "$@"; do
    [ "$a" = "sh" ] && { [ -n "${STUB_PENDING:-}" ] && printf '%s\n' "$STUB_PENDING"; exit 0; }
  done
  cat "$STUB_INVENTORY"
  exit 0
fi
exit 0
EOF
chmod +x "$WORK/bin/docker"

# --- trivy stubs: three behaviours, three directories
# ---------------------------- Registered findings only: both CVEs have bookworm
# rows in the real register.
cat > "$WORK/registered.json" <<'EOF'
{"SchemaVersion":2,"Results":[{"Class":"os-pkgs","Vulnerabilities":[
{"VulnerabilityID":"CVE-2026-86414","PkgName":"libcurl4","InstalledVersion":"7.88.1-10+deb12u15","Severity":"CRITICAL"},
{"VulnerabilityID":"CVE-2026-119591","PkgName":"libsqlite3-0","InstalledVersion":"3.40.1-2+deb12u2","Severity":"HIGH"}
]}]}
EOF
printf '%s\n' '{"SchemaVersion":2,"Results":[]}' > "$WORK/empty.json"

make_trivy() { # <dir> <ok|fail> [findings-file]
  mkdir -p "$1"
  if [ "$2" = "fail" ]; then
    cat > "$1/trivy" <<'EOF'
#!/bin/sh
[ "${1:-}" = "--version" ] && { echo "Version: 0.76.1"; exit 0; }
exit 1
EOF
  else
    # The ${1:-} below is literal text for the stub that gets generated, not an
    # expansion in this script -- which is why the format string is single-quoted.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\n[ "${1:-}" = "--version" ] && { echo "Version: 0.76.1"; exit 0; }\ncat %s\nexit 0\n' "$3" > "$1/trivy"
  fi
  chmod +x "$1/trivy"
}
make_trivy "$WORK/bin/fail" fail
make_trivy "$WORK/bin/registered" ok "$WORK/registered.json"
make_trivy "$WORK/bin/empty" ok "$WORK/empty.json"

# si <name> <want-rc> <trivy-dir or '-'> [extra scan-image args...] The
# inventory it reads is $INV, which a case may swap (bullseye has `*` rows,
# bookworm does not, and that difference is what case 6 is about). Reports are
# written as out-<name>.json rather than <name>.json: the fixtures live in the
# same directory, so case output must never collide with a fixture name. Cases
# skip the currency probe because it normally needs a real apt; SI_PROBE=1 runs
# it against the stub above instead.
INV="$WORK/inventory"
si() {
  name="$1"; want="$2"; trivydir="$3"; shift 3
  [ "$trivydir" = "-" ] && trivydir=""
  case_ok=1
  set +e
  if [ -n "${SI_PROBE:-}" ]; then
    case_out="$(STUB_INVENTORY="$INV" STUB_PENDING="${SI_PENDING:-}" \
      PATH="${trivydir:+$trivydir:}$WORK/bin:$PATH" \
      "$SI" image:stub --json-out "$WORK/out-$name.json" "$@" 2>&1)"
  else
    case_out="$(STUB_INVENTORY="$INV" \
      PATH="${trivydir:+$trivydir:}$WORK/bin:$PATH" \
      "$SI" image:stub --no-probe --json-out "$WORK/out-$name.json" "$@" 2>&1)"
  fi
  got=$?
  set -e
  if [ "$got" != "$want" ]; then
    case_ok=
    printf '     exit: want %s got %s\n' "$want" "$got"
  fi
  printf '%s\n' "$case_out" > "$WORK/$name.out"
  case_name="$name"
}

# want <substring> -- must appear in the step output
want() {
  if ! printf '%s\n' "$case_out" | grep -Fq -- "$1"; then
    case_ok=
    echo "     missing in output: $1"
  fi
}

# want_json <substring> -- must appear in the report the step wrote
want_json() {
  if [ ! -f "$WORK/out-$case_name.json" ]; then
    case_ok=
    echo "     no JSON report written"
  elif ! grep -Fq -- "$1" "$WORK/out-$case_name.json"; then
    case_ok=
    echo "     missing in JSON: $1"
  fi
}

# want_not <substring> -- must NOT appear anywhere in the step output. This is
# how the harness catches invented findings: their text is exactly the symptom,
# not an absence.
want_not() {
  if printf '%s\n' "$case_out" | grep -Fq -- "$1"; then
    case_ok=
    echo "     present but must not be: $1"
  fi
}

finish() {
  if [ -n "$case_ok" ]; then
    passed=$((passed + 1))
    printf 'ok   si-%s\n' "$case_name"
  else
    failed=$((failed + 1))
    printf 'FAIL si-%s\n' "$case_name"
    printf '%s\n' "$case_out" | sed -n 's/^/       | /p' | tail -8
    [ -f "$WORK/out-$case_name.json" ] && head -c 300 "$WORK/out-$case_name.json" && echo
  fi
}

echo "== scan-image harness: verdicts, JSON and exit codes against the real register"

# 1. No scanner anywhere on PATH and no --findings: the absence that must verdict
#    `unverified`, never `clean`.
si absent 1 -
want 'scan-image: unverified'
want 'no scanner ran'
want_json '"verdict":"unverified"'
want_json '"scanner":"absent"'
finish

# 2. trivy present but unable to produce a report (no DB, no network): still not clean,
#    and the currency field says so too.
si trivy-failed 1 "$WORK/bin/fail"
want 'scan-image: unverified'
want 'currency: skipped+trivy-failed'
want_json '"scanner":"trivy-failed"'
finish

# 3. A scan whose findings all have register rows: green, for the right reason, and the
#    report now names the scanner that produced it.
si registered 0 "$WORK/bin/registered"
want 'scan-image: clean'
want '2 registered'
want_json '"scanner":"trivy"'
want_json '"verdict":"registered"'
finish

# 4. A scan that found nothing at the selected severities: `clean` is honest exactly
#    when something actually scanned.
si empty-scan 0 "$WORK/bin/empty"
want 'scan-image: clean'
want 'reported nothing'
want_json '"scanner":"trivy"'
want_json '"findings":[]'
finish

# 5. A finding no row covers, on a suite whose register rows are written by CVE rather
#    than by a frozen-archive `*` row: it fails, and it does not get absorbed by the
#    bullseye `*` openssl row two suites away.
printf '%s\n' 'CVE-2999-0001|libssl3|3.0.17-1~deb12u4|' > "$WORK/unknown-cve.txt"
si unregistered 1 "$WORK/bin/empty" --findings "$WORK/unknown-cve.txt"
want 'scan-image: action-needed'
want 'not registered and the suite could not be probed'
want_json '"verdict":"unverified"'
finish

# 6. The same unknown CVE on the frozen archive *is* covered, by the `*` row written for
#    that purpose: the tightening in case 5 must not break the row's real job.
cat > "$WORK/inventory-bullseye" <<'EOF'
base_image=debian:bullseye-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000
collected_at=2026-11-03T00:00:00Z
format=source|package|version
curl|libcurl4|7.74.0-1.3+deb11u16
zlib|zlib1g|1:1.2.11.dfsg-2+deb11u2
EOF
printf '%s\n' 'CVE-2999-0001|libcurl4|7.74.0-1.3+deb11u16|' > "$WORK/unknown-cve-bullseye.txt"
INV="$WORK/inventory-bullseye"
si wildcard 0 "$WORK/bin/empty" --findings "$WORK/unknown-cve-bullseye.txt"
INV="$WORK/inventory"
want 'scan-image: clean'
want_json '"disposition":"frozen-archive"'
finish

# 7. --findings is a scanner answer like any other: the verdict is trusted, and the JSON
#    records where it came from.
si supplied 0 - --findings "$WORK/registered.json"
want 'scan-image: clean'
want_json '"scanner":"supplied"'
finish

# 8. Drift with no scanner. The pending-upgrade list and the absence of a scan are two
#    different facts; the verdict keeps both -- the upgrade reaches the report, and the
#    verdict says what was measured, which is currency and nothing else.
#    (The variables are set on their own lines and cleared right after, not as a prefix of
#    the call: a `VAR=x function` assignment persists in POSIX sh, and the leak would make
#    every later case run the probe.)
SI_PROBE=1
SI_PENDING='zlib1g|1:1.2.13.dfsg-1|1:1.3.dfsg-1'
si drift-no-scanner 1 -
SI_PROBE=""
SI_PENDING=""
want 'scan-image: unverified'
want '1 pending upgrade(s)'
want 'have a newer candidate in bookworm'
want_json '"pending_upgrades":["zlib1g'
want_json '"verdict":"unverified"'
finish

# 9. A trivy-shaped JSON report whose "Results" key sits behind a long build history --
#    the real shape of a container report. Probing a byte window for the string
#    "Results" reads this as loose text: every `|` inside a `created_by` string becomes
#    a "finding" and the real CVEs lose their package names. The JSON branch must be
#    taken, the history must not, and two identical entries are one finding.
{
  printf '{\n  "SchemaVersion": 2,\n  "ArtifactName": "image:stub",\n  "Metadata": {\n    "ImageConfig": {\n      "history": [\n'
  n=0
  while [ "$n" -lt 60 ]; do
    # Each line is ~150 bytes and is full of pipes and braces, like a real RUN body.
    # The `${e}` below is literal stub text, not an expansion in this script -- hence
    # the single quotes and the disable.
    # shellcheck disable=SC2016
    printf '        {"created_by": "RUN /bin/sh -c set -eux; case \\"${e}\\" in *[!a-z0-9_]*) echo \\"bad|pipe\\" ;; esac; sed -i s#deb.debian.org#archive.debian.org# /etc/apt/sources.list; padding_for_length_%03d"},\n' "$n"
    n=$((n + 1))
  done
  # The last element of every array carries no trailing comma, because this
  # fixture has to be valid JSON for the branch under test to be reached at all.
  printf '        {"created_by": "RUN /bin/sh -c the last history line; padding_for_length_END"}\n'
  printf '      ]\n    }\n  },\n  "Results": [\n    {"Class": "os-pkgs", "Vulnerabilities": [\n'
  printf '      {"VulnerabilityID": "CVE-2026-119373", "PkgName": "libsqlite3-0", "InstalledVersion": "3.40.1-2+deb12u2", "Severity": "CRITICAL", "FixedVersion": ""},\n'
  printf '      {"VulnerabilityID": "CVE-2026-119373", "PkgName": "libsqlite3-0", "InstalledVersion": "3.40.1-2+deb12u2", "Severity": "CRITICAL", "FixedVersion": ""}\n'
  printf '    ]}\n  ]\n}\n'
} > "$WORK/big-metadata.json"
[ "$(wc -c < "$WORK/big-metadata.json")" -gt 4000 ] || {
  echo "harness: the fixture is not longer than the old 4000-byte probe window; it would" >&2
  echo "         prove nothing about the bug it exists to catch." >&2
  exit 2
}
jq -e '.Results' "$WORK/big-metadata.json" >/dev/null 2>&1 || {
  echo "harness: the big-metadata fixture is not valid JSON, so it tests nothing." >&2
  exit 2
}
si json-long-metadata 0 - --findings "$WORK/big-metadata.json"
want '1 finding(s)'
want '1 registered'
want 'CVE-2026-119373 libsqlite3-0'
want_not 'no Debian package by that name'
want_not '"verdict":"not-an-os-package"'
want_json '"scanner":"supplied"'
finish

# 10. A text report that merely *contains* pipes. The `|` is a field separator only when
#     the text before it is a CVE id; otherwise a Dockerfile line, a log fragment or a
#     table row is invented into a finding that names no package and matches no row.
cat > "$WORK/pipey.txt" <<'EOF'
RUN /bin/sh -c case "$e" in *[!a-z0-9_]*) echo "x|y" ;; esac
CVE-2026-119373|libsqlite3-0|3.40.1-2+deb12u2|
the tracker mentions CVE-2026-85091 in prose|and nothing else
EOF
si text-pipes 0 - --findings "$WORK/pipey.txt"
want '2 finding(s)'
want_not 'no Debian package by that name'
finish

# 11. An empty report file is not "scanned, found nothing": it is the same absence of an
#     answer as a missing scanner, and it must not read as clean.
: > "$WORK/empty-report.json"
si empty-report 1 - --findings "$WORK/empty-report.json"
want 'scan-image: unverified'
want_json '"scanner":"empty-report"'
finish

# 12. A pipe that is not a column separator must not split a finding into four fields.
#     The second line is a scanner CSV row; the first is prose that happens to contain a
#     pipe. This is the shape that turned Dockerfile history into "package_absent" findings
#     when the JSON branch was missed.
printf '%s\n' 'just prose|with a pipe' 'CVE-2026-119373,libsqlite3-0,3.40.1-2+deb12u2,' > "$WORK/csv-mixed.txt"
si csv-mixed 0 - --findings "$WORK/csv-mixed.txt"
want '1 finding(s)'
want_not 'no Debian package by that name'
finish

# 13. The `*` (whole source package) row has to work through the *stdin* path too, not only
#     via --findings FILE: it is how the frozen bullseye archive is covered, and the
#     documented invocation is `scanner | tools/scan-image.sh IMAGE --findings -`. The stdin
#     branch is handled in a temp file first, so this case is what proves that works.
case_name="stdin-wildcard"; case_ok=1
set +e
printf '%s\n' 'CVE-2999-0002|libcurl4|7.74.0-1.3+deb11u16|' | \
  STUB_INVENTORY="$WORK/inventory-bullseye" PATH="$WORK/bin:$PATH" \
  "$SI" image:stub --no-probe --json-out "$WORK/out-stdin-wildcard.json" --findings - \
  > "$WORK/stdin-wildcard.out" 2>&1
got=$?
set -e
case_out="$(cat "$WORK/stdin-wildcard.out")"
[ "$got" = "0" ] || { case_ok=; printf '     exit: want 0 got %s\n' "$got"; }
want 'scan-image: clean'
want_json '"disposition":"frozen-archive"'
want_json '"scanner":"supplied"'
finish

# 14. The two suite-keyed columns: the gate reads them by position, splits each cell into
#     its `; `-separated groups, checks every group's token, and warns without dropping the
#     row when a token is unknown or missing -- the disposition is what answers a finding,
#     the evidence token only says which artifact a version was measured on. Case 15 then
#     proves the real register carries a usable token in every group, since a blank cell
#     there is invisible until someone reads the ledger and finds nobody cited.
cat > "$WORK/register-evidence.md" <<'EOF'
| CVE | Source package | Suites | Observed image package | Image evidence | Debian status | Disposition | Tracker evidence | Reviewed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CVE-2026-86414 | curl | bookworm | bookworm `libcurl4 7.88.1-10+deb12u15` | bookworm published-image | vulnerable in bookworm | fixed-only-in-unstable | https://example.invalid/86414 | 2026-11-02 |
| CVE-2026-92388 | curl | bookworm | bookworm `libcurl4 7.88.1-10+deb12u15` | bookworm scanned-image | vulnerable in bookworm | fixed-only-in-unstable | https://example.invalid/92388 | 2026-11-02 |
| CVE-2026-119591 | sqlite3 | bookworm | bookworm `libsqlite3-0 3.40.1-2+deb12u2` |  | vulnerable in bookworm | no-candidate-in-suite | https://example.invalid/119591 | 2026-11-02 |
EOF
printf '%s\n' \
  'CVE-2026-86414|libcurl4|7.88.1-10+deb12u15|' \
  'CVE-2026-92388|libcurl4|7.88.1-10+deb12u15|' \
  'CVE-2026-119591|libsqlite3-0|3.40.1-2+deb12u2|' > "$WORK/evidence-findings.txt"
si evidence-tokens 0 - --register "$WORK/register-evidence.md" --findings "$WORK/evidence-findings.txt"
want 'scan-image: clean'
want '3 registered'
want "cites image evidence 'scanned-image' for 'bookworm'"
want 'gives no image-evidence token'
want '2 row(s) whose version is cited to no token the gate knows'
# the one row with a valid token gets no warning of either kind, and its own
# citation is what the finding is answered with, in the log and in the report
want_not 'register row for CVE-2026-86414'
want 'register cites that version from: published-image'
want_json '"image_evidence":"published-image"'
finish

# 15. The real register: 92 rows, every group keyed and cited, no warning of any kind.
si evidence-real-register 0 "$WORK/bin/registered"
want 'scan-image: clean'
want '2 registered'
want '92 row(s) read from OS-CVE-STATUS.md'
want_not 'cites image evidence'
want_not 'no image-evidence token'
want_not 'no token the gate knows'
want_not 'which its Suites cell does not name'
want_not 'with no image-evidence group'
want_not 're-review that row'
finish

# 16. One row, two bases. The stale-row check has to compare the group keyed to the image's
#     own suite: a single bookworm version on a row scoped to trixie as well is what made
#     every trixie trial print seventeen false re-review warnings. The trixie group agrees
#     with the trixie image here, so nothing may warn, and the citation printed is trixie's
#     own. The ncurses row cites a source version with no binary name, which the check
#     cannot compare -- the inventory deliberately disagrees with it and no warning is
#     invented, because guessing a binary name would be a measurement nobody made.
cat > "$WORK/register-groups.md" <<'EOF'
| CVE | Source package | Suites | Observed image package | Image evidence | Debian status | Disposition | Tracker evidence | Reviewed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CVE-2026-119373 | sqlite3 | bookworm, trixie | bookworm `libsqlite3-0 3.40.1-2+deb12u2`; trixie `libsqlite3-0 3.46.1-7+deb13u2` | bookworm published-image; trixie trial-image (stub run) | vulnerable in every release | no-candidate-in-suite | https://example.invalid/119373 | 2026-11-02 |
| CVE-2025-69720 | ncurses | trixie | trixie `6.5+20250216-2` | trixie suite-index (stub index) | vulnerable in trixie | fixed-only-in-unstable | https://example.invalid/69720 | 2026-11-03 |
EOF
cat > "$WORK/inventory-trixie" <<'EOF'
base_image=debian:trixie-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000
collected_at=2026-11-03T00:00:00Z
format=source|package|version
sqlite3|libsqlite3-0|3.46.1-7+deb13u2
ncurses|libtinfo6|6.4+20240113-1
EOF
printf '%s\n' 'CVE-2026-119373|libsqlite3-0|3.46.1-7+deb13u2|' > "$WORK/groups-trixie.txt"
INV="$WORK/inventory-trixie"
si suite-groups-trixie 0 - --register "$WORK/register-groups.md" --findings "$WORK/groups-trixie.txt"
INV="$WORK/inventory"
want 'scan-image: clean'
want '1 registered'
want '2 Debian packages on trixie'
want_not 're-review that row'
want 'register cites that version from: trial-image (stub run)'
want_json '"image_evidence":"trial-image (stub run)"'
finish

# 17. The same row read against bookworm: the bookworm group is the one compared and the
#     one cited, and the trixie group is left alone.
printf '%s\n' 'CVE-2026-119373|libsqlite3-0|3.40.1-2+deb12u2|' > "$WORK/groups-bookworm.txt"
si suite-groups-bookworm 0 - --register "$WORK/register-groups.md" --findings "$WORK/groups-bookworm.txt"
want 'scan-image: clean'
want_not 're-review that row'
want_not 'register records no bookworm measurement'
want 'register cites that version from: published-image'
finish

# 18. A bookworm image that has moved on. The warning names the suite whose group is stale,
#     so a reader knows which measurement to re-read. A stale row warns; it does not fail
#     the gate, because the disposition is still Debian's answer.
sed 's/3\.40\.1-2+deb12u2/3.40.1-2+deb12u9/' "$WORK/inventory" > "$WORK/inventory-moved"
printf '%s\n' 'CVE-2026-119373|libsqlite3-0|3.40.1-2+deb12u9|' > "$WORK/groups-moved.txt"
INV="$WORK/inventory-moved"
si suite-group-stale 0 - --register "$WORK/register-groups.md" --findings "$WORK/groups-moved.txt"
INV="$WORK/inventory"
want 'scan-image: clean'
want 'cites bookworm libsqlite3-0 3.40.1-2+deb12u2, this image has 3.40.1-2+deb12u9'
want_not 'cites trixie'
finish

# 19. Suites is a matching field, not a reading aid. A named row written for another suite
#     still answers -- it is a statement about that CVE -- and the gate warns that it did.
#     A row that names this suite but records no measurement on it says so too, instead of
#     letting the scanner's version look like the ledger's.
cat > "$WORK/register-scope.md" <<'EOF'
| CVE | Source package | Suites | Observed image package | Image evidence | Debian status | Disposition | Tracker evidence | Reviewed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CVE-2026-6653 | libxml2 | bookworm, trixie | trixie `libxml2 2.12.7-1` | trixie install-log (stub run) | vulnerable in bookworm and trixie | fixed-only-in-unstable | https://example.invalid/6653 | 2026-11-03 |
| CVE-2026-76642 | util-linux | trixie | trixie `libblkid1 2.41.5-1` | trixie suite-index (stub index) | vulnerable in trixie | fixed-only-in-unstable | https://example.invalid/76642 | 2026-11-03 |
EOF
printf '%s\n' \
  'CVE-2026-6653|libxml2|2.9.14+dfsg-0.3|' \
  'CVE-2026-76642|libblkid1|2.38.1-5|' > "$WORK/scope-findings.txt"
si suite-scope 0 - --register "$WORK/register-scope.md" --findings "$WORK/scope-findings.txt"
want 'scan-image: clean'
want '2 registered'
want "CVE-2026-76642 is registered for 'trixie', this image is on 'bookworm' -- re-check the row"
want_not "CVE-2026-6653 is registered for"
want 'register records no bookworm measurement for this row'
want_json '"image_evidence":""'
finish

# 20. A base the script cannot name. Scoping is off, so the bullseye `*` curl row answers a
#     finding on it -- the exact absorption the suite scoping prevents everywhere else. The
#     gate warns that this is what it is doing rather than reporting it as a scoped match,
#     and the stale-row check compares nothing, since no group is keyed to `unknown`.
cat > "$WORK/inventory-unnameable" <<'EOF'
base_image=debian:sid-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000
collected_at=2026-11-03T00:00:00Z
format=source|package|version
curl|libcurl4|8.23.0-1
EOF
printf '%s\n' 'CVE-2999-0001|libcurl4|8.23.0-1|' > "$WORK/unknown-cve-curl.txt"
INV="$WORK/inventory-unnameable"
si suite-unnameable 0 "$WORK/bin/empty" --findings "$WORK/unknown-cve-curl.txt"
INV="$WORK/inventory"
want 'the base image line names no Debian suite this gate knows'
want 'scan-image: clean'
want '1 registered'
want_not 're-review that row'
want_json '"disposition":"frozen-archive"'
finish

# 21. The group keys are checked against Suites. A version group keyed to a suite the row
#     does not claim is a measurement answering a question nobody asked, and a version
#     group with no evidence group of its own is a version cited to nothing. Both warn; the
#     rows still answer, because the disposition is what excuses a finding.
cat > "$WORK/register-badkeys.md" <<'EOF'
| CVE | Source package | Suites | Observed image package | Image evidence | Debian status | Disposition | Tracker evidence | Reviewed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CVE-2026-86414 | curl | bookworm | bookworm `libcurl4 7.88.1-10+deb12u15`; trixie `libcurl4t64 8.14.1-2+deb13u7` | bookworm published-image | vulnerable in bookworm | fixed-only-in-unstable | https://example.invalid/86414 | 2026-11-02 |
| CVE-2026-92388 | curl | bookworm | bookworm `libcurl4 7.88.1-10+deb12u15` | bookworm published-image; trixie trial-image (stub run) | vulnerable in bookworm | fixed-only-in-unstable | https://example.invalid/92388 | 2026-11-02 |
EOF
printf '%s\n' \
  'CVE-2026-86414|libcurl4|7.88.1-10+deb12u15|' \
  'CVE-2026-92388|libcurl4|7.88.1-10+deb12u15|' > "$WORK/badkeys-findings.txt"
si suite-group-keys 0 - --register "$WORK/register-badkeys.md" --findings "$WORK/badkeys-findings.txt"
want 'scan-image: clean'
want "records a version for 'trixie', which its Suites cell does not name"
want 'records a trixie version with no image-evidence group for trixie'
want "cites evidence for 'trixie', which its Suites cell does not name"
want '1 row(s) whose version is cited to no token the gate knows'
finish

# 22. The identity fields are on every finding object, whatever verdict it got. A reader
#     of the artifact cannot tell an absent field from an empty one, and "what version is
#     installed in this image" is the measurement a register row has to cite -- so an
#     `unregistered` finding must carry it as surely as a registered one does. The
#     `--from-artifact` path of os-cve-draft.sh reads them, so a draft can be written
#     without opening the image again. The probe runs (an empty pending list is a
#     currency answer of "ok"), which is the only way the `unregistered` branch is
#     reachable here.
printf '%s\n' 'CVE-2999-0002|libssl3|3.0.17-1~deb12u4|3.0.18-1' > "$WORK/identity-findings.txt"
SI_PROBE=1
si identity-fields 1 - --findings "$WORK/identity-findings.txt"
SI_PROBE=""
want 'scan-image: action-needed'
want_json '"verdict":"unregistered"'
want_json '"source":"openssl"'
want_json '"installed":"3.0.17-1~deb12u4"'
want_json '"scanner_fixed":"3.0.18-1"'
want_json '"package":"libssl3"'
finish

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ] || exit 1
