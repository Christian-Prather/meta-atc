#!/usr/bin/env bash
# scripts/qemu-rauc-faults.sh
#
# The qemu fault suite of the RAUC OS update. Each case boots a fresh
# copy of the A/B disk, makes one fault, and checks which slot boots after it.
# It prints PASS, FAIL or RECORDED for each case, and keeps each case's serial
# console log.
#
# A case that boots to userspace reads the booted slot from /proc/cmdline
# (`rauc.slot=`, which only grub.cfg writes) and from `rauc status`, which
# reads the same argument. No case passes on an exit code alone.
# Each case also checks the line that grub.cfg prints for the branch of its
# slot decision, so every branch of that decision has a case that reaches it.
# See BRANCHES below.
#
# WHERE IT RUNS. On a workstation with /dev/kvm the guest runs under KVM. On the
# arm64 builder box it runs under TCG, and every timeout is multiplied by
# TCG_FACTOR. The images come from the box: run --build there, then copy the
# images directory to the workstation.
#
# Usage:
#   ./qemu-rauc-faults.sh --build [--build-dir <path>] [--images <dir>]
#       ON THE BOX, as the build user. Build the A/B disk and every bundle the
#       cases need, then stage them in <dir> (default <cache>/rauc-faults/images)
#       with a SHA256SUMS file.
#   ./qemu-rauc-faults.sh --images <dir> [--out <dir>] [--accel kvm|tcg]
#                         [--case <name>]... [--keep-disks]
#       Run the cases, all of them unless --case names some.
#   ./qemu-rauc-faults.sh --list
#   ./qemu-rauc-faults.sh --self-test       needs no box and no KVM
#
#   --out <dir>    where each case's logs go. Default
#                  ${XDG_CACHE_HOME:-~/.cache}/atc-rauc-faults/<timestamp>. Not
#                  tmpfs: the power-cut cases open the disk with O_DIRECT.
#   --keep-disks   keep each case's disk copy. By default it is deleted when
#                  the case ends, and only the logs stay.
#
# Each case writes <out>/<case>/:
#   serial.log         the serial console, across every boot of the case
#   case.log           what the harness did and saw
#   qemu-command.txt   each qemu command line the case ran
#   rauc-status.json   `rauc status` at the end of the case
#   grubenv.txt        the GRUB environment, read from the disk after qemu stops
#   record.txt         what the case records, if anything
#
# Needs: qemu-system-x86_64 (QEMU, or native.env in the image directory),
# mtools (mcopy), partx, fallocate, python3, sha256sum.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CACHE_DIR="${CACHE_DIR:-/cache}"
POKY_DIR="${POKY_DIR:-$CACHE_DIR/poky}"
BUILD_DIR="$CACHE_DIR/build-rauc"
IMAGES_DIR=""
OUT_DIR=""
ACCEL=""
CASES=()
KEEP_DISKS=0
MODE=run

QEMU="${QEMU:-qemu-system-x86_64}"
MCOPY="${MCOPY:-mcopy}"

MACHINE="qemux86-64"

# Guest timeouts in seconds, for KVM. TCG multiplies each one by TCG_FACTOR.
BOOT_TIMEOUT=300
INSTALL_TIMEOUT=600
COMMAND_TIMEOUT=60
# From the moment the hang slot freezes PID 1 to the revert.
WATCHDOG_TIMEOUT=300
# How long the both-slots-bad case watches the boot loop.
LOOP_WINDOW=90
TCG_FACTOR="${TCG_FACTOR:-6}"

die() {
  echo "qemu-rauc-faults: $*" >&2
  exit 1
}

step() {
  echo
  echo "=== $* ==="
}

# The hooks run shellcheck without -x, so it cannot follow this file.
# QEMU_GUEST_LIB names another copy of the lib, for a test.
# shellcheck disable=SC1090,SC1091
source "${QEMU_GUEST_LIB:-$SCRIPT_DIR/lib/qemu-guest.sh}"

# ── The tables ───────────────────────────────────────────────────────────────

# The bundles the cases attach, by the name the guest sees them under
# (/dev/disk/by-id/virtio-<name>), and the recipe that builds each one.
BUNDLES=(
  "good|atc-bundle"
  "badsig|atc-bundle-badsig"
  "other-compatible|atc-bundle-other-compatible"
  "panic|atc-bundle-panic"
  "hang|atc-bundle-hang"
  "empty|atc-bundle-empty"
)

# The cases, in run order: name | bundles | fidelity | expected.
#
# Fidelity is the design's "Faithful?" column. `approximation` cases model the
# fault, and the output says so. `recorded` is a case whose result is a stated
# behaviour, not a pass.
CASE_TABLE=(
  "happy-install|good|faithful|the new slot boots and is marked good"
  "bad-signature|badsig|faithful|rauc install refuses; the slots do not change"
  "wrong-compatible|other-compatible|faithful|rauc install refuses; the slots do not change"
  "no-confirm|good|faithful|the old slot boots after the one trial"
  "kernel-panic|panic|faithful|the old slot boots"
  "empty-rootfs|empty|faithful|the old slot boots"
  "watchdog-hang|hang|approximation|the watchdog resets the guest; the old slot boots"
  "both-slots-bad|panic|recorded|the behaviour is recorded"
  "data-partition|good|faithful|/var/atc content survives install and rollback"
  "mark-good-install-again-panic|good panic|faithful|the trial of A panics; B boots"
  "power-cut-write|good|approximation|the old slot boots; the new slot is not good"
  "power-cut-trial|good|approximation|the old slot boots; recorded against the GRUB counter"
)

# Every branch of grub.cfg's slot decision, and the cases that reach it: the
# design's "GRUB branch-to-fault" table. The self-test fails when a listed case
# does not check the branch with `grub_saw <branch>`.
BRANCHES=(
  "confirmed|happy-install mark-good-install-again-panic"
  "steady|happy-install"
  "spent|no-confirm kernel-panic empty-rootfs power-cut-trial"
  "new-trial|happy-install no-confirm kernel-panic empty-rootfs watchdog-hang both-slots-bad data-partition mark-good-install-again-panic power-cut-trial"
  "both-bad|both-slots-bad"
)

# Field $2 of the table row named $1 in the array named $3.
table_field() {
  local name="$1" field="$2" row
  local -n rows="$3"
  for row in "${rows[@]}"; do
    if [ "${row%%|*}" = "$name" ]; then
      cut -d'|' -f"$field" <<< "$row"
      return 0
    fi
  done
  return 1
}

case_names() {
  local row
  for row in "${CASE_TABLE[@]}"; do echo "${row%%|*}"; done
}

# The shell function that runs case $1.
case_function() {
  echo "case_${1//-/_}"
}

