#!/usr/bin/env bash
# scripts/rauc-test-keys.sh
#
# Generate the RAUC TEST keys for an atc image. Run it on the build host, as
# the build user. The proof scripts read them from <cache>/atc-rauc-keys.
#
# Two CAs, each with one signing key:
#
#   ca.cert.pem             the CA the image's keyring trusts
#   signing.{cert,key}.pem  signs the bundles the image accepts
#   other-ca.cert.pem       a CA the image does NOT trust
#   other-signing.{cert,key}.pem
#                           signs the bad-signature fault case
#
# THESE ARE TEST KEYS. They never enter a repository:
# scripts/check-meta-atc-recipe.sh fails on any *.pem, *.key or *.crt in the
# layer, and qemu-rauc-proof.sh refuses to build without them. A product
# signs its bundles with its own PKI.
#
# IDEMPOTENT. A file that exists stays, so a second run changes nothing and a
# bundle signed yesterday still verifies against the image built today. To
# rotate, delete the directory.
#
# Usage:
#   ./rauc-test-keys.sh [<dir>]     default <cache>/atc-rauc-keys
#   ./rauc-test-keys.sh --self-test
set -euo pipefail

CACHE_DIR="${CACHE_DIR:-/cache}"

die() {
  echo "rauc-test-keys: $*" >&2
  exit 1
}

# One self-signed CA. $1 is the directory, $2 the file prefix, $3 the name.
make_ca() {
  local dir="$1" prefix="$2" name="$3"
  if [ -f "$dir/$prefix.cert.pem" ]; then
    return 0
  fi
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -subj "/O=atc test/CN=$name" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$dir/$prefix.key.pem" -out "$dir/$prefix.cert.pem" 2> /dev/null
  echo "rauc-test-keys: created $dir/$prefix.cert.pem"
}

# One signing key under a CA. $1 dir, $2 CA prefix, $3 key prefix, $4 name.
make_signing_key() {
  local dir="$1" ca="$2" prefix="$3" name="$4"
  if [ -f "$dir/$prefix.cert.pem" ]; then
    return 0
  fi
  openssl req -newkey rsa:3072 -nodes -sha256 -subj "/O=atc test/CN=$name" \
    -keyout "$dir/$prefix.key.pem" -out "$dir/$prefix.csr.pem" 2> /dev/null
  printf '%s\n' "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature" \
    "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" \
    > "$dir/$prefix.ext"
  openssl x509 -req -sha256 -days 3650 -in "$dir/$prefix.csr.pem" \
    -CA "$dir/$ca.cert.pem" -CAkey "$dir/$ca.key.pem" -CAcreateserial \
    -extfile "$dir/$prefix.ext" -out "$dir/$prefix.cert.pem" 2> /dev/null
  rm -f "$dir/$prefix.csr.pem" "$dir/$prefix.ext"
  echo "rauc-test-keys: created $dir/$prefix.cert.pem"
}

generate() {
  local dir="$1"
  command -v openssl > /dev/null || die "openssl is not on PATH"
  install -d -m 0700 "$dir"
  make_ca "$dir" ca "atc RAUC test CA"
  make_signing_key "$dir" ca signing "atc RAUC test signing"
  make_ca "$dir" other-ca "atc RAUC untrusted test CA"
  make_signing_key "$dir" other-ca other-signing "atc RAUC untrusted signing"
  chmod 0600 "$dir"/*.key.pem
}

# Each signing cert must chain to its own CA and NOT to the other one. A key
# that verified under both would make the bad-signature case pass for the
# wrong reason.
verify_chains() {
  local dir="$1"
  openssl verify -CAfile "$dir/ca.cert.pem" "$dir/signing.cert.pem" > /dev/null ||
    die "signing.cert.pem does not chain to ca.cert.pem"
  openssl verify -CAfile "$dir/other-ca.cert.pem" "$dir/other-signing.cert.pem" > /dev/null ||
    die "other-signing.cert.pem does not chain to other-ca.cert.pem"
  if openssl verify -CAfile "$dir/ca.cert.pem" "$dir/other-signing.cert.pem" > /dev/null 2>&1; then
    die "other-signing.cert.pem chains to the TRUSTED CA"
  fi
}

self_test() {
  local tmp first second
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  generate "$tmp/keys" > /dev/null
  verify_chains "$tmp/keys"
  [ "$(find "$tmp/keys" -name '*.cert.pem' | wc -l)" = 4 ] &&
    [ "$(find "$tmp/keys" -name '*.key.pem' | wc -l)" = 4 ] ||
    die "self-test: the first run did not write four certificates and four keys"
  cmp -s "$tmp/keys/ca.cert.pem" "$tmp/keys/other-ca.cert.pem" &&
    die "self-test: the two CAs are the same certificate"
  first="$(cd "$tmp/keys" && sha256sum -- *.pem)"
  generate "$tmp/keys" > "$tmp/second.out"
  second="$(cd "$tmp/keys" && sha256sum -- *.pem)"
  [ "$first" = "$second" ] || die "self-test: a second run changed a key"
  [ ! -s "$tmp/second.out" ] || die "self-test: a second run created a file"
  [ "$(stat -c %a "$tmp/keys")" = 700 ] || die "self-test: the key directory is not 0700"
  [ "$(stat -c %a "$tmp/keys/signing.key.pem")" = 600 ] ||
    die "self-test: signing.key.pem is not 0600"
  echo "rauc-test-keys --self-test: OK"
}

case "${1:-}" in
  --self-test)
    self_test
    ;;
  -*)
    die "unknown option $1"
    ;;
  *)
    dir="${1:-$CACHE_DIR/atc-rauc-keys}"
    generate "$dir"
    verify_chains "$dir"
    echo "rauc-test-keys: keys in $dir"
    ;;
esac
