#!/usr/bin/env bash
# tests/atc-tegra-capsule_test.sh
#
# Behavioural tests for meta-atc's Jetson capsule tool and for the bundle hook
# that calls it. The real tool runs as `sh` against a fake ESP directory, a
# fake efivarfs directory and a fake mount table. The efivarfs file has the
# real layout: 4 bytes of attributes, then the 8-byte value. A fake chattr
# records each call, as the efivarfs immutable flag cannot be set on tmpfs.
#
# Usage: atc-tegra-capsule_test.sh <atc-tegra-capsule> <atc-bundle-hook>
set -euo pipefail

TOOL="${1:?usage: atc-tegra-capsule_test.sh <atc-tegra-capsule> <atc-bundle-hook>}"
HOOK="${2:?usage: atc-tegra-capsule_test.sh <atc-tegra-capsule> <atc-bundle-hook>}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

OSIND_NAME=OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c

# The fakes. chattr appends its arguments to $CHATTR_LOG. FAKE_CHATTR_FAIL
# makes it fail, and FAKE_CHATTR_FAIL_SET makes only `chattr +i` fail. cp
# writes a different file when FAKE_CP_CORRUPT is set.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/chattr" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CHATTR_LOG"
[ -z "${FAKE_CHATTR_FAIL:-}" ] || exit 1
[ -z "${FAKE_CHATTR_FAIL_SET:-}" ] || [ "$1" != +i ]
EOF
cat > "$tmp/bin/cp" << 'EOF'
#!/bin/sh
if [ -n "${FAKE_CP_CORRUPT:-}" ]; then
  printf 'corrupt' > "$2"
  exit 0
fi
exec /bin/cp "$@"
EOF
chmod +x "$tmp/bin/chattr" "$tmp/bin/cp"

# A fresh device: an ESP, an efivarfs and a mount table in $1. The ESP is a
# mount point unless $2 is "unmounted".
device() {
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d/esp" "$d/efivars" "$d/bundle" "$d/old/etc" "$d/new/etc" "$d/run"
  if [ "${2:-}" = unmounted ]; then
    printf '22 1 259:2 / / rw - ext4 /dev/root rw\n' > "$d/mountinfo"
  else
    printf '22 1 259:2 / / rw - ext4 /dev/root rw\n31 22 259:10 / %s rw - vfat /dev/nvme0n1p10 rw\n' \
      "$d/esp" > "$d/mountinfo"
  fi
  : > "$d/chattr.log"
  head -c 4096 /dev/urandom > "$d/bundle/tegra-bl.cap"
}

device_unmount() { printf '22 1 259:2 / / rw - ext4 /dev/root rw\n' > "$1/mountinfo"; }

# Run the tool against device $1. Stdout and stderr go to separate files.
tool() {
  local d="$1"
  shift
  PATH="$tmp/bin:$PATH" CHATTR_LOG="$d/chattr.log" ATC_TEGRA_ESP="$d/esp" \
    ATC_EFIVARS_DIR="$d/efivars" ATC_MOUNTINFO="$d/mountinfo" \
    ATC_TEGRA_CAPSULE_RUNDIR="$d/run" sh "$TOOL" "$@" > "$d/out" 2> "$d/err"
}

# The 12 bytes of OsIndications on device $1 as hex, or "absent".
osind() {
  if [ -e "$1/efivars/$OSIND_NAME" ]; then
    od -An -tx1 "$1/efivars/$OSIND_NAME" | tr -d ' \n'
  else
    echo absent
  fi
}

# Write OsIndications on device $1 from the hex string $2.
set_osind() {
  printf '%b' "$(printf '%s' "$2" | sed 's/../\\x&/g')" > "$1/efivars/$OSIND_NAME"
}

staged() { [ -f "$1/esp/EFI/UpdateCapsule/TEGRA_BL.Cap" ]; }
binding() { cat "$1/esp/EFI/.atc-capsule.slot" 2> /dev/null || echo none; }

# 1. stage puts an exact copy on the ESP, bound to the slot, and does not arm.
d="$tmp/stage"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B || fail "stage: exit $?: $(cat "$d/err")"
cmp -s "$d/bundle/tegra-bl.cap" "$d/esp/EFI/UpdateCapsule/TEGRA_BL.Cap" ||
  fail "stage: the ESP does not hold an exact copy of the capsule"