# ── Argument parsing ─────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --build) MODE=build && shift ;;
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}" && shift 2 ;;
    --images) IMAGES_DIR="${2:?--images needs a value}" && shift 2 ;;
    --out) OUT_DIR="${2:?--out needs a value}" && shift 2 ;;
    --accel) ACCEL="${2:?--accel needs a value}" && shift 2 ;;
    --case) CASES+=("${2:?--case needs a value}") && shift 2 ;;
    --keep-disks) KEEP_DISKS=1 && shift ;;
    --list) MODE=list && shift ;;
    --self-test) MODE=self-test && shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ── Pure helpers (the self-test drives these) ────────────────────────────────

# The serial-console line grub.cfg prints for branch $1 of its decision about
# slot $2, as an extended regex. The steady branch prints nothing.
grub_line() {
  local slot="$2"
  case "$1" in
    confirmed) echo "atc: slot $slot confirmed" ;;
    spent) echo "atc: trial boot of slot $slot did not confirm, reverting" ;;
    new-trial) echo "atc: trial boot of slot ${slot}[[:space:]]*\$" ;;
    both-bad) echo "atc: no slot is marked good, booting the last confirmed slot $slot" ;;
    *) die "no GRUB line for branch '$1'" ;;
  esac
}

# Does the serial text on stdin show branch $1 for slot $2? The steady branch
# is the absence of every other branch's line.
#
# Steady also excludes the two fallbacks that boot ATC_STEADY without taking
# the steady branch: an unreadable environment and a trial that could not be
# recorded. An unknown branch returns 2, never a match.
grub_branch_in() {
  local text line
  text="$(tr -d '\r')"
  if [ "$1" = steady ]; then
    if grep -Eq 'atc: (slot [AB] confirmed|trial boot of slot|no slot is marked good|boot environment unreadable|WARNING could not record the trial boot)' <<< "$text"; then
      return 1
    fi
  else
    line="$(grub_line "$1" "$2")" || return 2
    grep -Eq -- "$line" <<< "$text"
  fi
}

# A progress line of `rauc install` that shows the slot write under way. RAUC
# reports 46% when it starts to copy the image and 30% before it chooses the
# target slot, so 50% is the first value that is surely inside the write.
WRITE_PROGRESS_RE='(5[0-9]|[6-9][0-9])% Copying image to rootfs\.1[[:space:]]*$'

# The boot status RAUC gives the slot with bootname $1, from its shell output
# on stdin.
slot_boot_status() {
  awk -F= -v want="$1" '
    { gsub(/'\''/, "", $2) }
    $1 ~ /^RAUC_SLOT_BOOTNAME_/ { name[substr($1, 20)] = $2 }
    $1 ~ /^RAUC_SLOT_BOOT_STATUS_/ { status[substr($1, 23)] = $2 }
    END { for (n in name) if (name[n] == want) print status[n] }
  '
}

# The name=value lines of a GRUB environment block in file $1.
grubenv_lines() {
  tr -d '\0' < "$1" | grep -a -v '^#' || true
}

# Stdin without control characters other than tab and newline: the C0 and C1
# controls and the bidi overrides. Guest output reaches the terminal through
# this, so an escape sequence cannot rewrite it.
printable() {
  python3 -c '
import re, sys
text = sys.stdin.buffer.read().decode("utf-8", "replace")
sys.stdout.write(re.sub("[\x00-\x08\x0b-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]", "", text))
'
}

# How many times extended regex $1 matches a line of file $2.
count_lines() {
  tr -d '\r' < "$2" | grep -Ec -- "$1" || true
}

# ── The guest steps a case is made of ────────────────────────────────────────

# The byte of the serial log where the current boot began. grub_saw reads from
# here.
BOOT_MARK=0
# The byte after the last line that `await` matched.
MARK=0

# Wait for extended regex $1 after MARK, for at most $2 seconds, then move MARK
# past the start of the matched line. Dies on a timeout.
await() {
  local re="$1" timeout="$2" deadline pos
  [ -n "$re" ] || die "await needs a regex"
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    pos="$(tail -c +"$((MARK + 1))" "$GUEST_LOG" | grep -abE -m1 -- "$re" | cut -d: -f1 || true)"
    if [ -n "$pos" ]; then
      MARK=$((MARK + pos + 1))
      echo "seen: /$re/"
      return 0
    fi
    guest_alive || die "qemu exited while waiting for /$re/. See $GUEST_LOG"
    sleep "${GUEST_POLL:-2}"
  done
  die "no /$re/ on the serial console in ${timeout}s. See $GUEST_LOG"
}

# GRUB took branch $1 for slot $2 in this boot. See grub_branch_in.
grub_saw() {
  tail -c +"$((BOOT_MARK + 1))" "$GUEST_LOG" | grub_branch_in "$1" "${2:-}" ||
    die "grub.cfg did not take the '$1' branch for slot ${2:-?} in this boot. See $GUEST_LOG"
  # The steady branch prints no line, so it names no slot. assert_booted checks
  # the slot.
  if [ "$1" = steady ]; then
    echo "ok: grub.cfg took the 'steady' branch"
  else
    echo "ok: grub.cfg took the '$1' branch for slot $2"
  fi
}

login_here() {
  guest_login "$MARK" || die "no login prompt. See $GUEST_LOG"
  MARK="$(log_size)"
}

# Reboot from the shell. Then wait for each extended regex in $@ in order, and
# log in.
reboot_through() {
  local re
  BOOT_MARK="$(log_size)"
  MARK="$BOOT_MARK"
  guest_send reboot
  for re in "$@"; do
    await "$re" "$(scaled "$BOOT_TIMEOUT" "$ACCEL")"
  done
  login_here
}

# The case's disk and firmware variables, fresh from the image directory.
prepare_disk() {
  cp --sparse=always "$IMAGES_DIR/disk.wic" "$WORK_DIR/disk.wic"
  cp "$IMAGES_DIR/ovmf.vars.qcow2" "$WORK_DIR/ovmf.vars.qcow2"
}

# Start qemu on the case's disk with the bundles the case table names.
start_guest() {
  local name specs=()
  for name in $(table_field "$CASE_NAME" 2 CASE_TABLE); do
    specs+=("$name=$IMAGES_DIR/$name.raucb")
  done
  BOOT_MARK="$(log_size)"
  MARK="$BOOT_MARK"
  guest_start "$WORK_DIR/disk.wic" "$IMAGES_DIR/ovmf.code.qcow2" "$WORK_DIR/ovmf.vars.qcow2" "${specs[@]}"
}

