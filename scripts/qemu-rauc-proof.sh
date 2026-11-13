#!/usr/bin/env bash
# scripts/qemu-rauc-proof.sh
#
# The RAUC OS update, proved on qemu. Build atc-image-ab and a signed
# verity bundle. Boot the disk through OVMF and GRUB, and install the bundle
# into the other slot with RAUC. Reboot, check that the other slot booted, and
# check that RAUC marks it good. Then reboot twice more. The first reboot after
# the mark confirms the slot, and the second boots it as the steady slot.
#
# Run this ON THE BUILDER BOX, as the build user.
#
# THE DISCRIMINATING CHECKS. Only grub.cfg writes `rauc.slot=` on the kernel
# command line, and only the bundle's slot image carries /etc/atc-os-version.
# So /proc/cmdline proves GRUB chose the slot, and the version file proves RAUC
# wrote it. A guest that booted with -kernel, or that booted slot A again, fails
# one of the two.
#
# THE D-BUS POLICY. The run calls RAUC as user atc-deploy and expects
# AccessDenied, then as user atc and expects a reply. The second call is the
# control: without it, a RAUC that is down would pass the first.
#
# Usage:
#   ./qemu-rauc-proof.sh [--build-dir <path>] [--work-dir <path>]
#                        [--os-version <v>] [--accel kvm|tcg]
#                        [--skip-build] [--no-boot]
#   ./qemu-rauc-proof.sh --self-test
#
#   --build-dir <path>  bitbake build directory. Default <cache>/build-rauc.
#                       The script writes its conf/ on every run.
#   --work-dir <path>   where the guest's disk copy and serial log go.
#                       Default <cache>/rauc-proof/<timestamp>.
#   --os-version <v>    ATC_OS_VERSION of the bundle. Default rauc-proof-1.
#                       The run first builds a bundle of <v>-prev, then one
#                       of <v>, and installs the second.
#   --accel kvm|tcg     qemu accelerator. Default kvm when /dev/kvm is usable.
#                       tcg multiplies every guest timeout by TCG_FACTOR.
#   --skip-build        boot artifacts that are already built. The check
#                       that two versions give two slot images then does
#                       not run, and the run says so.
#   --no-boot           build and assert only.
#   --self-test         check this script's logic. Needs no box.
#
# Required on the box: poky (POKY_DIR, default <cache>/poky), the cache config
# from cache-setup.sh, a running yocto-hashserv, a prebuilt atcd for x86-64
# (ATCD_BINARY, default <cache>/atcd-x86_64), and the RAUC test keys in KEY_DIR
# (default <cache>/atc-rauc-keys). check_keys below names each key file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CACHE_DIR="${CACHE_DIR:-/cache}"
POKY_DIR="${POKY_DIR:-$CACHE_DIR/poky}"
ATCD_BINARY="${ATCD_BINARY:-$CACHE_DIR/atcd-x86_64}"
KEY_DIR="${KEY_DIR:-$CACHE_DIR/atc-rauc-keys}"

BUILD_DIR="$CACHE_DIR/build-rauc"
WORK_DIR=""
OS_VERSION="rauc-proof-1"
PREV_VERSION=""
TWO_VERSIONS=""
ACCEL=""
SKIP_BUILD=0
NO_BOOT=0
SELF_TEST=0

MACHINE="qemux86-64"
IMAGE_RECIPE="atc-image-ab"
BUNDLE_RECIPE="atc-bundle"
COMPATIBLE="atc-qemux86-64"

# Guest timeouts in seconds, for KVM. TCG on the arm64 builder emulates every
# x86 instruction, so each timeout is multiplied by TCG_FACTOR there.
# shellcheck disable=SC2034 # lib/qemu-guest.sh reads it
BOOT_TIMEOUT=300
INSTALL_TIMEOUT=600
# shellcheck disable=SC2034 # lib/qemu-guest.sh reads it
COMMAND_TIMEOUT=60
TCG_FACTOR="${TCG_FACTOR:-6}"

ENVBLK_SIZE=1024

die() {
  echo "qemu-rauc-proof: $*" >&2
  exit 1
}

