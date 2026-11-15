#!/usr/bin/env bash
# shellcheck disable=SC2016  # PHP snippets in single quotes must not expand shell vars
# Smoke test: version, required extensions (php -m AND php --ri), FPM config
# plus a served FastCGI request (fpm variant only), shared libraries, and
# route/OpenSSL consistency.
# Usage: tests/smoke.sh <image> [openssl11|openssl3] [cli|fpm]
set -Eeuo pipefail
IMAGE="${1:?Usage: $0 <image> [openssl11|openssl3] [cli|fpm]}"
ROUTE="${2:-}"
VARIANT="${3:-fpm}"
case "$VARIANT" in cli|fpm) ;; *) echo "Variant must be cli or fpm" >&2; exit 2 ;; esac

php() { docker run --rm --entrypoint /opt/php/bin/php "$IMAGE" "$@"; }

# The extension set an image promises is recorded in its own BUILD-PROVENANCE,
# so a per-version list (PHP_EXTENSIONS / PECL_EXTENSIONS in the manifest) is
# tested as it is, and an image predating those keys falls back to the baseline
# it would have been built with. One definition, used by both checks below.
provenance_extensions() {
  docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
set -eu
prov=/opt/php/BUILD-PROVENANCE
core="$(sed -n "s/^extensions_core=//p" "$prov" 2>/dev/null | head -1)"
pecl="$(sed -n "s/^extensions_pecl=//p" "$prov" 2>/dev/null | head -1)"
required="$core $pecl"
if [ -z "$core" ] && [ -z "$pecl" ]; then
  required="openssl curl mysqli pdo_mysql mbstring zip gd zlib apcu redis memcached"
  echo "NOTE: provenance records no extension set; checking the baseline" >&2
fi
echo "$required"
'
}

echo "== PHP version =="
php -v

echo "== Required extensions (php -m) =="
# An empty list here would make both checks below vacuous, so the read is
# guarded: `set -- $(provenance_extensions)` would not abort the script even
# under `set -e`, because the failing command substitution is inside an
# assignment whose own status is that of `set` (0). Reading into a variable
# first makes the substitution's status visible, and the non-empty test refuses
# the case where provenance exists but records nothing.
promised="$(provenance_extensions)" \
  || { echo "Could not read the promised extension set from $IMAGE" >&2; exit 1; }
if [[ -z "${promised// /}" ]]; then
  echo "This image promises no extensions at all (provenance empty): refusing to pass vacuously" >&2
  exit 1
fi
# shellcheck disable=SC2086  # word-splitting the extension list is the point
set -- $promised
missing=""
for ext in "$@"; do
  php -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$ext" || missing="$missing $ext"
done
if [[ -n "$missing" ]]; then
  echo "Missing:$missing" >&2
  exit 1
fi
echo "All promised extensions loaded: $*"

echo "== Extension info (php --ri) =="
# extension_loaded() alone is not enough: --ri proves the extension is actually
# initialized and exposes its linked library versions.
#
# Failing loudly is the point. `php --ri x && echo ok` under `set -e` does not
# abort on the failure (a non-final command in an AND-list is exempt), so a
# broken-but-loaded extension printed nothing and the test still exited 0 --
# which matters more now that this loop is the per-image promise check rather
# than a fixed list: mcrypt promised on 5.6 has to be able to fail this script.
# shellcheck disable=SC2061  # names come from the image provenance, see above
for ext in "$@"; do
  if ! php --ri "$ext" > /dev/null; then
    echo "php --ri $ext did not resolve: promised by this image, broken in it" >&2
    exit 1
  fi
  echo "ri OK: $ext"
done

echo "== OpenSSL route check =="
docker run --rm -e EXPECTED_ROUTE="$ROUTE" --entrypoint /opt/php/bin/php "$IMAGE" -r '
$route = getenv("EXPECTED_ROUTE");
$text = OPENSSL_VERSION_TEXT;
echo "OPENSSL_VERSION_TEXT: $text" . PHP_EOL;
if ($route === "openssl11" && !preg_match("/OpenSSL 1\.1\./", $text)) {
    fwrite(STDERR, "Route mismatch: expected OpenSSL 1.1.x\n"); exit(1);
}
if ($route === "openssl3" && !preg_match("/OpenSSL 3\./", $text)) {
    fwrite(STDERR, "Route mismatch: expected OpenSSL 3.x\n"); exit(1);
}
'