# The booted slot is $1, by /proc/cmdline and by `rauc status`.
assert_booted() {
  local label
  case "$1" in A) label=atcroota ;; B) label=atcrootb ;; *) die "no slot $1" ;; esac
  expect_slot "$1" "$label"
  must "rauc status --output-format=shell"
  [ "$(shell_value RAUC_SYSTEM_BOOTED_BOOTNAME <<< "$GUEST_OUT")" = "$1" ] ||
    die "rauc status does not name $1 as the booted slot"
  echo "ok: rauc status names $1 as the booted slot"
}

# Each `name=value` in $@ is in the GRUB environment.
expect_env() {
  local line
  read_grubenv
  for line in "$@"; do
    grep -qxF -- "$line" <<< "$GUEST_OUT" || die "the GRUB environment does not hold '$line'"
  done
  echo "ok: the GRUB environment holds $*"
}

# RAUC's boot status of the slot with bootname $1 is $2.
expect_slot_status() {
  local status
  must "rauc status --output-format=shell"
  status="$(slot_boot_status "$1" <<< "$GUEST_OUT")"
  [ "$status" = "$2" ] || die "RAUC reports slot $1 '$status', expected '$2'"
  echo "ok: RAUC reports slot $1 $2"
}

# Boot the factory disk and check that it is slot A with no trial.
boot_factory() {
  step "boot the factory disk"
  prepare_disk
  start_guest
  login_here
  assert_booted A
  expect_env "ATC_STEADY=A" "ATC_TRIAL=none"
}

# Copy bundle $1 from its drive into the store, and check its sum.
stage_bundle() {
  local file="$IMAGES_DIR/$1.raucb" size sum
  size="$(stat -Lc %s "$file")"
  sum="$(sha256sum "$file" | cut -d' ' -f1)"
  must "head -c $size /dev/disk/by-id/virtio-$1 > /var/atc/$1.raucb && sha256sum /var/atc/$1.raucb"
  expect_out "^$sum "
}

# Install bundle $1 as user atc, which is how atcd calls RAUC.
install_bundle() {
  step "install $1"
  must "su -s /bin/sh atc -c 'rauc install /var/atc/$1.raucb'" "$(scaled "$INSTALL_TIMEOUT" "$ACCEL")"
}

# Bundle $1 must be refused with a message that matches extended regex $2, and
# the GRUB environment must not change.
refuse_bundle() {
  local before
  step "install $1, which RAUC must refuse"
  read_grubenv
  before="$GUEST_OUT"
  if guest_run "su -s /bin/sh atc -c 'rauc install /var/atc/$1.raucb'" "$(scaled "$INSTALL_TIMEOUT" "$ACCEL")"; then
    die "RAUC installed $1"
  fi
  expect_out "$2"
  read_grubenv
  [ "$GUEST_OUT" = "$before" ] || die "the refused install changed the GRUB environment"
  echo "ok: RAUC refused $1, and the GRUB environment did not change"
}

mark_good() {
  must "su -s /bin/sh atc -c 'rauc status mark-good booted'"
  expect_booted_status good
}

record() {
  echo "record: $*"
  echo "$*" >> "$WORK_DIR/record.txt"
}

# End the case: keep `rauc status`, then power off.
finish() {
  must "rauc status --output-format=json"
  printf '%s\n' "$GUEST_OUT" > "$WORK_DIR/rauc-status.json"
  guest_poweroff
}

# The byte offset of partition $2 of disk image $1, and its length, in bytes.
partition_range() {
  local start sectors
  read -r start sectors < <(partx -g -o START,SECTORS -n "$2" "$1")
  echo "$((start * 512)) $((sectors * 512))"
}

# The sha256 of partition $2 of disk image $1. $3 is the image that gives the
# partition table, by default $1.
partition_sum() {
  local start length
  read -r start length < <(partition_range "${3:-$1}" "$2")
  [ -n "$length" ] || die "no partition $2 in ${3:-$1}"
  tail -c "+$((start + 1))" "$1" | head -c "$length" | sha256sum | cut -d' ' -f1
}

# Slot B of the case's disk holds the bytes of the factory disk. The booted
# slot A is mounted read-write, so its bytes change on each boot. An install
# from A can write only B.
expect_slot_b_unchanged() {
  [ "$(partition_sum "$WORK_DIR/disk.wic" 3)" = "$(partition_sum "$IMAGES_DIR/disk.wic" 3)" ] ||
    die "slot B does not hold the bytes of the factory disk"
  echo "ok: slot B holds the bytes of the factory disk"
}

# The GRUB environment of disk image $1, read with mtools, as name=value lines.
disk_grubenv() {
  local offset tmp
  read -r offset _ < <(partition_range "$1" 1)
  tmp="$(mktemp)"
  MTOOLS_SKIP_CHECK=1 "$MCOPY" -n -o -i "$1@@$offset" ::atc/grubenv "$tmp" ||
    die "mtools could not read atc/grubenv from $1"
  grubenv_lines "$tmp"
  rm -f "$tmp"
}

# ── The cases ────────────────────────────────────────────────────────────────

case_happy_install() {
  boot_factory
  stage_bundle good
  install_bundle good
  expect_env "ORDER=B A" "B_OK=1" "B_TRY=0"
  step "boot 2: the trial of B"
  reboot_through "$(grub_line new-trial B)"
  grub_saw new-trial B
  assert_booted B
  expect_env "ATC_TRIAL=B" "B_TRY=1" "ATC_STEADY=A"
  expect_booted_status bad
  mark_good
  step "boot 3: the mark confirms B"
  reboot_through "$(grub_line confirmed B)"
  grub_saw confirmed B
  assert_booted B
  expect_env "ATC_STEADY=B" "ATC_TRIAL=none" "B_TRY=0"
  expect_booted_status good
  step "boot 4: B is steady"
  reboot_through
  grub_saw steady B
  assert_booted B
  expect_env "ATC_STEADY=B" "ATC_TRIAL=none"
  expect_booted_status good
  finish
}

# The two refusals share one shape. $1 is the bundle, $2 the refusal message.
# Slot B starts bad, so its status cannot show a write. After the power-off,
# the case compares the bytes of slot B with the factory disk.
refused_case() {
  boot_factory
  stage_bundle "$1"
  refuse_bundle "$1" "$2"
  expect_slot_status B bad
  step "reboot: A is still steady"
  reboot_through
  grub_saw steady A
  assert_booted A
  expect_env "ORDER=A B" "ATC_STEADY=A" "ATC_TRIAL=none" "B_OK=0"
  finish
  expect_slot_b_unchanged
}

case_bad_signature() {
  refused_case badsig 'signature|[Vv]erif|certificate'
}

case_wrong_compatible() {
  refused_case other-compatible '[Cc]ompatible'
}

