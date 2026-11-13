#!/usr/bin/env bash
# tests/fixtures/fake-nvbootctrl.sh
#
# A stateful fake of NVIDIA's `nvbootctrl` on L4T R36, and of the L4T
# launcher's slot choice at a reset. The tests of meta-atc's RAUC custom
# backend copy it to <dir>/bin/nvbootctrl. The state is in two directories
# next to <dir>/bin.
#
# <dir>/nvbootctrl/ holds the scratch register SR_RF and the boot chain, one
# file per value:
#   current       the slot this boot runs from (0 or 1)
#   active        BootChainFwNext, the slot the next boot loads (0 or 1)
#   magic         1 when SR_RF holds the 0xFACE magic, 0 when it is clear
#   retry_<n>     the SR_RF retry count field of slot n
#   retry_max     RootfsRetryCountMax
#   calls         one line per nvbootctrl call, the arguments as given
#   seq           the same calls, each with the UEFI variables at that moment
#
# <dir>/efivars/ is the efivarfs directory. The launcher and the backend share
# RootfsStatusSlotA and RootfsStatusSlotB there. Each file is a 4-byte
# attribute word, then the data. ff 00 00 00 is unbootable. Any other data is
# normal.
#
# It models only the R36 commands: dump-slots-info, get-current-slot,
# get-number-slots, set-active-boot-slot and verify, with `-t rootfs` or the
# default bootloader target. R35.2 removed mark-boot-successful,
# set-slot-as-unbootable and is-slot-bootable. A call to one of them fails
# here, as on a device. The dump-slots-info text is the form on NVIDIA's R36
# "Update and Redundancy" page.
#
# `verify` writes 0 to the SR_RF magic and to both count fields, and keeps the
# current slot. The R36.5.2 nvbootctrl binary does this: its verify loop
# clears rootfs_sr_magic, rootfs_retry_count_a and rootfs_retry_count_b.
#
# Two calls are for the tests only. The real tool does not have them.
#   fake-init <current> <active> <retry_0> <retry_1> [retry_max] [magic]
#   fake-boot [cold]
#
# fake-boot is the L4T launcher at a reset, as ValidateRootfsStatus in
# edk2-nvidia L4TRootfsValidation.c does it:
# - A cold boot (power on) first clears SR_RF.
# - With no magic, InitializeRootfsStatusReg sets the magic and gives each
#   slot 0 if its RootfsStatusSlot is unbootable, else RootfsRetryCountMax.
#   This is the only place the launcher reads the status variables.
# - With the magic set, a slot boots only on a non-zero count
#   (IsRootfsSlotBootable). The active slot boots and its count goes down by
#   one. A slot with a count of 0 is marked unbootable. The launcher then
#   sets BootChainFwNext to the other slot, clears SR_RF and resets, so the
#   next pass starts again with no magic.
# - Before any count, both slots unbootable means the recovery kernel
#   (IsValidRootfs). With the active slot at 0 and the other slot at 0 too,
#   the launcher marks both unbootable and boots the recovery kernel. Either
#   way SR_RF is cleared, and fake-boot exits 3.
#
# Knobs, read at each call:
#   FAKE_NVBOOTCTRL_FAIL=<command>     that command prints an error, exits 1
#   FAKE_NVBOOTCTRL_FAIL_TIMES=<n>     with FAKE_NVBOOTCTRL_FAIL, only its
#                                      first n calls fail; later calls work
#   FAKE_NVBOOTCTRL_DUMP=<text>        dump-slots-info prints this text
#   FAKE_NVBOOTCTRL_CURRENT=<text>     get-current-slot prints this text
set -euo pipefail

here="$(dirname "$0")"
state="$here/../nvbootctrl"
efivars="$here/../efivars"
mkdir -p "$state" "$efivars"
guid=781e084c-a330-417c-b678-38e696380cb9

get() { cat "$state/$1"; }
put() { printf '%s\n' "$2" > "$state/$1"; }
letter() { if [ "$1" = 0 ]; then echo A; else echo B; fi; }
status_file() { echo "$efivars/RootfsStatusSlot$(letter "$1")-$guid"; }
# Only 0xFF is unbootable, as the launcher compares it. A missing variable
# reads as normal here; the real launcher refuses to boot without it.
unbootable() {
  local f
  f="$(status_file "$1")"
  [ -e "$f" ] && [ "$(tail -c +5 "$f" | tr '\000\377' 'zf')" = fzzz ]
}
mark_unbootable() { printf '\007\000\000\000\377\000\000\000' > "$(status_file "$1")"; }
# The data bytes of a variable file in hex, or "-" when it does not exist.
data_hex() {
  if [ -e "$1" ]; then tail -c +5 "$1" | od -An -v -tx1 | tr -d ' \n'; else echo -; fi
}
usage() {
  echo "Invalid command: $*" >&2
  echo "Usage: nvbootctrl [-t <target>] <command>" >&2
  exit 1
}

