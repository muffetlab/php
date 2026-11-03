#!/bin/sh
# Stub harness for tools/scan-image.sh -- the OS CVE gate's verdict logic.
#
# Why this exists: scan-image.sh's other half (what a Debian suite offers today) needs a
# real image and a real apt, and CI's validate job has neither. The half that decides
# *how a run is reported* does not: given a fake `docker` that prints an inventory and a
# fake `trivy` that behaves in one of three ways, the verdict, the JSON and the exit code
# are all reproducible in milliseconds, including the verdict that a run with no
# scanner is `unverified` and fails rather than reporting `clean`.
#
# Usage: tests/scan-image-harness.sh
# Exit:  0 = every case behaved as expected, 1 = at least one did not.
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

# A bookworm inventory, so the register's bookworm rows are the ones in play. The
# wildcard `*` rows cover bullseye only, which is what makes the unknown-CVE case below
# genuinely unregistered rather than absorbed by a frozen-archive row.
cat > "$WORK/inventory" <<'EOF'
base_image=debian:bookworm-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000
collected_at=2026-11-03T00:00:00Z
format=source|package|version
curl|libcurl4|7.88.1-10+deb12u15
sqlite3|libsqlite3-0|3.40.1-2+deb12u2
zlib|zlib1g|1:1.2.13.dfsg-1
openssl|libssl3|3.0.17-1~deb12u4
EOF

# The two docker calls scan-image.sh makes with --no-probe: inspect, then read the
# inventory the runtime stage wrote. When a case runs the real probe (SI_PROBE below) the
# same stub answers the `--entrypoint sh` call with STUB_PENDING's apt-style lines, so a
# pending upgrade can be asserted without an apt anywhere.
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

# --- trivy stubs: three behaviours, three directories ----------------------------
# Registered findings only: both CVEs have bookworm rows in the real register.
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

# si <name> <want-rc> <trivy-dir or '-'> [extra scan-image args...]
# The inventory it reads is $INV, which a case may swap (bullseye has `*` rows, bookworm
# does not, and that difference is what case 6 is about). Reports are written as
# out-<name>.json rather than <name>.json: the fixtures live in the same directory,
# so case output must never collide with a fixture name. Cases skip the
# currency probe because it normally needs a real apt; SI_PROBE=1 runs it against the
# stub above instead.
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

# want_not <substring> -- must NOT appear anywhere in the step output. This is how the
# harness catches invented findings: their text is exactly the symptom, not an absence.
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
#    bullseye `*` curl row two suites away.
printf '%s\n' 'CVE-2999-0001|libcurl4|7.88.1-10+deb12u15|' > "$WORK/unknown-cve.txt"
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
  # The last element of every array carries no trailing comma, because this fixture has
  # to be valid JSON for the branch under test to be reached at all.
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

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ] || exit 1