[ "$(binding "$d")" = B ] || fail "stage: the binding is $(binding "$d"), expected B"
[ "$(osind "$d")" = absent ] || fail "stage armed the capsule: $(osind "$d")"
[ ! -e "$d/esp/EFI/.atc-capsule.part" ] || fail "stage left its partial copy"
# UEFI tries every file in the directory, so it must hold the capsule only.
[ "$(ls -A "$d/esp/EFI/UpdateCapsule")" = TEGRA_BL.Cap ] ||
  fail "UpdateCapsule holds more than the capsule: $(ls -A "$d/esp/EFI/UpdateCapsule")"
tool "$d" is-staged B || fail "is-staged B: exit $? after a stage for B"
tool "$d" is-staged A && fail "is-staged A: exit 0 for a capsule staged for B"
tool "$d" stage "$d/bundle/tegra-bl.cap" C && fail "stage accepted the slot C"

# 1c. The binding the other way: a capsule staged for A is staged for A only,
#     and an arm for B is refused.
d="$tmp/stage-a"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" A || fail "stage A: exit $?: $(cat "$d/err")"
[ "$(binding "$d")" = A ] || fail "stage A: the binding is $(binding "$d"), expected A"
tool "$d" is-staged A || fail "is-staged A: exit $? after a stage for A"
tool "$d" is-staged B && fail "is-staged B: exit 0 for a capsule staged for A"
tool "$d" arm B && fail "arm B succeeded for a capsule staged for A"
[ "$(osind "$d")" = absent ] || fail "a refused arm B wrote OsIndications: $(osind "$d")"

# 1a. stage removes a stray capsule that is already in the directory, files
#     and subdirectories alike. UEFI tries every file there.
d="$tmp/stage-stray"
device "$d"
mkdir -p "$d/esp/EFI/UpdateCapsule/sub"
printf 'stray' > "$d/esp/EFI/UpdateCapsule/other.cap"
printf 'stray' > "$d/esp/EFI/UpdateCapsule/sub/deep.cap"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
[ "$(ls -A "$d/esp/EFI/UpdateCapsule")" = TEGRA_BL.Cap ] ||
  fail "stage kept a stray capsule: $(ls -A "$d/esp/EFI/UpdateCapsule")"

# 1b. A copy that differs from the bundle's capsule is refused and removed.
d="$tmp/stage-corrupt"
device "$d"
if FAKE_CP_CORRUPT=1 tool "$d" stage "$d/bundle/tegra-bl.cap" B; then
  fail "stage accepted a copy that differs from the capsule"
fi
grep -q 'differs' "$d/err" || fail "a corrupt copy: no reason on stderr: $(cat "$d/err")"
staged "$d" && fail "a corrupt copy was staged"
[ ! -e "$d/esp/EFI/.atc-capsule.part" ] || fail "a corrupt copy stayed as the partial copy"
[ "$(binding "$d")" = none ] || fail "a corrupt copy left a binding"

# 2. An ESP that is not mounted is refused, and nothing is written: the copy
#    would land on the rootfs, and no switch would happen.
d="$tmp/unmounted"
device "$d" unmounted
if tool "$d" stage "$d/bundle/tegra-bl.cap" B; then
  fail "stage succeeded on an unmounted ESP"
fi
[ ! -e "$d/esp/EFI" ] || fail "stage wrote to an unmounted ESP"
grep -q 'not mounted' "$d/err" || fail "stage on an unmounted ESP: no reason on stderr: $(cat "$d/err")"

# 3. An empty capsule is refused.
d="$tmp/empty"
device "$d"
: > "$d/bundle/tegra-bl.cap"
if tool "$d" stage "$d/bundle/tegra-bl.cap" B; then
  fail "stage accepted an empty capsule"
fi
staged "$d" && fail "stage of an empty capsule left a file on the ESP"

# 4. arm with nothing staged, or for another slot, is refused, and
#    OsIndications is not created.
d="$tmp/arm-none"
device "$d"
tool "$d" arm B && fail "arm succeeded with no capsule staged"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm A && fail "arm A succeeded for a capsule staged for B"
grep -q 'no capsule staged for slot A' "$d/err" || fail "arm A: no reason on stderr: $(cat "$d/err")"
[ "$(osind "$d")" = absent ] || fail "a refused arm wrote OsIndications: $(osind "$d")"

