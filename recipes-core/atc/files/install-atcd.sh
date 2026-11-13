#!/bin/sh
# install-atcd.sh: fetch a VERIFIED atcd onto a Linux device, then run
# `atcd install` with your arguments.
#
# Usage:
#   curl -fsSL https://atc.dev/install-atcd.sh | sudo sh -s -- --root --socket-owner <user> [atcd install flags]
#   curl -fsSL https://atc.dev/agency/nightly/install-atcd.sh | sudo sh -s -- ...
#
# Every argument goes to `atcd install` unchanged. Run `atcd install --help`
# for the flags. This script installs nothing itself. One addition: if PID 1
# is not systemd, the script adds --no-service. atcd then seeds the store and
# writes no unit.
#
# POSIX sh: a device can have no bash.
#
# The script stops before it runs atcd if any check fails:
#   1. The ed25519 signature on index.json verifies against a key pinned below.
#   2. The signed index names the requested track (and version, if pinned).
#   3. The sha256 of the atcd binary equals the digest in the signed index.
#
# Environment:
#   ATC_TRACK           release track (default: the track this copy came from)
#   ATC_BASE_URL        index base URL (default: https://atc.dev/agency)
#   ATC_VERSION         refuse unless the signed index names this version.
#                       A leading "v" is ignored, so a release tag also works.
#   ATC_LOCAL_DIR       air-gapped mode: read index.json, index.json.sig and
#                       atcd-<target> from this directory. No network access.
#   ATC_DOWNLOAD_ONLY   after every check, write the verified atcd to this
#                       path (mode 0755) and exit 0. atcd does not run. Use it
#                       to carry a verified binary to an air-gapped host.
#   ATC_TARGET          with ATC_DOWNLOAD_ONLY only: the atcd target to fetch,
#                       linux-x86_64-musl or linux-aarch64-musl, in place of
#                       this host's. For an image build of another arch.
#   ATC_CHANNEL_TOKEN   token for the internal dev and pr-* tracks. Sent only
#                       to https://atc.dev/agency/dev/ and /agency/pr-*/.
#
# Requires: openssl 3 (ed25519 with -rawin), awk, sha256sum or shasum, and
# curl unless ATC_LOCAL_DIR is set.

set -eu

# The pinned release-signing public keys, hex, space-separated. This MUST equal
# AGENCY_PUBKEYS_HEX in crates/atc-update/src/keys.rs.
# tools/scripts/tests/install-atcd_test.sh fails when the two differ.
ATCD_PUBKEYS_HEX="8f0661861de15f450781f8cdb08a33e094aff7c67539371d9ecc4dd12362202d"

# publish-release-origin.sh replaces this line in the copy it publishes at
# agency/<track>/install-atcd.sh. The apex copy keeps `stable`.
DEFAULT_TRACK=stable

# The init probe reads this file. It is a line of its own so that
# tools/scripts/tests/install-atcd_test.sh can point a COPY at a fixture.
INIT_COMM=/proc/1/comm

die() {
  printf 'install-atcd: %s\n' "$*" >&2
  exit 1
}

info() {
  printf 'install-atcd: %s\n' "$*" >&2
}

# A binary for another target cannot run here, so ATC_TARGET only downloads.
if [ -n "${ATC_TARGET:-}" ]; then
  [ -n "${ATC_DOWNLOAD_ONLY:-}" ] ||
    die "ATC_TARGET needs ATC_DOWNLOAD_ONLY: a binary for another target cannot run on this host"
  case "$ATC_TARGET" in
    linux-x86_64-musl | linux-aarch64-musl) target="$ATC_TARGET" ;;
    *) die "ATC_TARGET=$ATC_TARGET is not a target. Use linux-x86_64-musl or linux-aarch64-musl." ;;
  esac
else
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) target="linux-x86_64-musl" ;;
    Linux/aarch64 | Linux/arm64) target="linux-aarch64-musl" ;;
    *) die "unsupported platform $(uname -s)/$(uname -m). atcd runs on Linux x86_64 and aarch64." ;;
  esac
fi

TRACK="${ATC_TRACK:-$DEFAULT_TRACK}"
BASE="${ATC_BASE_URL:-https://atc.dev/agency}"
PIN="${ATC_VERSION:-}"
case "$PIN" in
  v) die "ATC_VERSION=v names no version. Set a version such as 0.4.2 or v0.4.2." ;;