case_no_confirm() {
  boot_factory
  stage_bundle good
  install_bundle good
  step "boot 2: the trial of B, which nothing marks"
  reboot_through "$(grub_line new-trial B)"
  grub_saw new-trial B
  assert_booted B
  expect_env "ATC_TRIAL=B" "B_TRY=1"
  # The runtime profile's pre-install handler: no install while a trial is in
  # flight, because the target would be A, the only revert target.
  refuse_bundle good 'Pre-install handler|on trial and not marked good'
  step "bring the trial deadline forward"
  # An empty OnBootSec= clears every timer of the unit. A deadline already in
  # the past elapses at once. The service's output goes to the console too, so
  # the log shows that the deadline, not the harness, rebooted the guest.
  must "mkdir -p /run/systemd/system/atc-os-trial-deadline.timer.d /run/systemd/system/atc-os-trial-deadline.service.d && printf '[Timer]\\nOnBootSec=\\nOnBootSec=1s\\n' > /run/systemd/system/atc-os-trial-deadline.timer.d/fault.conf && printf '[Service]\\nStandardOutput=journal+console\\n' > /run/systemd/system/atc-os-trial-deadline.service.d/fault.conf"
  # The reload alone can fire the timer, and the reboot then ends the shell
  # before a marker prints. So the command goes in with no marker, after the
  # log position is taken.
  BOOT_MARK="$(log_size)"
  MARK="$BOOT_MARK"
  guest_send "systemctl daemon-reload; systemctl restart atc-os-trial-deadline.timer"
  await 'atc-os-trial-deadline: trial slot B is not good at the deadline, rebooting' "$(scaled "$COMMAND_TIMEOUT" "$ACCEL")"
  await "$(grub_line spent B)" "$(scaled "$BOOT_TIMEOUT" "$ACCEL")"
  login_here
  grub_saw spent B
  assert_booted A
  expect_env "ORDER=A B" "B_OK=0" "ATC_STEADY=A" "ATC_TRIAL=none"
  expect_booted_status good
  finish
}

# A trial slot that fails before userspace. $1 is the bundle, $2 the regex of
# the failure on the console.
early_failure_case() {
  boot_factory
  stage_bundle "$1"
  install_bundle "$1"
  step "boot 2: the trial of B fails"
  reboot_through "$(grub_line new-trial B)" "$2" "$(grub_line spent B)"
  grub_saw new-trial B
  grub_saw spent B
  assert_booted A
  expect_env "ORDER=A B" "B_OK=0" "ATC_STEADY=A" "ATC_TRIAL=none"
  expect_booted_status good
  finish
}

case_kernel_panic() {
  early_failure_case panic 'Kernel panic - not syncing: Attempted to kill init'
}

case_empty_rootfs() {
  early_failure_case empty 'atc: could not load the kernel of slot B, rebooting'
}

case_watchdog_hang() {
  local hang reset
  boot_factory
  stage_bundle hang
  install_bundle hang
  step "boot 2: the trial of B stops feeding the watchdog"
  BOOT_MARK="$(log_size)"
  MARK="$BOOT_MARK"
  guest_send reboot
  await "$(grub_line new-trial B)" "$(scaled "$BOOT_TIMEOUT" "$ACCEL")"
  await 'atc-fault-hang: freezing PID 1' "$(scaled "$BOOT_TIMEOUT" "$ACCEL")"
  hang="$MARK"
  await "$(grub_line spent B)" "$(scaled "$WATCHDOG_TIMEOUT" "$ACCEL")"
  # head first: it stops at MARK, and tail reads all it gets, so no SIGPIPE.
  reset="$(head -c "$MARK" "$GUEST_LOG" | tail -c +"$hang" | tr -d '\r')"
  # A software reboot or a panic would also revert. Neither may appear between
  # the freeze and the revert, so only the watchdog can have reset the guest.
  if grep -Eq 'reboot: Restarting system|Kernel panic' <<< "$reset"; then
    die "the guest rebooted itself after the freeze; the watchdog did not reset it"
  fi
  echo "ok: no software reboot and no panic between the freeze and the revert"
  login_here
  grub_saw new-trial B
  grub_saw spent B
  assert_booted A
  expect_env "ORDER=A B" "B_OK=0" "ATC_STEADY=A" "ATC_TRIAL=none"
  finish
}

case_both_slots_bad() {
  local range boots
  boot_factory
  stage_bundle panic
  install_bundle panic
  # Both slots bad means no slot has OK=1. RAUC's mark-bad of A is the only
  # way A_OK reaches 0 here. Without it the loop below would run through the
  # steady branch, and the both-bad branch would go untested.
  must "su -s /bin/sh atc -c 'rauc status mark-bad booted'"
  expect_env "A_OK=0" "B_OK=1" "ORDER=B A"
  guest_poweroff
  step "zero slot A offline"
  read -r -a range < <(partition_range "$WORK_DIR/disk.wic" 2)
  fallocate --punch-hole --offset "${range[0]}" --length "${range[1]}" "$WORK_DIR/disk.wic"
  record "slot A zeroed: bytes ${range[0]} to $((range[0] + range[1])) of the disk"
  step "boot: B panics on trial, then A cannot load"
  start_guest
  await "$(grub_line new-trial B)" "$(scaled "$BOOT_TIMEOUT" "$ACCEL")"
  await "$(grub_line spent B)" "$(scaled "$BOOT_TIMEOUT" "$ACCEL")"
  await "$(grub_line both-bad A)" "$(scaled "$BOOT_TIMEOUT" "$ACCEL")"
  grub_saw new-trial B
  grub_saw spent B
  grub_saw both-bad A
  sleep "$(scaled "$LOOP_WINDOW" "$ACCEL")"
  tail -c +"$((MARK + 1))" "$GUEST_LOG" > "$WORK_DIR/loop.log"
  boots="$(count_lines "$(grub_line both-bad A)" "$WORK_DIR/loop.log")"
  [ "$boots" -ge 1 ] || die "the both-bad branch ran once and then stopped"
  ! grep -q 'login: ' "$WORK_DIR/loop.log" || die "a slot reached a login prompt with both slots bad"
  rm -f "$WORK_DIR/loop.log"
  record "boot loop on A: grub.cfg took the both-bad branch $((boots + 1)) times," \
    "$boots of them in the $(scaled "$LOOP_WINDOW" "$ACCEL") s after the first. No slot reached userspace."
  guest_stop
  echo '{"note": "no slot reached userspace, so rauc status could not run"}' > "$WORK_DIR/rauc-status.json"
}

# Read the sentinel and compare it with $1.
expect_sentinel() {
  must "cat /var/atc/fault-sentinel"
  expect_out "^$1\$"
  echo "ok: /var/atc/fault-sentinel holds $1"
}

