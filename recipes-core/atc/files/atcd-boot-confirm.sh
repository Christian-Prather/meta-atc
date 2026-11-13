#!/usr/bin/env sh
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
ATCD="${ATCD_BIN:-$ATCD_CHANNEL/$ATCD_RELEASE_DIR/current/atcd/atcd}"

count_raw="$("$ATCD" boot-confirm increment --store-root "$STORE_ROOT" 2> /dev/null)" &&
  increment_ran=1 || increment_ran=0
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
if [ "$increment_ran" = 0 ]; then
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
  rollback_output="$("$ATCD" rollback --store-root "$STORE_ROOT" 2>&1)" &&
    rollback_rc=0 || rollback_rc=$?
  if [ "$rollback_rc" = 0 ]; then
    if [ -n "$rollback_output" ]; then echo "$rollback_output" >&2; fi
    "$ATCD" boot-confirm reset --store-root "$STORE_ROOT" || true
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
