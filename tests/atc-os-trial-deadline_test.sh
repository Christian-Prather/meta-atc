#!/usr/bin/env bash
# tests/atc-os-trial-deadline_test.sh
#
# Behavioural test for meta-atc's atc-os-trial-deadline. It runs the real
# script against stub `rauc` and `systemctl` and a fake atc-slot-trial, and
# checks which states reboot. A grep of the script's text cannot tell a deadline
# that never reboots from one that works, and this can.
#
# Usage: atc-os-trial-deadline_test.sh <path-to-atc-os-trial-deadline>
set -euo pipefail

SCRIPT="${1:?usage: atc-os-trial-deadline_test.sh <script>}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
failures=0

printf '#!/bin/sh\necho REBOOTED\n' > "$tmp/bin/systemctl"

# $1 name, $2 the booted bootname rauc reports (empty for none), $3 what the
# fake atc-slot-trial prints, $4 its exit status, $5 the expected outcome:
# reboot or stay.
run_case() {
  local name="$1" booted="$2" trial="$3" trial_exit="$4" want="$5" out got
  cat > "$tmp/bin/rauc" << STUB
#!/bin/sh
printf '%s\n' "RAUC_SYSTEM_BOOTED_BOOTNAME='$booted'" "RAUC_SLOTS='1 2'"
STUB
  printf '#!/bin/sh\necho %s\nexit %s\n' "$trial" "$trial_exit" > "$tmp/atc-slot-trial"
  chmod +x "$tmp/bin/"* "$tmp/atc-slot-trial"
  out="$(PATH="$tmp/bin:$PATH" ATC_SLOT_TRIAL="$tmp/atc-slot-trial" sh "$SCRIPT" 2> /dev/null || true)"
  if grep -q REBOOTED <<< "$out"; then got=reboot; else got=stay; fi
  if [ "$got" = "$want" ]; then
    echo "ok: $name"
  else
    echo "FAIL: $name: $got, expected $want. Output: $out" >&2
    failures=$((failures + 1))
  fi
}

run_case "no trial stays" B none 0 stay
run_case "an unconfirmed trial of the booted slot reboots" B B 0 reboot
run_case "a trial of the other slot stays" B A 0 stay
run_case "an unreadable trial state stays" B B 1 stay
run_case "no booted slot stays" "" B 0 stay

# qemu-rauc-faults.sh waits for this exact line on the serial console.
cat > "$tmp/bin/rauc" << 'STUB'
#!/bin/sh
printf '%s\n' "RAUC_SYSTEM_BOOTED_BOOTNAME='B'"
STUB
printf '#!/bin/sh\necho B\n' > "$tmp/atc-slot-trial"
out="$(PATH="$tmp/bin:$PATH" ATC_SLOT_TRIAL="$tmp/atc-slot-trial" sh "$SCRIPT" 2> /dev/null || true)"
if ! grep -qx 'atc-os-trial-deadline: trial slot B is not good at the deadline, rebooting' <<< "$out"; then
  echo "FAIL: the reboot line changed, and qemu-rauc-faults.sh waits for it: $out" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "atc-os-trial-deadline_test: $failures failure(s)" >&2
  exit 1
fi
echo "atc-os-trial-deadline_test: all cases passed"