# The guest driver: boot, serial console, guest commands, assertions.
# The hooks run shellcheck without -x, so it cannot follow this file.
# QEMU_GUEST_LIB names another copy of the lib, for a test.
# shellcheck disable=SC1090,SC1091
source "${QEMU_GUEST_LIB:-$SCRIPT_DIR/lib/qemu-guest.sh}"

step() {
  echo
  echo "=== $* ==="
}

# ── Argument parsing ─────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir)
      BUILD_DIR="${2:?--build-dir needs a value}"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="${2:?--work-dir needs a value}"
      shift 2
      ;;
    --os-version)
      OS_VERSION="${2:?--os-version needs a value}"
      shift 2
      ;;
    --accel)
      ACCEL="${2:?--accel needs a value}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --no-boot)
      NO_BOOT=1
      shift
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# ── Pure helpers (the self-test drives these) ────────────────────────────────

# The build directory's bblayers.conf and local.conf. Written on every run, so
# the build cannot drift from what this script states. $1 is the build dir, $2
# the newline-separated layer paths from checkout-layers.sh.
write_build_conf() {
  local build_dir="$1" layers="$2" layer_lines=""
  install -d "$build_dir/conf"
  while read -r layer; do
    [ -n "$layer" ] && layer_lines+="  $layer \\"$'\n'
  done <<< "$layers"
  cat > "$build_dir/conf/bblayers.conf" << EOF
# Written by meta-atc scripts/qemu-rauc-proof.sh. Edits are overwritten.
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
# Written by meta-atc scripts/qemu-rauc-proof.sh. Edits are overwritten.
#
# The shared cache (SSTATE_DIR, DL_DIR, the hash server) comes from site.conf.
# TMPDIR is this build's own. The RAUC distro feature changes the signature of
# every target recipe. A shared TMPDIR would mix two images in one deploy
# directory.
MACHINE = "$MACHINE"
DISTRO = "poky"
INIT_MANAGER = "systemd"
DISTRO_FEATURES:append = " rauc"
EXTRA_IMAGE_FEATURES = "debug-tweaks"
TMPDIR = "$CACHE_DIR/tmp-rauc"
CONF_VERSION = "2"
ATCD_BINARY = "$ATCD_BINARY"
ATC_OS_VERSION = "$OS_VERSION"
RAUC_KEYRING_FILE = "$KEY_DIR/ca.cert.pem"
RAUC_KEY_FILE = "$KEY_DIR/signing.key.pem"
RAUC_CERT_FILE = "$KEY_DIR/signing.cert.pem"
# The fault suite's bad-signature bundle, signed under a CA the image does not
# trust. Only the recipes under recipes-test/ read these.
ATC_RAUC_UNTRUSTED_KEY_FILE = "$KEY_DIR/other-signing.key.pem"
ATC_RAUC_UNTRUSTED_CERT_FILE = "$KEY_DIR/other-signing.cert.pem"
EOF
  ln -sfn "$CACHE_DIR/conf/site.conf" "$build_dir/conf/site.conf"
}

# Assert a GRUB environment block: exactly ENVBLK_SIZE bytes, the header, and
# each expected `name=value` line. $1 is the file, the rest the lines.
check_envblk() {
  local file="$1" size line
  shift
  size="$(wc -c < "$file")"
  [ "$size" -eq "$ENVBLK_SIZE" ] || {
    echo "FAIL: $file is $size bytes, not $ENVBLK_SIZE" >&2
    return 1
  }
  grep -qx '# GRUB Environment Block' < <(sed -n 1p "$file") || {
    echo "FAIL: $file has no GRUB environment header" >&2
    return 1
  }
  for line in "$@"; do
    grep -qxF -- "$line" "$file" || {
      echo "FAIL: $file does not hold '$line'" >&2
      return 1
    }
  done
}

