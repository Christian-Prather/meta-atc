#!/usr/bin/env bash
# tests/atc-nvbootctrl-backend_test.sh
#
# Behavioural test for meta-atc's nvbootctrl slot backend on Tegra. It runs the
# real backend against tests/fixtures/fake-nvbootctrl.sh, a stateful fake of
# nvbootctrl on L4T R36, and a fake efivarfs directory. Each case sets the slot
# state and runs one verb. Then it checks the output and the exit status. Where
# the verb writes, it also checks the exact bytes of each UEFI variable and the
# exact nvbootctrl calls. The ordering cases read the fake's sequence log,
# which records the UEFI variables at each nvbootctrl call.
#
# The contract is the backend's verb table and the per-verb comments.
#
# Usage: atc-nvbootctrl-backend_test.sh <backend> <atc-slot-trial> <fake-nvbootctrl> <atc-tegra-capsule>
set -euo pipefail

usage="usage: atc-nvbootctrl-backend_test.sh <backend> <atc-slot-trial> <fake-nvbootctrl> <atc-tegra-capsule>"
BACKEND="${1:?$usage}"
TRIAL_WRAPPER="${2:?$usage}"
FAKE="${3:?$usage}"
CAPSULE_TOOL="${4:?$usage}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$FAKE" "$tmp/bin/nvbootctrl"
# The fake chattr records each call in the fake's sequence log.
# FAKE_CHATTR_FAIL makes it fail. FAKE_CHATTR_FAIL_SET makes only `chattr +i`
# fail. FAKE_CHATTR_CLOBBER_SET makes `chattr +i` write the value 1 to the
# variable and then fail, so the read-back differs from the write.
cat > "$tmp/bin/chattr" << 'EOF'
#!/bin/sh
printf 'chattr %s\n' "$*" >> "$(dirname "$0")/../nvbootctrl/seq"
[ -z "${FAKE_CHATTR_FAIL:-}" ] || exit 1
[ "$1" = +i ] || exit 0
if [ -n "${FAKE_CHATTR_CLOBBER_SET:-}" ]; then
  printf '\007\000\000\000\001\000\000\000' > "$2"
  exit 1
fi
[ -z "${FAKE_CHATTR_FAIL_SET:-}" ]
EOF
# The backend requests a reboot through ATC_NVBOOTCTRL_REBOOT. The test points
# it at a fake that only records the call, so no case can reboot the host.
# A fake systemctl backs that up if the variable is ever not read.
cat > "$tmp/bin/fake-reboot" << 'EOF'
#!/bin/sh
printf 'reboot %s\n' "$*" >> "$(dirname "$0")/../nvbootctrl/seq"
EOF
cp "$tmp/bin/fake-reboot" "$tmp/bin/systemctl"
# A fake tail passes through to the real one. With FAKE_TAIL_FAIL_AFTER=<n> set,
# each read of a RootfsStatusSlot variable after the first n fails, as an
# efivarfs read error would.
real_tail="$(command -v tail)"
cat > "$tmp/bin/tail" << EOF
#!/bin/sh
case "\$*" in
  *RootfsStatusSlot*)
    if [ -n "\${FAKE_TAIL_FAIL_AFTER:-}" ]; then
      ctr="\$(dirname "\$0")/../tail-reads"
      n=\$(( \$(cat "\$ctr" 2> /dev/null || echo 0) + 1 ))
      echo "\$n" > "\$ctr"
      if [ "\$n" -gt "\$FAKE_TAIL_FAIL_AFTER" ]; then
        echo "tail: read error" >&2
        exit 1
      fi
    fi
    ;;
esac
exec "$real_tail" "\$@"
EOF
chmod +x "$tmp/bin/nvbootctrl" "$tmp/bin/chattr" "$tmp/bin/fake-reboot" "$tmp/bin/systemctl" "$tmp/bin/tail"
export ATC_NVBOOTCTRL_REBOOT="$tmp/bin/fake-reboot"
state="$tmp/nvbootctrl"
efi="$tmp/efivars"
NV_GUID=781e084c-a330-417c-b678-38e696380cb9
ATC_VAR="$efi/AtcSlotState-02a2442b-c5ad-47ce-a9c6-41083c3b727d"
export ATC_EFIVARS_DIR="$efi"
export ATC_NVBOOTCTRL_LOCK="$tmp/lock"
# The boot unit's done marker. A reset removes it, as a boot clears /run.
export ATC_NVBOOTCTRL_BOOT_DONE="$tmp/boot.done"
# No capsule tool unless a case installs one, so the device's own path never
# reaches a case.
export ATC_TEGRA_CAPSULE="$tmp/no-capsule-tool"
failures=0

fail_case() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# ── Fixture: the slot state before a call ──────────────────────────────────

# $1 RootfsStatusSlot bootname, $2 normal or unbootable.
put_status() {
  if [ "$2" = normal ]; then
    printf '\007\000\000\000\000\000\000\000' > "$efi/RootfsStatusSlot$1-$NV_GUID"
  else
    printf '\007\000\000\000\377\000\000\000' > "$efi/RootfsStatusSlot$1-$NV_GUID"
  fi
}

# $1 the AtcSlotState text, or "missing".
put_state() {
  if [ "$1" = missing ]; then
    rm -f "$ATC_VAR"
  else
    printf '\007\000\000\000%s' "$1" > "$ATC_VAR"
  fi
}

# $1 booted (A|B) $2 active (A|B) $3 status A $4 status B $5 AtcSlotState.
# Both retry counts start at 1 with the SR_RF magic set, so each partner can
# boot. A verify shows up as a cleared magic.
init() {
  local cur=0 act=0
  if [ "$1" = B ]; then cur=1; fi
  if [ "$2" = B ]; then act=1; fi
  rm -rf "$efi" "$state"
  rm -f "$ATC_NVBOOTCTRL_BOOT_DONE"
  mkdir -p "$efi"
  "$tmp/bin/nvbootctrl" fake-init "$cur" "$act" 1 1
  put_status A "$3"
  put_status B "$4"
  put_state "$5"
  : > "$state/calls"
  : > "$state/seq"
}

# ── Running the backend ────────────────────────────────────────────────────

# Sets out, err and status. Environment assignments before the call reach the
# fake, for example FAKE_NVBOOTCTRL_FAIL. Every call has a time limit, so a
# mutant that retries forever fails the case and does not hang the suite.
# RAUC's writing verbs run after the boot unit, so set-state and set-primary
# first write the boot unit's done marker. NO_BOOT_DONE=1 leaves it out.
backend() {
  case "${1:-}" in
    set-state | set-primary)
      [ -n "${NO_BOOT_DONE:-}" ] || : > "$ATC_NVBOOTCTRL_BOOT_DONE"
      ;;
  esac
  set +e
  PATH="$tmp/bin:$PATH" timeout 30 sh "$BACKEND" "$@" > "$tmp/out" 2> "$tmp/err"
  status=$?
  set -e
  out="$(cat "$tmp/out")"
  err="$(cat "$tmp/err")"
}

# backend with a time limit: $1 seconds, then the verb and its arguments.
backend_timeout() {
  local limit="$1"
  shift
  set +e
  PATH="$tmp/bin:$PATH" timeout "$limit" sh "$BACKEND" "$@" > "$tmp/out" 2> "$tmp/err"
  status=$?
  set -e
  out="$(cat "$tmp/out")"
  err="$(cat "$tmp/err")"
}

# The launcher at a reset, for the scenario cases.
reset_board() {
  rm -f "$ATC_NVBOOTCTRL_BOOT_DONE"
  "$tmp/bin/nvbootctrl" fake-boot "$@" || fail_case "fake-boot $*: no slot to boot"
}

# ── Assertions ────────────────────────────────────────────────────────────

# $1 case name, $2 expected stdout. The call must exit 0.
expect_ok() {
  if [ "$status" != 0 ]; then
    fail_case "$1: exit $status, expected 0. stderr: $err"
  elif [ "$out" != "$2" ]; then
    fail_case "$1: stdout '$out', expected '$2'"
  else
    echo "ok: $1"
  fi
}

# $1 case name, $2 a fixed string the last stderr line must contain. The call
# must exit non-zero and print nothing on stdout, so RAUC reads no answer. The
# last stderr line is the backend's reason. nvbootctrl's own error can precede
# it.
expect_refused() {
  local last
  last="$(tail -n 1 <<< "$err")"
  if [ "$status" = 0 ]; then
    fail_case "$1: exit 0, expected a refusal. stdout: '$out'"
  elif [ -n "$out" ]; then
    fail_case "$1: refused, but stdout is '$out'"
  elif [ "${last%%:*}" != atc-nvbootctrl-backend ]; then
    fail_case "$1: the last stderr line is not the backend's own: '$err'"
  elif ! grep -qF -- "$2" <<< "$last"; then
    fail_case "$1: stderr '$last' does not contain '$2'"
  else
    echo "ok: $1"
  fi
}

hex() { od -An -v -tx1 "$1" | tr -d ' \n'; }

# $1 case name, $2 bootname, $3 normal or unbootable: the exact bytes.
expect_status() {
  local want=0700000000000000 got
  if [ "$3" = unbootable ]; then want=07000000ff000000; fi
  got="$(hex "$efi/RootfsStatusSlot$2-$NV_GUID")"
  [ "$got" = "$want" ] || fail_case "$1: RootfsStatusSlot$2 is $got, expected $want"
}

# $1 case name, $2 the AtcSlotState text: the attribute word, then exactly
# that text, with no newline. "missing" expects no variable.
expect_state() {
  local got want
  if [ "$2" = missing ]; then
    [ ! -e "$ATC_VAR" ] || fail_case "$1: AtcSlotState exists: $(hex "$ATC_VAR"), expected none"
    return 0
  fi
  [ -e "$ATC_VAR" ] || {
    fail_case "$1: AtcSlotState is missing, expected '$2'"
    return 0
  }
  got="$(hex "$ATC_VAR")"
  want="07000000$(printf '%s' "$2" | od -An -v -tx1 | tr -d ' \n')"
  [ "$got" = "$want" ] || fail_case "$1: AtcSlotState is $got, expected $want ('$2')"
}

