#!/usr/bin/env bash
# Extension-specific functional tests. extension_loaded() only proves the
# extension initialized; these checks exercise protocols, algorithms and the
# underlying OpenSSL library.
#
# The set is read from the image's own BUILD-PROVENANCE (extensions_core /
# extensions_pecl) rather than assumed, because the kit's extension set is now
# per-version: an image that did not promise mcrypt must not be failed for
# lacking it, and one that did must be. An image predating those keys falls back
# to the baseline set.
# Usage: tests/extensions.sh <image> [openssl11|openssl3]
set -Eeuo pipefail
IMAGE="${1:?Usage: $0 <image> [openssl11|openssl3]}"
ROUTE="${2:-}"

promised="$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
set -eu
prov=/opt/php/BUILD-PROVENANCE
core="$(sed -n "s/^extensions_core=//p" "$prov" 2>/dev/null | head -1)"
pecl="$(sed -n "s/^extensions_pecl=//p" "$prov" 2>/dev/null | head -1)"
if [ -n "$core" ] || [ -n "$pecl" ]; then echo "$core $pecl"; else
  echo "openssl curl mysqli pdo_mysql mbstring zip gd zlib apcu redis memcached"; fi
')"

# apcu is loaded but disabled under the CLI SAPI unless apc.enable_cli=1, and
# every block below runs through that SAPI -- the flag is passed on the command
# line so the setting exists only for this test process, never in the image.
docker run --rm -e EXPECTED_ROUTE="$ROUTE" -e PROMISED="$promised" --entrypoint /opt/php/bin/php "$IMAGE" -d apc.enable_cli=1 -r '
$route = getenv("EXPECTED_ROUTE");
$promiseList = preg_split("/\s+/", trim((string) getenv("PROMISED")), -1, PREG_SPLIT_NO_EMPTY);
$fail = 0;
function check($name, $ok) {
  global $fail;
  if ($ok) { echo "PASS: $name\n"; }
  else { echo "FAIL: $name\n"; $fail = 1; }
}
// promised(): is this extension part of the set this image was built to ship?
// Every extension-specific block below is wrapped in it, so a per-version set is
// tested for exactly what it promises -- and an absent optional extension is a
// clean skip here rather than a FAIL that would make the manifest and the suite
// disagree about what "correct" means.
function promised($name) {
  global $promiseList;
  return in_array(strtolower($name), $promiseList, true);
}
function skip($name) { echo "INFO: $name not in this image\x27s promised set, skipped\n"; }

if (promised("mysqli")) {
  check("mysqli loaded", extension_loaded("mysqli"));
} else { skip("mysqli"); }
if (promised("pdo_mysql")) {
  check("pdo_mysql driver", extension_loaded("pdo_mysql")
    && in_array("mysql", PDO::getAvailableDrivers(), true));
} else { skip("pdo_mysql"); }
if (promised("gd")) {
  check("gd truecolor", function_exists("imagecreatetruecolor"));
  check("gd jpeg support", function_exists("imagejpeg"));
  check("gd png support", function_exists("imagepng"));
  check("gd freetype support", function_exists("imagettfbbox"));
} else { skip("gd"); }
if (promised("mbstring")) {
  check("mbstring functional", mb_strlen("日本語") === 3);
} else { skip("mbstring"); }
if (promised("curl")) {
  check("curl functional", function_exists("curl_init") && function_exists("curl_exec"));
  check("curl ssl feature", (curl_version()["features"] & CURL_VERSION_SSL) !== 0);
} else { skip("curl"); }
if (promised("zip")) {
  check("zip functional", class_exists("ZipArchive"));
} else { skip("zip"); }
// version-branch: ext-mcrypt-presence
// mcrypt is only buildable on 5.6-7.1 (removed from core in 7.2), so it is in
// the promised set on at most those series. The roundtrip proves the extension
// found libmcrypt at runtime, which is the part a runtime stage can lose.
if (promised("mcrypt")) {
  check("mcrypt loaded", extension_loaded("mcrypt"));
  if (extension_loaded("mcrypt")) {
    // RIJNDAEL-128/CBC uses a 16-byte IV. mcrypt_enc_get_iv_size() needs a
    // module descriptor, not constants, so just hardcode the size here.
    $iv = mcrypt_create_iv(16, MCRYPT_RAND);
    $ct = mcrypt_encrypt(MCRYPT_RIJNDAEL_128, str_repeat("k", 16), "secret-data!", MCRYPT_MODE_CBC, $iv);
    check("mcrypt rijndael-128 cbc roundtrip",
      rtrim(mcrypt_decrypt(MCRYPT_RIJNDAEL_128, str_repeat("k", 16), $ct, MCRYPT_MODE_CBC, $iv), "\0") === "secret-data!");
    check("mcrypt algorithm list non-empty", count(mcrypt_list_algorithms()) > 0);
  }
} else { skip("mcrypt"); }