# Two bundles built with two ATC_OS_VERSION values must carry two different
# slot images. $1 and $2 are `rauc info --output-format=shell` texts, $3 and $4
# the versions they must name. A build that hashed no version into the image
# reuses the stamped one, and both manifests then name one image digest.
# RAUC numbers the images of a manifest from 0.
check_two_versions() {
  local first="$1" second="$2" v1="$3" v2="$4" d1 d2
  [ "$(shell_value RAUC_MF_VERSION <<< "$first")" = "$v1" ] || {
    echo "FAIL: the first bundle does not name version $v1" >&2
    return 1
  }
  [ "$(shell_value RAUC_MF_VERSION <<< "$second")" = "$v2" ] || {
    echo "FAIL: the second bundle does not name version $v2" >&2
    return 1
  }
  d1="$(shell_value RAUC_IMAGE_DIGEST_0 <<< "$first")"
  d2="$(shell_value RAUC_IMAGE_DIGEST_0 <<< "$second")"
  [ -n "$d1" ] && [ -n "$d2" ] || {
    echo "FAIL: a bundle manifest names no slot image digest" >&2
    return 1
  }
  if [ "$d1" = "$d2" ]; then
    echo "FAIL: versions $v1 and $v2 carry one slot image, sha256 $d1" >&2
    return 1
  fi
  echo "ok: slot image of $v1: sha256 $d1"
  echo "ok: slot image of $v2: sha256 $d2"
}

# ── The proof sequence ───────────────────────────────────────────────────────

prove_dbus_policy() {
  step "the D-Bus policy"
  if guest_run "su -s /bin/sh atc-deploy -c 'rauc status'"; then
    die "user atc-deploy could call RAUC. The policy allows more than root and atc."
  fi
  expect_out 'AccessDenied|not allowed|Rejected send message'
  echo "ok: RAUC refuses user atc-deploy"
  must "su -s /bin/sh atc -c 'rauc status --output-format=shell'"
  expect_out "^RAUC_SYSTEM_COMPATIBLE='?$COMPATIBLE'?\$"
  echo "ok: RAUC answers user atc"
}

prove_factory_boot() {
  step "boot 1: the factory disk, slot A"
  expect_slot A atcroota
  must "test ! -e /etc/atc-os-version"
  read_grubenv
  expect_out '^ATC_STEADY=A$'
  expect_out '^ATC_TRIAL=none$'
  # rauc.service is D-Bus activated, so it is not checked here: the first
  # `rauc` call below starts it.
  must "systemctl is-active atc-os-trial-deadline.timer atc-os-reboot.path"
  # meta-rauc's mark-good unit would confirm every trial that reaches
  # userspace. rauc_%.bbappend drops it.
  must "test ! -e /usr/lib/systemd/system/rauc-mark-good.service"
  # The runtime profile's watchdog: the driver is built in, and systemd feeds
  # it every 15 seconds.
  # systemd logs the device it opened to the kernel log, before journald runs.
  # The kernel has no watchdog sysfs attributes, so that line is the evidence
  # that the device is armed.
  must "systemctl show -p RuntimeWatchdogUSec && dmesg | grep -m1 'hardware watchdog'"
  expect_out '^RuntimeWatchdogUSec=30s$'
  expect_out '[Uu]sing hardware watchdog .*i6300ESB'
  echo "ok: systemd feeds the i6300esb watchdog"
  prove_dbus_policy
}

# Stand-ins for the device-local state `atc bootstrap` writes, so the
# post-install hook has something to carry: the unit, a drop-in, the CA bundle
# and the enrollment token.
plant_device_state() {
  must "printf '[Unit]\\nDescription=proof stand-in\\n[Service]\\nType=oneshot\\nExecStart=/bin/true\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/atcd.service && systemctl enable atcd.service"
  must "mkdir -p /etc/atc /etc/systemd/system/atcd.service.d && echo proof-ca > /etc/atc/ca.pem && echo proof-token > /etc/atc/enroll.token && printf '[Service]\\nEnvironment=PROOF=1\\n' > /etc/systemd/system/atcd.service.d/10-proof.conf"
}