if [[ "$VARIANT" == "fpm" ]]; then
  echo "== FPM configuration =="
  docker run --rm --entrypoint /opt/php/sbin/php-fpm "$IMAGE" -t

  echo "== FPM pool serves a request on 9000 =="
  # -t above only parses. It passes on a pool that listens on 127.0.0.1 inside
  # the container and is therefore unreachable from a web server in another
  # container or through a published port -- a real 5.6 failure mode, because
  # its php-fpm.conf carries an inline [www] pool that overrides an include
  # placed above it (see fpm-www-conf-fallback in the Dockerfile). So this
  # check asks the pool to serve a request the way nginx would: a second
  # container on the same network, FastCGI over TCP 9000.
  #
  # A host-side `nc -z` against a published port is not evidence for this:
  # docker-proxy accepts the connection before dialing the container, so it
  # reports success even when nothing answers behind it.
  fpm_net="php-legacy-smoke-$$-${RANDOM}"
  fpm_srv="${fpm_net}-fpm"
  trap 'docker rm -f "$fpm_srv" > /dev/null 2>&1 || true; docker network rm "$fpm_net" > /dev/null 2>&1 || true' EXIT
  # FPM's error_log stays at the upstream default, a file under the install
  # prefix, so `docker logs` can be empty even when the master recorded why it
  # failed. Both are printed, best effort, plus the container state.
  fpm_diagnostics() {
    echo "container state: $(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$fpm_srv" 2>/dev/null || echo unknown)" >&2
    docker logs "$fpm_srv" >&2 || true
    docker exec "$fpm_srv" /bin/sh -c 'cat /opt/php/var/log/php-fpm.log 2>/dev/null' >&2 || true
  }
  docker network create "$fpm_net" > /dev/null
  docker run -d --name "$fpm_srv" --network "$fpm_net" "$IMAGE" > /dev/null
  if ! docker exec "$fpm_srv" /bin/sh -c 'echo "<?php echo \"SMOKE-FPM-OK\";" > /tmp/smoke-fpm-probe.php'; then
    echo "FPM container is not usable; diagnostics:" >&2
    fpm_diagnostics
    exit 1
  fi
  # The merged configuration, for the log, read in a throwaway container: -tt
  # appends its whole dump to error_log, and the server's log has to stay clean
  # for the diagnostics above. The assertion is the request below; a change in
  # this dump format must not fail the test on its own.
  docker run --rm --entrypoint /opt/php/sbin/php-fpm "$IMAGE" -tt 2>&1 | grep -F "listen = " || true
  # Client runs on the image's own PHP, so it stays 5.6-compatible. Retries
  # cover the master's startup; flags=0 asks FPM to close after the reply.
  if ! docker run --rm --network "$fpm_net" \
      -e PROBE_HOST="$fpm_srv" -e PROBE_SCRIPT=/tmp/smoke-fpm-probe.php \
      --entrypoint /opt/php/bin/php "$IMAGE" -r '
$host = getenv("PROBE_HOST");
$script = getenv("PROBE_SCRIPT");
$deadline = time() + 30;
$sock = false;
$errstr = "";
while (time() < $deadline) {
    $sock = @fsockopen($host, 9000, $errno, $errstr, 2);
    if ($sock) { break; }
    sleep(1);
}
if (!$sock) {
    fwrite(STDERR, "FPM pool not reachable at $host:9000: $errstr\n");
    exit(1);
}
stream_set_timeout($sock, 10);
function smoke_fcgi_record($type, $body)
{
    return pack("CCnnCC", 1, $type, 1, strlen($body), 0, 0) . $body;
}
$params = "";
$pairs = array(
    "SCRIPT_FILENAME" => $script,
    "SCRIPT_NAME" => "/smoke-fpm-probe.php",
    "REQUEST_METHOD" => "GET",
    "REQUEST_URI" => "/smoke-fpm-probe.php",
    "QUERY_STRING" => "",
    "CONTENT_TYPE" => "",
    "CONTENT_LENGTH" => "0",
    "SERVER_PROTOCOL" => "HTTP/1.1",
    "GATEWAY_INTERFACE" => "FastCGI/1.0",
    "DOCUMENT_ROOT" => "/tmp",
);
foreach ($pairs as $k => $v) {
    $params .= chr(strlen($k)) . chr(strlen($v)) . $k . $v;
}
fwrite($sock, smoke_fcgi_record(1, pack("nC6", 1, 0, 0, 0, 0, 0, 0)));
fwrite($sock, smoke_fcgi_record(4, $params));
fwrite($sock, smoke_fcgi_record(4, ""));
$reply = "";
while (!feof($sock)) {
    $chunk = fread($sock, 8192);
    if ($chunk === false || $chunk === "") { break; }
    $reply .= $chunk;
}
fclose($sock);
$body = "";
for ($i = 0; $i + 8 <= strlen($reply);) {
    $h = unpack("Cversion/Ctype/nreq/nlen/Cpad/Cres", substr($reply, $i, 8));
    if ($h["type"] === 6) { $body .= substr($reply, $i + 8, $h["len"]); }
    $i += 8 + $h["len"] + $h["pad"];
}
if (strpos($body, "SMOKE-FPM-OK") === false) {
    fwrite(STDERR, "FastCGI request to $host:9000 got no SMOKE-FPM-OK (reply " . strlen($reply) . " bytes)\n");
    exit(1);
}
echo "FastCGI OK: $host:9000 served the probe script\n";
'; then
    echo "FPM pool did not serve the probe request; diagnostics:" >&2
    fpm_diagnostics
    exit 1
  fi
fi

echo "== Shared libraries =="
docker run --rm -e VARIANT="$VARIANT" --entrypoint /bin/sh "$IMAGE" -c '
set -eu
binaries="/opt/php/bin/php"
if [ "$VARIANT" = "fpm" ]; then
  binaries="$binaries /opt/php/sbin/php-fpm"
fi
for binary in $binaries; do
  echo "-- $binary"
  output="$(ldd "$binary" 2>&1 || true)"
  printf "%s\n" "$output"
  if printf "%s\n" "$output" | grep -q "not found"; then
    echo "Missing shared library" >&2
    exit 1
  fi
done
'
echo "Smoke tests passed."