// --- redis (PECL) ---
if (promised("redis")) {
  check("redis loaded", class_exists("Redis"));
  if (class_exists("Redis")) {
    $r = new Redis();
    // The reported version comes from phpversion(), not Redis::getVersion():
    // on the pinned ext-redis that method is not defined at all (fatal "Call to
    // undefined method Redis::getVersion()"), and where it does exist it asks a
    // *connected* server -- which this suite has none of. A fatal here aborts php before the zip/gd/openssl checks below,
    // so it would hide most of the suite instead of reporting on it.
    check("redis version report", is_string(phpversion("redis")) && phpversion("redis") !== "");
    echo "INFO: ext-redis " . (defined("Redis::VERSION") ? Redis::VERSION : phpversion("redis")) . "\n";
    // Serializer round-trip: on the pinned ext-redis 4.3.0 setOption() needs a
    // live connection -- measured, it throws RedisException("Redis server went
    // away") when no server is configured, which is fatal in php -r and would
    // again hide every check below. So it is attempted, and a server-less failure
    // degrades to checking that the API surface exists.
    try {
      $r->setOption(Redis::OPT_SERIALIZER, Redis::SERIALIZER_PHP);
      check("redis serializer option", $r->getOption(Redis::OPT_SERIALIZER) === Redis::SERIALIZER_PHP);
    } catch (Exception $e) {
      echo "INFO: redis serializer round-trip needs a server (" . $e->getMessage() . "), checking API surface instead\n";
      check("redis serializer API", defined("Redis::OPT_SERIALIZER") && defined("Redis::SERIALIZER_PHP"));
    }
  }
} else { skip("redis"); }

// --- memcached (PECL) ---
if (promised("memcached")) {
  check("memcached loaded", class_exists("Memcached"));
  if (class_exists("Memcached")) {
    $m = new Memcached();
    // Same reason as redis: Memcached::getVersion() talks to a server, and with
    // no server the pinned ext-memcached 2.2.0 returns false rather than an array.
    check("memcached version report", is_string(phpversion("memcached")) && phpversion("memcached") !== "");
    echo "INFO: ext-memcached " . phpversion("memcached") . "\n";
    $m->setOption(Memcached::OPT_COMPRESSION, false);
    check("memcached option set/get", $m->getOption(Memcached::OPT_COMPRESSION) === false);
    // A server-less addServer + get must fail cleanly, not crash. The list of
    // acceptable result codes is built from whatever constants this series
    // actually defines, because they are not the same across versions: measured
    // on the pinned ext-memcached 2.2.0 the call returns resultCode 3
    // (MEMCACHED_CONNECTION_FAILURE in the libmemcached enum) and 2.2.0 exposes no
    // PHP constant for that name -- RES_CONNECTION_FAILURE appears only in later
    // ext-memcached. Referencing an undefined class constant is a fatal error in
    // PHP, hence the defined() guards plus the explicit numeric code.
    $m->addServer("127.0.0.1", 1);
    $m->get("nonexistent");
    $acceptable = [3];
    foreach (["RES_ERRNO", "RES_NOTFOUND", "RES_CONNECTION_FAILURE",
              "RES_SERVER_MARKED_DEAD", "RES_HOST_LOOKUP_FAILURE",
              "RES_CONNECTION_SOCKET_CREATE_FAILURE"] as $c) {
      if (defined("Memcached::" . $c)) { $acceptable[] = constant("Memcached::" . $c); }
    }
    check("memcached graceful failure", in_array($m->getResultCode(), $acceptable, true));
  }
} else { skip("memcached"); }

// --- apcu (PECL) ---
if (promised("apcu")) {
  check("apcu loaded", extension_loaded("apcu"));
  // Server-less by design: the roundtrip exercises the shared-memory store in
  // this process, so no external service is needed.
  check("apcu store/fetch roundtrip", apcu_store("kit-probe", "secret-data!") && apcu_fetch("kit-probe") === "secret-data!");
  check("apcu delete", apcu_delete("kit-probe") && apcu_fetch("kit-probe", $ok) === false && $ok === false);
  check("apcu version report", is_string(phpversion("apcu")) && phpversion("apcu") !== "");
  echo "INFO: ext-apcu " . phpversion("apcu") . "\n";
} else { skip("apcu"); }

// --- zip roundtrip ---
if (promised("zip")) {
  $tmp = tempnam(sys_get_temp_dir(), "ziptest");
  $z = new ZipArchive();
  check("zip open", $z->open($tmp, ZipArchive::OVERWRITE) === true);
  $z->addFromString("a.txt", "hello");
  $z->close();
  $z2 = new ZipArchive();
  check("zip read back", $z2->open($tmp) === true && $z2->getFromName("a.txt") === "hello");
  $z2->close();
  unlink($tmp);
} else { skip("zip"); }

