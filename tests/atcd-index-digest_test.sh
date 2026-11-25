#!/usr/bin/env bash
# tests/atcd-index-digest_test.sh
#
# Test of recipes-core/atc/files/atcd-index-digest.py with crafted index bytes.
# atcd reads artifacts[package][target].digest at its JSON path. The helper
# must read the same value, or refuse the index. Each crafted index hides the
# pinned guard text where a text search finds it and atcd does not.
#
# Usage: atcd-index-digest_test.sh <path-to-atcd-index-digest.py>
set -euo pipefail

HELPER="${1:?usage: atcd-index-digest_test.sh <path-to-atcd-index-digest.py>}"

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pinned="sha256:$(printf 'e%.0s' {1..64})"
other="sha256:$(printf '1%.0s' {1..64})"
atcd='"agency/atcd":{"linux-x86_64-musl":{"digest":"sha256:'"$(printf 'a%.0s' {1..64})"'","size":1,"url":"u"}}'
guard() { printf '"agency/atcd-boot-confirm":{"any":{"digest":"%s","size":1,"url":"u"}}' "$1"; }

# expect_digest <name> <index bytes> <want digest>
expect_digest() {
  local got
  printf '%s' "$2" > "$tmp/index.json"
  if got="$(python3 "$HELPER" "$tmp/index.json" agency/atcd-boot-confirm any 2> "$tmp/err")" &&
    [ "$got" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: got [$got], want [$3]: $(cat "$tmp/err")" >&2
    failures=$((failures + 1))
  fi
}

# expect_refused <name> <index bytes>
expect_refused() {
  local got
  printf '%s' "$2" > "$tmp/index.json"
  if got="$(python3 "$HELPER" "$tmp/index.json" agency/atcd-boot-confirm any 2> "$tmp/err")"; then
    echo "FAIL: $1: the helper printed [$got], want a refusal" >&2
    failures=$((failures + 1))
  else
    echo "ok: $1"
  fi
}

expect_digest "a compact index gives the guard digest" \
  "{\"artifacts\":{$atcd,$(guard "$pinned")},\"track\":\"stable\",\"version\":\"0.2.4\"}" "$pinned"
expect_digest "whitespace and key order do not matter" \
  "{ \"version\" : \"0.2.4\", \"artifacts\" : { $(guard "$pinned") , $atcd } }" "$pinned"

# A nested copy of the pinned entry before the real one. A text search finds
# the nested copy. atcd reads the real entry, so the helper must too.
expect_digest "a nested guard entry in a root field does not answer" \
  "{\"aaa\":{\"artifacts\":{$(guard "$pinned")}},\"artifacts\":{$atcd,$(guard "$other")}}" "$other"
expect_digest "a guard entry inside another package does not answer" \
  "{\"artifacts\":{\"aaa\":{$(guard "$pinned")},$atcd,$(guard "$other")}}" "$other"
expect_digest "a guard entry inside another target does not answer" \
  "{\"artifacts\":{\"agency/atcd-boot-confirm\":{\"aaa\":{$(guard "$pinned")},\"any\":{\"digest\":\"$other\"}}}}" "$other"
# atcd decodes an escape in a key. So does the helper.
expect_digest "an escaped key reads as its plain form, as atcd reads it" \
  "{\"artifacts\":{\"agency\\/atcd-boot-confirm\":{\"any\":{\"digest\":\"$pinned\"}}}}" "$pinned"

# atcd keeps the last of two equal keys, and a reader that keeps the first
# disagrees with it. The helper refuses both.
expect_refused "two guard packages are refused" \
  "{\"artifacts\":{$(guard "$pinned"),$(guard "$other")}}"
expect_refused "a plain and an escaped guard key are refused" \
  "{\"artifacts\":{$(guard "$pinned"),\"agency\\/atcd-boot-confirm\":{\"any\":{\"digest\":\"$other\"}}}}"
expect_refused "two root artifacts objects are refused" \
  "{\"artifacts\":{$(guard "$pinned")},\"artifacts\":{$(guard "$other")}}"
expect_refused "bytes after the index are refused" \
  "{\"artifacts\":{$(guard "$other")}}{\"artifacts\":{$(guard "$pinned")}}"
expect_refused "an index with no guard entry is refused" "{\"artifacts\":{$atcd}}"
expect_refused "a guard digest that is not sha256 hex is refused" \
  "{\"artifacts\":{\"agency/atcd-boot-confirm\":{\"any\":{\"digest\":\"sha256:EE\"}}}}"
expect_refused "a guard digest that is not a string is refused" \
  "{\"artifacts\":{\"agency/atcd-boot-confirm\":{\"any\":{\"digest\":1}}}}"
expect_refused "an artifacts array is refused" "{\"artifacts\":[$(guard "$pinned" | sed 's/^"[^"]*"://')]}"
expect_refused "bytes that are not JSON are refused" "not json"

# Bytes that atcd (serde_json) refuses and Python's json module takes. The
# helper must refuse them too, or the build accepts an index atcd cannot read.
good="{\"artifacts\":{$(guard "$pinned")}"
expect_refused "NaN is refused" "$good,\"n\":NaN}"
expect_refused "Infinity is refused" "$good,\"n\":-Infinity}"
expect_refused "a number too large for a float is refused" "$good,\"n\":1e400}"
expect_refused "a lone surrogate is refused" "$good,\"n\":\"\\ud800\"}"
deep="$(printf '[%.0s' {1..200})$(printf ']%.0s' {1..200})"
expect_refused "nesting deeper than 128 is refused" "$good,\"n\":$deep}"
printf '\xef\xbb\xbf%s}' "$good" > "$tmp/bom.json"
if python3 "$HELPER" "$tmp/bom.json" agency/atcd-boot-confirm any > /dev/null 2>&1; then
  echo "FAIL: an index with a BOM: the helper read it, want a refusal" >&2
  failures=$((failures + 1))
else
  echo "ok: an index with a BOM is refused"
fi
printf '%s}' "$good" | iconv -f UTF-8 -t UTF-16LE > "$tmp/utf16.json"
if python3 "$HELPER" "$tmp/utf16.json" agency/atcd-boot-confirm any > /dev/null 2>&1; then
  echo "FAIL: a UTF-16 index: the helper read it, want a refusal" >&2
  failures=$((failures + 1))
else
  echo "ok: a UTF-16 index is refused"
fi

# --extract takes named members from a plain tar. Each must be one regular
# file whose sha256 and size equal its entry in the signed manifest.
bundle="$tmp/bundle"
mkdir -p "$bundle/bin"
printf 'uid helper\n' > "$bundle/bin/newuidmap"
printf 'gid helper, longer\n' > "$bundle/bin/newgidmap"
printf 'podman\n' > "$bundle/bin/podman"
mentry() { # <path> [<sha256>] [<size>] [<type>]: one manifest entry
  local f="$bundle/$1"
  printf '{"path":"%s","sha256":"%s","size":%s,"type":"%s"}' "$1" \
    "${2:-$(sha256sum "$f" | cut -d' ' -f1)}" "${3:-$(stat -c %s "$f")}" "${4:-file}"
}
podman_index() { # <manifest entries, comma-separated>
  printf '{"artifacts":{"agency/podman":{"linux-x86_64-musl":{"digest":"%s","manifest":[%s]}}}}' \
    "$pinned" "$1" > "$tmp/podman-index.json"
}
good_manifest="$(mentry bin/newgidmap),$(mentry bin/newuidmap),$(mentry bin/podman)"
# names <dir>: the sorted names in <dir>, dot files too, each with a space.
names() { find "$1" -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
# expect_extract <name> <ok|refused> <tar>: run --extract into a new directory.
case_n=0
expect_extract() {
  local got out
  case_n=$((case_n + 1))
  out="$tmp/out-$case_n"
  mkdir "$out"
  if got="$(python3 "$HELPER" "$tmp/podman-index.json" agency/podman linux-x86_64-musl \
    --extract "$3" "$out" bin/newuidmap bin/newgidmap 2> "$tmp/err")"; then
    if [ "$2" = ok ] && [ "$got" = "$pinned" ] && cmp -s "$out/newuidmap" "$bundle/bin/newuidmap" &&
      cmp -s "$out/newgidmap" "$bundle/bin/newgidmap" && [ "$(names "$out")" = "newgidmap newuidmap " ]; then
      echo "ok: $1"
    else
      echo "FAIL: $1: the helper extracted [$(names "$out")] and printed [$got]" >&2
      failures=$((failures + 1))
    fi
  elif [ "$2" = refused ] && [ -z "$(names "$out")" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: want $2, got exit non-zero: $(cat "$tmp/err")" >&2
    failures=$((failures + 1))
  fi
}
tar -C "$bundle" -cf "$tmp/good.tar" bin/podman bin/newgidmap bin/newuidmap
podman_index "$good_manifest"
expect_extract "the two helpers with the manifest bytes are extracted" ok "$tmp/good.tar"
podman_index "$(mentry bin/newgidmap "$(printf '0%.0s' {1..64})"),$(mentry bin/newuidmap)"
expect_extract "a helper with another sha256 is refused" refused "$tmp/good.tar"
podman_index "$(mentry bin/newgidmap "" 1),$(mentry bin/newuidmap)"
expect_extract "a helper with another size is refused" refused "$tmp/good.tar"
podman_index "$(mentry bin/newuidmap)"
expect_extract "a helper with no manifest entry is refused" refused "$tmp/good.tar"
podman_index "$good_manifest,$(mentry bin/newgidmap)"
expect_extract "a helper with two manifest entries is refused" refused "$tmp/good.tar"
podman_index "$(mentry bin/newgidmap "" "" dir),$(mentry bin/newuidmap)"
expect_extract "a manifest entry that is not a file is refused" refused "$tmp/good.tar"
podman_index "$good_manifest"
tar -C "$bundle" -cf "$tmp/missing.tar" bin/podman bin/newuidmap
expect_extract "a tar with no newgidmap is refused" refused "$tmp/missing.tar"
tar -C "$bundle" -cf "$tmp/dot.tar" ./bin/newgidmap ./bin/newuidmap
expect_extract "members under another name are not taken" refused "$tmp/dot.tar"
cp "$tmp/good.tar" "$tmp/twice.tar"
tar -C "$bundle" -rf "$tmp/twice.tar" bin/newgidmap
expect_extract "a tar that holds a helper twice is refused" refused "$tmp/twice.tar"
links="$tmp/links"
mkdir -p "$links/bin"
cp "$bundle/bin/newuidmap" "$bundle/bin/podman" "$links/bin/"
ln -s podman "$links/bin/newgidmap"
tar -C "$links" -cf "$tmp/symlink.tar" bin/newgidmap bin/newuidmap
expect_extract "a helper that is a symbolic link is refused" refused "$tmp/symlink.tar"
hard="$tmp/hard"
mkdir -p "$hard/bin"
cp "$bundle/bin/newgidmap" "$bundle/bin/newuidmap" "$hard/bin/"
ln "$hard/bin/newgidmap" "$hard/bin/other"
tar -C "$hard" -cf "$tmp/hardlink.tar" bin/other bin/newgidmap bin/newuidmap
expect_extract "a helper that is a hard link is refused" refused "$tmp/hardlink.tar"
gzip -c "$tmp/good.tar" > "$tmp/good.tar.gz"
expect_extract "a compressed tar is refused" refused "$tmp/good.tar.gz"

[ "$failures" -eq 0 ] || {
  echo "$failures case(s) failed" >&2
  exit 1
}
