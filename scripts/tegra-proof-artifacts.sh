#!/usr/bin/env bash
# scripts/tegra-proof-artifacts.sh
#
# Collect the Orin hardware-proof artifacts from a Tegra build into one
# directory, under fixed names, with a SHA256SUMS file. A hardware proof reads
# them by these names:
#
#   tegraflash.tar.gz  atc-image-ab-<machine>.rootfs.tegraflash.tar.gz, the
#                      factory image (APP and APP_b)
#   good.raucb         atc-bundle-<machine>.raucb, a bundle that confirms
#   bad-panic.raucb    atc-bundle-panic-<machine>.raucb, a bundle whose slot
#                      panics, so it never confirms and the board falls back
#   bad-hang.raucb     atc-bundle-hang-<machine>.raucb, a bundle whose slot
#                      stops feeding the watchdog
#   ca.cert.pem        the CA that the image's RAUC keyring holds
#   SHA256SUMS         `sha256sum` of the five files above
#
# It copies the files into <out>.partial first, then checks the copies, so
# the output holds exactly the files it checked. The archive has exactly one ext4
# member and a flash layout that names APP and APP_b. Each bundle has a
# signature the CA verifies, the compatible atc-<machine>, and a tegra-bl.cap,
# and the three bundles carry the same capsule.
#
# Run it on the build host after:
#   bitbake atc-image-ab atc-bundle atc-bundle-panic atc-bundle-hang
#
# Usage:
#   ./tegra-proof-artifacts.sh --deploy-dir <dir> --machine <m> --ca <file> \
#     --rauc <rauc> --unsquashfs <unsquashfs> --out <dir>
#   ./tegra-proof-artifacts.sh --self-test
#
#   --rauc, --unsquashfs  the native tools of the build, for example
#                         <TMPDIR>/sysroots-components/aarch64/rauc-native/usr/bin/rauc
#
# The output directory must not exist. The files go to <out>.partial first,
# which is renamed to <out> only when every file is in place. A run stopped
# halfway leaves no <out>, and the next run starts <out>.partial again.
set -euo pipefail

DEPLOY_DIR=""
MACHINE=""
CA=""
OUT=""
RAUC=""
UNSQUASHFS=""
SELF_TEST=0

die() {
  echo "tegra-proof-artifacts: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --deploy-dir)
      DEPLOY_DIR="${2:?--deploy-dir needs a value}"
      shift 2
      ;;
    --machine)
      MACHINE="${2:?--machine needs a value}"
      shift 2
      ;;
    --ca)
      CA="${2:?--ca needs a value}"
      shift 2
      ;;
    --out)
      OUT="${2:?--out needs a value}"
      shift 2
      ;;
    --rauc)
      RAUC="${2:?--rauc needs a value}"
      shift 2
      ;;
    --unsquashfs)
      UNSQUASHFS="${2:?--unsquashfs needs a value}"
      shift 2
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Check the factory archive $1.
check_archive() {
  local archive="$1" listing ext4 layout_file layout
  listing="$(tar -tzf "$archive")" || die "$archive is not a readable tar.gz"
  ext4="$(grep -c '\.ext4$' <<< "$listing" || :)"
  [ "$ext4" = 1 ] || die "$archive has $ext4 ext4 members, expected exactly one rootfs"
  for layout_file in external-flash.xml.in flash.xml.in; do
    grep -qx "$layout_file" <<< "$listing" || continue
    layout="$(tar -xzOf "$archive" "$layout_file")"
    if grep -qE '<partition [^>]*name="APP"' <<< "$layout" &&
      grep -qE '<partition [^>]*name="APP_b"' <<< "$layout"; then
      return 0
    fi
  done
  die "no flash layout in $archive names both APP and APP_b"
}

