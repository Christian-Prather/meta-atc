#!/usr/bin/env sh
# atcd-boot-guard-contract: 2
# systemd ExecStartPre guard for atcd A/B boot-confirm rollback.
# Increments the boot-attempt counter; if it exceeds the limit, reverts atcd to
# the prior version via `atcd rollback` (which goes through the store's
# sanctioned flip_current — never a raw symlink flip) and resets the counter so
# the reverted-to (known-good) version boots cleanly. atcd itself resets the
# counter to 0 once it reaches ready AND sustains health for a warm-up dwell, so
# a healthy new version is never reverted.
#
# The count is scoped to the version the delivery pointer names: `increment`
# returns 1 for the first start of a newly activated atcd, whoever activated it.
# A shared count let one version's attempts revert the NEXT one on its own first
# start, which the bootstrap sequence (several restarts inside the dwell)
# reproduced on a focal device. See crates/atcd/src/boot_confirm.rs.
set -eu
STORE_ROOT="${ATCD_STORE_ROOT:-/var/atc}"
LIMIT="${ATCD_BOOT_CONFIRM_LIMIT:-3}"
# S4 + PR2 Area D: resolve atcd through the authoritative delivery pointer in the
# reserved agency channel (channel/agency/atcd/<dir>/current → active delivery
# dir → atcd member symlink → active version dir; the atcd self-update
# artifact is stored under the BARE name `atcd`). Mirrors
# Layout::channel_release_member_path.
#
# <dir> is `release` when the channel has a real `release/` dir, else the
# legacy `delivery`: the rule of atc-store's layout::release_dir. The legacy
# name stays supported until Jack explicitly approves its deprecation.
ATCD_CHANNEL="$STORE_ROOT/channel/agency/atcd"
if [ -d "$ATCD_CHANNEL/release" ] && [ ! -L "$ATCD_CHANNEL/release" ]; then
  ATCD_RELEASE_DIR=release
else
  ATCD_RELEASE_DIR=delivery
fi
# Contract 2 (server-delivered atcd design, section 5.2.3): count, roll back
# and reset with the CONFIRMED atcd, the last one that ran healthy. The store
# writes `confirmed` before it flips `current` to a candidate. A candidate that
# cannot run at all (a same-arch ELF with no runtime linker) cannot run these
# verbs either, so a guard that used `current` stayed inert on it. A store with
# no `confirmed` link (a first install, or no floor yet) keeps `current`. D4's
# supervision check reads the contract line at the top of this file.
ATCD_RELEASE_ROOT="$ATCD_CHANNEL/$ATCD_RELEASE_DIR"
if [ -n "${ATCD_BIN:-}" ]; then
  ATCD="$ATCD_BIN"
# `confirmed` must be the store's symlink: a real directory of that name is
# not the pointer.
elif [ -L "$ATCD_RELEASE_ROOT/confirmed" ] &&
  [ -f "$ATCD_RELEASE_ROOT/confirmed/atcd/atcd" ] &&
  [ -x "$ATCD_RELEASE_ROOT/confirmed/atcd/atcd" ]; then
  ATCD="$ATCD_RELEASE_ROOT/confirmed/atcd/atcd"
else
  ATCD="$ATCD_RELEASE_ROOT/current/atcd/atcd"
fi

# ATC-91: every atcd call has a time limit. The unit sets no TimeoutStartSec.
# So a hung atcd held this ExecStartPre until systemd's 90 s start timeout.
# Restart=always then ran it again, for ever, with no count.
#
# The probes, the count and the reset get 10 s each. The rollback gets the
# time that is left of an 85 s budget after the reset, and at least 10 s. It
# opens the store, and it can move a layout 6 store back. A test sets shorter
# limits through the environment.
#
# The kill is SIGKILL, because a hung atcd can ignore SIGTERM. GNU coreutils
# and BusyBox `timeout` both take `-s KILL SECS`, and both then exit 137. GNU
# kills the process group of the call, and BusyBox kills only its pid. The
# atc image installs coreutils. Without `timeout`, the call runs unbounded,
# as before.
GUARD_START="$(date +%s)"
BUDGET_SECS=85
PROBE_SECS="${ATCD_BOOT_CONFIRM_PROBE_SECS:-10}"
COUNT_SECS="${ATCD_BOOT_CONFIRM_COUNT_SECS:-10}"
TIMED_OUT=137
bounded() {
  b_secs="$1"
  shift
  if command -v timeout > /dev/null 2>&1; then
    timeout -s KILL "$b_secs" "$@"
  else
    "$@"
  fi
}