# $1 case name, $2 the nvbootctrl calls, one per line.
expect_calls() {
  local got
  got="$(cat "$state/calls")"
  [ "$got" = "$2" ] || fail_case "$1: nvbootctrl calls were '$got', expected '$2'"
}

# $1 case name, $2 the file under the fake's state, $3 the expected value.
expect_fake() {
  local got
  got="$(cat "$state/$2")"
  [ "$got" = "$3" ] || fail_case "$1: fake $2 is '$got', expected '$3'"
}

# $1 case name, $2 an exact line of the sequence log.
expect_seq() {
  grep -qxF -- "$2" "$state/seq" || fail_case "$1: no sequence line '$2' in: $(cat "$state/seq")"
}

GET_CURRENT="-t rootfs get-current-slot"
STEADY_A="steady=A trial=none ok=0"

# ── The boot unit and the recipe ──────────────────────────────────────────
# Both sit next to the backend in the layer.
UNIT="$(dirname "$BACKEND")/atc-tegra-slot-boot.service"
RECIPE="$(dirname "$BACKEND")/../atc-nvbootctrl_1.0.bb"

# $1 case name, $2 file, $3 an exact line the file must hold.
expect_line() {
  if grep -qxF -- "$3" "$2"; then
    echo "ok: $1"
  else
    fail_case "$1: $2 has no line '$3'"
  fi
}

expect_line "the boot unit wants setup-nv-boot-control" "$UNIT" "Wants=setup-nv-boot-control.service"
expect_line "the boot unit runs after setup-nv-boot-control" "$UNIT" "After=setup-nv-boot-control.service"
expect_line "the boot unit has a start timeout" "$UNIT" "TimeoutStartSec=60"
expect_line "the boot unit restarts on failure" "$UNIT" "Restart=on-failure"
expect_line "the boot unit has no start limit" "$UNIT" "StartLimitIntervalSec=0"
expect_line "the boot unit stops on a give-up and after a revert" "$UNIT" "RestartPreventExitStatus=3 4"
if grep -q '^StartLimitBurst=' "$UNIT"; then
  fail_case "the boot unit sets StartLimitBurst, so its restarts can stop"
else
  echo "ok: the boot unit sets no StartLimitBurst"
fi
# shellcheck disable=SC2016  # ${PN} is BitBake text, not shell
expect_line "the package needs setup-nv-boot-control-service and cmp" "$RECIPE" \
  'RDEPENDS:${PN} = "tegra-redundant-boot-base setup-nv-boot-control-service util-linux-flock e2fsprogs diffutils"'

# ── The fake launcher's recovery path ─────────────────────────────────────
# Both slots 0xFF boots the recovery kernel before any count is read.
init A A unbootable unbootable "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 0 0 1 1 1 1
if "$tmp/bin/nvbootctrl" fake-boot 2> /dev/null; then
  fail_case "fake launcher: both slots 0xFF booted a slot"
else
  echo "ok: fake launcher: both slots 0xFF boot the recovery kernel"
fi

# Both counts 0 under the magic: both slots end 0xFF.
init A A normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 0 0 0 0 1 1
if "$tmp/bin/nvbootctrl" fake-boot 2> /dev/null; then
  fail_case "fake launcher: both counts 0 booted a slot"
else
  echo "ok: fake launcher: both counts 0 boot the recovery kernel"
fi
expect_status "fake launcher: recovery marks A" A unbootable
expect_status "fake launcher: recovery marks B" B unbootable

# ── get-current ───────────────────────────────────────────────────────────
init B A normal normal "$STEADY_A"
backend get-current
expect_ok "get-current names the booted slot B while A is active" B
expect_calls "get-current" "$GET_CURRENT"

init A B normal normal "$STEADY_A"
backend get-current
expect_ok "get-current names the booted slot A while B is active" A

# ── get-primary ───────────────────────────────────────────────────────────
init A B normal normal "$STEADY_A"
backend get-primary
expect_ok "get-primary names the active slot B while A is booted" B
expect_calls "get-primary" "dump-slots-info"

init B A normal normal "$STEADY_A"
backend get-primary
expect_ok "get-primary names the active slot A while B is booted" A

# ── get-state ─────────────────────────────────────────────────────────────
init A A normal unbootable "$STEADY_A"
backend get-state B
expect_ok "get-state of an unbootable slot is bad" bad

init A A unbootable normal "$STEADY_A"
backend get-state A
expect_ok "get-state of the booted slot, unbootable, is bad" bad

init A A normal normal "$STEADY_A"
backend get-state B
expect_ok "get-state of a normal slot that is not booted is good" good
expect_calls "get-state B" "$GET_CURRENT"

init B B normal normal "steady=A trial=B ok=0"
backend get-state B
expect_ok "get-state of the booted trial, not confirmed, is bad" bad

init B B normal normal "steady=A trial=B ok=1"
backend get-state B
expect_ok "get-state of the booted trial, confirmed, is good" good

init A A normal normal "steady=A trial=B ok=0"
backend get-state A
expect_ok "get-state of the booted steady slot is good" good

# ── set-state bad ─────────────────────────────────────────────────────────
# The verb reads the booted slot, the state and the active slot first. Then it
# verifies, then it writes.
init A A normal normal "$STEADY_A"
backend set-state B bad
expect_ok "set-state B bad, B not active" ""
expect_status "set-state B bad" B unbootable
expect_status "set-state B bad" A normal
expect_calls "set-state B bad, B not active" "$GET_CURRENT
dump-slots-info
verify"
expect_fake "set-state B bad, B not active" active 0
expect_seq "set-state B bad verifies before the status write" \
  "verify | steady=A trial=none ok=0 | A=00000000 B=00000000"
expect_seq "a write clears the immutable flag first" "chattr -i $efi/RootfsStatusSlotB-$NV_GUID"
expect_seq "a write sets the immutable flag again" "chattr +i $efi/RootfsStatusSlotB-$NV_GUID"

# A failed read or verify refuses with no write.
init A A normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=verify backend set-state B bad
expect_refused "set-state B bad when verify fails is refused" "nvbootctrl verify failed"
expect_status "set-state B bad with a failed verify writes nothing" B normal

init A A normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=get-current-slot backend set-state B bad
expect_refused "set-state B bad when get-current-slot fails is refused" "get-current-slot failed"
expect_status "set-state B bad with a failed get-current-slot writes nothing" B normal

init A A normal normal "steady=C trial=none ok=0"
backend set-state B bad
expect_refused "set-state B bad with an unusable AtcSlotState is refused" "cannot read"
expect_status "set-state B bad with an unusable AtcSlotState writes nothing" B normal

# The boot unit's verify did not run: A has spent its count under the magic.
# A failed verify in set-state B bad writes nothing, so a warm reset falls
# back to B, which still holds an image. It does not boot the recovery kernel.
init A A normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 0 0 0 1 1 1
FAKE_NVBOOTCTRL_FAIL=verify backend set-state B bad
expect_refused "scenario stale verify: set-state B bad is refused" "nvbootctrl verify failed"
reset_board
expect_fake "scenario stale verify: a warm reset boots B, not the recovery kernel" current 1

# Same start, verify works: a warm reset must not fail over to B, which RAUC
# writes.
init A A normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 0 0 0 1 1 1
backend set-state B bad
expect_ok "scenario mark bad: set-state B bad" ""
reset_board
expect_fake "scenario mark bad: a warm reset boots A, not the slot marked bad" current 0
expect_status "scenario mark bad: A stays normal" A normal

# atcd's reject of the booted trial B: switch to A, no verify.
init B B normal normal "steady=A trial=B ok=0"
backend set-state B bad
expect_ok "set-state B bad, B active, A normal" ""
expect_status "set-state B bad, B active" B unbootable
expect_calls "set-state B bad, B active" "$GET_CURRENT
dump-slots-info
set-active-boot-slot 0"
expect_fake "set-state B bad, B active" active 0
expect_seq "set-state B bad writes the status before the switch" \
  "set-active-boot-slot 0 | steady=A trial=B ok=0 | A=00000000 B=ff000000"
backend set-state B bad
expect_ok "set-state B bad a second time" ""
expect_status "set-state B bad twice" B unbootable
expect_fake "set-state B bad twice" active 0

# B failed over and the boot unit's write failed, so the state still names A
# as steady. RAUC now rewrites A: the state must stop naming A as steady.
init B B unbootable normal "$STEADY_A"
backend set-state A bad
expect_ok "set-state A bad after an unrecorded fall back to B" ""
expect_state "set-state A bad makes the booted B steady" "steady=B trial=none ok=0"
expect_status "set-state A bad after the fall back" A unbootable

# The invariant: other(X) is a confirmed bootable slot. Three triggers.
# 1. other(X) is unbootable.
init B B unbootable normal "steady=A trial=B ok=0"
backend set-state B bad
expect_refused "set-state B bad, A unbootable, is refused" \
  "refusing to mark the last bootable slot bad: slot A is unbootable"
expect_status "the refused set-state B bad writes nothing" B normal
expect_calls "the refused set-state B bad does not switch" "$GET_CURRENT
dump-slots-info"
expect_fake "set-state B bad, A unbootable" active 1

# 1b. A switch that failed left B 0xFF and B active. Marking A bad then
# leaves no bootable slot.
init B B normal normal "steady=A trial=B ok=0"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
FAKE_NVBOOTCTRL_FAIL=set-active-boot-slot backend set-state B bad
expect_refused "scenario failed switch: set-state B bad is refused" "set-active-boot-slot 0 failed"
backend set-state A bad
expect_refused "scenario failed switch: set-state A bad is refused" "slot B is unbootable"
expect_status "scenario failed switch: A stays normal" A normal
reset_board
expect_fake "scenario failed switch: a warm reset boots A" current 0