prove_install() {
  local size="$1" sum="$2"
  step "install the bundle into slot B"
  plant_device_state
  must "head -c $size /dev/disk/by-id/virtio-proof > /var/atc/proof.raucb && sha256sum /var/atc/proof.raucb"
  expect_out "^$sum "
  # As user atc, which is how atcd calls RAUC. A policy that let only root
  # through would fail here.
  must "su -s /bin/sh atc -c 'rauc install /var/atc/proof.raucb'" "$(scaled "$INSTALL_TIMEOUT" "$ACCEL")"
  must "rauc status --output-format=shell"
  [ "$(shell_value RAUC_BOOT_PRIMARY <<< "$GUEST_OUT")" = "rootfs.1" ] ||
    die "RAUC did not make rootfs.1 primary"
  read_grubenv
  expect_out '^ORDER=B A$'
  expect_out '^B_OK=1$'
  expect_out '^B_TRY=0$'
  echo "ok: RAUC wrote slot B and put it first in ORDER"
}

prove_trial_boot() {
  step "boot 2: the trial of slot B"
  expect_slot B atcrootb
  must "cat /etc/atc-os-version"
  expect_out "^$OS_VERSION\$"
  echo "ok: slot B holds the bundle's OS version $OS_VERSION"
  read_grubenv
  expect_out '^ATC_TRIAL=B$'
  expect_out '^B_TRY=1$'
  expect_out '^ATC_STEADY=A$'
  expect_booted_status bad
  # A second install during the trial would overwrite slot A, the only revert
  # target. The pre-install handler in system.conf refuses it.
  if guest_run "su -s /bin/sh atc -c 'rauc install /var/atc/proof.raucb'" "$(scaled "$INSTALL_TIMEOUT" "$ACCEL")"; then
    die "RAUC installed a bundle during an unconfirmed trial"
  fi
  expect_out '[Pp]re-install handler|on trial and not marked good'
  echo "ok: the pre-install handler refuses an install during the trial"
  must "test -f /etc/systemd/system/atcd.service && test -L /etc/systemd/system/multi-user.target.wants/atcd.service && test -f /etc/systemd/system/atcd.service.d/10-proof.conf && cat /etc/atc/ca.pem /etc/atc/enroll.token"
  expect_out '^proof-ca$'
  expect_out '^proof-token$'
  echo "ok: the post-install hook carried /etc/atc, the atcd unit and its drop-in into slot B"
  must "su -s /bin/sh atc -c 'rauc status mark-good booted'"
  expect_booted_status good
  echo "PASS: slot B booted, and RAUC marks it good"
}

prove_confirmed_boot() {
  step "boot 3: the first boot after the mark confirms slot B"
  expect_slot B atcrootb
  read_grubenv
  expect_out '^ATC_STEADY=B$'
  expect_out '^ATC_TRIAL=none$'
  expect_out '^B_TRY=0$'
  expect_booted_status good
}

prove_steady_boot() {
  step "boot 4: slot B is the steady slot"
  expect_slot B atcrootb
  read_grubenv
  expect_out '^ATC_STEADY=B$'
  expect_out '^ATC_TRIAL=none$'
  expect_booted_status good
  echo "ok: the two-reboot happy case holds"
}

run_guest_proof() {
  local disk="$WORK_DIR/disk.wic" vars="$WORK_DIR/ovmf.vars.qcow2" size sum
  step "boot under qemu, accel=$ACCEL"
  cp --sparse=always "$WIC_IMAGE" "$disk"
  cp "$DEPLOY_DIR/ovmf.vars.qcow2" "$vars"
  size="$(stat -Lc %s "$BUNDLE")"
  sum="$(sha256sum "$BUNDLE" | cut -d' ' -f1)"
  # The trap goes first, so a die inside guest_start stops qemu too.
  trap guest_stop EXIT
  guest_start "$disk" "$DEPLOY_DIR/ovmf.code.qcow2" "$vars" "proof=$BUNDLE"
  guest_login 0 || die "no login prompt on the first boot"
  prove_factory_boot
  prove_install "$size" "$sum"
  guest_reboot
  prove_trial_boot
  guest_reboot
  prove_confirmed_boot
  guest_reboot
  prove_steady_boot
  guest_poweroff
  echo
  if [ -n "$TWO_VERSIONS" ]; then
    echo "qemu-rauc-proof: PASS ($TWO_VERSIONS). Serial log: $GUEST_LOG"
  else
    echo "qemu-rauc-proof: PASS. Serial log: $GUEST_LOG"
  fi
}