case "${1:-}" in
  fake-init)
    put current "$2"
    put active "$3"
    put retry_0 "$4"
    put retry_1 "$5"
    put retry_max "${6:-1}"
    put magic "${7:-1}"
    exit 0
    ;;
  fake-boot)
    if [ "${2:-}" = cold ]; then put magic 0; fi
    for _ in 1 2 3; do
      if unbootable 0 && unbootable 1; then break; fi
      if [ "$(get magic)" = 0 ]; then
        for n in 0 1; do
          if unbootable "$n"; then put "retry_$n" 0; else put "retry_$n" "$(get retry_max)"; fi
        done
        put magic 1
      fi
      a="$(get active)"
      if [ "$(get "retry_$a")" -gt 0 ]; then
        put "retry_$a" "$(($(get "retry_$a") - 1))"
        put current "$a"
        exit 0
      fi
      mark_unbootable "$a"
      o=$((1 - a))
      if [ "$(get "retry_$o")" -eq 0 ]; then
        mark_unbootable "$o"
        break
      fi
      put active "$o"
      put magic 0
    done
    put magic 0
    echo "fake-boot: no bootable slot, the recovery kernel boots" >&2
    exit 3
    ;;
esac

# The test-only calls are not logged: calls and seq hold what the backend did.
printf '%s\n' "$*" >> "$state/calls"
atc_state="$(tail -c +5 "$efivars/AtcSlotState-02a2442b-c5ad-47ce-a9c6-41083c3b727d" 2> /dev/null || echo -)"
printf '%s | %s | A=%s B=%s\n' "$*" "$atc_state" \
  "$(data_hex "$(status_file 0)")" "$(data_hex "$(status_file 1)")" >> "$state/seq"

target=bootloader
if [ "${1:-}" = -t ]; then
  target="${2:-}"
  shift 2 || usage "$@"
fi
case "$target" in bootloader | rootfs) ;; *) usage "-t $target $*" ;; esac
cmd="${1:-}"

if [ "${FAKE_NVBOOTCTRL_FAIL:-}" = "$cmd" ]; then
  fails=$(($(cat "$state/fail-count" 2> /dev/null || echo 0) + 1))
  echo "$fails" > "$state/fail-count"
  if [ -z "${FAKE_NVBOOTCTRL_FAIL_TIMES:-}" ] || [ "$fails" -le "$FAKE_NVBOOTCTRL_FAIL_TIMES" ]; then
    echo "nvbootctrl: $cmd: failed to access the boot control data" >&2
    exit 1
  fi
fi

status_word() { if unbootable "$1"; then echo unbootable; else echo normal; fi; }

case "$cmd" in
  dump-slots-info)
    if [ -n "${FAKE_NVBOOTCTRL_DUMP+set}" ]; then
      printf '%s\n' "$FAKE_NVBOOTCTRL_DUMP"
      exit 0
    fi
    if [ "$target" = bootloader ]; then
      echo "Current version: 36.5.2"
      echo "Capsule update status: 0"
      echo "Current bootloader slot: $(letter "$(get current)")"
      echo "Active bootloader slot: $(letter "$(get active)")"
      echo "num_slots: 2"
      for n in 0 1; do
        echo "slot: $n,             status: $(status_word "$n")"
      done
    else
      echo "Current rootfs slot: $(letter "$(get current)")"
      echo "Active rootfs slot: $(letter "$(get active)")"
      echo "num_slots: 2"
      for n in 0 1; do
        echo "slot: $n,             retry_count: $(get "retry_$n"),             status: $(status_word "$n")"
      done
    fi
    ;;
  get-current-slot)
    if [ -n "${FAKE_NVBOOTCTRL_CURRENT+set}" ]; then
      printf '%s\n' "$FAKE_NVBOOTCTRL_CURRENT"
    else
      get current
    fi
    ;;
  get-number-slots) echo 2 ;;
  set-active-boot-slot)
    case "${2:-}" in
      0 | 1) put active "$2" ;;
      *) usage "$@" ;;
    esac
    ;;
  verify)
    put magic 0
    put retry_0 0
    put retry_1 0
    ;;
  *) usage "$@" ;;
esac