esac
PIN="${PIN#v}"
LOCAL_DIR="${ATC_LOCAL_DIR:-}"
DOWNLOAD_ONLY="${ATC_DOWNLOAD_ONLY:-}"
if [ -n "$DOWNLOAD_ONLY" ] && [ $# -gt 0 ]; then
  die "ATC_DOWNLOAD_ONLY runs no 'atcd install', so it takes no arguments (got: $*)"
fi

TOKEN="${ATC_CHANNEL_TOKEN:-}"

case "$TRACK" in
  "" | *[!a-z0-9-]*) die "invalid ATC_TRACK '$TRACK' (use lower-case letters, digits and '-')" ;;
esac
case "$TOKEN" in
  *[!A-Za-z0-9._~+/=-]*) die "ATC_CHANNEL_TOKEN contains a character that is not allowed (whitespace or a quote?)" ;;
esac

command -v openssl > /dev/null 2>&1 ||
  die "openssl is required to verify the release signature, and it is not in PATH. Install OpenSSL 3."
command -v awk > /dev/null 2>&1 || die "awk is required, and it is not in PATH"
if command -v sha256sum > /dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum > /dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "sha256sum or shasum is required, and neither is in PATH"
fi
if [ -z "$LOCAL_DIR" ]; then
  command -v curl > /dev/null 2>&1 || die "curl is required, and it is not in PATH (or set ATC_LOCAL_DIR)"
fi

work=$(mktemp -d) || die "mktemp -d failed"
trap 'rm -rf "$work"' EXIT
# dash runs no EXIT trap on a signal death, so turn each signal into an exit.
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# The channel token goes ONLY to the gated paths on atc.dev, the same rule as
# crates/atc-update/src/channel_gate.rs. A mirror, a look-alike host and the
# public blob prefix never see it. It goes through `--config -` on stdin, so it
# is not in argv, where any user on the device can read it with `ps`. A token
# request does not follow redirects (no -L): curl would send the header to the
# redirect target too, before the signature check can refuse anything.
fetch() { # <url> <out-file>
  case "$1" in
    https://atc.dev/agency/dev/* | https://atc.dev/agency/pr-*/*)
      if [ -n "$TOKEN" ]; then
        printf 'header = "X-Atc-Channel-Token: %s"\n' "$TOKEN" |
          curl -fsS --config - -o "$2" "$1"
        return
      fi
      ;;
  esac
  curl -fsSL -o "$2" "$1"
}

# Write the bytes that a lower-case hex string names. POSIX printf reads octal
# escapes, so this needs no xxd.
hex_to_file() { # <hex> <out-file>
  case "$1" in
    "" | *[!0-9a-f]*) return 1 ;;
  esac
  htf_esc=$(printf '%s' "$1" | awk '{
    d = "0123456789abcdef"
    for (i = 1; i < length($0); i += 2)
      printf "\\%03o", (index(d, substr($0, i, 1)) - 1) * 16 + index(d, substr($0, i + 1, 1)) - 1
  }')
  # shellcheck disable=SC2059 # the format is octal escapes that awk built from checked hex
  printf "$htf_esc" > "$2"
}

# ---------------------------------------------------------------------------
# 1. Get the index, its signature and (in local mode) the binary
# ---------------------------------------------------------------------------

if [ -n "$LOCAL_DIR" ]; then
  info "local mode: reading $LOCAL_DIR (track $TRACK, target $target)"
  cp "$LOCAL_DIR/index.json" "$work/index.json" || die "cannot read $LOCAL_DIR/index.json"
  cp "$LOCAL_DIR/index.json.sig" "$work/index.json.sig" || die "cannot read $LOCAL_DIR/index.json.sig"
else
  info "track $TRACK, target $target, index $BASE/$TRACK/index.json"
  hint=""
  case "$BASE/$TRACK/" in
    https://atc.dev/agency/dev/* | https://atc.dev/agency/pr-*/*)
      hint=" (track $TRACK is internal: set ATC_CHANNEL_TOKEN)"
      ;;
  esac
  fetch "$BASE/$TRACK/index.json" "$work/index.json" ||
    die "cannot fetch $BASE/$TRACK/index.json$hint"
  fetch "$BASE/$TRACK/index.json.sig" "$work/index.json.sig" ||
    die "cannot fetch $BASE/$TRACK/index.json.sig$hint"