# 5. arm creates OsIndications with the runtime attributes and bit 2, and sets
#    the immutable flag again after the write, as efi_write does.
d="$tmp/arm"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm B || fail "arm: exit $?: $(cat "$d/err")"
[ "$(osind "$d")" = 070000000400000000000000 ] || fail "arm: OsIndications is $(osind "$d")"
[ "$(cat "$d/chattr.log")" = "+i $d/efivars/$OSIND_NAME" ] ||
  fail "arm of a new variable: chattr calls were '$(cat "$d/chattr.log")'"
: > "$d/chattr.log"
# A second arm changes nothing, and clears the flag first on the existing file.
tool "$d" arm B
[ "$(osind "$d")" = 070000000400000000000000 ] || fail "a second arm: OsIndications is $(osind "$d")"
[ "$(cat "$d/chattr.log")" = "-i $d/efivars/$OSIND_NAME"$'\n'"+i $d/efivars/$OSIND_NAME" ] ||
  fail "a second arm: chattr calls were '$(cat "$d/chattr.log")'"
tool "$d" armed-slot || fail "armed-slot: exit $? after arm B"
[ "$(cat "$d/out")" = B ] || fail "armed-slot printed '$(cat "$d/out")', expected B"

# 5a. A failed chattr fails the write.
d="$tmp/chattr-fails"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
set_osind "$d" 070000000000000000000000
if FAKE_CHATTR_FAIL=1 tool "$d" arm B; then
  fail "arm succeeded although chattr -i failed"
fi
grep -q 'immutable' "$d/err" || fail "a failed chattr: no reason on stderr: $(cat "$d/err")"

# 5b. A `chattr +i` that fails AFTER the write: the bit is written, so the arm
#     is committed and reports success. A failure here would leave an armed
#     capsule behind an install that RAUC marks failed.
d="$tmp/chattr-set-fails"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
set_osind "$d" 070000000000000000000000
FAKE_CHATTR_FAIL_SET=1 tool "$d" arm B ||
  fail "arm failed although only chattr +i failed, after the write: $(cat "$d/err")"
[ "$(osind "$d")" = 070000000400000000000000 ] || fail "arm with chattr +i failing: OsIndications is $(osind "$d")"
grep -q 'immutable' "$d/err" || fail "chattr +i failed without a warning on stderr: $(cat "$d/err")"
#     The same for clear-bit: the bit is cleared, so it succeeds.
FAKE_CHATTR_FAIL_SET=1 tool "$d" clear-bit ||
  fail "clear-bit failed although only chattr +i failed, after the write: $(cat "$d/err")"
[ "$(osind "$d")" = 070000000000000000000000 ] || fail "clear-bit with chattr +i failing: OsIndications is $(osind "$d")"

# 5c. The write needs no /tmp. The boot unit clears the bit before
#     sysinit.target, when /tmp may not be mounted. The scratch file goes to
#     the run directory (/run on a device) and is removed after the write.
d="$tmp/no-tmp"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
TMPDIR="$d/no-such-dir" tool "$d" arm B || fail "arm with no usable TMPDIR: exit $?: $(cat "$d/err")"
TMPDIR="$d/no-such-dir" tool "$d" clear-bit || fail "clear-bit with no usable TMPDIR: exit $?: $(cat "$d/err")"
[ "$(osind "$d")" = 070000000000000000000000 ] || fail "clear-bit with no usable TMPDIR: OsIndications is $(osind "$d")"
[ -z "$(ls -A "$d/run")" ] || fail "the write left files in the run directory: $(ls -A "$d/run")"

# 6. arm and disarm keep the other bits of OsIndications.
d="$tmp/bits"
device "$d"
set_osind "$d" 070000000100000000000080
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm B
[ "$(osind "$d")" = 070000000500000000000080 ] || fail "arm lost other bits: $(osind "$d")"
tool "$d" disarm || fail "disarm: exit $?: $(cat "$d/err")"
[ "$(osind "$d")" = 070000000100000000000080 ] || fail "disarm lost other bits: $(osind "$d")"
staged "$d" && fail "disarm left the capsule on the ESP"
[ "$(binding "$d")" = none ] || fail "disarm left the binding"