case_data_partition() {
  local token
  token="sentinel-$RANDOM$RANDOM"
  boot_factory
  must "echo $token > /var/atc/fault-sentinel"
  stage_bundle good
  install_bundle good
  step "boot 2: the trial of B"
  reboot_through "$(grub_line new-trial B)"
  grub_saw new-trial B
  assert_booted B
  expect_sentinel "$token"
  mark_good
  step "boot 3: B confirmed"
  reboot_through "$(grub_line confirmed B)"
  grub_saw confirmed B
  assert_booted B
  expect_sentinel "$token"
  install_bundle good
  expect_env "ORDER=A B" "A_OK=1" "ATC_STEADY=B"
  step "boot 4: the trial of A, which nothing marks"
  reboot_through "$(grub_line new-trial A)"
  grub_saw new-trial A
  assert_booted A
  expect_sentinel "$token"
  step "boot 5: the trial of A is spent, B boots"
  reboot_through "$(grub_line spent A)"
  grub_saw spent A
  assert_booted B
  expect_env "A_OK=0" "ATC_STEADY=B" "ATC_TRIAL=none"
  expect_sentinel "$token"
  finish
}

case_mark_good_install_again_panic() {
  boot_factory
  stage_bundle good
  stage_bundle panic
  install_bundle good
  step "boot 2: the trial of B, marked good"
  reboot_through "$(grub_line new-trial B)"
  assert_booted B
  mark_good
  # No reboot: B is marked good but GRUB has not recorded the confirm yet. The
  # pre-install handler lets the install through, and RAUC writes A.
  install_bundle panic
  expect_env "ORDER=A B" "A_OK=1" "ATC_TRIAL=B" "B_OK=1" "B_TRY=0" "ATC_STEADY=A"
  step "boot 3: B is confirmed, then A panics on trial"
  reboot_through "$(grub_line confirmed B)" "$(grub_line new-trial A)" \
    'Kernel panic - not syncing: Attempted to kill init' "$(grub_line spent A)"
  grub_saw confirmed B
  grub_saw new-trial A
  grub_saw spent A
  assert_booted B
  expect_env "ATC_STEADY=B" "ATC_TRIAL=none" "A_OK=0"
  expect_booted_status good
  finish
}

case_power_cut_write() {
  local env KILL_FROM
  # shellcheck disable=SC2034 # lib/qemu-guest.sh reads it
  GUEST_DISK_CACHE=none
  boot_factory
  stage_bundle good
  step "install good, and SIGKILL qemu during the slot write"
  MARK="$(log_size)"
  KILL_FROM="$((MARK + 1))"
  guest_send "su -s /bin/sh atc -c 'rauc install /var/atc/good.raucb'"
  GUEST_POLL=0.2 await "$WRITE_PROGRESS_RE" "$(scaled "$INSTALL_TIMEOUT" "$ACCEL")"
  guest_stop KILL
  env="$(disk_grubenv "$WORK_DIR/disk.wic")"
  printf '%s\n' "$env" > "$WORK_DIR/grubenv-at-kill.txt"
  # The log is final once qemu is dead. Read all of it from the install on:
  # the last progress line is where the kill landed, and the write must not
  # have ended before it.
  tail -c +"$KILL_FROM" "$GUEST_LOG" | tr -d '\r' > "$WORK_DIR/install-at-kill.log"
  record "killed at: $(grep -E '[0-9]+% ' "$WORK_DIR/install-at-kill.log" | tail -n 1)"
  if grep 'Copying image to rootfs.1 done' "$WORK_DIR/install-at-kill.log" > /dev/null; then
    die "the slot write ended before the kill"
  fi
  record "at the kill: $(grep -E '^(ORDER|B_OK|B_TRY)=' <<< "$env" | tr '\n' ' ')"
  step "boot again after the power cut"
  start_guest
  login_here
  grub_saw steady A
  assert_booted A
  expect_slot_status B bad
  expect_env "ORDER=A B" "B_OK=0" "ATC_TRIAL=none"
  finish
}

case_power_cut_trial() {
  local env
  # shellcheck disable=SC2034 # lib/qemu-guest.sh reads it
  GUEST_DISK_CACHE=none
  boot_factory
  stage_bundle good
  install_bundle good
  step "boot 2: the trial of B, then SIGKILL qemu before any mark"
  reboot_through "$(grub_line new-trial B)"
  grub_saw new-trial B
  assert_booted B
  expect_env "ATC_TRIAL=B" "B_TRY=1"
  guest_stop KILL
  env="$(disk_grubenv "$WORK_DIR/disk.wic")"
  printf '%s\n' "$env" > "$WORK_DIR/grubenv-at-kill.txt"
  record "at the kill: $(grep -E '^(ATC_TRIAL|B_TRY|B_OK)=' <<< "$env" | tr '\n' ' ')"
  step "boot again after the power cut"
  start_guest
  await "$(grub_line spent B)" "$(scaled "$BOOT_TIMEOUT" "$ACCEL")"
  login_here
  grub_saw spent B
  assert_booted A
  expect_env "ORDER=A B" "B_OK=0" "ATC_TRIAL=none"
  record "after: GRUB spent the trial, slot A booted, B_OK=0"
  finish
}

# ── Running the cases ────────────────────────────────────────────────────────

# A second run in one case directory would append to the first run's logs.
# Refuse before the first case runs, not part way through the suite.
refuse_used_case_dirs() {
  local name
  [ -n "$OUT_DIR" ] || return 0
  for name in "${CASES[@]}"; do
    [ ! -e "$OUT_DIR/$name" ] || die "$OUT_DIR/$name exists. Name a new --out"
  done
}

# Run case $1 in a subshell, so a failure ends the case and not the suite.
# Writes <out>/<case>/result: PASS, FAIL or RECORDED.
run_case() {
  local name="$1" fn status result
  fn="$(case_function "$name")"
  WORK_DIR="$OUT_DIR/$name"
  # A second run in one directory would append to the first run's logs.
  [ ! -e "$WORK_DIR" ] || die "$WORK_DIR exists. Name a new --out"
  mkdir -p "$WORK_DIR"
  echo "--- $name: $(table_field "$name" 4 CASE_TABLE)"
  set +e
  (
    set -e
    CASE_NAME="$name"
    trap guest_stop EXIT
    "$fn"
  ) > "$WORK_DIR/case.log" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    result=FAIL
  elif [ "$(table_field "$name" 3 CASE_TABLE)" = recorded ]; then
    result=RECORDED
  else
    result=PASS
  fi
  echo "$result" > "$WORK_DIR/result"
  collect_case "$name"
  echo "    $result"
  [ "$result" != FAIL ] || tail -n 5 "$WORK_DIR/case.log" | printable | sed 's/^/    /'
  return 0
}

# After the guest stops: the GRUB environment from the disk, then the disk
# goes unless --keep-disks.
collect_case() {
  local dir="$OUT_DIR/$1"
  if [ -f "$dir/disk.wic" ]; then
    (disk_grubenv "$dir/disk.wic") > "$dir/grubenv.txt" 2>&1 || true
    [ "$KEEP_DISKS" -eq 1 ] || rm -f "$dir/disk.wic" "$dir/ovmf.vars.qcow2"
  fi
}