fi

# ---------------------------------------------------------------------------
# 2. Verify the ed25519 signature over the index bytes
# ---------------------------------------------------------------------------

# The .sig file is one line: "<key_id> <signature hex>". key_id is the first 8
# bytes of the public key (crates/atc-update/src/sign.rs), so it picks the
# pinned key to check against during a key rotation.
sig_key_id=$(awk 'NR == 1 { print $1 }' "$work/index.json.sig")
sig_hex=$(awk 'NR == 1 { print $2 }' "$work/index.json.sig")
[ "${#sig_hex}" -eq 128 ] || die "index.json.sig is malformed (expected a 64-byte signature)"
hex_to_file "$sig_hex" "$work/sig.raw" || die "index.json.sig is malformed (signature is not hex)"

pubkey=""
for k in $ATCD_PUBKEYS_HEX; do
  case "$k" in
    "$sig_key_id"*) pubkey="$k" ;;
  esac
done
[ "${#sig_key_id}" -eq 16 ] && [ -n "$pubkey" ] ||
  die "index.json.sig names key '$sig_key_id', which is not a pinned release key. Refusing the index."

# An ed25519 SubjectPublicKeyInfo in DER is a fixed 12-byte prefix and the raw
# 32-byte key.
hex_to_file "302a300506032b6570032100$pubkey" "$work/key.der" || die "a pinned key is not valid hex"

# Check the output AND the exit status. Some OpenSSL builds have returned 0 on
# a failed verify, and the release index is the root of trust for this run.
verify_out=$(openssl pkeyutl -verify -pubin -inkey "$work/key.der" -keyform DER \
  -rawin -in "$work/index.json" -sigfile "$work/sig.raw" 2>&1) ||
  die "SIGNATURE CHECK FAILED for index.json. Refusing the index. openssl said: $verify_out"
case "$verify_out" in
  *"Signature Verified Successfully"*) ;;
  *) die "SIGNATURE CHECK FAILED for index.json (openssl gave no success line). openssl said: $verify_out" ;;
esac
info "index signature verified (key $sig_key_id)"

# ---------------------------------------------------------------------------
# 3. Read the signed index: track, version, and the atcd entry for this target
# ---------------------------------------------------------------------------

# Compact, sorted JSON from build-release-index.py. No string value holds '{',
# '}' or '"', so brace counting finds each object. The same parser as install.sh.
parsed=$(awk -v pkg="agency/atcd" -v target="$target" '
  function obj_body(s, openkey,   p, i, depth, c, n, start) {
    p = index(s, openkey)
    if (p == 0) return ""
    start = p + length(openkey) - 1
    depth = 0; n = length(s)
    for (i = start; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "{") depth++
      else if (c == "}") { depth--; if (depth == 0) return substr(s, start, i - start + 1) }
    }
    return ""
  }
  function strval(s, key,   pat, p, start, e) {
    pat = "\"" key "\":\""
    p = index(s, pat)
    if (p == 0) return ""
    start = p + length(pat)
    e = start
    while (e <= length(s) && substr(s, e, 1) != "\"") e++
    return substr(s, start, e - start)
  }
  { js = js $0 }
  END {
    arts = obj_body(js, "\"artifacts\":{")
    if (arts == "") { print "no artifacts object in the index" > "/dev/stderr"; exit 1 }
    # Read top-level fields with the artifacts object cut out, so a nested
    # "version" or "track" key cannot answer for the index.
    p = index(js, arts)
    top = substr(js, 1, p - 1) substr(js, p + length(arts))
    entry = obj_body(obj_body(arts, "\"" pkg "\":{"), "\"" target "\":{")
    if (entry == "") { print "the index has no " pkg " artifact for " target > "/dev/stderr"; exit 1 }
    print "track=" strval(top, "track")
    print "version=" strval(top, "version")
    print "url=" strval(entry, "url")
    print "digest=" strval(entry, "digest")
  }
' "$work/index.json") || die "cannot read the atcd entry for $target from the signed index"