# 6a. disarm removes a stray capsule that another tool left, hidden or not.
#     UEFI would apply it at the next reboot that finds the bit set.
d="$tmp/stray"
device "$d"
mkdir -p "$d/esp/EFI/UpdateCapsule"
printf 'stray' > "$d/esp/EFI/UpdateCapsule/other.cap"
printf 'stray' > "$d/esp/EFI/UpdateCapsule/.hidden.cap"
tool "$d" disarm
[ -z "$(ls -A "$d/esp/EFI/UpdateCapsule")" ] ||
  fail "disarm kept a stray capsule: $(ls -A "$d/esp/EFI/UpdateCapsule")"

# 6b. clear-bit clears the bit and keeps the staged file and its binding.
d="$tmp/clear-bit"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm B
tool "$d" clear-bit || fail "clear-bit: exit $?: $(cat "$d/err")"
[ "$(osind "$d")" = 070000000000000000000000 ] || fail "clear-bit left the bit: $(osind "$d")"
tool "$d" is-staged B || fail "clear-bit removed the staged capsule"
tool "$d" armed-slot && fail "armed-slot: exit 0 after clear-bit"

# 7. A second stage of the same bundle converges, and a stage clears a capsule
#    an earlier install left armed. While the new copy is written, no armed
#    capsule may be on the ESP.
d="$tmp/restage"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm B
head -c 4096 /dev/urandom > "$d/bundle/tegra-bl.cap"
tool "$d" stage "$d/bundle/tegra-bl.cap" A || fail "restage: exit $?: $(cat "$d/err")"
cmp -s "$d/bundle/tegra-bl.cap" "$d/esp/EFI/UpdateCapsule/TEGRA_BL.Cap" ||
  fail "restage kept the earlier install's capsule"
[ "$(binding "$d")" = A ] || fail "restage kept the earlier binding: $(binding "$d")"
[ "$(osind "$d")" = 070000000000000000000000 ] || fail "restage left the earlier capsule armed: $(osind "$d")"

# 8. A power loss in the middle of a stage leaves a partial copy, outside the
#    directory UEFI reads, and maybe a binding with no capsule. is-staged does
#    not count either, and disarm removes both.
d="$tmp/powerloss"
device "$d"
mkdir -p "$d/esp/EFI"
head -c 100 "$d/bundle/tegra-bl.cap" > "$d/esp/EFI/.atc-capsule.part"
printf 'B' > "$d/esp/EFI/.atc-capsule.slot"
tool "$d" is-staged B && fail "is-staged counted a partial copy"
tool "$d" arm B && fail "arm accepted a partial copy"
tool "$d" disarm
[ ! -e "$d/esp/EFI/.atc-capsule.part" ] || fail "disarm kept a partial copy from a power loss"
[ "$(binding "$d")" = none ] || fail "disarm kept a binding from a power loss"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
cmp -s "$d/bundle/tegra-bl.cap" "$d/esp/EFI/UpdateCapsule/TEGRA_BL.Cap" ||
  fail "stage after a power loss did not converge"

# 8a. A capsule with no binding is not staged for any slot.
d="$tmp/no-binding"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
rm "$d/esp/EFI/.atc-capsule.slot"
tool "$d" is-staged B && fail "is-staged B: exit 0 for a capsule with no binding"
tool "$d" arm B && fail "arm B: exit 0 for a capsule with no binding"

# 8b. With the ESP unmounted, is-staged cannot tell: exit 2, not the 1 of
#     "none staged". set-primary refuses on it instead of switching without
#     the capsule.
d="$tmp/is-staged-unmounted"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
device_unmount "$d"
set +e
tool "$d" is-staged B
rc=$?
set -e
[ "$rc" = 2 ] || fail "is-staged with the ESP unmounted: exit $rc, expected 2"
grep -q 'cannot tell' "$d/err" || fail "is-staged with the ESP unmounted: no reason: $(cat "$d/err")"

# 9. An unusable OsIndications fails arm. Two guards enforce this: the read
#    of the variable, and the read-back after the write. The dd status check
#    is a third, so removing it alone leaves this case red.
d="$tmp/readonly"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
mkdir "$d/efivars/$OSIND_NAME"
if tool "$d" arm B; then
  fail "arm succeeded although OsIndications could not be written"
fi

# 9a. armed-slot needs both facts: the bound file and the bit.
d="$tmp/armed-slot"
device "$d"
tool "$d" armed-slot && fail "armed-slot: exit 0 on a clean device"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" armed-slot && fail "armed-slot: exit 0 with a file and no bit"
tool "$d" arm B
rm "$d/esp/EFI/UpdateCapsule/TEGRA_BL.Cap"
tool "$d" armed-slot && fail "armed-slot: exit 0 with the bit and no file"