# 2. other(X) is the booted trial, not confirmed. The trial deadline's warm
# reboot must still find A.
init B B normal normal "steady=A trial=B ok=0"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
backend set-state A bad
expect_refused "set-state A bad from an unconfirmed trial of B is refused" \
  "slot B is booted but not confirmed"
expect_calls "the refused set-state A bad does not verify" "$GET_CURRENT
dump-slots-info"
expect_status "the refused set-state A bad writes nothing" A normal
reset_board
expect_fake "scenario unconfirmed trial: the deadline's warm reboot falls back to A" current 0

# 3. other(X) is normal, but neither steady nor booted.
init A A normal normal "$STEADY_A"
backend set-state A bad
expect_refused "set-state A bad with B neither steady nor booted is refused" \
  "slot B is neither steady nor booted"
expect_status "the refused set-state A bad, B not steady, writes nothing" A normal

# ── set-state good ────────────────────────────────────────────────────────
init B B normal normal "steady=A trial=B ok=0"
backend set-state B good
expect_ok "set-state B good confirms the booted trial" ""
expect_state "set-state B good on the trial" "steady=A trial=B ok=1"
expect_status "set-state B good on the trial" B normal
expect_calls "set-state B good on the trial" "$GET_CURRENT
verify"
expect_fake "set-state B good clears the SR_RF magic" magic 0
expect_seq "set-state B good writes ok=1 before verify" \
  "verify | steady=A trial=B ok=1 | A=00000000 B=00000000"
backend set-state B good
expect_ok "set-state B good a second time" ""
expect_state "set-state B good twice" "steady=A trial=B ok=1"

init B B normal normal "steady=A trial=B ok=0"
FAKE_NVBOOTCTRL_FAIL=verify backend set-state B good
expect_refused "set-state good when verify fails is refused" "nvbootctrl verify failed"
expect_state "a failed verify writes ok=0 back" "steady=A trial=B ok=0"

init A A normal normal "$STEADY_A"
backend set-state A good
expect_ok "set-state A good on the steady slot" ""
expect_state "set-state A good on the steady slot" "$STEADY_A"
expect_calls "set-state A good on the steady slot verifies" "$GET_CURRENT
verify"

init B B normal unbootable "$STEADY_A"
backend set-state B good
expect_ok "set-state B good on a booted slot that is neither steady nor trial" ""
expect_status "set-state B good, neither steady nor trial" B normal
expect_state "set-state B good, neither steady nor trial" "$STEADY_A"
expect_calls "set-state B good, neither steady nor trial, does only the status write" "$GET_CURRENT"

init A A normal unbootable "$STEADY_A"
backend set-state B good
expect_ok "set-state B good on a slot that is not booted" ""
expect_status "set-state B good, not booted" B normal
expect_state "set-state B good, not booted" "$STEADY_A"
expect_calls "set-state B good, not booted, does not verify" "$GET_CURRENT"

# ── set-primary ───────────────────────────────────────────────────────────
# RAUC calls set-state B bad before the write, so B is unbootable here.
init A A normal unbootable "$STEADY_A"
backend set-primary B
expect_ok "set-primary B starts a trial of B" ""
expect_state "set-primary B" "steady=A trial=B ok=0"
expect_status "set-primary B clears the status" B normal
expect_calls "set-primary B" "$GET_CURRENT
set-active-boot-slot 1
verify"
expect_fake "set-primary B" active 1
expect_fake "set-primary B clears the SR_RF magic" magic 0
expect_seq "set-primary B switches after the state write, with B still 0xFF" \
  "set-active-boot-slot 1 | steady=A trial=B ok=0 | A=00000000 B=ff000000"
expect_seq "set-primary B verifies after the switch and the status write" \
  "verify | steady=A trial=B ok=0 | A=00000000 B=00000000"
backend set-primary B
expect_ok "set-primary B a second time" ""
expect_state "set-primary B twice" "steady=A trial=B ok=0"
expect_fake "set-primary B twice" active 1

init B B normal normal "steady=A trial=B ok=1"
backend set-primary A
expect_ok "set-primary A after a confirm of B" ""
expect_state "set-primary folds the pending confirm into steady" "steady=B trial=A ok=0"
expect_calls "set-primary A from the confirmed B verifies" "$GET_CURRENT
set-active-boot-slot 0
verify"

init B B normal normal "steady=A trial=B ok=0"
backend set-primary A
expect_ok "set-primary A from an unconfirmed trial of B" ""
expect_state "mark-active of the steady slot during a trial writes no trial" "$STEADY_A"
expect_seq "an aborted trial keeps its state until the switch" \
  "set-active-boot-slot 0 | steady=A trial=B ok=0 | A=00000000 B=00000000"
expect_calls "set-primary from an unconfirmed trial does not verify" "$GET_CURRENT
set-active-boot-slot 0"

# An aborted trial whose switch failed, then a cold boot: the chain is still
# on B. B must stay an unconfirmed trial, not become steady.
init B B normal normal "steady=A trial=B ok=0"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
FAKE_NVBOOTCTRL_FAIL=set-active-boot-slot backend set-primary A
expect_refused "scenario abort: set-primary A with a failed switch" "set-active-boot-slot 0 failed"
expect_state "scenario abort: the state still names the trial of B" "steady=A trial=B ok=0"
backend trial-slot
expect_ok "scenario abort: trial-slot still names B" B
reset_board cold
expect_fake "scenario abort: the cold boot boots B again" current 1
backend boot
expect_ok "scenario abort: the cold boot leaves B on trial" \
  "atc-nvbootctrl-backend: boot: trial in flight, slot B"
expect_state "scenario abort: B is not made steady" "steady=A trial=B ok=0"

# S1: B failed over and the boot unit's write failed, so the state still says
# steady=A while A is 0xFF and B runs. An install of A must start a trial of
# A over B, with B as the steady slot.
init B B unbootable normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 1 1 0 0 1 0
backend trial-slot
expect_ok "scenario failed over: no trial" none
backend set-state A bad
expect_ok "scenario failed over: set-state A bad" ""
backend set-primary A
expect_ok "scenario failed over: set-primary A" ""
expect_state "scenario failed over: B is steady, A on trial" "steady=B trial=A ok=0"
reset_board
expect_fake "scenario failed over: A boots its trial" current 0
backend boot
expect_ok "scenario failed over: the trial of A is in flight" "atc-nvbootctrl-backend: boot: trial in flight, slot A"
backend trial-slot
expect_ok "scenario failed over: trial-slot names A" A
backend get-state A
expect_ok "scenario failed over: A reads bad until confirmed" bad

init A A normal normal "steady=A trial=B ok=0"
backend set-primary A
expect_ok "set-primary of the booted slot" ""
expect_state "set-primary of the booted slot is mark-active" "$STEADY_A"
expect_calls "set-primary A while A is booted verifies" "$GET_CURRENT
verify
set-active-boot-slot 0"

init B B normal normal "steady=A trial=B ok=0"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
backend set-primary B
expect_ok "mark-active of the booted trial B" ""
expect_state "mark-active of the booted trial B makes it steady" "steady=B trial=none ok=0"
expect_seq "mark-active verifies before the state says steady" \
  "verify | steady=A trial=B ok=0 | A=00000000 B=00000000"
reset_board
expect_fake "mark-active of B lasts a warm reset" current 1

init B B normal normal "steady=A trial=B ok=0"
FAKE_NVBOOTCTRL_FAIL=verify backend set-primary B
expect_refused "mark-active when verify fails is refused" "slot B is not made steady"
expect_state "a refused mark-active writes nothing" "steady=A trial=B ok=0"

init A A normal normal missing
backend set-primary B
expect_refused "set-primary with no AtcSlotState is refused" "cannot read"
expect_fake "set-primary with no AtcSlotState does not switch" active 0
expect_calls "set-primary with no AtcSlotState" "$GET_CURRENT"

init A A normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=set-active-boot-slot backend set-primary B
expect_refused "set-primary when set-active-boot-slot fails is refused" \
  "nvbootctrl set-active-boot-slot 1 failed"

init A A normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=verify backend set-primary B
expect_refused "set-primary when verify fails is refused" "nvbootctrl verify failed"
expect_calls "set-primary with a failed verify" "$GET_CURRENT
set-active-boot-slot 1
verify"

# R3-A: set-primary B fails, at the switch or at the verify, after RAUC wrote
# an unconfirmed image into B. A later reboot, then an early-boot panic on A,
# must not make B steady and must not reach the recovery kernel.
for fault in set-active-boot-slot verify; do
  init A A normal normal "$STEADY_A"
  "$tmp/bin/nvbootctrl" fake-init 0 0 0 0 1 0
  backend set-state B bad
  expect_ok "R3-A $fault: set-state B bad" ""
  FAKE_NVBOOTCTRL_FAIL=$fault backend set-primary B
  expect_refused "R3-A $fault: set-primary B fails" "failed"
  reset_board
  backend boot
  # A warm reboot, then a panic before the boot unit. B is 0xFF, so the panic
  # may reach the recovery kernel: an early panic on the only bootable slot is
  # the cost the design records. B must never become steady.
  reset_board
  "$tmp/bin/nvbootctrl" fake-boot 2> /dev/null || true
  backend boot
  if [ "$(tail -c +5 "$ATC_VAR")" = "steady=B trial=none ok=0" ]; then
    fail_case "R3-A $fault: the unconfirmed B became steady"
  else
    echo "ok: R3-A $fault: the unconfirmed B is not steady"
  fi
done

# R3-B: set-primary B stops after the switch and the status write (the verify
# fails, as at a power cut). A cold boot boots the trial of B, an early panic
# falls back to A, and the deadline's warm reboot stays on A.
init A A normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 0 0 0 0 1 0
backend set-state B bad
FAKE_NVBOOTCTRL_FAIL=verify backend set-primary B
reset_board cold
reset_board
expect_fake "R3-B: the early panic falls back to A" current 0
backend boot
expect_ok "R3-B: the boot unit clears the spent trial of B" \
  "atc-nvbootctrl-backend: boot: the trial of B is spent, slot A is steady"
