#!/usr/bin/env bash
# scripts/tegra-build.sh
#
# Build a meta-atc image for a Jetson Orin MACHINE and check the tegraflash
# archive it emits: atc-image builds, and the archive's flash layout names the
# rootfs partition APP.
#
# Run this on the build host, as the build user.
#
# The script writes conf/local.conf on every run, so an edit there is lost.
# Put your own settings, for example ATC_DEPLOY_SSH_KEY, in conf/auto.conf of
# the build directory. bitbake reads it before local.conf, and this script
# never writes it.
#
# The build directory is the Tegra build's own. Its bblayers.conf names
# meta-tegra, which `checkout-layers.sh --for tegra234` checks out. The qemu
# build directories never name it, so a qemu build cannot change through it.
# The shared cache (SSTATE_DIR, DL_DIR, the hash server) comes from site.conf.
# TMPDIR is this build directory's own.
#
# Usage:
#   ./tegra-build.sh [--machine <m>] [--build-dir <path>] [<recipe>...]
#   ./tegra-build.sh --self-test
#
#   --machine <m>       a meta-tegra tegra234 machine. Default
#                       jetson-orin-nano-devkit-nvme.
#   --build-dir <path>  bitbake build directory. Default <cache>/build-tegra.
#                       The script writes its conf/ on every run.
#   <recipe>            the images to build. Default atc-image. Each one must
#                       emit <recipe>-<machine>.rootfs.tegraflash.tar.gz.
#   --self-test         check this script's logic. Needs no box.
#
# Required on the build host: poky (POKY_DIR, default <cache>/poky), the cache config
# from cache-setup.sh, and network access to atc.dev: the atcd recipe downloads
# a verified atcd with install-atcd.sh. To build in a local atcd instead, set
# ATCD_BINARY to a static aarch64 binary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CACHE_DIR="${CACHE_DIR:-/cache}"
POKY_DIR="${POKY_DIR:-$CACHE_DIR/poky}"
ATCD_BINARY="${ATCD_BINARY:-}"

MACHINE="jetson-orin-nano-devkit-nvme"
BUILD_DIR="$CACHE_DIR/build-tegra"
RECIPES=()
SELF_TEST=0

die() {
  echo "tegra-build: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --machine)
      MACHINE="${2:?--machine needs a value}"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="${2:?--build-dir needs a value}"
      shift 2
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -*) die "unknown argument: $1" ;;
    *)
      RECIPES+=("$1")
      shift
      ;;
  esac
done
[ "${#RECIPES[@]}" -gt 0 ] || RECIPES=(atc-image)

# The build directory's bblayers.conf and local.conf. Written on every run, so
# the build cannot drift from what this script states. $1 is the build dir, $2
# the newline-separated layer paths from checkout-layers.sh.
write_build_conf() {
  local build_dir="$1" layers="$2" layer_lines="" layer
  install -d "$build_dir/conf"
  while read -r layer; do
    [ -n "$layer" ] && layer_lines+="  $layer \\"$'\n'
  done <<< "$layers"
  cat > "$build_dir/conf/bblayers.conf" << EOF
# Written by meta-atc scripts/tegra-build.sh. Edits are overwritten.
POKY_BBLAYERS_CONF_VERSION = "2"
BBPATH = "\${TOPDIR}"
BBFILES ?= ""
BBLAYERS = " \\
  $POKY_DIR/meta \\
  $POKY_DIR/meta-poky \\
${layer_lines}  $LAYER_ROOT \\
  "
EOF
  cat > "$build_dir/conf/local.conf" << EOF
# Written by meta-atc scripts/tegra-build.sh. Edits are overwritten.
MACHINE = "$MACHINE"
DISTRO = "poky"
INIT_MANAGER = "systemd"
TMPDIR = "$build_dir/tmp"
CONF_VERSION = "2"
EOF
  if [ -n "$ATCD_BINARY" ]; then
    printf 'ATCD_BINARY_AARCH64 = "%s"\n' "$ATCD_BINARY" >> "$build_dir/conf/local.conf"
  fi
  ln -sfn "$CACHE_DIR/conf/site.conf" "$build_dir/conf/site.conf"
}

# The image must carry atcd. The recipe checks the ELF machine; this checks
# that there is a file to check.
#
# It prints the binary's sha256 and what `file` says about it, so the build log
# names the atcd the image carries. The recipe refuses an ELF of another
# machine, but only after bitbake has parsed and fetched.
require_atcd() {
  if [ -z "$ATCD_BINARY" ]; then
    echo "atcd: the recipe downloads a verified release with install-atcd.sh"
    return 0
  fi
  [ -f "$ATCD_BINARY" ] || die "no atcd at ATCD_BINARY=$ATCD_BINARY. Copy a
  static aarch64 atcd to the build host, or set ATCD_BINARY."
  echo "atcd: $(sha256sum "$ATCD_BINARY")"
  if command -v file > /dev/null; then
    echo "atcd: $(file -b "$ATCD_BINARY")"
  else
    echo "atcd: 'file' is not installed, so the ELF type is not printed here"
  fi
}