# 9a'. With the ESP unmounted, the file is out of sight. With bit 2 set,
#      armed-slot cannot tell and exits 2, as is-staged does. With the bit
#      clear nothing can apply, so it exits 1 as before.
d="$tmp/armed-slot-unmounted"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm B
device_unmount "$d"
rc=0
tool "$d" armed-slot || rc=$?
[ "$rc" = 2 ] || fail "armed-slot with the bit set and the ESP unmounted: exit $rc, expected 2"
grep -q 'cannot tell' "$d/err" || fail "armed-slot with the ESP unmounted: no reason on stderr: $(cat "$d/err")"
set_osind "$d" 070000000000000000000000
rc=0
tool "$d" armed-slot || rc=$?
[ "$rc" = 1 ] || fail "armed-slot with the bit clear and the ESP unmounted: exit $rc, expected 1"

# 9b. A stage that fails still clears the bit first. An install that fails at
#     the hook then leaves nothing armed. This holds when an earlier install
#     armed a capsule and the ESP is now out of reach.
d="$tmp/stage-fails"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm B
device_unmount "$d"
if tool "$d" stage "$d/bundle/tegra-bl.cap" B; then
  fail "stage succeeded on an unmounted ESP"
fi
[ "$(osind "$d")" = 070000000000000000000000 ] || fail "a failed stage left the bit set: $(osind "$d")"

# 9c. disarm with the ESP out of reach clears the bit and succeeds. The file
#     it cannot reach applies nothing.
d="$tmp/disarm-unmounted"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm B
device_unmount "$d"
tool "$d" disarm || fail "disarm with the ESP unmounted: exit $?: $(cat "$d/err")"
[ "$(osind "$d")" = 070000000000000000000000 ] || fail "disarm left the bit set: $(osind "$d")"

# The bundle hook. It runs as RAUC runs it, for the rootfs slot B.
hook() {
  local d="$1"
  shift
  PATH="$tmp/bin:$PATH" CHATTR_LOG="$d/chattr.log" ATC_TEGRA_ESP="$d/esp" \
    ATC_EFIVARS_DIR="$d/efivars" ATC_MOUNTINFO="$d/mountinfo" ATC_TEGRA_CAPSULE_RUNDIR="$d/run" \
    ATC_HOOK_SOURCE_ROOT="$d/old" RAUC_SLOT_CLASS=rootfs RAUC_SLOT_BOOTNAME=B \
    RAUC_SLOT_MOUNT_POINT="$d/new" "$@" sh "$HOOK" slot-post-install > "$d/out" 2> "$d/err"
}

# A wrapper that runs the tool under sh. The hook needs an executable path.
printf '#!/bin/sh\nexec sh %q "$@"\n' "$TOOL" > "$tmp/atc-tegra-capsule"
chmod +x "$tmp/atc-tegra-capsule"

# 10. A bundle with a capsule: the hook stages it for the slot it runs for,
#     and does not arm it.
d="$tmp/hook-stage"
device "$d"
hook "$d" env ATC_TEGRA_CAPSULE="$tmp/atc-tegra-capsule" RAUC_BUNDLE_MOUNT_POINT="$d/bundle" ||
  fail "hook: exit $?: $(cat "$d/err")"
cmp -s "$d/bundle/tegra-bl.cap" "$d/esp/EFI/UpdateCapsule/TEGRA_BL.Cap" ||
  fail "the hook did not stage the bundle's capsule"
[ "$(binding "$d")" = B ] || fail "the hook bound the capsule to $(binding "$d"), expected B"
[ "$(osind "$d")" = absent ] || fail "the hook armed the capsule: $(osind "$d")"

# 10a. The hook for slot A binds the capsule to A.
d="$tmp/hook-stage-a"
device "$d"
hook "$d" env ATC_TEGRA_CAPSULE="$tmp/atc-tegra-capsule" RAUC_BUNDLE_MOUNT_POINT="$d/bundle" \
  RAUC_SLOT_BOOTNAME=A || fail "hook for A: exit $?: $(cat "$d/err")"
[ "$(binding "$d")" = A ] || fail "the hook for A bound the capsule to $(binding "$d")"