expect_state "R3-B: A stays steady" "$STEADY_A"
reset_board
expect_fake "R3-B: the next warm reboot stays on A" current 0

# ── trial-slot, and the atc-slot-trial wrapper ─────────────────────────────
init B B normal normal "steady=A trial=B ok=0"
backend trial-slot
expect_ok "trial-slot names an unconfirmed trial" B
expect_calls "trial-slot reads only the booted slot" "$GET_CURRENT"

init A A normal normal "steady=A trial=B ok=0"
backend trial-slot
expect_ok "trial-slot of a recorded trial that is not booted is none" none

# A set-primary whose switch failed leaves trial=B recorded and A booted. It
# must not block the next install.
init A A normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=set-active-boot-slot backend set-primary B
expect_refused "set-primary B with a failed switch" "set-active-boot-slot 1 failed"
backend trial-slot
expect_ok "trial-slot after a failed switch is none" none
backend set-primary B
expect_ok "a second set-primary B after a failed switch" ""
expect_fake "the second set-primary B switches" active 1

init B B normal normal "steady=A trial=B ok=1"
backend trial-slot
expect_ok "trial-slot of a confirmed trial is none" none

init A A normal normal "$STEADY_A"
backend trial-slot
expect_ok "trial-slot with no trial is none" none

init A A normal normal missing
backend trial-slot
expect_refused "trial-slot with no AtcSlotState is refused" "cannot read"

# The wrapper execs the backend, so the backend needs its own +x here.
init B B normal normal "steady=A trial=B ok=0"
cp "$BACKEND" "$tmp/backend"
chmod +x "$tmp/backend"
set +e
wrapper_out="$(PATH="$tmp/bin:$PATH" ATC_NVBOOTCTRL_BACKEND="$tmp/backend" sh "$TRIAL_WRAPPER")"
wrapper_status=$?
set -e
if [ "$wrapper_status" = 0 ] && [ "$wrapper_out" = B ]; then
  echo "ok: atc-slot-trial runs trial-slot"
else
  fail_case "atc-slot-trial: exit $wrapper_status, stdout '$wrapper_out', expected B"
fi

# ── boot: one case per row of the table ────────────────────────────────────
init B B normal normal missing
backend boot
expect_ok "boot row 'first boot', no variable" "atc-nvbootctrl-backend: boot: first boot, slot B is steady"
expect_state "boot row 'first boot'" "steady=B trial=none ok=0"
expect_calls "boot row 'first boot'" "$GET_CURRENT
verify"

init A A normal normal "steady=C trial=none ok=0"
backend boot
expect_refused "boot with an unparsable variable is refused" "requested a reboot to revert to slot B"
expect_state "boot with an unparsable variable writes nothing" "steady=C trial=none ok=0"
expect_calls "boot with an unparsable variable does not verify" "$GET_CURRENT
-t rootfs dump-slots-info
set-active-boot-slot 1"
expect_status "boot with an unparsable variable marks A unbootable" A unbootable
expect_seq "boot with an unparsable variable requests the reverting reboot" "reboot "

init A A normal normal "steady=A trial=none ok=1"
backend boot
expect_refused "boot with ok=1 and no trial is refused" "requested a reboot to revert to slot B"
expect_state "boot with ok=1 and no trial writes nothing" "steady=A trial=none ok=1"

# A corrupt AtcSlotState on B, with A bootable: no write, and the unit
# requests the reboot that reverts to A. On A, B is now unbootable, so A is
# the last bootable slot. The unit verifies A and makes it steady, so A stays
# up after a warm reset.
init B B normal normal "steady=C trial=B ok=0"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
backend boot
expect_refused "scenario corrupt: on B with A bootable, boot is refused" \
  "requested a reboot to revert to slot A"
expect_state "scenario corrupt: on B with A bootable, nothing is written" "steady=C trial=B ok=0"
expect_seq "scenario corrupt: the unit requests the reverting reboot" "reboot "
reset_board
expect_fake "scenario corrupt: the warm reset reverts to A" current 0
expect_status "scenario corrupt: B is now unbootable" B unbootable
backend boot
expect_ok "scenario corrupt: on A, the last bootable slot, the state is rewritten" \
  "atc-nvbootctrl-backend: boot: corrupt state rewritten, slot A is steady"
expect_state "scenario corrupt: A is steady" "$STEADY_A"
reset_board
expect_fake "scenario corrupt: A stays up after a warm reset" current 0
expect_status "scenario corrupt: A stays normal" A normal

# S5: a corrupt state on the steady slot A, B bootable. The boot unit
# requests the reverting reboot. An install that marks B bad first must write
# nothing, so that reboot reaches B and not the recovery kernel.
init A A normal normal "steady=C trial=none ok=0"
"$tmp/bin/nvbootctrl" fake-init 0 0 0 1 1 1
backend boot
expect_refused "scenario corrupt steady: boot is refused" "requested a reboot to revert to slot B"
backend set-state B bad
expect_refused "scenario corrupt steady: set-state B bad is refused" "cannot read"
expect_status "scenario corrupt steady: B stays normal" B normal
reset_board
expect_fake "scenario corrupt steady: the reverting reboot boots B" current 1

init B B normal normal missing
mkdir "$ATC_VAR"
backend boot
expect_refused "boot with an unreadable variable is refused" "requested a reboot to revert to slot A"
rmdir "$ATC_VAR"
expect_calls "boot with an unreadable variable does not verify" "$GET_CURRENT
-t rootfs dump-slots-info
set-active-boot-slot 0"

init B B normal normal "steady=A trial=B ok=1"
backend boot
expect_ok "boot row 'confirmed', then 'steady'" "atc-nvbootctrl-backend: boot: confirmed, slot B is steady
atc-nvbootctrl-backend: boot: steady, slot B"
expect_state "boot row 'confirmed'" "steady=B trial=none ok=0"
expect_calls "boot row 'confirmed'" "$GET_CURRENT
verify"

init A A normal unbootable "steady=A trial=B ok=1"
backend boot
expect_ok "boot row 'confirm lost', then 'steady'" "atc-nvbootctrl-backend: boot: confirm lost, slot B is unbootable
atc-nvbootctrl-backend: boot: steady, slot A"
expect_state "boot row 'confirm lost'" "$STEADY_A"

init A A normal normal "$STEADY_A"
backend boot
expect_ok "boot row 'steady'" "atc-nvbootctrl-backend: boot: steady, slot A"
expect_state "boot row 'steady'" "$STEADY_A"
expect_calls "boot row 'steady' verifies" "$GET_CURRENT
verify"
expect_fake "boot row 'steady' clears the SR_RF magic" magic 0

init A A normal unbootable "steady=A trial=B ok=0"
backend boot
expect_ok "boot row 'spent'" "atc-nvbootctrl-backend: boot: the trial of B is spent, slot A is steady"
expect_state "boot row 'spent'" "$STEADY_A"
expect_calls "boot row 'spent'" "$GET_CURRENT
dump-slots-info
verify"

# The row itself is idempotent: with the marker removed, a second decision
# reads the state the first one wrote.
rm -f "$ATC_NVBOOTCTRL_BOOT_DONE"
backend boot
expect_ok "boot a second time after 'spent' is 'steady'" "atc-nvbootctrl-backend: boot: steady, slot A"
expect_state "boot twice" "$STEADY_A"

# R3-D: a set-primary of B ran after this reset, while the unit waited. The
# spent row verifies and keeps the new trial of B.
init A B normal normal "steady=A trial=B ok=0"
backend boot
expect_ok "R3-D: the spent row keeps a new trial" \
  "atc-nvbootctrl-backend: boot: steady, slot A; the new trial of B boots next"
expect_state "R3-D: the new trial of B stays recorded" "steady=A trial=B ok=0"
reset_board
backend boot
expect_ok "R3-D: B boots its trial" "atc-nvbootctrl-backend: boot: trial in flight, slot B"

init B B normal normal "steady=A trial=B ok=0"
backend boot
expect_ok "boot row 'trial in flight'" "atc-nvbootctrl-backend: boot: trial in flight, slot B"
expect_state "boot row 'trial in flight'" "steady=A trial=B ok=0"
# The row reads the partner's count, and with a bootable partner it does not
# verify.
expect_calls "boot row 'trial in flight' does not verify" "$GET_CURRENT
-t rootfs dump-slots-info"

init B B unbootable normal "$STEADY_A"
backend boot
expect_ok "boot row 'failed over'" "atc-nvbootctrl-backend: boot: failed over, slot B is steady"
expect_state "boot row 'failed over'" "steady=B trial=none ok=0"
expect_calls "boot row 'failed over'" "$GET_CURRENT
-t rootfs dump-slots-info
verify"

# The booted slot B is neither steady nor on trial, and A can boot. So the
# state does not record the switch to B, for example after a cold boot. The
# unit writes nothing, does not verify, and reboots to revert to A.
init B B normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
backend boot
expect_refused "boot on an unrecorded slot with a bootable partner is refused" \
  "requested a reboot to revert to slot A"
expect_state "boot on an unrecorded slot writes nothing" "$STEADY_A"
expect_seq "boot on an unrecorded slot requests the reverting reboot" "reboot "
reset_board
expect_fake "the reverting reboot from an unrecorded slot boots A" current 0

# After a revert row requests its reboot, the unit must not be
# restarted into the same row. It exits 4, which the unit's
# RestartPreventExitStatus= names, and requests the reboot once.
init B B normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
backend boot
if [ "$status" = 4 ]; then
  echo "ok: a revert row exits 4, so systemd does not restart it"
else
  fail_case "a revert row exits $status, expected 4"
fi
reboots="$(grep -c '^reboot ' "$state/seq")"
[ "$reboots" = 1 ] || fail_case "a revert row requested $reboots reboots, expected 1"

# A corrupt state whose partner cannot be read. The partner
# counts as not bootable, as in boot_verify, so the last-slot row runs and
# the unit completes.
init A A normal normal "steady=C trial=none ok=0"
FAKE_NVBOOTCTRL_FAIL=dump-slots-info backend boot
expect_ok "a corrupt state with an unreadable partner takes the last-slot row" \
  "atc-nvbootctrl-backend: boot: corrupt state rewritten, slot A is steady"