# ── The build and the artifact assertions ────────────────────────────────────

bb_recipe_value() {
  bitbake-getvar --value -r "$1" "$2" 2> /dev/null || true
}

resolve_artifacts() {
  local link_name native
  DEPLOY_DIR="$(bb_recipe_value "$IMAGE_RECIPE" DEPLOY_DIR_IMAGE)"
  [ -d "$DEPLOY_DIR" ] || die "DEPLOY_DIR_IMAGE '$DEPLOY_DIR' does not exist"
  link_name="$(bb_recipe_value "$IMAGE_RECIPE" IMAGE_LINK_NAME)"
  WIC_IMAGE="$DEPLOY_DIR/$link_name.wic"
  QEMUBOOT_CONF="$DEPLOY_DIR/$link_name.qemuboot.conf"
  BUNDLE="$DEPLOY_DIR/$BUNDLE_RECIPE-$MACHINE.raucb"
  native="$(sed -n 's/^staging_bindir_native = //p' "$QEMUBOOT_CONF")"
  QEMU="${native%/}/qemu-system-x86_64"
  WIC_NATIVE="$(bb_recipe_value "$IMAGE_RECIPE" STAGING_DIR_NATIVE)"
  RAUC_NATIVE="$(bb_recipe_value "$BUNDLE_RECIPE" STAGING_BINDIR_NATIVE)/rauc"
  local f
  for f in "$WIC_IMAGE" "$QEMUBOOT_CONF" "$BUNDLE" "$QEMU" "$RAUC_NATIVE" \
    "$DEPLOY_DIR/ovmf.code.qcow2" "$DEPLOY_DIR/ovmf.vars.qcow2"; do
    [ -e "$f" ] || die "missing build output: $f"
  done
}

assert_artifacts() {
  local tmp="$WORK_DIR/esp" info
  mkdir -p "$tmp"
  grep -qE '^qb_default_kernel *= *none$' "$QEMUBOOT_CONF" ||
    die "$QEMUBOOT_CONF does not set qb_default_kernel = none"
  wic cp "$WIC_IMAGE:1/EFI/BOOT/grub.cfg" "$tmp/grub.cfg" -n "$WIC_NATIVE" > /dev/null ||
    die "could not read EFI/BOOT/grub.cfg out of $WIC_IMAGE"
  grep -q 'GRUB A/B slot selection for atc' < <(sed -n 1p "$tmp/grub.cfg") ||
    die "the ESP holds a grub.cfg this layer did not write"
  wic cp "$WIC_IMAGE:1/atc/grubenv" "$tmp/grubenv" -n "$WIC_NATIVE" > /dev/null ||
    die "the ESP has no atc/grubenv"
  check_envblk "$tmp/grubenv" "ORDER=A B" "A_OK=1" "A_TRY=0" "B_OK=0" "B_TRY=0" \
    "ATC_STEADY=A" "ATC_TRIAL=none" || die "the initial boot environment is wrong"
  echo "ok: the ESP carries this layer's grub.cfg and the initial grubenv"
  info="$("$RAUC_NATIVE" info --keyring "$KEY_DIR/ca.cert.pem" "$BUNDLE" 2>&1)" ||
    die "rauc info refused the bundle: $info"
  grep -q "Compatible:.*'$COMPATIBLE'" <<< "$info" || die "the bundle is not '$COMPATIBLE': $info"
  grep -q "Bundle Format:.*verity" <<< "$info" || die "the bundle is not verity: $info"
  grep -q "Version:.*'$OS_VERSION'" <<< "$info" || die "the bundle is not version '$OS_VERSION': $info"
  echo "ok: the bundle is verity, '$COMPATIBLE', '$OS_VERSION', and signed under $KEY_DIR/ca.cert.pem"
  # A prev.raucb that this run did not build is stale. Never compare with it.
  if [ "$SKIP_BUILD" -eq 1 ] || [ ! -f "$WORK_DIR/prev.raucb" ]; then
    echo "NOT PROVEN: --skip-build, so no second version was built to compare"
    TWO_VERSIONS="two-version check not run"
    return 0
  fi
  check_two_versions \
    "$("$RAUC_NATIVE" info --keyring "$KEY_DIR/ca.cert.pem" --output-format=shell "$WORK_DIR/prev.raucb" 2> /dev/null)" \
    "$("$RAUC_NATIVE" info --keyring "$KEY_DIR/ca.cert.pem" --output-format=shell "$BUNDLE" 2> /dev/null)" \
    "$PREV_VERSION" "$OS_VERSION" || die "two versions did not give two slot images"
}