print_results() {
  local name result fidelity failed=0
  echo
  echo "qemu-rauc-faults: results (accel=$ACCEL)"
  printf '%-31s %-9s %-14s %s\n' case result fidelity "serial log"
  for name in "${CASES[@]}"; do
    result="$(cat "$OUT_DIR/$name/result")"
    fidelity="$(table_field "$name" 3 CASE_TABLE)"
    printf '%-31s %-9s %-14s %s\n' "$name" "$result" "$fidelity" "$OUT_DIR/$name/serial.log"
    if [ -s "$OUT_DIR/$name/record.txt" ]; then
      printable < "$OUT_DIR/$name/record.txt" | sed 's/^/    record: /'
    fi
    [ "$result" != FAIL ] || failed=$((failed + 1))
  done
  echo
  echo "Approximations: a power cut is a SIGKILL to qemu with cache=none. It loses"
  echo "the guest page cache and every request in flight, and tears no sector."
  echo "The hang freezes PID 1, the watchdog feeder; the kernel keeps running."
  [ "$failed" -eq 0 ] || die "$failed case(s) failed"
}

check_images() {
  local f row
  [ -n "$IMAGES_DIR" ] || die "--images <dir> is required. On the box, run --build first; on a workstation, run fetch-images.sh"
  for f in disk.wic ovmf.code.qcow2 ovmf.vars.qcow2; do
    [ -f "$IMAGES_DIR/$f" ] || die "missing $IMAGES_DIR/$f"
  done
  for row in "${BUNDLES[@]}"; do
    [ -f "$IMAGES_DIR/${row%%|*}.raucb" ] || die "missing $IMAGES_DIR/${row%%|*}.raucb"
  done
  # The box's native tools, written by --build. A workstation uses its own.
  if [ -f "$IMAGES_DIR/native.env" ]; then
    QEMU="$(sed -n 's/^QEMU=//p' "$IMAGES_DIR/native.env")"
    MCOPY="$(sed -n 's/^MCOPY=//p' "$IMAGES_DIR/native.env")"
  fi
  for f in "$QEMU" "$MCOPY" partx fallocate python3 sha256sum; do
    command -v "$f" > /dev/null || die "'$f' is not on PATH"
  done
}

# A case that sets GUEST_DISK_CACHE=none opens its disk with O_DIRECT. tmpfs
# aligns O_DIRECT to a page, and the disk image is not a whole number of pages,
# so qemu refuses to start. Refuse here, before any case runs.
check_direct_io() {
  local name
  [ "$(stat -f -c %T "$OUT_DIR")" = tmpfs ] || return 0
  for name in "${CASES[@]}"; do
    if grep -q 'GUEST_DISK_CACHE=none' <<< "$(case_body "$(case_function "$name")")"; then
      die "case $name opens its disk with cache=none, which $OUT_DIR (tmpfs) cannot hold. Use --out on a disk filesystem"
    fi
  done
}

run_suite() {
  local name
  check_images
  if [ -z "$ACCEL" ]; then
    if [ -w /dev/kvm ]; then ACCEL=kvm; else ACCEL=tcg; fi
  fi
  scaled 1 "$ACCEL" > /dev/null
  [ "${#CASES[@]}" -gt 0 ] || mapfile -t CASES < <(case_names)
  for name in "${CASES[@]}"; do
    table_field "$name" 1 CASE_TABLE > /dev/null || die "no case '$name'. See --list"
  done
  [ "$(printf '%s\n' "${CASES[@]}" | sort | uniq -d)" = "" ] || die "a case is named twice"
  [ -n "$OUT_DIR" ] || OUT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/atc-rauc-faults/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$OUT_DIR"
  OUT_DIR="$(cd "$OUT_DIR" && pwd)"
  refuse_used_case_dirs
  check_direct_io
  echo "qemu-rauc-faults: accel=$ACCEL, images $IMAGES_DIR, logs $OUT_DIR"
  for name in "${CASES[@]}"; do
    run_case "$name"
  done
  print_results
}

# ── The build (on the box) ───────────────────────────────────────────────────

bb_recipe_value() {
  bitbake-getvar --value -r "$1" "$2" 2> /dev/null || true
}

