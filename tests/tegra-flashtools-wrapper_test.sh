#!/usr/bin/env bash
# tests/tegra-flashtools-wrapper_test.sh
#
# Behavioural test for meta-atc's tegra-flashtools-native append, which wraps
# each of NVIDIA's i386 and x86-64 flash tools so the arm64 builder can run it.
#
# It runs the append's real do_install:append body in this shell, against a
# fake ${D}${BINDIR} that holds ELF fixtures for i386 (e_machine 3), x86-64
# (62) and aarch64 (183), a script, and a symbolic link. bitbake expands
# ${D}, ${BINDIR} and ${BUILD_ARCH} before it runs the body, and a shell
# expands them the same way, so the body runs unchanged. Then it runs the
# wrappers the body wrote:
#
#   - on the arm64 builder, the tool runs under the matching qemu;
#   - on the x86-64 flash host, the tool runs directly, with no qemu;
#   - through a symbolic link in another directory, which is how initrd-flash
#     runs tegrarcm_v2 from rcmboot_blob/.
#
# Usage: tegra-flashtools-wrapper_test.sh <path-to-tegra-flashtools-native_%.bbappend>
# shellcheck disable=SC2016  # every literal $NAME here is the append's text
set -euo pipefail

APPEND="${1:?usage: tegra-flashtools-wrapper_test.sh <append>}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# The body of `do_install:append() {`, up to the `}` at column 0.
body="$(sed -n '/^do_install:append() {$/,/^}$/{//!p;}' "$APPEND")"
[ -n "$body" ] || {
  echo "FAIL: no do_install:append body in $APPEND" >&2
  exit 1
}
printf 'run_append() {\n%s\n}\n' "$body" > "$tmp/append.sh"

# An ELF header that stops after e_machine: the magic, then e_machine as a
# little-endian 16-bit value at offset 18. The append reads nothing else.
# $1 the file, $2 e_machine.
elf() {
  {
    printf '\177ELF\001\001\001'
    head -c 11 /dev/zero
    # shellcheck disable=SC2059  # the format IS the two octal escapes
    printf "\\$(printf '%03o' $(($2 % 256)))\\$(printf '%03o' $(($2 / 256)))"
  } > "$1"
  chmod 0755 "$1"
}

# A fake ${D}${BINDIR}. Each ELF tool is a fixture whose "run" is only that
# its path reaches the fake qemu or the wrapper's direct exec.
make_bindir() {
  local d="$1/usr/bin"
  mkdir -p "$d"
  elf "$d/tegrarcm_v2" 3
  elf "$d/tegrahost_v2_64" 62
  elf "$d/native_tool" 183
  printf '#!/bin/sh\necho script\n' > "$d/tegraflash.py"
  chmod 0755 "$d/tegraflash.py"
  ln -s tegrarcm_v2 "$d/tegrarcm_link"
}

run_body() { # $1 D, $2 BUILD_ARCH
  (
    # shellcheck disable=SC2034  # the sourced body reads all three
    D="$1" BINDIR=/usr/bin BUILD_ARCH="$2"
    # shellcheck disable=SC1091
    source "$tmp/append.sh"
    run_append
  )
}

# ── 1. An x86-64 build host leaves every tool as it is ──────────────────────
make_bindir "$tmp/x86"
run_body "$tmp/x86" x86_64
if [ -n "$(find "$tmp/x86" -name '*.real')" ]; then
  fail "an x86-64 build host wrapped a tool"
else
  echo "ok: an x86-64 build host wraps nothing"
fi

# ── 2. An aarch64 build host wraps exactly the i386 and x86-64 ELF tools ────
B="$tmp/arm/usr/bin"
make_bindir "$tmp/arm"
run_body "$tmp/arm" aarch64

check_wrapped() { # $1 tool, $2 the qemu it must name
  if [ ! -f "$B/$1.real" ]; then
    fail "$1 was not renamed to $1.real"
  elif ! grep -qx "    aarch64 | arm64) exec $2 \"\$real\" \"\$@\" ;;" "$B/$1"; then
    fail "the wrapper for $1 does not run $2: $(tr '\n' '|' < "$B/$1")"
  else
    echo "ok: $1 is wrapped with $2"
  fi
}
check_wrapped tegrarcm_v2 qemu-i386
check_wrapped tegrahost_v2_64 qemu-x86_64

for left in native_tool tegraflash.py; do
  if [ -e "$B/$left.real" ] || ! cmp -s "$tmp/x86/usr/bin/$left" "$B/$left"; then
    fail "$left was changed, and it is not an i386 or x86-64 ELF"
  else
    echo "ok: $left is left as it is"
  fi
done
if [ -L "$B/tegrarcm_link" ] && [ ! -e "$B/tegrarcm_link.real" ]; then
  echo "ok: a symbolic link is left as it is"
else
  fail "the symbolic link was wrapped"
fi

# ── 3. The wrappers run the right thing on each host ────────────────────────
# Replace the ELF fixtures with stand-ins that say they ran.
printf '#!/bin/sh\necho "REAL $*"\n' > "$B/tegrarcm_v2.real"
mkdir -p "$tmp/fake"
for q in qemu-i386 qemu-x86_64; do
  printf '#!/bin/sh\necho "%s $*"\n' "$q" > "$tmp/fake/$q"
done
chmod 0755 "$B/tegrarcm_v2.real" "$tmp/fake/"*

# $1 name, $2 what uname prints, $3 the directory to run from, $4 the command,
# $5 the expected stdout.
run_case() {
  local out
  printf '#!/bin/sh\necho %s\n' "$2" > "$tmp/fake/uname"
  chmod 0755 "$tmp/fake/uname"
  out="$(cd "$3" && PATH="$tmp/fake:$PATH" "$4" --chip 0x23 2> "$tmp/err")" || true
  if [ "$out" = "$5" ]; then
    echo "ok: $1"
  else
    fail "$1: printed '$out', expected '$5'. stderr: $(cat "$tmp/err")"
  fi
}

real="$(readlink -f "$B/tegrarcm_v2.real")"
run_case "an x86-64 flash host runs the tool directly" x86_64 "$B" ./tegrarcm_v2 "REAL --chip 0x23"
run_case "the aarch64 builder runs the tool under qemu-i386" aarch64 "$B" ./tegrarcm_v2 \
  "qemu-i386 $real --chip 0x23"

# initrd-flash links the tool into rcmboot_blob/ and runs it from there.
mkdir -p "$tmp/flash/rcmboot_blob"
ln -s "$B/tegrarcm_v2" "$tmp/flash/rcmboot_blob/tegrarcm_v2"
run_case "an x86-64 host runs the tool through a link in another directory" x86_64 \
  "$tmp/flash/rcmboot_blob" ./tegrarcm_v2 "REAL --chip 0x23"
run_case "the aarch64 builder runs the tool through a link in another directory" aarch64 \
  "$tmp/flash/rcmboot_blob" ./tegrarcm_v2 "qemu-i386 $real --chip 0x23"

if [ "$failures" -gt 0 ]; then
  echo "tegra-flashtools-wrapper_test: $failures failure(s)" >&2
  exit 1
fi
echo "tegra-flashtools-wrapper_test: all cases passed"