# Store layout v6 (design section 7): on a store at layout 6, an atcd that
# reads only layout 5 must not count or roll back. Both write v5 paths into
# the v6 store. Such an atcd prints 5 for `layout-version`, or clap refuses
# the verb with exit 2. Any other answer counts as before: the checks below
# report a broken atcd.
reads_only_v5() {
  rov_out="$(bounded "$PROBE_SECS" "$1" layout-version 2> /dev/null)" && rov_rc=0 || rov_rc=$?
  if [ "$rov_rc" = 0 ] && [ "$rov_out" = 5 ]; then return 0; fi
  if [ "$rov_rc" = 2 ]; then
    rov_err="$(bounded "$PROBE_SECS" "$1" layout-version 2>&1 > /dev/null)" || :
    case "$rov_err" in *'unrecognized subcommand'*) return 0 ;; esac
  fi
  return 1
}
# Under contract 2 the confirmed atcd can read only layout 5, while the
# current atcd, the candidate, moved the store to layout 6 on its first start
# and then failed to confirm. Only an atcd that reads layout 6 can move the
# store back: its `atcd rollback` reverses the store, then flips `current`.
# So the guard then uses `current`, but only when `current` runs and answers
# 6 or more. When `current` cannot run, no atcd on the device may write here: the
# guard writes nothing and names the repair. ExecStart then fails on the
# layout, which writes nothing either. An ATCD_BIN override is never replaced.
#
# ATC-243: the sentinel is read only when it is a regular file that is not a
# link, as the bootstrap reader does. A `cat` of a FIFO blocks this start for
# ever. atcd refuses any other LAYOUT_VERSION with ATC-E0184, and the layout of
# such a store is unknown, so this guard does not count or roll back there.
# ponytail: test, then `cat`. A swap to a FIFO between the two still blocks;
# a reader with O_NONBLOCK needs a helper binary on the device.
SENTINEL="$STORE_ROOT/LAYOUT_VERSION"
if [ -e "$SENTINEL" ] || [ -L "$SENTINEL" ]; then
  if [ ! -f "$SENTINEL" ] || [ -L "$SENTINEL" ]; then
    echo "atcd-boot-confirm: $SENTINEL is not a regular file (ATC-E0184)." >&2
    echo "atcd-boot-confirm: skipped the count and the rollback, and wrote nothing." >&2
    echo "atcd-boot-confirm: replace it with a regular file that holds 6, then restart atcd." >&2
    exit 0
  fi
fi
layout="$(cat "$SENTINEL" 2> /dev/null || true)"
if [ "$layout" = 6 ] && reads_only_v5 "$ATCD"; then
  ATCD_CURRENT="$ATCD_RELEASE_ROOT/current/atcd/atcd"
  cur_lv=
  if [ -z "${ATCD_BIN:-}" ] && [ "$ATCD" != "$ATCD_CURRENT" ] &&
    [ -f "$ATCD_CURRENT" ] && [ -x "$ATCD_CURRENT" ]; then
    cur_lv="$(bounded "$PROBE_SECS" "$ATCD_CURRENT" layout-version 2> /dev/null)" || cur_lv=
  fi
  # A later atcd reads layout 6 too, so any integer of 6 or more qualifies.
  case "$cur_lv" in '' | *[!0-9]*) cur_lv=0 ;; esac
  if [ "$cur_lv" -ge 6 ]; then
    echo "atcd-boot-confirm: the store has layout 6 and the confirmed atcd reads only" >&2
    echo "atcd-boot-confirm: layout 5, so the count and any rollback use the current atcd." >&2
    ATCD="$ATCD_CURRENT"
  else
    echo "atcd-boot-confirm: the store has layout 6, and this atcd reads only layout 5." >&2
    echo "atcd-boot-confirm: skipped the count and the rollback, and wrote nothing." >&2
    echo "atcd-boot-confirm: run 'atc bootstrap atcd install' with a current atcd to repair it." >&2
    exit 0
  fi
