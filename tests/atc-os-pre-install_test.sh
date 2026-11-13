#!/usr/bin/env bash
# tests/atc-os-pre-install_test.sh
#
# Behavioural test for meta-atc's RAUC pre-install handler. It runs the real
# script against a fake atc-slot-trial, the slot backend's trial predicate, and
# checks which answers let an install through. The GRUB predicate itself has
# its own test, atc-slot-trial-grub_test.sh.
#
# Usage: atc-os-pre-install_test.sh <path-to-atc-os-pre-install>
set -euo pipefail

SCRIPT="${1:?usage: atc-os-pre-install_test.sh <script>}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

# $1 name, $2 what the fake predicate prints, $3 its exit status, $4 the
# handler's expected exit status.
check_case() {
  local name="$1" prints="$2" exits="$3" want="$4" status
  printf '#!/bin/sh\necho %s\nexit %s\n' "$prints" "$exits" > "$tmp/atc-slot-trial"
  chmod +x "$tmp/atc-slot-trial"
  set +e
  ATC_SLOT_TRIAL="$tmp/atc-slot-trial" sh "$SCRIPT" > "$tmp/out" 2> "$tmp/err"
  status=$?
  set -e
  if [ "$status" != "$want" ]; then
    echo "FAIL: $name: exit $status, expected $want" >&2
    failures=$((failures + 1))
    return
  fi
  # A refusal must reach RAUC's status message: stdout starts with "<< error".
  if [ "$want" != 0 ] && ! grep -q '^<< error atc-os-pre-install: ' "$tmp/out"; then
    echo "FAIL: $name: the refusal printed no '<< error' line for RAUC" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok: $name"
}

check_case "no trial installs" none 0 0
check_case "a trial of B in flight is refused" B 0 1
check_case "a trial of A in flight is refused" A 0 1
check_case "an unreadable trial state is refused" none 1 1
check_case "an answer that is not a slot is refused" C 0 1
check_case "an empty answer is refused" "" 0 1

if ! grep -q 'on trial and not marked good' < <(
  printf '#!/bin/sh\necho B\n' > "$tmp/atc-slot-trial"
  chmod +x "$tmp/atc-slot-trial"
  ATC_SLOT_TRIAL="$tmp/atc-slot-trial" sh "$SCRIPT" 2> /dev/null || true
); then
  echo "FAIL: the refusal no longer says 'on trial and not marked good'," \
    "which qemu-rauc-proof.sh and qemu-rauc-faults.sh match" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "atc-os-pre-install_test: $failures failure(s)" >&2
  exit 1
fi
echo "atc-os-pre-install_test: all cases passed"