# Check bundle $1 against CA $2 for machine $3. Prints the capsule's sha256.
check_bundle() {
  local bundle="$1" ca="$2" machine="$3" info
  info="$("$RAUC" info --keyring "$ca" "$bundle" 2>&1)" ||
    die "$bundle does not verify against $ca: $(tail -n 1 <<< "$info")"
  grep -qE "^Compatible: +'atc-$machine'\$" <<< "$info" ||
    die "$bundle is not compatible with atc-$machine"
  grep -qx 'squashfs-root/tegra-bl.cap' < <("$UNSQUASHFS" -l "$bundle" 2> /dev/null) ||
    die "$bundle carries no tegra-bl.cap"
  local capsule
  capsule="$(mktemp)"
  "$UNSQUASHFS" -cat "$bundle" tegra-bl.cap > "$capsule" || {
    rm -f "$capsule"
    die "cannot read tegra-bl.cap from $bundle"
  }
  sha256sum "$capsule" | cut -d' ' -f1
  rm -f "$capsule"
}

# Copy the artifacts. $1 deploy dir, $2 machine, $3 CA file, $4 output dir.
collect() {
  local deploy="$1" machine="$2" ca="$3" out="$4" pair src dst sum first=""
  [ -d "$deploy" ] || die "no deploy directory at $deploy"
  [ -f "$ca" ] || die "no CA certificate at $ca"
  [ -x "$RAUC" ] || die "no rauc at '$RAUC'; give --rauc"
  [ -x "$UNSQUASHFS" ] || die "no unsquashfs at '$UNSQUASHFS'; give --unsquashfs"
  [ ! -e "$out" ] || die "$out exists; give a new output directory"
  for pair in \
    "atc-image-ab-$machine.rootfs.tegraflash.tar.gz tegraflash.tar.gz" \
    "atc-bundle-$machine.raucb good.raucb" \
    "atc-bundle-panic-$machine.raucb bad-panic.raucb" \
    "atc-bundle-hang-$machine.raucb bad-hang.raucb"; do
    src="${pair% *}"
    [ -f "$deploy/$src" ] || die "no $src in $deploy"
  done
  # A partial directory from a stopped run is this script's own; start again.
  if [ -e "$out.partial" ]; then
    find "$out.partial" -delete || die "cannot remove $out.partial"
  fi
  mkdir -p "$out.partial" || die "cannot make $out.partial"
  # Copy first, then check the copies. A deploy link that moves after a check
  # cannot then put a file that was never checked into the output.
  for pair in \
    "atc-image-ab-$machine.rootfs.tegraflash.tar.gz tegraflash.tar.gz" \
    "atc-bundle-$machine.raucb good.raucb" \
    "atc-bundle-panic-$machine.raucb bad-panic.raucb" \
    "atc-bundle-hang-$machine.raucb bad-hang.raucb"; do
    src="${pair% *}"
    dst="${pair#* }"
    # -L: the deploy names are links to the timestamped files.
    cp -L "$deploy/$src" "$out.partial/$dst" || die "cannot copy $src"
  done
  cp -L "$ca" "$out.partial/ca.cert.pem" || die "cannot copy $ca"
  check_archive "$out.partial/tegraflash.tar.gz"
  for dst in good bad-panic bad-hang; do
    # check_bundle dies in a subshell, so its exit is passed on by hand. The
    # self-test runs collect under `if`, where set -e does not apply.
    sum="$(check_bundle "$out.partial/$dst.raucb" "$out.partial/ca.cert.pem" "$machine")" || exit 1
    [ -z "$first" ] || [ "$sum" = "$first" ] || die "$dst.raucb carries another capsule than good.raucb"
    first="$sum"
  done
  (cd "$out.partial" && sha256sum tegraflash.tar.gz good.raucb bad-panic.raucb bad-hang.raucb ca.cert.pem > SHA256SUMS) ||
    die "cannot write SHA256SUMS"
  mv "$out.partial" "$out" || die "cannot rename $out.partial"
  echo "ok: $out, capsule sha256 $first"
  cat "$out/SHA256SUMS"
}