fi

count_raw="$(bounded "$COUNT_SECS" "$ATCD" boot-confirm increment --store-root "$STORE_ROOT" 2> /dev/null)" &&
  increment_rc=0 || increment_rc=$?
# #1099: the numeric test below must never die with "[: Illegal number", so an
# unparseable count still becomes 0. But 0 NEVER triggers a rollback, so a
# silent coercion is a silently DISABLED safety net. Say so, loudly, on stderr:
# this runs as an ExecStartPre, so stderr is journald and an operator debugging
# a boot loop can see why the guard did nothing.
#
# EXIT STATUS FIRST, output second. atcd can fail nonzero AFTER writing a partial
# line, so a non-empty count_raw does not mean atcd succeeded. Classifying on the
# output before the exit code would report a "bad output" contract violation for
# what is really a failed command, sending an operator down the wrong recovery.
if [ "$increment_rc" = "$TIMED_OUT" ]; then
  # ATC-91: under contract 2 the count runs the confirmed atcd. So a count
  # that hangs is most likely a slow disk, not a bad release, and one stall
  # must not roll back. This start is not counted, and the guard goes on.
  echo "atcd-boot-confirm: WARNING 'atcd boot-confirm increment' hung for ${COUNT_SECS} s and was killed;" >&2
  echo "atcd-boot-confirm: this start is not counted, and the guard is INERT for it." >&2
  count=0
elif [ "$increment_rc" != 0 ]; then
  # atcd did not complete: it could not exec, or it exited nonzero (whatever it
  # managed to print is unreliable). Both are out of this guard's reach --
  # increment and rollback are atcd subcommands, so a broken binary leaves the
  # counter stuck. Recovery is an external re-seed from a KNOWN-GOOD atcd you
  # bring to the device (re-run `atc bootstrap atcd install`, or scp a binary
  # and `install-self` from it) -- NOT from /usr/local/bin/atcd, which is a
  # symlink to the very store binary that just failed to run.
  echo "atcd-boot-confirm: WARNING 'atcd boot-confirm increment' did not complete;" >&2
  echo "atcd-boot-confirm: guard INERT, recover by re-seeding atcd externally." >&2
  count=0
else
  # increment exited 0, so now its OUTPUT is the contract.
  case "$count_raw" in
    '')
      echo "atcd-boot-confirm: WARNING increment exited 0 but printed nothing;" >&2
      echo "atcd-boot-confirm: the A/B rollback guard is INERT for this boot." >&2
      count=0
      ;;
    *[!0-9]*)
      # A contract violation. `boot-confirm increment` must print a BARE INTEGER;
      # anything else (a prefix, padding, colour, a JSON object) disables A/B
      # rollback for every boot until it is fixed. The output format is frozen
      # for this reason.
      echo "atcd-boot-confirm: WARNING increment printed a non-integer:" >&2
      echo "atcd-boot-confirm:   $count_raw" >&2
      echo "atcd-boot-confirm: the A/B rollback guard is DISABLED until this is fixed." >&2
      echo "atcd-boot-confirm: 'atcd boot-confirm increment' must print a bare integer." >&2
      count=0
      ;;
    *)
      count="$count_raw"
      ;;
  esac