expect_state "a corrupt state with an unreadable partner is rewritten" "$STEADY_A"

# R3-C: the same revert holds when the requested reboot clears SR_RF.
init B B normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
backend boot
expect_refused "R3-C: boot on an unrecorded slot reverts" "requested a reboot to revert to slot A"
expect_status "R3-C: the revert marks B unbootable" B unbootable
expect_fake "R3-C: the revert points the chain at A" active 0
reset_board cold
expect_fake "R3-C: a reboot that clears SR_RF still boots A" current 0

# An unrecorded booted slot with a normal partner is not confirmed. RAUC must
# not mark its partner bad, and set-primary of the steady slot must not make
# the unrecorded slot steady.
init B B normal normal "$STEADY_A"
backend set-state A bad
expect_refused "set-state A bad from an unrecorded slot B is refused" "slot B is booted but not confirmed"
expect_status "the refused set-state A bad from an unrecorded slot writes nothing" A normal
backend set-primary A
expect_ok "set-primary A from an unrecorded slot B" ""
expect_state "set-primary A from an unrecorded slot keeps A steady" "$STEADY_A"

init B B normal normal "steady=A trial=B ok=1"
FAKE_CHATTR_FAIL=1 backend boot
expect_refused "boot row 'confirmed' with a failed write prints no journal line" "cannot clear the immutable flag"

init A A normal normal "steady=A trial=B ok=0"
FAKE_NVBOOTCTRL_FAIL=get-current-slot backend boot
expect_refused "boot when get-current-slot fails is refused" "get-current-slot failed"
expect_state "boot with no booted slot leaves AtcSlotState unchanged" "steady=A trial=B ok=0"

init A A normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=verify backend boot
expect_refused "boot row 'steady' when verify fails is refused" "row 'steady': nvbootctrl verify failed 3 times"
expect_state "a failed verify leaves the state for the restarted unit" "$STEADY_A"

init B B normal normal missing
FAKE_NVBOOTCTRL_FAIL=verify backend boot
expect_refused "boot row 'first boot' when verify fails is refused" "row 'first boot'"
expect_state "a failed first-boot verify writes nothing" missing

# A partner with a normal status but a count of 0 under the magic cannot
# boot either. The launcher judges a fail over by the count.
init A A normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 0 0 0 0 1 1
set +e
FAKE_NVBOOTCTRL_FAIL=verify PATH="$tmp/bin:$PATH" timeout 4 sh "$BACKEND" boot > /dev/null 2>&1
retry_status=$?
set -e
if [ "$retry_status" = 124 ]; then
  echo "ok: boot keeps verifying while the partner's count is 0"
else
  fail_case "boot with verify failing and B at count 0: exit $retry_status, expected 124 (still retrying)"
fi

# Between two tries the retry releases the lock. A writing verb does not wait
# for it: it gets the lock at once and refuses, because the boot decision is
# not complete.
init A A normal unbootable "steady=A trial=B ok=0"
(FAKE_NVBOOTCTRL_FAIL=verify PATH="$tmp/bin:$PATH" timeout 5 sh "$BACKEND" boot > /dev/null 2>&1) &
retry_pid=$!
sleep 1.5
set +e
PATH="$tmp/bin:$PATH" timeout 3 sh "$BACKEND" set-state A good > /dev/null 2> "$tmp/writer-err"
writer_status=$?
wait "$retry_pid"
set -e
if [ "$writer_status" = 1 ] && grep -qF "has not completed" "$tmp/writer-err"; then
  echo "ok: a writing verb refuses at once while the boot unit retries its verify"
else
  fail_case "set-state A good during the boot unit's retry: exit $writer_status, expected a prompt refusal"
fi

# RAUC's writing verbs refuse before the boot decision of this boot.
init A A normal normal "$STEADY_A"
NO_BOOT_DONE=1 backend set-primary B
expect_refused "set-primary before the boot decision is refused" "the boot decision of this boot has not completed"
expect_fake "the refused set-primary does not switch" active 0
NO_BOOT_DONE=1 backend set-state B bad
expect_refused "set-state before the boot decision is refused" "the boot decision of this boot has not completed"
expect_status "the refused set-state writes nothing" B normal

# A second boot run in the same boot (a restart, or systemctl restart) after
# RAUC installed B must keep the new trial. After the reset B boots on trial.
init A A normal normal "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 0 0 0 1 1 1
backend boot
expect_ok "second run: the boot decision" "atc-nvbootctrl-backend: boot: steady, slot A"
if [ -e "$ATC_NVBOOTCTRL_BOOT_DONE" ]; then
  echo "ok: second run: the boot decision writes the done marker"
else
  fail_case "second run: the boot decision wrote no done marker"
fi
backend set-state B bad
backend set-primary B
expect_ok "second run: set-primary B" ""
backend boot
expect_ok "second run: boot again in the same boot decides nothing" \
  "atc-nvbootctrl-backend: boot: the boot decision of this boot is already made"
expect_state "second run: the trial of B stays" "steady=A trial=B ok=0"
reset_board
expect_fake "second run: B boots after the reset" current 1
backend boot
expect_ok "second run: B is on trial, not steady" "atc-nvbootctrl-backend: boot: trial in flight, slot B"

init A A normal unbootable "steady=A trial=B ok=0"
set +e
FAKE_NVBOOTCTRL_FAIL=verify PATH="$tmp/bin:$PATH" timeout 4 sh "$BACKEND" boot > /dev/null 2>&1
retry_status=$?
set -e
if [ "$retry_status" = 124 ]; then
  echo "ok: boot keeps verifying while the partner is unbootable"
else
  fail_case "boot with verify failing and B unbootable: exit $retry_status, expected 124 (still retrying)"
fi
expect_state "boot with an unbootable partner and a failing verify writes nothing" "steady=A trial=B ok=0"

# timeout: a mutant that retries forever fails here, and does not hang.
init A A normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=verify backend_timeout 10 boot
expect_refused "boot when verify fails three times is refused" "row 'steady': nvbootctrl verify failed 3 times"
if [ "$status" = 3 ]; then
  echo "ok: the bootable-partner give-up exits 3"
else
  fail_case "the bootable-partner give-up exits $status, expected 3"
fi
expect_calls "boot tries verify three times" "$GET_CURRENT
verify
-t rootfs dump-slots-info
verify
verify"

# ── Refusals: arguments ───────────────────────────────────────────────────
init A A normal normal "$STEADY_A"
backend frobnicate
expect_refused "an unknown verb is refused" "unknown verb 'frobnicate'"
expect_calls "an unknown verb calls nothing" ""

backend
expect_refused "no verb is refused" "no verb"

backend set-primary C
expect_refused "set-primary of an unknown bootname is refused" "unknown slot bootname 'C'"
expect_calls "set-primary C calls nothing" ""
expect_fake "set-primary C" active 0

backend set-primary 1
expect_refused "set-primary of a slot number is refused" "unknown slot bootname '1'"

backend get-state C
expect_refused "get-state of an unknown bootname is refused" "unknown slot bootname 'C'"

backend set-state C bad
expect_refused "set-state of an unknown bootname is refused" "unknown slot bootname 'C'"
expect_status "set-state C bad writes nothing" A normal
expect_status "set-state C bad writes nothing" B normal

backend set-state B broken
expect_refused "set-state of an unknown state is refused" "unknown state 'broken'"
expect_status "set-state B broken writes nothing" B normal

backend set-primary
expect_refused "set-primary without a bootname is refused" "set-primary takes 1 argument(s), got 0"

backend set-primary B A
expect_refused "set-primary with two bootnames is refused" "set-primary takes 1 argument(s), got 2"
expect_fake "set-primary B A" active 0

backend set-state B
expect_refused "set-state without a state is refused" "set-state takes 2 argument(s), got 1"

backend get-primary B
expect_refused "get-primary with an argument is refused" "get-primary takes 0 argument(s), got 1"

# ── Refusals: nvbootctrl fails or prints something else ───────────────────
init A B normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=get-current-slot backend get-current
expect_refused "get-current when get-current-slot fails is refused" "get-current-slot failed"

FAKE_NVBOOTCTRL_CURRENT=2 backend get-current
expect_refused "get-current-slot output 2 is refused" "printed '2', not 0 or 1"

FAKE_NVBOOTCTRL_CURRENT="" backend get-current
expect_refused "empty get-current-slot output is refused" "printed '', not 0 or 1"

FAKE_NVBOOTCTRL_CURRENT=A backend get-state A
expect_refused "get-state when get-current-slot prints a letter is refused" "printed 'A', not 0 or 1"

FAKE_NVBOOTCTRL_FAIL=dump-slots-info backend get-primary
expect_refused "get-primary when dump-slots-info fails is refused" "dump-slots-info failed"

FAKE_NVBOOTCTRL_DUMP="Active bootloader slot: B" backend get-primary
expect_ok "the Active bootloader slot line alone parses" B

FAKE_NVBOOTCTRL_DUMP="Active bootloader slot: C" backend get-primary
expect_refused "an active slot that is not A or B is refused" "cannot parse nvbootctrl dump-slots-info"

FAKE_NVBOOTCTRL_DUMP="Active rootfs slot: B" backend get-primary
expect_refused "the rootfs form of the output is refused" "cannot parse nvbootctrl dump-slots-info"

FAKE_NVBOOTCTRL_DUMP="Active bootloader slot: A
Active bootloader slot: B" backend get-primary
expect_refused "two active lines are refused" "cannot parse nvbootctrl dump-slots-info"

FAKE_NVBOOTCTRL_DUMP="" backend get-primary
expect_refused "empty dump-slots-info output is refused" "cannot parse nvbootctrl dump-slots-info"

init B B normal normal "steady=A trial=B ok=0"
FAKE_NVBOOTCTRL_FAIL=set-active-boot-slot backend set-state B bad
expect_refused "set-state bad when set-active-boot-slot fails is refused" \
  "nvbootctrl set-active-boot-slot 0 failed"

