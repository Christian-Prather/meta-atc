#!/usr/bin/env bash
# tests/atc-slot-trial-grub_test.sh
#
# Behavioural test for meta-atc's atc-slot-trial-grub, the GRUB backend's trial
# predicate. It runs the real script against a stub grub-editenv and checks what
# it prints for each boot environment, and that an unreadable one fails.
#
# Usage: atc-slot-trial-grub_test.sh <path-to-atc-slot-trial-grub>
set -euo pipefail

SCRIPT="${1:?usage: atc-slot-trial-grub_test.sh <script>}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
failures=0

# $1 name, $2 the grubenv lines (one word each), $3 the expected stdout, or
# `fail` for a non-zero exit with nothing on stdout.
check_case() {
  local name="$1" env="$2" want="$3" status out
  printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$env" > "$tmp/bin/grub-editenv"
  chmod +x "$tmp/bin/grub-editenv"
  set +e
  out="$(PATH="$tmp/bin:$PATH" sh "$SCRIPT" 2> "$tmp/err")"
  status=$?
  set -e
  if [ "$want" = fail ]; then
    if [ "$status" -ne 0 ] && [ -z "$out" ] && [ -s "$tmp/err" ]; then
      echo "ok: $name"
      return
    fi
  elif [ "$status" -eq 0 ] && [ "$out" = "$want" ]; then
    echo "ok: $name"
    return
  fi
  echo "FAIL: $name: exit $status, stdout '$out', expected '$want'" >&2
  failures=$((failures + 1))
}

check_case "no trial prints none" "ATC_TRIAL=none B_OK=1 B_TRY=0" none
check_case "a trial marked good prints none" "ATC_TRIAL=B B_OK=1 B_TRY=0" none
check_case "a trial in flight prints the slot" "ATC_TRIAL=B B_OK=1 B_TRY=1" B
check_case "a trial marked bad prints the slot" "ATC_TRIAL=B B_OK=0 B_TRY=0" B
check_case "a spent trial marked bad prints the slot" "ATC_TRIAL=B B_OK=0 B_TRY=1" B
check_case "a trial of A in flight prints A" "ATC_TRIAL=A A_OK=1 A_TRY=1 B_OK=1 B_TRY=0" A
check_case "a trial of A marked good prints none" "ATC_TRIAL=A A_OK=1 A_TRY=0 B_OK=1 B_TRY=1" none
check_case "a corrupt trial fails" "ATC_TRIAL=C" fail
check_case "a missing ATC_TRIAL fails" "A_OK=1 A_TRY=0" fail

printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/grub-editenv"
set +e
out="$(PATH="$tmp/bin:$PATH" sh "$SCRIPT" 2> /dev/null)"
status=$?
set -e
if [ "$status" -eq 0 ] || [ -n "$out" ]; then
  echo "FAIL: an unreadable environment: exit $status, stdout '$out'" >&2
  failures=$((failures + 1))
else
  echo "ok: an unreadable environment fails"
fi

if [ "$failures" -gt 0 ]; then
  echo "atc-slot-trial-grub_test: $failures failure(s)" >&2
  exit 1
fi
echo "atc-slot-trial-grub_test: all cases passed"