# check_image reads the built ext4 with debugfs. Check for it before the
# layers and bitbake, not after an hour of build.
require_debugfs() {
  command -v debugfs > /dev/null || die "debugfs is not installed, so the built image cannot be read"
}

# Check one line of `debugfs -R "stat <path>"` output on stdin: the inode has
# type $1 and mode $2, as debugfs prints them. $3 names the path for the error.
check_stat() {
  local want_type="$1" want_mode="$2" path="$3" line
  line="$(sed -n 's/^Inode: [0-9]* *Type: \([a-z]*\) *Mode: *\([0-7]*\) .*/\1 \2/p')"
  [ "$line" = "$want_type $want_mode" ] ||
    die "$path in the image is '${line:-absent}', not '$want_type $want_mode'"
}

# The files an extlinux.conf on stdin boots: the path after each LINUX, FDT and
# INITRD keyword, one per line. L4TLauncher reads them from the rootfs, so a
# missing one is a board that cannot boot. Exits 1 when no LINUX line exists.
extlinux_files() {
  local files
  files="$(sed -n 's/^[[:space:]]*\(LINUX\|FDT\|INITRD\)[[:space:]]\{1,\}\([^[:space:]]*\).*/\1 \2/p')"
  grep -q '^LINUX ' <<< "$files" || return 1
  printf '%s\n' "$files" | cut -d' ' -f2
}

# Check the rootfs inside the image. The kernel and every other file that
# /boot/extlinux/extlinux.conf names exist, atcd is installed, and /var/tmp is
# a 1777 directory on disk. debugfs reads the ext4 without mounting it. $1 is
# the ext4 image.
check_image() {
  local image="$1" conf files file
  conf="$(debugfs -R "cat /boot/extlinux/extlinux.conf" "$image" 2> /dev/null)"
  files="$(extlinux_files <<< "$conf")" ||
    die "/boot/extlinux/extlinux.conf in $image names no kernel, so L4TLauncher boots nothing"
  for file in $files; do
    debugfs -R "stat $file" "$image" 2> /dev/null | check_stat regular 0644 "$file"
  done
  debugfs -R "stat /usr/bin/atcd" "$image" 2> /dev/null | check_stat regular 0755 /usr/bin/atcd
  debugfs -R "stat /var/tmp" "$image" 2> /dev/null | check_stat directory 01777 /var/tmp
  echo "ok: $image boots $(tr '\n' ' ' <<< "$files")and carries /usr/bin/atcd, and /var/tmp is a 1777 directory"
}

# Check one tegraflash archive: it exists, and one flash layout names both
# rootfs partitions of the redundant layout, APP and APP_b (conf/layer.conf). A machine that boots from NVMe carries the rootfs in
# external-flash.xml.in, and flash.xml.in describes the QSPI only. $1 is the
# archive.
check_archive() {
  local archive="$1" redundant="$2" listing layout_file layout want
  if [ "$redundant" = 1 ]; then want="APP and APP_b"; else want="APP"; fi
  [ -f "$archive" ] || die "no tegraflash archive at $archive"
  listing="$(tar -tzf "$archive")" || die "$archive is not a readable tar.gz"
  for layout_file in external-flash.xml.in flash.xml.in; do
    grep -qx "$layout_file" <<< "$listing" || continue
    layout="$(tar -xzOf "$archive" "$layout_file")"
    grep -qE '<partition [^>]*name="APP"' <<< "$layout" || continue
    if [ "$redundant" != 1 ] || grep -qE '<partition [^>]*name="APP_b"' <<< "$layout"; then
      echo "ok: $archive, $(wc -c < "$archive") bytes, $layout_file names $want"
      return 0
    fi
  done
  die "no flash layout in $archive names $want"
}

# ── Self-test ────────────────────────────────────────────────────────────────