# The keys are an input, like ATCD_BINARY. A test CA and two signing pairs
# signed by it are enough.
check_keys() {
  local k
  for k in ca.cert.pem signing.key.pem signing.cert.pem other-signing.key.pem other-signing.cert.pem; do
    [ -f "$1/$k" ] || die "no $1/$k. Make a test CA and two signing pairs in $1 first"
  done
}

build() {
  local layers
  step "layers, keys and the build directory"
  layers="$("$SCRIPT_DIR/checkout-layers.sh")"
  check_keys "$KEY_DIR"
  [ -f "$ATCD_BINARY" ] || die "no atcd at ATCD_BINARY=$ATCD_BINARY"
  write_build_conf "$BUILD_DIR" "$layers"
  [ -d "$POKY_DIR" ] || die "no poky checkout at $POKY_DIR"
  set +u
  # shellcheck disable=SC1091
  source "$POKY_DIR/oe-init-build-env" "$BUILD_DIR" > /dev/null
  set -u
  # The slot backend seam, read back from bitbake. An override that resolved to
  # anything but atc-slot-grub would drop every GRUB line of the image, and the
  # disk would boot no bootloader.
  case ":$(bb_recipe_value "$IMAGE_RECIPE" OVERRIDES):" in
    *:atc-slot-grub:*) ;;
    *) die "$IMAGE_RECIPE does not carry the atc-slot-grub override" ;;
  esac
  [ "$(bb_recipe_value "$IMAGE_RECIPE" WKS_FILE)" = atc-ab.wks.in ] ||
    die "$IMAGE_RECIPE does not build atc-ab.wks.in"
  if [ "$SKIP_BUILD" -eq 0 ]; then
    # First a bundle of the previous version, kept aside, then the one this
    # run installs. assert_artifacts compares their slot images.
    step "bitbake $BUNDLE_RECIPE, version $PREV_VERSION"
    OS_VERSION="$PREV_VERSION" write_build_conf "$BUILD_DIR" "$layers"
    bitbake "$BUNDLE_RECIPE"
    cp -L "$(bb_recipe_value "$BUNDLE_RECIPE" DEPLOY_DIR_IMAGE)/$BUNDLE_RECIPE-$MACHINE.raucb" \
      "$WORK_DIR/prev.raucb"
    write_build_conf "$BUILD_DIR" "$layers"
    step "bitbake $IMAGE_RECIPE $BUNDLE_RECIPE ovmf, version $OS_VERSION"
    bitbake "$IMAGE_RECIPE" "$BUNDLE_RECIPE" ovmf
  fi
}

# ── Self-test ────────────────────────────────────────────────────────────────

# The lib's self-test covers the guest helpers. This adds the two-version
# check, which only the proof uses.
self_test_helpers() {
  local tmp="$1"
  qemu_guest_self_test "$tmp"
  local one two
  one="$(printf '%s\n' "RAUC_MF_VERSION='v-prev'" "RAUC_IMAGE_DIGEST_0='aaa'")"
  two="$(printf '%s\n' "RAUC_MF_VERSION='v'" "RAUC_IMAGE_DIGEST_0='bbb'")"
  check_two_versions "$one" "$two" v-prev v > /dev/null || die "self-test: two images failed"
  two="$(printf '%s\n' "RAUC_MF_VERSION='v'" "RAUC_IMAGE_DIGEST_0='aaa'")"
  (check_two_versions "$one" "$two" v-prev v) > /dev/null 2>&1 &&
    die "self-test: one image under two versions passed"
  (check_two_versions "$one" "$one" v-prev v) > /dev/null 2>&1 &&
    die "self-test: a bundle with the wrong version passed"
  (check_two_versions "RAUC_MF_VERSION='v-prev'" "RAUC_MF_VERSION='v'" v-prev v) > /dev/null 2>&1 &&
    die "self-test: manifests with no digest passed"
  return 0
}