self_test() {
  local tmp m=jetson-orin-nano-devkit-nvme name
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/deploy" "$tmp/archive" "$tmp/bin"
  printf '<partition_layout>\n  <partition name="APP" type="data">\n  <partition name="APP_b" type="data">\n' \
    > "$tmp/archive/external-flash.xml.in"
  printf 'rootfs' > "$tmp/archive/atc-image-ab.ext4"
  pack() { (cd "$tmp/archive" && tar -czf "$tmp/deploy/atc-image-ab-$m.rootfs-20261111.tegraflash.tar.gz" -- *); }
  pack
  ln -s "atc-image-ab-$m.rootfs-20261111.tegraflash.tar.gz" "$tmp/deploy/atc-image-ab-$m.rootfs.tegraflash.tar.gz"
  # A fake bundle is a text file: line 1 the signer's CA, line 2 the
  # compatible, line 3 the capsule content, or "none".
  for name in bundle bundle-panic bundle-hang; do
    printf 'ca\natc-%s\ncapsule-1\n' "$m" > "$tmp/deploy/atc-$name-$m.raucb"
  done
  printf 'ca' > "$tmp/ca.pem"
  # The fake tools read that text. rauc info verifies when line 1 is the CA
  # file's content. unsquashfs lists and prints the capsule.
  # SWAP_FROM/SWAP_TO: the third rauc call, the last bundle check, replaces
  # the file SWAP_TO with SWAP_FROM: a deploy file that moves after its own
  # check and before the copy.
  cat > "$tmp/bin/rauc" << 'EOF'
#!/bin/sh
if [ -n "${SWAP_TO:-}" ]; then
  echo x >> "$SWAP_TO.calls"
  [ "$(wc -l < "$SWAP_TO.calls")" != 3 ] || cp "$SWAP_FROM" "$SWAP_TO"
fi
[ "$1 $2" = "info --keyring" ] || exit 2
[ "$(sed -n 1p "$4")" = "$(cat "$3")" ] || { echo "signature verification failed"; exit 1; }
echo "Compatible:     '$(sed -n 2p "$4")'"
EOF
  cat > "$tmp/bin/unsquashfs" << 'EOF'
#!/bin/sh
case "$1" in
  -l) [ "$(sed -n 3p "$2")" = none ] || echo squashfs-root/tegra-bl.cap ;;
  -cat)
    [ "$(sed -n 3p "$2")" != unreadable ] || exit 1
    sed -n 3p "$2"
    ;;