# ── Temporary files go to the lock's directory, not TMPDIR ─────────────────
init A A normal normal "$STEADY_A"
TMPDIR="$tmp/missing" backend set-state B bad
expect_ok "a write works with no usable TMPDIR" ""
expect_status "a write with no usable TMPDIR" B unbootable
leftover="$(find "$tmp" -maxdepth 1 -name 'atc-nvbootctrl.*' | wc -l)"
[ "$leftover" -eq 0 ] || fail_case "a write leaves $leftover temporary file(s) in $tmp"

# ── Refusals: UEFI variables ──────────────────────────────────────────────
# A fresh board may have no RootfsStatusSlot variables. Absent reads as normal.
init A A normal normal "$STEADY_A"
rm "$efi/RootfsStatusSlotB-$NV_GUID"
backend get-state B
expect_ok "get-state with no RootfsStatusSlotB reads good" good

init B B normal normal "steady=A trial=B ok=0"
rm "$efi/RootfsStatusSlotA-$NV_GUID"
backend set-state B bad
expect_ok "set-state B bad switches to a partner with no status variable" ""
expect_fake "set-state B bad, partner A absent" active 0

init A A normal normal "$STEADY_A"
rm "$efi/RootfsStatusSlotB-$NV_GUID"
backend set-primary B
expect_ok "set-primary B with no RootfsStatusSlotB" ""
expect_status "set-primary B creates RootfsStatusSlotB" B normal
if grep -qxF "chattr -i $efi/RootfsStatusSlotB-$NV_GUID" "$state/seq"; then
  fail_case "a new variable gets no chattr -i: $(cat "$state/seq")"
else
  echo "ok: a new variable gets no chattr -i"
fi
expect_seq "an existing variable gets chattr -i" "chattr -i $ATC_VAR"
expect_seq "a new variable is made immutable after the write" "chattr +i $efi/RootfsStatusSlotB-$NV_GUID"

# A read error on RootfsStatusSlotB must not decode as normal. The first read
# succeeds and every later one fails: a second read of the same variable
# would decode the failed read as normal.
init A A normal unbootable "$STEADY_A"
rm -f "$tmp/tail-reads"
FAKE_TAIL_FAIL_AFTER=1 backend get-state B
expect_ok "get-state reads RootfsStatusSlotB once, and decodes that read" bad
rm -f "$tmp/tail-reads"
FAKE_TAIL_FAIL_AFTER=0 backend get-state B
expect_refused "get-state with a failed read of RootfsStatusSlotB is refused" "cannot read"
rm -f "$tmp/tail-reads"

# Only 0xFF is unbootable, as the launcher reads it.
init A A normal normal "$STEADY_A"
printf '\007\000\000\000\001\000\000\000' > "$efi/RootfsStatusSlotB-$NV_GUID"
backend get-state B
expect_ok "a RootfsStatusSlotB of 1 reads good, as the launcher reads it" good

init A A normal normal "$STEADY_A"
printf '\007\000\000\000\377\377\377\377' > "$efi/RootfsStatusSlotB-$NV_GUID"
backend get-state B
expect_ok "a RootfsStatusSlotB of 0xFFFFFFFF reads good, as the launcher reads it" good

init A A normal normal "$STEADY_A"
printf '\007\000\000\000\000\000' > "$efi/RootfsStatusSlotB-$NV_GUID"
backend get-state B
expect_refused "a RootfsStatusSlotB of 2 data bytes is refused" "holds 2 data bytes, not 4"

init A A normal normal "$STEADY_A"
printf '\007\000\000\000' > "$efi/RootfsStatusSlotB-$NV_GUID"
backend get-state B
expect_refused "a present RootfsStatusSlotB with no data is refused" "holds 0 data bytes, not 4"

init B B normal normal missing
backend get-state B
expect_refused "get-state of the booted slot with no AtcSlotState is refused" "cannot read"

init A A normal normal "$STEADY_A"
FAKE_CHATTR_FAIL=1 backend set-state B bad
expect_refused "a write whose immutable flag stays is refused" "cannot clear the immutable flag"
expect_status "a refused chattr writes nothing" B normal

# A `chattr +i` that fails after dd wrote the variable does not fail the verb:
# the write is committed. The backend reads the variable back and warns.
init A A normal normal "$STEADY_A"
FAKE_CHATTR_FAIL_SET=1 backend set-state B bad
expect_ok "a write whose chattr +i fails after dd is committed" ""
expect_status "a write whose chattr +i fails after dd keeps its value" B unbootable
if grep -qF "warning: wrote $efi/RootfsStatusSlotB-$NV_GUID" <<< "$err"; then
  echo "ok: a failed chattr +i after dd prints a warning"
else
  fail_case "a failed chattr +i after dd prints no warning. stderr: '$err'"
fi

# The same failure with a read-back that differs from the write is refused.
init A A normal normal "$STEADY_A"
FAKE_CHATTR_CLOBBER_SET=1 backend set-state B bad
expect_refused "a write that reads back a different value is refused" "reads back a different value"

# ── The lock: a writing verb waits while another holds it ──────────────────
init A A normal normal "$STEADY_A"
exec 8> "$ATC_NVBOOTCTRL_LOCK"
flock 8
set +e
PATH="$tmp/bin:$PATH" timeout 2 sh "$BACKEND" set-state B bad > /dev/null 2>&1
lock_status=$?
set -e
exec 8>&-
if [ "$lock_status" = 124 ]; then
  echo "ok: set-state waits for the lock"
else
  fail_case "set-state with the lock held: exit $lock_status, expected 124 (still waiting)"
fi
expect_status "set-state with the lock held writes nothing" B normal

# ── Scenarios: an install, a reset, then a confirm or a fall back ──────────
# A steady device on A, both counts full. RAUC installs B. reset_board is the
# launcher at a warm reset.
scenario_install_b() {
  init A A normal normal "$STEADY_A"
  "$tmp/bin/nvbootctrl" fake-init 0 0 1 1
  backend set-state B bad
  expect_ok "scenario: install, set-state B bad" ""
  backend set-primary B
  expect_ok "scenario: install, set-primary B" ""
  backend get-state B
  expect_ok "transition 1: B reads good after the install" good
  reset_board
  expect_fake "scenario: the trial boots B" current 1
  backend boot
  expect_ok "scenario: the boot unit leaves the trial" "atc-nvbootctrl-backend: boot: trial in flight, slot B"
  backend trial-slot
  expect_ok "scenario: the trial of B is in flight" B
  backend get-state B
  expect_ok "transition 2: B reads bad during the unconfirmed trial" bad
}

scenario_install_b
: > "$state/calls"
backend set-state B good
expect_ok "scenario confirm: atcd marks B good" ""
expect_calls "scenario confirm: mark-good runs nvbootctrl verify" "$GET_CURRENT
verify"
backend get-state B
expect_ok "transition 3: B reads good after mark-good" good
reset_board
expect_fake "scenario confirm: B boots again after the confirm" current 1
backend boot
expect_state "scenario confirm: B is steady" "steady=B trial=none ok=0"
backend get-state B
expect_ok "scenario confirm: RAUC reads B good" good
backend trial-slot
expect_ok "scenario confirm: no trial" none

scenario_install_b
reset_board
expect_fake "scenario fall back: the launcher fails over to A" current 0
expect_status "scenario fall back: the launcher marked B unbootable" B unbootable
backend get-state B
expect_ok "transition 4: B reads bad after the bootloader falls back" bad
backend boot
expect_ok "scenario fall back: the boot unit clears the spent trial" \
  "atc-nvbootctrl-backend: boot: the trial of B is spent, slot A is steady"
expect_state "scenario fall back: A is steady" "$STEADY_A"
backend get-primary
expect_ok "scenario fall back: the next boot is A" A
reset_board
expect_fake "scenario fall back: A boots again after the boot unit's verify" current 0
backend boot
expect_ok "scenario fall back: the boot unit verifies the steady boot" "atc-nvbootctrl-backend: boot: steady, slot A"

# A second install after the fall back. The boot unit's verify cleared SR_RF,
# so B boots its trial.
backend set-state B bad
backend set-primary B
expect_ok "scenario fall back: a second install of B" ""
reset_board
expect_fake "scenario fall back: the second install boots B" current 1
backend boot
expect_ok "scenario fall back: the second trial is in flight" "atc-nvbootctrl-backend: boot: trial in flight, slot B"

scenario_install_b
reset_board cold
expect_fake "scenario power cut: a cold boot refills the count, and B boots again" current 1
backend boot
expect_ok "scenario power cut: the trial stays in flight" "atc-nvbootctrl-backend: boot: trial in flight, slot B"

# The end state of a fall back with no boot-unit verify since: B's SR_RF
# count is 0 with the magic set, and RootfsStatusSlotB is unbootable. Only
# set-primary's verify lets the next install boot B.
init A A normal unbootable "$STEADY_A"
"$tmp/bin/nvbootctrl" fake-init 0 0 1 0 1 1
backend set-state B bad
backend set-primary B
expect_ok "scenario stale count: set-primary B" ""
expect_status "scenario stale count: B is normal" B normal
reset_board
expect_fake "scenario stale count: B boots its trial" current 1
backend boot
expect_ok "scenario stale count: the trial is in flight" "atc-nvbootctrl-backend: boot: trial in flight, slot B"

# ── The UEFI capsule ──────────────────────────────────────────────────────
#
# The real atc-tegra-capsule runs against a fake ESP and a fake mount table,
# and shares the fake efivarfs with the backend. The bundle hook stages;
# set-primary arms as its last step, and then calls no set-active-boot-slot.