self_test() {
  local tmp conf out
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  (POKY_DIR=/p LAYER_ROOT=/r/meta-atc CACHE_DIR=/c MACHINE=jetson-agx-orin-devkit ATCD_BINARY=/a \
    write_build_conf "$tmp/build" "/c/layers/meta-rauc"$'\n'"/c/layers/meta-tegra")
  conf="$tmp/build/conf"
  grep -qx 'MACHINE = "jetson-agx-orin-devkit"' "$conf/local.conf" || die "self-test: MACHINE"
  grep -qx "TMPDIR = \"$tmp/build/tmp\"" "$conf/local.conf" || die "self-test: TMPDIR is shared"
  grep -qx 'INIT_MANAGER = "systemd"' "$conf/local.conf" || die "self-test: no systemd"
  grep -qx 'ATCD_BINARY_AARCH64 = "/a"' "$conf/local.conf" || die "self-test: no atcd binary"
  (POKY_DIR=/p LAYER_ROOT=/r/meta-atc CACHE_DIR=/c MACHINE=jetson-agx-orin-devkit ATCD_BINARY="" \
    write_build_conf "$tmp/build2" "/c/layers/meta-tegra")
  if grep -q '^ATCD_BINARY' "$tmp/build2/conf/local.conf"; then
    die "self-test: an empty ATCD_BINARY reached local.conf, so the recipe would not download atcd"
  fi
  (ATCD_BINARY="" require_atcd) > /dev/null || die "self-test: require_atcd refused the download case"
  if (ATCD_BINARY="$tmp/absent" require_atcd) > /dev/null 2>&1; then
    die "self-test: a missing atcd binary was accepted"
  fi
  printf 'not an elf\n' > "$tmp/atcd"
  out="$(ATCD_BINARY="$tmp/atcd" require_atcd)" || die "self-test: a present atcd binary was refused"
  grep -qxF "atcd: $(sha256sum "$tmp/atcd")" <<< "$out" ||
    die "self-test: require_atcd did not print the binary's sha256: $out"
  [ "$(grep -c '^atcd: ' <<< "$out")" = 2 ] ||
    die "self-test: require_atcd did not print what file says: $out"
  grep -qxF "  /c/layers/meta-tegra \\" "$conf/bblayers.conf" || die "self-test: no meta-tegra layer"
  grep -qxF "  /r/meta-atc \\" "$conf/bblayers.conf" || die "self-test: no meta-atc layer"
  [ "$(readlink "$conf/site.conf")" = /c/conf/site.conf ] || die "self-test: no site.conf link"

  mkdir -p "$tmp/good" "$tmp/bad"
  printf '<partition_layout>\n  <partition name="APP" type="data">\n  <partition name="APP_b" type="data">\n' > "$tmp/good/flash.xml.in"
  printf '<partition_layout>\n  <partition name="UDA" type="data">\n' > "$tmp/bad/flash.xml.in"
  tar -czf "$tmp/good.tar.gz" -C "$tmp/good" flash.xml.in
  tar -czf "$tmp/bad.tar.gz" -C "$tmp/bad" flash.xml.in
  # The NVMe shape: the QSPI layout without APP, the external one with it.
  mkdir -p "$tmp/nvme"
  printf '<partition_layout>\n  <partition name="A_mb1" type="data">\n' > "$tmp/nvme/flash.xml.in"
  printf '<partition_layout>\n  <partition name="APP" type="data">\n  <partition name="APP_b" type="data">\n' > "$tmp/nvme/external-flash.xml.in"
  tar -czf "$tmp/nvme.tar.gz" -C "$tmp/nvme" flash.xml.in external-flash.xml.in
  check_archive "$tmp/nvme.tar.gz" 1 > /dev/null || die "self-test: an NVMe archive was refused"
  # The single-APP layout passes only the opt-out build
  # (ATC_TEGRA_REDUNDANT = "0", which sets USE_REDUNDANT_FLASH_LAYOUT to 0).
  mkdir -p "$tmp/single"
  printf '<partition_layout>\n  <partition name="APP" type="data">\n' > "$tmp/single/external-flash.xml.in"
  tar -czf "$tmp/single.tar.gz" -C "$tmp/single" external-flash.xml.in
  tar -czf "$tmp/none.tar.gz" -C "$tmp" good
  check_archive "$tmp/good.tar.gz" 1 > /dev/null || die "self-test: a good archive was refused"
  (check_archive "$tmp/single.tar.gz" 0) > /dev/null 2>&1 || die "self-test: the opt-out refused a single-APP archive"
  if (check_archive "$tmp/bad.tar.gz" 0) > /dev/null 2>&1; then
    die "self-test: the opt-out accepted an archive with no APP"
  fi
  local name
  for name in bad single none absent; do
    if (check_archive "$tmp/$name.tar.gz" 1) > /dev/null 2>&1; then
      die "self-test: the archive '$name' was accepted"
    fi
  done

  # The debugfs stat parser, on the lines debugfs 1.46 prints.
  printf 'Inode: 304   Type: regular    Mode:  0755   Flags: 0x80000\n' |
    check_stat regular 0755 atcd || die "self-test: a good atcd stat was refused"
  printf 'Inode: 4877   Type: directory    Mode:  01777   Flags: 0x80000\n' |
    check_stat directory 01777 /var/tmp || die "self-test: a good /var/tmp stat was refused"
  local bad
  for bad in 'Inode: 12   Type: symlink    Mode:  0777   Flags: 0x0' \
    'Inode: 12   Type: directory    Mode:  0755   Flags: 0x80000' \
    '/var/tmp: File not found by ext2_lookup'; do
    if (printf '%s\n' "$bad" | check_stat directory 01777 /var/tmp) > /dev/null 2>&1; then
      die "self-test: the stat line '$bad' was accepted for /var/tmp"
    fi
  done

  # The extlinux.conf parser, on the file OE4T writes.
  out="$(
    extlinux_files << 'EOF'
# L4TLauncher configuration file generated by OE4T
DEFAULT primary
LABEL primary
	MENU LABEL primary
	LINUX /boot/Image
	INITRD /boot/initrd
	APPEND ${cbootargs} console=ttyTCU0,115200 panic=5
EOF
  )" || die "self-test: an extlinux.conf with a kernel was refused"
  [ "$out" = "/boot/Image"$'\n'"/boot/initrd" ] || die "self-test: extlinux_files printed '$out'"
  if printf 'DEFAULT primary\nLABEL primary\n\tAPPEND quiet\n' | extlinux_files > /dev/null; then
    die "self-test: an extlinux.conf with no LINUX line was accepted"
  fi
  if extlinux_files < /dev/null > /dev/null; then
    die "self-test: an empty extlinux.conf was accepted"
  fi

  # The layer list comes from the scoped pin: a tegra234 build gets meta-tegra.
  grep -qE '^meta-tegra [^ ]+ [^ ]+ [0-9a-f]{40} tegra234$' "$LAYER_ROOT/conf/layers.pin" ||
    die "self-test: layers.pin pins no meta-tegra for tegra234"
  echo "tegra-build --self-test: OK"
}