idx_track="" idx_version="" url="" digest=""
while IFS= read -r line; do
  case "$line" in
    track=*) idx_track="${line#track=}" ;;
    version=*) idx_version="${line#version=}" ;;
    url=*) url="${line#url=}" ;;
    digest=sha256:*) digest="${line#digest=sha256:}" ;;
  esac
done << EOF
$parsed
EOF

# A validly signed index for ANOTHER track is still the wrong index.
[ "$idx_track" = "$TRACK" ] ||
  die "the signed index is for track '$idx_track', not '$TRACK'. Refusing it."
if [ -n "$PIN" ] && [ "$idx_version" != "$PIN" ] && [ -n "$LOCAL_DIR" ]; then
  # No origin is involved in local mode: name the index that was compared.
  die "ATC_VERSION is $PIN, but the local index in $LOCAL_DIR is for $idx_version. Put the index.json, index.json.sig and atcd-$target of release $PIN in that directory."
fi
if [ -n "$PIN" ] && [ "$idx_version" != "$PIN" ]; then
  die "ATC_VERSION is $PIN, but track $TRACK now serves $idx_version. The origin keeps only the current version. For an older one, put its release's index.json, index.json.sig and atcd-$target in a directory and set ATC_LOCAL_DIR."
fi
[ "${#digest}" -eq 64 ] || die "the atcd entry in the signed index has no sha256 digest"
info "atcd $idx_version, sha256 $digest"

# ---------------------------------------------------------------------------
# 4. Get the binary and verify its sha256 against the signed index
# ---------------------------------------------------------------------------

if [ -n "$LOCAL_DIR" ]; then
  cp "$LOCAL_DIR/atcd-$target" "$work/atcd" || die "cannot read $LOCAL_DIR/atcd-$target"
else
  [ -n "$url" ] || die "the atcd entry in the signed index has no url"
  fetch "$url" "$work/atcd" || die "cannot fetch $url"
fi
got=$(sha256_of "$work/atcd") || die "cannot compute the sha256 of the atcd binary"
[ "$got" = "$digest" ] ||
  die "SHA256 MISMATCH for atcd: the signed index says $digest, the file is $got. Refusing it."
info "atcd sha256 verified"

# Download-only: put the verified bytes at the path in one rename, so a reader
# never sees a partial file there.
if [ -n "$DOWNLOAD_ONLY" ]; then
  dl_tmp=$(mktemp "$(dirname "$DOWNLOAD_ONLY")/.atcd.XXXXXX") ||
    die "cannot create a temporary file next to $DOWNLOAD_ONLY"
  # An interrupted run must not leave a binary-sized file beside the target.
  trap 'rm -rf "$work"; rm -f "$dl_tmp"' EXIT
  if cp "$work/atcd" "$dl_tmp" && chmod 0755 "$dl_tmp" && mv -f "$dl_tmp" "$DOWNLOAD_ONLY"; then
    info "verified atcd $idx_version written to $DOWNLOAD_ONLY"
    exit 0
  fi
  rm -f "$dl_tmp"
  die "cannot write $DOWNLOAD_ONLY"
fi

# ---------------------------------------------------------------------------
# 5. Hand over to atcd install
# ---------------------------------------------------------------------------

# atcd refuses a service install when PID 1 is not systemd. The rule is
# remote_init_is_systemd in crates/atc-cmd-bootstrap: read /proc/1/comm, and
# take an unreadable file as systemd. Do not probe for systemctl: a container
# can hold systemctl and /run/systemd/system with no systemd running.
want_service=yes
for a in "$@"; do
  case "$a" in --no-service) want_service=no ;; esac
done
if [ "$want_service" = yes ] && init=$(cat "$INIT_COMM" 2> /dev/null) && [ "$init" != systemd ]; then
  info "PID 1 is '$init', not systemd: adding --no-service. atcd seeds the store and writes no unit."
  set -- "$@" --no-service
fi

chmod 0755 "$work/atcd"
info "running: atcd install $*"
# Not `exec`: the EXIT trap must still remove the temporary copy. stdin is
# /dev/null, so atcd cannot read the rest of a `curl | sh` script.
rc=0
"$work/atcd" install "$@" < /dev/null || rc=$?
if [ "$rc" -eq 126 ]; then
  info "the kernel refused to run $work/atcd. Is $(dirname "$work") mounted noexec? Set TMPDIR to an exec mount."
fi
exit "$rc"