# Build the base images through qemu-rauc-proof.sh, which also asserts them,
# then the fault bundles. Stage everything under IMAGES_DIR with fixed names.
build_and_stage() {
  local deploy link row recipe native_bin wic_native
  [ -n "$IMAGES_DIR" ] || IMAGES_DIR="$CACHE_DIR/rauc-faults/images"
  step "the base images, through qemu-rauc-proof.sh"
  "$SCRIPT_DIR/qemu-rauc-proof.sh" --no-boot --build-dir "$BUILD_DIR"
  set +u
  # shellcheck disable=SC1091
  source "$POKY_DIR/oe-init-build-env" "$BUILD_DIR" > /dev/null
  set -u
  local recipes=()
  for row in "${BUNDLES[@]}"; do recipes+=("${row#*|}"); done
  step "bitbake ${recipes[*]}"
  bitbake "${recipes[@]}"
  deploy="$(bb_recipe_value atc-image-ab DEPLOY_DIR_IMAGE)"
  link="$(bb_recipe_value atc-image-ab IMAGE_LINK_NAME)"
  [ -d "$deploy" ] || die "DEPLOY_DIR_IMAGE '$deploy' does not exist"
  step "stage in $IMAGES_DIR"
  mkdir -p "$IMAGES_DIR"
  cp --sparse=always -L "$deploy/$link.wic" "$IMAGES_DIR/disk.wic"
  zstd -T0 -q -f "$IMAGES_DIR/disk.wic" -o "$IMAGES_DIR/disk.wic.zst"
  cp -L "$deploy/ovmf.code.qcow2" "$deploy/ovmf.vars.qcow2" "$IMAGES_DIR/"
  for row in "${BUNDLES[@]}"; do
    recipe="${row#*|}"
    cp -L "$deploy/$recipe-$MACHINE.raucb" "$IMAGES_DIR/${row%%|*}.raucb"
  done
  (cd "$IMAGES_DIR" && sha256sum disk.wic.zst ovmf.code.qcow2 ovmf.vars.qcow2 ./*.raucb |
    sed 's| \./| |' > SHA256SUMS)
  native_bin="$(sed -n 's/^staging_bindir_native = //p' "$deploy/$link.qemuboot.conf")"
  wic_native="$(bb_recipe_value atc-image-ab STAGING_DIR_NATIVE)"
  printf 'QEMU=%s\nMCOPY=%s\n' "${native_bin%/}/qemu-system-x86_64" "$wic_native/usr/bin/mcopy" \
    > "$IMAGES_DIR/native.env"
  echo "qemu-rauc-faults: staged in $IMAGES_DIR"
  cat "$IMAGES_DIR/SHA256SUMS"
}

# ── Self-test ────────────────────────────────────────────────────────────────

# The text of case function $1, and of each shared case shape it calls.
case_body() {
  local shape
  declare -f "$1"
  for shape in refused_case early_failure_case; do
    if grep -qw "$shape" <<< "$(declare -f "$1")"; then declare -f "$shape"; fi
  done
}

self_test_tables() {
  local row name bundle fn branch cases seen=" "
  for row in "${CASE_TABLE[@]}"; do
    [ "$(tr -cd '|' <<< "$row" | wc -c)" -eq 3 ] || die "self-test: case row is not 4 fields: $row"
    name="${row%%|*}"
    case "$seen" in *" $name "*) die "self-test: case $name twice" ;; esac
    seen+="$name "
    fn="$(case_function "$name")"
    declare -F "$fn" > /dev/null || die "self-test: case $name has no function $fn"
    for bundle in $(table_field "$name" 2 CASE_TABLE); do
      table_field "$bundle" 1 BUNDLES > /dev/null || die "self-test: case $name names no bundle $bundle"
    done
    case "$(table_field "$name" 3 CASE_TABLE)" in
      faithful | approximation | recorded) ;;
      *) die "self-test: case $name has an unknown fidelity" ;;
    esac
  done
  for row in "${BUNDLES[@]}"; do
    name="${row%%|*}"
    [ "${#name}" -le 20 ] || die "self-test: bundle name $name is over the 20-byte virtio serial"
  done
  [ "${#CASE_TABLE[@]}" -eq 12 ] || die "self-test: the suite has 12 cases, not ${#CASE_TABLE[@]}"
  # These cases are approximations or recorded results.
  for name in power-cut-write power-cut-trial watchdog-hang; do
    [ "$(table_field "$name" 3 CASE_TABLE)" = approximation ] || die "self-test: $name is not an approximation"
  done
  [ "$(table_field both-slots-bad 3 CASE_TABLE)" = recorded ] || die "self-test: both-slots-bad is not recorded"
  [ "$(printf '%s\n' "${BRANCHES[@]}" | cut -d'|' -f1 | tr '\n' ' ')" = "confirmed steady spent new-trial both-bad " ] ||
    die "self-test: BRANCHES does not list the five branches of grub.cfg"
  for row in "${BRANCHES[@]}"; do
    branch="${row%%|*}" cases="${row#*|}"
    [ -n "$cases" ] || die "self-test: no case reaches branch $branch"
    for name in $cases; do
      fn="$(case_function "$name")"
      declare -F "$fn" > /dev/null || die "self-test: branch $branch names no case $name"
      grep -q "grub_saw $branch\\b" <<< "$(case_body "$fn")" ||
        die "self-test: case $name does not check branch $branch"
    done
  done
}

self_test_grub_lines() {
  local log
  log=$'atc: trial boot of slot B\r\nboot\r\natc: trial boot of slot B did not confirm, reverting to A\r\n'
  grub_branch_in new-trial B <<< "$log" || die "self-test: new trial not seen"
  grub_branch_in spent B <<< "$log" || die "self-test: spent not seen"
  grub_branch_in new-trial A <<< "$log" && die "self-test: a trial of A was seen"
  grub_branch_in new-trial B <<< $'atc: trial boot of slot B did not confirm\r\n' &&
    die "self-test: the spent line counted as a new trial"
  grub_branch_in steady A <<< "$log" && die "self-test: a trial boot counted as steady"
  grub_branch_in steady A <<< $'GRUB\r\nLinux version\r\n' || die "self-test: a quiet boot is not steady"
  grub_branch_in confirmed B <<< 'atc: slot B confirmed' || die "self-test: confirmed not seen"
  grub_branch_in both-bad A <<< 'atc: no slot is marked good, booting the last confirmed slot A' ||
    die "self-test: both-bad not seen"
  (grub_line bogus A) > /dev/null 2>&1 && die "self-test: an unknown branch has a line"
  grub_branch_in bogus A <<< "$log" 2> /dev/null && die "self-test: an unknown branch matched"
  grub_branch_in steady A <<< 'atc: boot environment unreadable, falling back to slot A' &&
    die "self-test: a fallback boot counted as steady"
  grub_branch_in steady A <<< 'atc: WARNING could not record the trial boot of B, staying on A' &&
    die "self-test: an unrecorded trial counted as steady"
  grub_branch_in steady A <<< 'atc: WARNING could not clear the ended trial' ||
    die "self-test: a steady boot that could not clear its trial is not steady"
  return 0
}

self_test_parsers() {
  local tmp="$1" pad
  grep -Eq "$WRITE_PROGRESS_RE" <<< '     46% Copying image to rootfs.1' && die "self-test: 46% counts as the write"
  grep -Eq "$WRITE_PROGRESS_RE" <<< '     30% Checking manifest contents done.' && die "self-test: 30% counts"
  grep -Eq "$WRITE_PROGRESS_RE" <<< '     50% Copying image to rootfs.1' || die "self-test: 50% does not count"
  grep -Eq "$WRITE_PROGRESS_RE" <<< '     83% Copying image to rootfs.1' || die "self-test: 83% does not count"
  grep -Eq "$WRITE_PROGRESS_RE" <<< '     85% Copying image to rootfs.1 done.' && die "self-test: the done line counts"
  printf '%s\n' "RAUC_SLOT_BOOTNAME_1='A'" "RAUC_SLOT_BOOT_STATUS_1='good'" \
    "RAUC_SLOT_BOOTNAME_2='B'" "RAUC_SLOT_BOOT_STATUS_2='bad'" > "$tmp/status"
  [ "$(slot_boot_status B < "$tmp/status")" = bad ] || die "self-test: slot_boot_status B"
  [ "$(slot_boot_status A < "$tmp/status")" = good ] || die "self-test: slot_boot_status A"
  printf '%s\n' '# GRUB Environment Block' 'ORDER=A B' 'B_TRY=1' > "$tmp/env"
  pad=$((1024 - $(wc -c < "$tmp/env")))
  head -c "$pad" /dev/zero | tr '\0' '#' >> "$tmp/env"
  [ "$(grubenv_lines "$tmp/env")" = "$(printf 'ORDER=A B\nB_TRY=1')" ] || die "self-test: grubenv_lines"
  printf 'x\r\natc: no slot\r\natc: no slot\r\n' > "$tmp/loop"
  [ "$(count_lines 'atc: no slot' "$tmp/loop")" = 2 ] || die "self-test: count_lines"
  [ "$(count_lines 'absent' "$tmp/loop")" = 0 ] || die "self-test: count_lines with no match"
  [ "$(printf 'a\033[2Jb\tc\r' | printable)" = "$(printf 'a[2Jb\tc')" ] || die "self-test: printable"
  [ "$(printf 'a\302\233b\342\200\256c' | printable)" = abc ] || die "self-test: printable kept a C1 or bidi control"
}

# await on a log that a fake guest writes: it finds lines in order, it moves
# MARK past each one, and it dies on a timeout.
#
# It runs in a subshell, so an EXIT trap there stops the fake guest without
# replacing the RETURN trap that removes self_test's scratch directory.
self_test_await() {
  (self_test_await_body "$1") || die "self-test: await"
}

self_test_await_body() {
  local tmp="$1"
  GUEST_LOG="$tmp/await.log"
  printf 'one\r\ntwo\r\none again\r\n' > "$GUEST_LOG"
  sleep 600 &
  GUEST_PID=$!
  trap 'kill "$GUEST_PID" 2> /dev/null || true' EXIT
  MARK=0
  await '^two' 1 > /dev/null
  [ "$MARK" -eq 6 ] || die "self-test: await left MARK at $MARK, not 6"
  await '^one' 1 > /dev/null
  [ "$MARK" -eq 11 ] || die "self-test: await found the first 'one' again"
  (await '^two' 1) > /dev/null 2>&1 && die "self-test: await found a line before MARK"
  (await '' 1) > /dev/null 2>&1 && die "self-test: await took an empty regex"
  kill "$GUEST_PID"
  wait "$GUEST_PID" 2> /dev/null || true
  GUEST_PID=""
}

# The log layout of a run: a case that passes, one that fails, and one that
# records. Each keeps case.log and result, and the summary fails the run.
# expect_slot_b_unchanged sees a write inside slot B and ignores one outside
# it. A fixed range stands in for partx, which the test host may not have.
self_test_slot_b() {
  (self_test_slot_b_body "$1") > /dev/null || die "self-test: expect_slot_b_unchanged"
}

self_test_slot_b_body() {
  local tmp="$1"
  partition_range() { echo "4096 8192"; }
  IMAGES_DIR="$tmp/factory"
  WORK_DIR="$tmp/case"
  mkdir -p "$IMAGES_DIR" "$WORK_DIR"
  head -c 16384 /dev/zero > "$IMAGES_DIR/disk.wic"
  cp "$IMAGES_DIR/disk.wic" "$WORK_DIR/disk.wic"
  printf 'x' | dd of="$WORK_DIR/disk.wic" bs=1 seek=100 conv=notrunc status=none
  printf 'x' | dd of="$WORK_DIR/disk.wic" bs=1 seek=12300 conv=notrunc status=none
  expect_slot_b_unchanged
  cp "$IMAGES_DIR/disk.wic" "$WORK_DIR/disk.wic"
  printf 'x' | dd of="$WORK_DIR/disk.wic" bs=1 seek=12287 conv=notrunc status=none
  (expect_slot_b_unchanged) 2> /dev/null && die "self-test: a write at the end of slot B passed"
  cp "$IMAGES_DIR/disk.wic" "$WORK_DIR/disk.wic"
  printf 'x' | dd of="$WORK_DIR/disk.wic" bs=1 seek=4096 conv=notrunc status=none
  (expect_slot_b_unchanged) 2> /dev/null && die "self-test: a write at the start of slot B passed"
  true
}

self_test_layout() {
  local tmp="$1"
  case_selftest_pass() { echo "passing"; }
  case_selftest_fail() { die "failing on purpose"; }
  case_selftest_record() { record "a stated behaviour"; }
  # A bare failing command, not die, must also fail the case.
  case_selftest_false() {
    false
    echo "set -e did not stop the case"
  }
  local -a CASE_TABLE=(
    "selftest-pass|good|faithful|passes"
    "selftest-fail|good|approximation|fails"
    "selftest-record|good|recorded|records"
    "selftest-false|good|faithful|fails without die"
  )
  OUT_DIR="$tmp/out"
  CASES=(selftest-pass selftest-fail selftest-record selftest-false)
  ACCEL=kvm
  local name
  for name in "${CASES[@]}"; do run_case "$name" > /dev/null; done
  [ "$(cat "$OUT_DIR/selftest-pass/result")" = PASS ] || die "self-test: a passing case did not pass"
  [ "$(cat "$OUT_DIR/selftest-fail/result")" = FAIL ] || die "self-test: a failing case did not fail"
  [ "$(cat "$OUT_DIR/selftest-record/result")" = RECORDED ] || die "self-test: a recorded case is not RECORDED"
  [ "$(cat "$OUT_DIR/selftest-false/result")" = FAIL ] || die "self-test: a failing command did not fail the case"
  (run_case selftest-pass) > /dev/null 2>&1 && die "self-test: a second run reused a case directory"
  (refuse_used_case_dirs) > /dev/null 2>&1 && die "self-test: a used --out passed the up-front check"
  grep -q 'failing on purpose' "$OUT_DIR/selftest-fail/case.log" || die "self-test: case.log lost the failure"
  grep -qx 'a stated behaviour' "$OUT_DIR/selftest-record/record.txt" || die "self-test: no record.txt"
  (print_results) > "$tmp/summary" 2>&1 && die "self-test: a run with a failed case exited 0"
  grep -q "^selftest-fail .* FAIL .* approximation .* $OUT_DIR/selftest-fail/serial.log" "$tmp/summary" ||
    die "self-test: the summary row of the failed case is wrong"
  grep -q 'record: a stated behaviour' "$tmp/summary" || die "self-test: the summary lost the record"
}

self_test() {
  local tmp n
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  qemu_guest_self_test "$tmp"
  [ "$(scaled "$WATCHDOG_TIMEOUT" tcg)" = "$((WATCHDOG_TIMEOUT * TCG_FACTOR))" ] ||
    die "self-test: the watchdog timeout does not scale under TCG"
  self_test_tables
  self_test_grub_lines
  self_test_parsers "$tmp"
  self_test_await "$tmp"
  self_test_slot_b "$tmp"
  self_test_layout "$tmp"
  n="$(guest_commands_parse "${BASH_SOURCE[0]}")"
  [ "$n" -ge 5 ] || die "self-test: found only $n guest commands to parse"
  echo "qemu-rauc-faults --self-test: OK"
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "$MODE" in
  self-test) self_test ;;
  list)
    for row in "${CASE_TABLE[@]}"; do
      IFS='|' read -r name _ fidelity expected <<< "$row"
      printf '%-31s %-14s %s\n' "$name" "$fidelity" "$expected"
    done
    ;;
  build) build_and_stage ;;
  run) run_suite ;;
esac