if [ "$SELF_TEST" = 1 ]; then
  self_test
  exit 0
fi

# ── The build ────────────────────────────────────────────────────────────────

[ -f "$POKY_DIR/oe-init-build-env" ] || die "no poky at $POKY_DIR; set POKY_DIR"
require_atcd
require_debugfs
layers="$("$SCRIPT_DIR/checkout-layers.sh" --for tegra234)"
write_build_conf "$BUILD_DIR" "$layers"

# oe-init-build-env reads unset variables and changes the directory.
set +u
# shellcheck disable=SC1091  # poky's, on the build host
source "$POKY_DIR/oe-init-build-env" "$BUILD_DIR" > /dev/null
set -u

# The machine bitbake actually builds, read back. A MACHINE that is not a
# tegra234 machine would build an image this check cannot judge.
machine_built="$(bitbake-getvar --value MACHINE)"
[ "$machine_built" = "$MACHINE" ] || die "bitbake builds MACHINE=$machine_built, not $MACHINE"
case ":$(bitbake-getvar --value MACHINEOVERRIDES):" in
  *:tegra234:*) ;;
  *) die "$MACHINE is not a tegra234 machine" ;;
esac
# The slot backend seam, read back from a recipe that inherits it. atc-os
# parses with no RAUC keyring, unlike the A/B images.
case ":$(bitbake-getvar -r atc-os --value OVERRIDES):" in
  *:atc-slot-nvbootctrl:*) ;;
  *) die "atc-os does not carry the atc-slot-nvbootctrl override on $MACHINE" ;;
esac
# A panic must reboot, so the launcher counts it against the slot.
case " $(bitbake-getvar -r l4t-launcher-extlinux --value UBOOT_EXTLINUX_KERNEL_ARGS) " in
  *" panic=5 "*) ;;
  *) die "the extlinux.conf command line carries no panic=5" ;;
esac

echo "=== bitbake ${RECIPES[*]} for $MACHINE"
bitbake "${RECIPES[@]}"

deploy="$(bitbake-getvar --value DEPLOY_DIR_IMAGE)"
# APP_b is required only of the redundant layout; ATC_TEGRA_REDUNDANT = "0"
# builds the single-APP one.
redundant="$(bitbake-getvar --value USE_REDUNDANT_FLASH_LAYOUT)"
for recipe in "${RECIPES[@]}"; do
  # IMAGE_LINK_NAME, read back: scarthgap names it <recipe>-<machine>.rootfs.
  link="$(bitbake-getvar -r "$recipe" --value IMAGE_LINK_NAME)"
  check_archive "$deploy/$link.tegraflash.tar.gz" "$redundant"
  check_image "$deploy/$link.ext4"
done