esp="$tmp/esp"
OSIND="$efi/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c"
# The wrapper puts the fake chattr first, also when a case runs the tool
# itself. The tool's scratch directory stands in for /run.
mkdir -p "$tmp/capsule-run"
# shellcheck disable=SC2016  # $PATH and "$@" are the wrapper's, not this shell's
printf '#!/bin/sh\nPATH=%q:"$PATH" ATC_TEGRA_ESP=%q ATC_MOUNTINFO=%q ATC_TEGRA_CAPSULE_RUNDIR=%q exec sh %q "$@"\n' \
  "$tmp/bin" "$esp" "$tmp/mountinfo" "$tmp/capsule-run" "$CAPSULE_TOOL" > "$tmp/bin/atc-tegra-capsule"
chmod +x "$tmp/bin/atc-tegra-capsule"
printf '31 22 259:10 / %s rw - vfat /dev/nvme0n1p10 rw\n' "$esp" > "$tmp/mountinfo"
head -c 4096 /dev/urandom > "$tmp/tegra-bl.cap"

# The bundle hook's step: stage the capsule for slot $1 (default B), not armed.
hook_stage() { "$tmp/bin/atc-tegra-capsule" stage "$tmp/tegra-bl.cap" "${1:-B}" > /dev/null; }
arm_for() { "$tmp/bin/atc-tegra-capsule" arm "$1" > /dev/null; }
armed() { "$tmp/bin/atc-tegra-capsule" armed-slot > /dev/null; }
staged() { "$tmp/bin/atc-tegra-capsule" is-staged "${1:-B}"; }
# The low byte of OsIndications in hex, or "absent".
osind_low() { if [ -e "$OSIND" ]; then od -An -tx1 -j4 -N1 "$OSIND" | tr -d ' '; else echo absent; fi; }
with_tool() { ATC_TEGRA_CAPSULE="$tmp/bin/atc-tegra-capsule" backend "$@"; }

capsule_init() {
  init "$@"
  mkdir -p "$esp"
  find "$esp" -mindepth 1 -delete
  rm -f "$OSIND"
}

# An install with a capsule: set-state B bad, the hook stages for B,
# set-primary B arms. No set-active-boot-slot: the capsule switches the chain.
capsule_init A A normal normal "$STEADY_A"
with_tool set-state B bad
expect_ok "capsule: set-state B bad" ""
hook_stage B
with_tool set-primary B
expect_ok "capsule: set-primary B arms" ""
armed || fail_case "capsule: set-primary B left the capsule unarmed"
[ "$(osind_low)" = 04 ] || fail_case "capsule: OsIndications low byte is $(osind_low), expected 04"
grep -q 'set-active-boot-slot' "$state/calls" &&
  fail_case "capsule: set-primary B switched the chain with nvbootctrl as well: $(cat "$state/calls")"
expect_state "capsule: set-primary B records the trial" "steady=A trial=B ok=0"
expect_status "capsule: B is normal" B normal
expect_fake "capsule: nvbootctrl's next boot stays A" active 0
with_tool get-primary
expect_ok "capsule: get-primary reads the armed capsule's slot" B

# A capsule staged for B never arms for A. The board booted B, the boot unit
# left the file and cleared the bit, and the operator makes A primary.
# set-primary A switches with nvbootctrl and leaves the bit clear.
capsule_init B B normal normal "steady=B trial=none ok=0"
hook_stage B
with_tool set-primary A
expect_ok "capsule bound to B: set-primary A" ""
grep -qx 'set-active-boot-slot 0' "$state/calls" ||
  fail_case "capsule bound to B: set-primary A did not call set-active-boot-slot 0: $(cat "$state/calls")"
[ "$(osind_low)" = absent ] || [ "$(osind_low)" = 00 ] ||
  fail_case "capsule bound to B: set-primary A set OsIndications to $(osind_low)"

# The same the other way: booted A, a capsule bound to A, set-primary B
# switches with nvbootctrl and leaves the bit clear.
capsule_init A A normal normal "$STEADY_A"
hook_stage A
with_tool set-primary B
expect_ok "capsule bound to A: set-primary B" ""
grep -qx 'set-active-boot-slot 1' "$state/calls" ||
  fail_case "capsule bound to A: set-primary B did not call set-active-boot-slot 1: $(cat "$state/calls")"
[ "$(osind_low)" = absent ] || [ "$(osind_low)" = 00 ] ||
  fail_case "capsule bound to A: set-primary B set OsIndications to $(osind_low)"

# The boot unit clears the bit at every boot, and keeps the staged file.
capsule_init A A normal normal "$STEADY_A"
hook_stage B
arm_for B
with_tool boot
[ "$(osind_low)" = 00 ] || fail_case "boot: OsIndications low byte is $(osind_low), expected 00"
staged B || fail_case "boot: the staged capsule is gone"
armed && fail_case "boot: a capsule is still armed"

# A second boot verb in the same boot does nothing. The capsule that
# set-primary armed after the first one stays armed, and the trial stays.
capsule_init A A normal normal "$STEADY_A"
with_tool boot
with_tool set-state B bad
hook_stage B
with_tool set-primary B
expect_ok "capsule: set-primary B after the first boot verb" ""
with_tool boot
[ "$(osind_low)" = 04 ] || fail_case "a second boot verb: OsIndications low byte is $(osind_low), expected 04"
expect_state "a second boot verb keeps the trial" "steady=A trial=B ok=0"

# set-primary refuses to arm while the next boot already runs another chain.
# The capsule would then write the chain of the booted slot.
capsule_init A B normal normal "$STEADY_A"
hook_stage B
with_tool set-primary B
expect_refused "capsule: no arm while the chain already points at B" "already points at slot B"
armed && fail_case "capsule: a refused arm left a capsule armed"

# Crash after the stage: set-primary never ran. Nothing is armed, so a reboot
# applies nothing, and the next boot is still A.
capsule_init A A normal normal "$STEADY_A"
with_tool set-state B bad
hook_stage B
armed && fail_case "crash after the stage: a capsule is armed"
with_tool get-primary
expect_ok "crash after the stage: get-primary stays A" A
reset_board
expect_fake "crash after the stage: the board boots A" current 0

# Crash after the trial write, before the arm: the arm fails here. set-primary
# fails, so RAUC fails the install. Nothing is armed, the chain stays on A, and
# the boot unit clears the trial that never booted.
capsule_init A A normal normal "$STEADY_A"
with_tool set-state B bad
hook_stage B
mkdir "$OSIND"
with_tool set-primary B
expect_refused "crash after the trial write: set-primary fails at the arm" "cannot arm the UEFI capsule"
rmdir "$OSIND"
expect_state "crash after the trial write: the trial is recorded" "steady=A trial=B ok=0"
armed && fail_case "crash after the trial write: a capsule is armed"
grep -q 'set-active-boot-slot' "$state/calls" &&
  fail_case "crash after the trial write: set-primary switched the chain: $(cat "$state/calls")"
reset_board
expect_fake "crash after the trial write: the board boots A" current 0
with_tool trial-slot
expect_ok "crash after the trial write: no trial is in flight" none

# Crash after the arm: the install is committed. get-primary reads B.
capsule_init A A normal normal "$STEADY_A"
with_tool set-state B bad
hook_stage B
with_tool set-primary B
with_tool get-primary
expect_ok "crash after the arm: get-primary reads B" B

# A failed install leaves nothing armed. An earlier install armed a capsule
# for B, and no reboot followed. The next install marks B bad first, which
# disarms, and then stops in the write.
capsule_init A A normal normal "$STEADY_A"
hook_stage B
arm_for B
armed || fail_case "failed install: the fixture did not arm"
with_tool set-state B bad
expect_ok "failed install: set-state B bad" ""
armed && fail_case "failed install: set-state B bad left the earlier capsule armed"
staged B && fail_case "failed install: set-state B bad left the earlier capsule staged"

# The booted slot marked bad while a capsule is armed for its partner: the
# backend switches the chain to the partner with nvbootctrl, so the capsule
# must go. Armed, it would write the booted slot's chain at the next reset.
capsule_init A A normal normal "steady=B trial=A ok=1"
hook_stage B
arm_for B
with_tool set-state A bad
expect_ok "capsule: the booted slot marked bad" ""
armed && fail_case "capsule: marking the booted slot bad left the capsule armed"
expect_fake "capsule: the booted slot marked bad switches to B" active 1

# mark-active booted: set-primary of the booted slot disarms, and the chain
# goes back to A through nvbootctrl.
capsule_init A A normal normal "$STEADY_A"
hook_stage B
arm_for B
with_tool set-primary A
expect_ok "capsule: mark-active booted" ""
armed && fail_case "capsule: mark-active booted left the capsule armed"
staged B && fail_case "capsule: mark-active booted left the capsule staged"
expect_state "capsule: mark-active booted is steady" "$STEADY_A"
with_tool get-primary
expect_ok "capsule: get-primary after mark-active booted" A

# mark-active booted disarms BEFORE the state write. When the disarm fails,
# the state still records the trial, so the boot unit reverts whatever the
# capsule does.
capsule_init A A normal normal "steady=A trial=B ok=0"
hook_stage B
mkdir "$OSIND"
with_tool set-primary A
expect_refused "capsule: a failed disarm stops mark-active booted" "cannot disarm the UEFI capsule"
rmdir "$OSIND"
expect_state "capsule: a failed disarm writes no state" "steady=A trial=B ok=0"

# No staged capsule: set-primary B switches the chain with nvbootctrl.
capsule_init A A normal normal "$STEADY_A"
with_tool set-primary B
expect_ok "no capsule: set-primary B" ""
expect_fake "no capsule: nvbootctrl's next boot is B" active 1
[ "$(osind_low)" = absent ] || fail_case "no capsule: set-primary B wrote OsIndications"

# ── Final review of S3: the capsule path and the boot unit's exits ────────

# P1-1: the spent row marks the spent trial unbootable. Here the capsule
# install wrote B normal, and UEFI did not apply the capsule: the reset kept
# chain A and cleared the bit. A later fail over to B must not find it normal.
capsule_init A A normal normal "$STEADY_A"
with_tool set-state B bad
hook_stage B
with_tool set-primary B
expect_ok "capsule rejected: set-primary B arms" ""
expect_status "capsule rejected: set-primary B wrote B normal" B normal
"$tmp/bin/atc-tegra-capsule" clear-bit > /dev/null
reset_board
expect_fake "capsule rejected: the board boots A" current 0
with_tool boot
expect_ok "capsule rejected: the boot unit takes the spent row" \
  "atc-nvbootctrl-backend: boot: the trial of B is spent, slot A is steady"