// --- gd roundtrip ---
if (promised("gd")) {
  $im = imagecreatetruecolor(8, 8);
  imagestring($im, 1, 0, 0, "x", imagecolorallocate($im, 255, 255, 255));
  ob_start(); imagepng($im); $png = ob_get_clean();
  check("gd png roundtrip", substr($png, 1, 3) === "PNG");
} else { skip("gd"); }

// --- zlib roundtrip ---
if (promised("zlib")) {
  $raw = "legacy-kit-zlib";
  check("zlib gz roundtrip", gzdecode(gzencode($raw, 6)) === $raw);
} else { skip("zlib"); }

// --- openssl: underlying library version and route ---
$text = OPENSSL_VERSION_TEXT;
echo "OPENSSL_VERSION_TEXT: $text\n";
check("openssl version parse", (bool) preg_match("/^OpenSSL (\d+)\.(\d+)\./", $text, $m));
if ($route === "openssl11") {
  check("route openssl11", isset($m) && $m[1] === "1" && $m[2] === "1");
} elseif ($route === "openssl3") {
  check("route openssl3", isset($m) && (int) $m[1] >= 3);
}

// --- openssl: TLS protocol support ---
check("TLS 1.2 constant", defined("STREAM_CRYPTO_METHOD_TLSv1_2_CLIENT"));
// STREAM_CRYPTO_METHOD_TLSv1_3_CLIENT only exists since PHP 7.4: the constant
// arrived together with TLS 1.3 stream support in PHP itself, so 7.0-7.3 on the
// openssl3 route have OpenSSL 3 underneath but no such method: those series must
// not fail on a constant their stream API never had.
// version-branch: tls13-const-74
if ($route === "openssl3" && version_compare(PHP_VERSION, "7.4", ">=")) {
  check("TLS 1.3 constant", defined("STREAM_CRYPTO_METHOD_TLSv1_3_CLIENT"));
} else {
  echo "INFO: TLS 1.3 constant check skipped on PHP " . PHP_VERSION . "\n";
}

// --- openssl: cipher availability ---
$ciphers = openssl_get_cipher_methods();
check("aes-256-cbc cipher", in_array("aes-256-cbc", $ciphers, true)
  || in_array("AES-256-CBC", $ciphers, true));
check("aes-256-gcm cipher", in_array("aes-256-gcm", $ciphers, true)
  || in_array("AES-256-GCM", $ciphers, true));

// --- openssl: symmetric roundtrip, AEAD only where the series supports it ---
$key = openssl_random_pseudo_bytes(32, $strong);
check("csprng strong", $strong === true);
$cbcIv = openssl_random_pseudo_bytes(16);
$ct = openssl_encrypt("secret", "aes-256-cbc", $key, OPENSSL_RAW_DATA, $cbcIv);
check("aes-256-cbc roundtrip", $ct !== false
  && openssl_decrypt($ct, "aes-256-cbc", $key, OPENSSL_RAW_DATA, $cbcIv) === "secret");

// On 5.6 the 8-argument AEAD call is rejected outright ("openssl_encrypt()
// expects at most 5 parameters, 8 given"): the tag never gets set, the roundtrip
// reports FAIL, and the notice is only the symptom. The cipher NAME being listed above is the honest assertion on 5.6;
// the AEAD roundtrip runs from 7.1, which introduced that signature.
// version-branch: aead-openssl-encrypt-71
if (version_compare(PHP_VERSION, "7.1", ">=")) {
  $gcmIv = openssl_random_pseudo_bytes(12);
  $tag = "";
  $ct = openssl_encrypt("secret", "aes-256-gcm", $key, OPENSSL_RAW_DATA, $gcmIv, $tag, "", 16);
  check("aes-256-gcm roundtrip", $ct !== false
    && openssl_decrypt($ct, "aes-256-gcm", $key, OPENSSL_RAW_DATA, $gcmIv, $tag) === "secret");
} else {
  echo "INFO: AES-256-GCM roundtrip skipped on PHP " . PHP_VERSION
    . " (the AEAD arguments exist only from 7.1)\n";
}

// --- openssl: RSA sign/verify roundtrip ---
$res = openssl_pkey_new(["private_key_bits" => 2048, "private_key_type" => OPENSSL_KEYTYPE_RSA]);
check("rsa keygen", $res !== false);
if ($res !== false) {
  $ok = openssl_sign("data", $sig, $res, OPENSSL_ALGO_SHA256);
  $pub = openssl_pkey_get_details($res)["key"];
  check("rsa sha256 sign/verify", $ok && openssl_verify("data", $sig, $pub, OPENSSL_ALGO_SHA256) === 1);
}

// --- hash/digest sanity ---
check("sha256 hash", hash("sha256", "abc") ===
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

exit($fail);
'