# 11. A Jetson bundle without a capsule is refused, and the hook first clears
#     a capsule an earlier install left armed.
d="$tmp/hook-clear"
device "$d"
tool "$d" stage "$d/bundle/tegra-bl.cap" B
tool "$d" arm B
rm "$d/bundle/tegra-bl.cap"
if hook "$d" env ATC_TEGRA_CAPSULE="$tmp/atc-tegra-capsule" RAUC_BUNDLE_MOUNT_POINT="$d/bundle"; then
  fail "the hook accepted a Jetson bundle with no capsule"
fi
grep -q 'needs a bundle with tegra-bl.cap' "$d/err" ||
  fail "the hook refused a bundle with no capsule, but not with its reason: $(cat "$d/err")"
staged "$d" && fail "the hook kept an earlier install's capsule"
[ "$(osind "$d")" = 070000000000000000000000 ] || fail "the hook left OsIndications armed: $(osind "$d")"

# 12. A bundle with a capsule on a device without the tool fails the install.
d="$tmp/hook-notool"
device "$d"
if hook "$d" env ATC_TEGRA_CAPSULE="$tmp/missing" RAUC_BUNDLE_MOUNT_POINT="$d/bundle"; then
  fail "the hook succeeded with a capsule and no tool"
fi
grep -q 'carries a UEFI capsule' "$d/err" ||
  fail "the hook with no tool did not say why: $(cat "$d/err")"

# 13. A failed stage fails the hook, so RAUC fails the install.
d="$tmp/hook-unmounted"
device "$d" unmounted
if hook "$d" env ATC_TEGRA_CAPSULE="$tmp/atc-tegra-capsule" RAUC_BUNDLE_MOUNT_POINT="$d/bundle"; then
  fail "the hook succeeded although the ESP is not mounted"
fi

# 13a. A crash after the hook staged and before set-primary armed: nothing is
#      armed, so a reboot applies nothing. The next install's hook replaces
#      the stale file with its own, and leaves it unarmed for its set-primary.
d="$tmp/crash-after-stage"
device "$d"
hook "$d" env ATC_TEGRA_CAPSULE="$tmp/atc-tegra-capsule" RAUC_BUNDLE_MOUNT_POINT="$d/bundle"
tool "$d" armed-slot && fail "the hook left a capsule armed"
head -c 4096 /dev/urandom > "$d/bundle/tegra-bl.cap"
hook "$d" env ATC_TEGRA_CAPSULE="$tmp/atc-tegra-capsule" RAUC_BUNDLE_MOUNT_POINT="$d/bundle" ||
  fail "the next install's hook: exit $?: $(cat "$d/err")"
cmp -s "$d/bundle/tegra-bl.cap" "$d/esp/EFI/UpdateCapsule/TEGRA_BL.Cap" ||
  fail "the next install kept the crashed install's capsule"
tool "$d" armed-slot && fail "the next install's hook armed the capsule"

# 13b. A crash after set-primary armed: the install is committed. The next
#      install's hook clears that bit before it writes, so it cannot apply
#      the old capsule with the new rootfs.
d="$tmp/crash-after-arm"
device "$d"
hook "$d" env ATC_TEGRA_CAPSULE="$tmp/atc-tegra-capsule" RAUC_BUNDLE_MOUNT_POINT="$d/bundle"
tool "$d" arm B
tool "$d" armed-slot || fail "arm after the hook: not armed"
head -c 4096 /dev/urandom > "$d/bundle/tegra-bl.cap"
hook "$d" env ATC_TEGRA_CAPSULE="$tmp/atc-tegra-capsule" RAUC_BUNDLE_MOUNT_POINT="$d/bundle"
tool "$d" armed-slot && fail "the next install's hook left the earlier capsule armed"

# 14. A bundle with no capsule on a device without the tool: the qemux86-64
#     path is unchanged.
d="$tmp/hook-qemu"
device "$d"
rm "$d/bundle/tegra-bl.cap"
hook "$d" env ATC_TEGRA_CAPSULE="$tmp/missing" RAUC_BUNDLE_MOUNT_POINT="$d/bundle" ||
  fail "the hook failed with no capsule and no tool: $(cat "$d/err")"

if [ "$failures" -gt 0 ]; then
  echo "atc-tegra-capsule_test: $failures failure(s)" >&2
  exit 1
fi
echo "atc-tegra-capsule_test: all checks passed"