fi
# #3078: a FAILED revert is not a report that nothing can be reverted to.
# A root-run `atcd update` left parts of the store owned by root. The atc user
# could not open it. This guard's own revert hit the same EACCES. It then said
# "no prior version to revert to" while the prior version sat on disk.
#
# A probe that fails answers nothing. So classify on the EXIT CODE. atcd splits
# the two cases. NO_PRIOR_RELEASE_EXIT is the store's ANSWER that no prior
# delivery exists. See crates/atcd/src/self_update.rs. Every other nonzero exit
# leaves the question open. An open question must not read as an answer.
#
# This guard cannot repair the store. It runs as the unit's User=, which is the
# store owner on an isolated device. It cannot chown the store. It has no
# second identity to retry as. So it stays out of the way of the start, and it
# says what happened on stderr. Under ExecStartPre that stderr is journald.
NO_PRIOR_RELEASE_EXIT=4
# #6337: a prior version exists, but it is older than the settings rollback
# floor, the first store-aware atcd that confirmed a boot here. It cannot read
# the device settings, so atcd refuses to roll back to it. Its own code, not 4:
# this is not "no prior", and nothing was rolled back.
BELOW_SETTINGS_FLOOR_EXIT=5
if [ "$count" -gt "$LIMIT" ]; then
  echo "atcd-boot-confirm: $count attempts > $LIMIT — rolling back to prior atcd" >&2
  # #3382: capture atcd's own output instead of passing it straight through.
  # On the determined absence atcd writes `error: ...: ATC-E0129: ...`, and that
  # names an EXPECTED state: a device with one delivery has no prior one. The
  # line put dozens of `error` matches in every DUT journal and it buried the
  # real fault on two chaos-farm nights. Every OTHER outcome still gets atcd's
  # text verbatim, because the operator needs the store error under the verdict.
  # Capture the status now: the `elif` test overwrites `$?`.
  if [ -n "${ATCD_BOOT_CONFIRM_ROLLBACK_SECS:-}" ]; then
    rollback_secs="$ATCD_BOOT_CONFIRM_ROLLBACK_SECS"
  else
    # Keep the reset's limit out of the budget, so a reset after a slow
    # rollback still ends before systemd's start timeout.
    rollback_secs=$((BUDGET_SECS - COUNT_SECS - ($(date +%s) - GUARD_START)))
    if [ "$rollback_secs" -lt 10 ]; then rollback_secs=10; fi
  fi
  rollback_output="$(bounded "$rollback_secs" "$ATCD" rollback --store-root "$STORE_ROOT" 2>&1)" &&
    rollback_rc=0 || rollback_rc=$?
  if [ "$rollback_rc" = 0 ]; then
    if [ -n "$rollback_output" ]; then echo "$rollback_output" >&2; fi
    bounded "$COUNT_SECS" "$ATCD" boot-confirm reset --store-root "$STORE_ROOT" || true
    echo "atcd-boot-confirm: reverted to prior atcd" >&2
  elif [ "$rollback_rc" = "$NO_PRIOR_RELEASE_EXIT" ]; then
    # INFO, not an error. atcd's ATC-E0129 line is dropped here on purpose: it
    # is the store's ANSWER, and its wording reads as a failure. The exit code
    # already classified the outcome, so no diagnostic is lost.
    echo "atcd-boot-confirm: INFO no prior version to revert to; continuing." >&2
    echo "atcd-boot-confirm: INFO a device with one delivery has no prior one." >&2
  elif [ "$rollback_rc" = "$BELOW_SETTINGS_FLOOR_EXIT" ]; then
    if [ -n "$rollback_output" ]; then echo "$rollback_output" >&2; fi
    echo "atcd-boot-confirm: WARNING a prior version exists below the settings rollback" >&2
    echo "atcd-boot-confirm: floor (atcd's line above names the cause), so atcd stays." >&2
    echo "atcd-boot-confirm: recover by re-seeding a store-aware atcd (atc bootstrap atcd install)." >&2
  elif [ "$rollback_rc" = "$TIMED_OUT" ]; then
    # The kill can stop a store move part way. atcd must not start on such a
    # store, so this start fails. The count stays over the limit, so the next
    # start runs the rollback again, and the move goes on from where it
    # stopped.
    if [ -n "$rollback_output" ]; then echo "$rollback_output" >&2; fi
    echo "atcd-boot-confirm: WARNING 'atcd rollback' ran for ${rollback_secs} s and was killed." >&2
    echo "atcd-boot-confirm: this start fails, and the next start runs the rollback again." >&2
    exit 1
  else
    if [ -n "$rollback_output" ]; then echo "$rollback_output" >&2; fi
    echo "atcd-boot-confirm: WARNING the revert FAILED with exit $rollback_rc." >&2
    echo "atcd-boot-confirm: whether a prior version exists is UNKNOWN. This is" >&2
    echo "atcd-boot-confirm: NOT a report that there is none. Read atcd's error above." >&2
    echo "atcd-boot-confirm: a store this user cannot open gives this exit. Compare the" >&2
    echo "atcd-boot-confirm: owner of $STORE_ROOT with the unit's User=, then repair the" >&2
    echo "atcd-boot-confirm: owner and run 'systemctl reset-failed atcd; systemctl restart atcd'." >&2
  fi
fi
exit 0