esac
EOF
  chmod +x "$tmp/bin/rauc" "$tmp/bin/unsquashfs"
  RAUC="$tmp/bin/rauc" UNSQUASHFS="$tmp/bin/unsquashfs"
  run() { (collect "$tmp/deploy" "$m" "$tmp/ca.pem" "$1") > "$tmp/out.log" 2>&1; }

  run "$tmp/out" || die "self-test: a complete deploy was refused: $(cat "$tmp/out.log")"
  cmp -s "$tmp/out/tegraflash.tar.gz" "$tmp/deploy/atc-image-ab-$m.rootfs-20261111.tegraflash.tar.gz" ||
    die "self-test: tegraflash.tar.gz is not the image"
  [ ! -L "$tmp/out/tegraflash.tar.gz" ] || die "self-test: tegraflash.tar.gz is a link"
  [ ! -e "$tmp/out.partial" ] || die "self-test: the partial directory stayed"
  (cd "$tmp/out" && sha256sum -c --quiet SHA256SUMS) || die "self-test: SHA256SUMS does not verify"
  [ "$(wc -l < "$tmp/out/SHA256SUMS")" = 5 ] || die "self-test: SHA256SUMS does not list five files"
  run "$tmp/out" && die "self-test: an existing output directory was reused"

  # A partial directory from a stopped run is replaced.
  mkdir -p "$tmp/out3.partial"
  printf 'stale' > "$tmp/out3.partial/stale"
  run "$tmp/out3" || die "self-test: a stale partial directory stopped the run: $(cat "$tmp/out.log")"
  [ ! -e "$tmp/out3/stale" ] || die "self-test: a file of a stopped run reached the output"

  # Each refusal leaves no output directory.
  refuse() {
    if run "$tmp/out-$1"; then
      die "self-test: $1 was accepted"
    fi
    grep -qF -- "$2" "$tmp/out.log" || die "self-test: $1 was refused without '$2': $(cat "$tmp/out.log")"
    [ ! -e "$tmp/out-$1" ] || die "self-test: $1 left an output directory"
  }
  cp "$tmp/deploy/atc-bundle-hang-$m.raucb" "$tmp/good"
  printf 'other\natc-%s\ncapsule-1\n' "$m" > "$tmp/deploy/atc-bundle-hang-$m.raucb"
  refuse "an unsigned bundle" "does not verify"
  printf 'ca\natc-other\ncapsule-1\n' > "$tmp/deploy/atc-bundle-hang-$m.raucb"
  refuse "a bundle for another machine" "not compatible"
  printf 'ca\natc-%s\nnone\n' "$m" > "$tmp/deploy/atc-bundle-hang-$m.raucb"
  refuse "a bundle with no capsule" "carries no tegra-bl.cap"
  printf 'ca\natc-%s\nunreadable\n' "$m" > "$tmp/deploy/atc-bundle-hang-$m.raucb"
  refuse "a bundle whose capsule cannot be read" "cannot read tegra-bl.cap"
  printf 'ca\natc-%s\ncapsule-2\n' "$m" > "$tmp/deploy/atc-bundle-hang-$m.raucb"
  refuse "a bundle with another capsule" "another capsule"
  cp "$tmp/good" "$tmp/deploy/atc-bundle-hang-$m.raucb"

  # A deploy file replaced while the script runs. The output must hold the
  # files that were checked, never a file that replaced them after a check.
  printf 'other\natc-%s\ncapsule-1\n' "$m" > "$tmp/unsigned"
  cp "$tmp/deploy/atc-bundle-$m.raucb" "$tmp/signed"
  SWAP_FROM="$tmp/unsigned" SWAP_TO="$tmp/deploy/atc-bundle-$m.raucb" run "$tmp/out-swap" ||
    die "self-test: a run with a swapped deploy file failed: $(cat "$tmp/out.log")"
  cmp -s "$tmp/out-swap/good.raucb" "$tmp/signed" ||
    die "self-test: good.raucb is not the bundle that was checked"
  cp "$tmp/signed" "$tmp/deploy/atc-bundle-$m.raucb"
  rm -f "$tmp/deploy/atc-bundle-$m.raucb.calls"

  printf 'second' > "$tmp/archive/second.ext4"
  pack
  refuse "an archive with two ext4 members" "expected exactly one rootfs"
  rm "$tmp/archive/second.ext4"
  printf '<partition_layout>\n  <partition name="APP" type="data">\n' > "$tmp/archive/external-flash.xml.in"
  pack
  refuse "a single-APP archive" "both APP and APP_b"

  rm "$tmp/deploy/atc-bundle-panic-$m.raucb"
  refuse "a deploy without the panic bundle" "no atc-bundle-panic"
  echo "tegra-proof-artifacts --self-test: OK"
}

if [ "$SELF_TEST" = 1 ]; then
  self_test
  exit 0
fi
[ -n "$DEPLOY_DIR" ] && [ -n "$MACHINE" ] && [ -n "$CA" ] && [ -n "$OUT" ] ||
  die "usage: tegra-proof-artifacts.sh --deploy-dir <dir> --machine <m> --ca <file> --rauc <rauc> --unsquashfs <unsquashfs> --out <dir>"
collect "$DEPLOY_DIR" "$MACHINE" "$CA" "$OUT"