self_test_envblk() {
  local tmp="$1" pad
  printf '%s\n' '# GRUB Environment Block' 'ORDER=A B' 'ATC_TRIAL=none' > "$tmp/env"
  pad=$((ENVBLK_SIZE - $(wc -c < "$tmp/env")))
  head -c "$pad" /dev/zero | tr '\0' '#' >> "$tmp/env"
  check_envblk "$tmp/env" 'ORDER=A B' 'ATC_TRIAL=none' || die "self-test: a good block failed"
  (check_envblk "$tmp/env" 'ATC_TRIAL=B') 2> /dev/null && die "self-test: a wrong value passed"
  printf 'x' >> "$tmp/env"
  (check_envblk "$tmp/env" 'ORDER=A B') 2> /dev/null && die "self-test: a wrong size passed"
  return 0
}

self_test_build_conf() {
  local tmp="$1" conf
  (CACHE_DIR=/c POKY_DIR=/p KEY_DIR=/k ATCD_BINARY=/a LAYER_ROOT=/r/meta-atc \
    write_build_conf "$tmp/build" "/c/layers/meta-rauc")
  conf="$tmp/build/conf"
  grep -qx 'DISTRO_FEATURES:append = " rauc"' "$conf/local.conf" || die "self-test: no rauc feature"
  grep -qx 'INIT_MANAGER = "systemd"' "$conf/local.conf" || die "self-test: no systemd"
  grep -qx 'RAUC_KEYRING_FILE = "/k/ca.cert.pem"' "$conf/local.conf" || die "self-test: keyring"
  grep -qx 'TMPDIR = "/c/tmp-rauc"' "$conf/local.conf" || die "self-test: TMPDIR is shared"
  grep -qx 'ATC_RAUC_UNTRUSTED_CERT_FILE = "/k/other-signing.cert.pem"' "$conf/local.conf" ||
    die "self-test: no untrusted signing cert"
  grep -qxF "  /c/layers/meta-rauc \\" "$conf/bblayers.conf" || die "self-test: no meta-rauc layer"
  grep -qxF "  /r/meta-atc \\" "$conf/bblayers.conf" || die "self-test: no meta-atc layer"
  [ "$(readlink "$conf/site.conf")" = /c/conf/site.conf ] || die "self-test: site.conf link"
}

# Every command the proof runs in the guest must parse as POSIX shell. A guest
# command with a quoting error is found here, not an hour into a TCG boot.
self_test_guest_commands() {
  local n
  n="$(guest_commands_parse "${BASH_SOURCE[0]}")"
  [ "$n" -ge 10 ] || die "self-test: found only $n guest commands to parse"
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  self_test_helpers "$tmp"
  self_test_envblk "$tmp"
  self_test_build_conf "$tmp"
  self_test_guest_commands
  echo "qemu-rauc-proof --self-test: OK"
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit 0
fi

PREV_VERSION="$OS_VERSION-prev"
if [ -z "$ACCEL" ]; then
  if [ -w /dev/kvm ]; then ACCEL=kvm; else ACCEL=tcg; fi
fi
scaled 1 "$ACCEL" > /dev/null
[ -n "$WORK_DIR" ] || WORK_DIR="$CACHE_DIR/rauc-proof/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$WORK_DIR"
echo "qemu-rauc-proof: work directory $WORK_DIR"

build
resolve_artifacts
assert_artifacts

if [ "$NO_BOOT" -eq 1 ]; then
  echo "qemu-rauc-proof: assertions passed. --no-boot, so stopping here."
  exit 0
fi

run_guest_proof