expect_status "capsule rejected: the spent row marks B unbootable" B unbootable
expect_state "capsule rejected: A is steady" "$STEADY_A"

# The same row without a capsule: B is already unbootable, and stays so.
init A A normal unbootable "steady=A trial=B ok=0"
backend boot
expect_status "spent row without a capsule: B stays unbootable" B unbootable
expect_state "spent row without a capsule: A is steady" "$STEADY_A"

# P1-2: the trial in flight with no bootable partner verifies, so a warm
# reset finds its count again. The state keeps the trial unconfirmed.
init B B normal normal "steady=A trial=B ok=0"
"$tmp/bin/nvbootctrl" fake-init 1 1 0 0 1 1
backend boot
expect_ok "trial with no bootable partner: the unit verifies" \
  "atc-nvbootctrl-backend: boot: trial in flight, slot B; slot A cannot boot, so the trial's count is back"
grep -qx 'verify' "$state/calls" || fail_case "trial with no bootable partner: no verify in: $(cat "$state/calls")"
expect_state "trial with no bootable partner: the trial stays unconfirmed" "steady=A trial=B ok=0"
reset_board
expect_fake "trial with no bootable partner: a warm reset boots B again" current 1

# The trial in flight with a bootable partner does not verify, as before.
init B B normal normal "steady=A trial=B ok=0"
"$tmp/bin/nvbootctrl" fake-init 1 1 1 0 1 1
backend boot
expect_ok "trial with a bootable partner" "atc-nvbootctrl-backend: boot: trial in flight, slot B"
grep -qx 'verify' "$state/calls" && fail_case "trial with a bootable partner: the unit verified"

# The trial whose partner is marked unbootable: atcd's reject is refused (no
# last bootable slot is marked bad), and trial-slot reports no trial. So the
# deadline does not reboot into the same slot every 15 minutes, and the
# pre-install guard lets an install write A, the only repair.
init B B unbootable normal "steady=A trial=B ok=0"
"$tmp/bin/nvbootctrl" fake-init 1 1 0 0 1 1
backend set-state B bad
expect_refused "reject of the last bootable trial is refused" "refusing to mark the last bootable slot bad"
expect_status "reject of the last bootable trial: B stays normal" B normal
backend trial-slot
expect_ok "a trial with an unbootable partner is not in flight" none
backend get-state B
expect_ok "a trial with an unbootable partner still reads bad" bad
init B B normal normal "steady=A trial=B ok=0"
backend trial-slot
expect_ok "a trial with a normal partner is in flight" B

# Lane B P3: a verify that gives up with a bootable partner requests the
# reboot that falls back, and exits 3, which the unit does not restart.
init A A normal normal "$STEADY_A"
FAKE_NVBOOTCTRL_FAIL=verify backend boot
[ "$status" = 3 ] || fail_case "a verify that gives up: exit $status, expected 3"
expect_seq "a verify that gives up requests the reboot" "reboot "

# Lane B P3: a revert row whose reboot request fails exits 4, which the unit
# does not restart. Exit 1 restarted it every 2 s.
init A A normal normal "steady=C trial=none ok=0"
ATC_NVBOOTCTRL_REBOOT=false backend boot
[ "$status" = 4 ] || fail_case "a failed reverting reboot: exit $status, expected 4"
grep -q 'the reverting reboot could not be requested' <<< "$err" ||
  fail_case "a failed reverting reboot: no reason on stderr: $err"

# Lane C P3: set-primary refuses when the tool cannot tell whether a capsule
# is staged, here an unmounted ESP. A switch with set-active-boot-slot would
# boot the bundle's rootfs on the old firmware.
capsule_init A A normal normal "$STEADY_A"
with_tool set-state B bad
hook_stage B
mv "$tmp/mountinfo" "$tmp/mountinfo.saved"
printf '22 1 259:2 / / rw - ext4 /dev/root rw\n' > "$tmp/mountinfo"
with_tool set-primary B
expect_refused "set-primary with the ESP unmounted is refused" "cannot tell whether a UEFI capsule is staged"
mv "$tmp/mountinfo.saved" "$tmp/mountinfo"
grep -q 'set-active-boot-slot' "$state/calls" &&
  fail_case "set-primary with the ESP unmounted switched the chain: $(cat "$state/calls")"

# ── Third review of S3 ────────────────────────────────────────────────────

# PRRT_kwDOSV4xDc62Y9xV: the spent row marks the spent trial unbootable
# BEFORE its verify. A capsule that UEFI did not apply leaves B normal with a
# count. A verify that failed there found B bootable and gave up, and the
# reboot it requested fell over into B's rootfs on the old firmware. Now B is
# unbootable first, so the unit finds no bootable partner and retries until
# the verify succeeds.
init A A normal normal "steady=A trial=B ok=0"
FAKE_NVBOOTCTRL_FAIL=verify FAKE_NVBOOTCTRL_FAIL_TIMES=4 backend boot
expect_ok "spent row, verify fails 4 times: the unit retries until it succeeds" \
  "atc-nvbootctrl-backend: boot: the trial of B is spent, slot A is steady"
expect_status "spent row, verify fails: B is unbootable" B unbootable
expect_state "spent row, verify fails: A is steady" "$STEADY_A"
grep -q '^reboot' "$state/seq" &&
  fail_case "spent row, verify fails: the unit requested a reboot: $(cat "$state/seq")"
# The capsule path of the same row: the bit cleared at the reset, B normal.
capsule_init A A normal normal "$STEADY_A"
with_tool set-state B bad
hook_stage B
with_tool set-primary B
"$tmp/bin/atc-tegra-capsule" clear-bit > /dev/null
reset_board
FAKE_NVBOOTCTRL_FAIL=verify FAKE_NVBOOTCTRL_FAIL_TIMES=4 with_tool boot
expect_ok "capsule rejected, verify fails: the unit retries and does not fall over to B" \
  "atc-nvbootctrl-backend: boot: the trial of B is spent, slot A is steady"
expect_status "capsule rejected, verify fails: B is unbootable" B unbootable
grep -q '^reboot' "$state/seq" &&
  fail_case "capsule rejected, verify fails: the unit requested a reboot: $(cat "$state/seq")"

# PRRT_kwDOSV4xDc62Y9xc: the repair of a trial whose partner is marked
# unbootable. trial-slot reports none, so the install runs. Its set-state A
# bad is accepted, as A is already unbootable, and changes no state: the old
# trial is not made steady. Its set-primary A makes A the trial and records B
# as the fallback.
repair_to_trial_a() {
  init B B unbootable normal "steady=A trial=B ok=0"
  "$tmp/bin/nvbootctrl" fake-init 1 1 0 0 1 1
  backend boot
  expect_ok "repair: the boot unit keeps the trial" \
    "atc-nvbootctrl-backend: boot: trial in flight, slot B; slot A cannot boot, so the trial's count is back"
  backend trial-slot
  expect_ok "repair: no trial in flight, so the install may run" none
  backend set-state A bad
  expect_ok "repair: set-state A bad of an unbootable A is accepted" ""
  expect_status "repair: A stays unbootable" A unbootable
  expect_state "repair: set-state A bad does not make the old trial steady" "steady=A trial=B ok=0"
  backend set-primary A
  expect_ok "repair: set-primary A" ""
  expect_state "repair: A is the trial, B the fallback" "steady=B trial=A ok=0"
  expect_status "repair: A is normal" A normal
  expect_fake "repair: the next boot loads A" active 0
  reset_board
  expect_fake "repair: the board boots A" current 0
  backend boot
  expect_ok "repair: A boots as a trial" "atc-nvbootctrl-backend: boot: trial in flight, slot A"
  backend trial-slot
  expect_ok "repair: A's trial is in flight" A
}
# The confirm makes A steady.
repair_to_trial_a
backend set-state A good
expect_ok "repair: atcd confirms A" ""
reset_board
backend boot
expect_state "repair: the confirm makes A steady" "$STEADY_A"
# A reject falls back to B, the last bootable image.
repair_to_trial_a
backend set-state A bad
expect_ok "repair: atcd rejects A" ""
reset_board
expect_fake "repair: the reject boots B" current 1
backend boot
expect_ok "repair: the spent row after a reject" \
  "atc-nvbootctrl-backend: boot: the trial of A is spent, slot B is steady"
expect_status "repair: the rejected A is unbootable" A unbootable
# With a normal A, the booted trial is still not confirmed: refused as before.
init B B normal normal "steady=A trial=B ok=0"
backend set-state A bad
expect_refused "set-state A bad from an unconfirmed trial with A normal is refused" \
  "refusing to mark the last bootable slot bad"

# PRRT_kwDOSV4xDc62Z5Al: get-primary with bit 2 set and the ESP unmounted
# cannot tell which chain the next boot loads, so it refuses. It named the
# active chain, A, while the armed capsule switches to B.
capsule_init A A normal normal "$STEADY_A"
with_tool set-state B bad
hook_stage B
with_tool set-primary B
expect_ok "get-primary, ESP unmounted: set-primary B arms" ""
mv "$tmp/mountinfo" "$tmp/mountinfo.saved"
printf '22 1 259:2 / / rw - ext4 /dev/root rw\n' > "$tmp/mountinfo"
with_tool get-primary
expect_refused "get-primary with an armed capsule and the ESP unmounted is refused" \
  "cannot tell whether a UEFI capsule is armed"
mv "$tmp/mountinfo.saved" "$tmp/mountinfo"
with_tool get-primary
expect_ok "get-primary with the ESP mounted names the capsule's slot" B

if [ "$failures" -gt 0 ]; then
  echo "atc-nvbootctrl-backend_test: $failures failure(s)" >&2
  exit 1
fi
echo "atc-nvbootctrl-backend_test: all cases passed"
