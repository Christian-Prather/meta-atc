#!/usr/bin/env bash
# tests/atc-bundle-hook_test.sh
#
# Tests for meta-atc's bundle hook, which carries the device-local state that
# `atc bootstrap` writes into the new slot of an OS update.
#
# 1. Coverage. Every absolute path under /etc, /var/lib or /usr/local that the
#    bootstrap installer's source or `atcd --setup-rootless`'s source names must
#    fall under a pattern in the hook's CARRY list, or under an exemption below
#    that gives its reason. A new file that bootstrap stages
#    and the hook does not carry fails here, not as an update that reverts on
#    every device.
#    The scan sees only literal absolute paths. A path that the source builds
#    with join(), such as the podman helpers, the AppArmor profile and the
#    delegate drop-in, escapes it. The behaviour fixtures cover those paths.
# 2. Behaviour. The real hook runs against a fixture rootfs and a fixture new
#    slot. It must carry the state, keep the new image's own files, and merge
#    /etc/subuid and /etc/subgid.
#
# Usage: atc-bundle-hook_test.sh <hook> [<src-dir>...]
#   each <src-dir> is atc Rust source that writes device state:
#   crates/atc-cmd-bootstrap/src, and crates/atcd/src/setup_rootless. With no
#   <src-dir>, part 1 is skipped and the test says so.
set -euo pipefail

HOOK="${1:?usage: atc-bundle-hook_test.sh <hook> [<src-dir>...]}"
shift
SRCS=("$@")
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# Paths the installer names that the hook does not carry, each with its reason.
EXEMPT=(
  # The unit directory itself. The hook carries the files in it by name.
  "/etc/systemd/system"
  # systemctl set-property writes here at runtime. It is not bootstrap state.
  "/etc/systemd/system.control"
  # The hook user's home, /var/lib/{hook_user}. The image creates it in both
  # slots (atc-ab-runtime.inc), and its content is engine storage, not config.
  # Compared as a string, so it exempts that one derived path only.
  "/var/lib/*"
  # Lines that bootstrap appends to files the image ships. The hook merges
  # them; see MERGE in the hook.
  "/etc/subuid"
  "/etc/subgid"
  # setup-rootless's messages name /etc/{label}, which is /etc/subuid or
  # /etc/subgid. Both are merged.
  "/etc/*"
  # Read only: setup-rootless checks the subid backend and the distro's own
  # skopeo profile, and writes neither.
  "/etc/nsswitch.conf"
  "/etc/apparmor.d/skopeo"
  # Base directories. The image creates them, and the hook carries the files
  # in them by name.
  "/etc/apparmor.d"
  "/usr/local/bin"
  "/usr/local/libexec"
  # A unit search path that bootstrap reads, never writes.
  "/usr/local/lib/systemd/system"
  # A fixture in the inline tests of bootstrap's enrollment.rs.
  "/usr/local/bin/atcd-wrapper"
)

# ── 1. Coverage ──────────────────────────────────────────────────────────────

carry="$(sed -n '/^# BEGIN CARRY$/,/^# END CARRY$/{/^#/d;p;}' "$HOOK")"
[ -n "$carry" ] || fail "the hook has no CARRY list between its markers"
grep -q '^MERGE=.*/etc/subuid.*/etc/subgid' "$HOOK" ||
  fail "the hook does not merge /etc/subuid and /etc/subgid"

coverage() {
  # The paths: string literals under /etc, /var/lib or /usr/local in the
  # sources, test files excluded. A format placeholder becomes a glob. A message
  # that follows the path is cut at the first space, and a trailing ':', '.' or
  # ',' goes.
  mapfile -t paths < <(
    find -L "${SRCS[@]}" -name '*.rs' ! -name '*_tests.rs' ! -name 'test_support.rs' -print0 |
      xargs -0 grep -ohE '"/(etc|var/lib|usr/local)/[^"]*"' |
      tr -d '"' | sed -E 's/\{[^}]*\}/*/g; s/ .*//; s/[:.,]$//' | sort -u
  )
  [ "${#paths[@]}" -ge 10 ] || fail "found only ${#paths[@]} installer paths in ${SRCS[*]}"
  # Each source must name at least one path, so a wrong directory argument fails
  # instead of shrinking the set.
  for src in "${SRCS[@]}"; do
    find -L "$src" -name '*.rs' ! -name '*_tests.rs' -print0 |
      xargs -0 grep -qE '"/(etc|var/lib|usr/local)/' ||
      fail "$src names no path under /etc, /var/lib or /usr/local"
  done

  covered() {
    local path="$1" pattern
    while IFS= read -r pattern; do
      # shellcheck disable=SC2254  # the pattern IS a glob
      case "$path" in $pattern | $pattern/*) return 0 ;; esac
    done <<< "$carry"
    exempt "$path"
  }

  exempt() {
    local path="$1" e
    for e in "${EXEMPT[@]}"; do
      [ "$path" = "$e" ] && return 0
    done
    return 1
  }

  for path in "${paths[@]}"; do
    covered "$path" || fail "the source names $path, and the hook carries nothing that covers it"
  done
  echo "ok: the hook covers ${#paths[@]} installer paths"
}

if [ "${#SRCS[@]}" -gt 0 ]; then
  coverage
else
  echo "skip: part 1 (coverage) needs the atc source directories" >&2
fi

# The hook must not lean on a cp flag whose meaning moved between coreutils
# releases: -n exits 1 on a skipped file in 9.2 to 9.4, which the image ships,
# and --update=none does not exist before 9.3. The host running this test may
# carry any of them, so the behaviour below cannot see the difference.
if grep -qE "^[^#]*\\bcp\\b.*( -[a-zA-Z]*n[a-zA-Z]* | --update| --no-clobber)" "$HOOK"; then
  fail "the hook runs cp with -n or --update; copy only a path the new slot lacks"
fi

# ── 2. Behaviour ─────────────────────────────────────────────────────────────

old="$tmp/old" new="$tmp/new"
mkdir -p "$old/etc/atc" "$old/etc/sudoers.d" "$old/etc/systemd/system/atcd.service.d" \
  "$old/etc/systemd/system/multi-user.target.wants" "$old/etc/systemd/system/user@2001.service.d" \
  "$new/etc/systemd/system/multi-user.target.wants"
printf 'ca\n' > "$old/etc/atc/ca.pem"
printf 'token\n' > "$old/etc/atc/enroll.token"
printf '[Service]\n' > "$old/etc/systemd/system/atcd.service"
printf 'drop-in\n' > "$old/etc/systemd/system/atcd.service.d/10-groups.conf"
printf 'stop\n' > "$old/etc/systemd/system/user@2001.service.d/90-atc.conf"
ln -s /etc/systemd/system/atcd.service "$old/etc/systemd/system/multi-user.target.wants/atcd.service"
printf 'sudo\n' > "$old/etc/sudoers.d/atc-shell"
# What `atcd --setup-rootless` wrote.
# The helpers are setuid and the pin is 0644; the resolver and the pin reader
# refuse any other mode, so the test checks the modes survive the copy.
helpers_rel="usr/local/libexec/atc-podman/helpers/0123abcd"
mkdir -p "$old/etc/sysctl.d" "$old/etc/apparmor.d" "$old/$helpers_rel" \
  "$old/etc/systemd/system/user@2001.service.d"
printf 'user.max_user_namespaces = 15000\n' > "$old/etc/sysctl.d/70-atc-podman-rootless.conf"
printf 'profile atc_podman {}\n' > "$old/etc/apparmor.d/atc_podman"
printf '{}\n' > "$old/usr/local/libexec/atc-podman/provisioned.json"
chmod 0644 "$old/usr/local/libexec/atc-podman/provisioned.json"
printf 'helper\n' > "$old/$helpers_rel/newuidmap"
chmod 4750 "$old/$helpers_rel/newuidmap"
printf '[Service]\nDelegate=yes\n' > "$old/etc/systemd/system/user@2001.service.d/50-atc-podman-delegate.conf"
printf 'restore\n' > "$old/usr/local/libexec/.atcd-settings-restore"
mkdir -p "$old/var/lib/systemd/linger"
: > "$old/var/lib/systemd/linger/atc-hooks"
printf 'old image unit\n' > "$old/etc/systemd/system/image.service"
# Image-owned entries the new image dropped: a mask, an enable link to a
# packaged unit, and a drop-in for a packaged unit. None is device-local, so
# none may come back.
ln -s /dev/null "$old/etc/systemd/system/masked.service"
mkdir -p "$old/etc/systemd/system/serial-getty@.service.d"
mkdir -p "$old/etc/systemd/system/user@.service.d"
printf 'template\n' > "$old/etc/systemd/system/user@.service.d/10-image.conf"
printf 'autologin\n' > "$old/etc/systemd/system/serial-getty@.service.d/autologin.conf"
ln -s /usr/lib/systemd/system/telnetd.service "$old/etc/systemd/system/multi-user.target.wants/telnetd.service"
printf 'new image unit\n' > "$new/etc/systemd/system/image.service"
printf 'root:100000:65536\natc-hooks:200000:65536\n' > "$old/etc/subuid"
printf 'root:100000:65536\n' > "$new/etc/subuid"
# A directory both sides have: the hook walks it, carries the old children and
# keeps the new image's own file.
mkdir -p "$new/etc/atc"
printf 'image\n' > "$new/etc/atc/image.conf"
# The push plane's paths: the atcd link bootstrap writes, the host keys sshd
# made at the old slot's first boot, and the deploy user's key. The new image
# ships the directories, its own sshd_config, and no keys.
mkdir -p "$old/usr/local/bin" "$old/etc/ssh" "$old/home/atc-deploy/.ssh" \
  "$new/usr/local/bin" "$new/etc/ssh" "$new/home/atc-deploy"
ln -s /var/atc/channel/agency/atcd/delivery/current/atcd/atcd "$old/usr/local/bin/atcd"
printf 'host key\n' > "$old/etc/ssh/ssh_host_ed25519_key"
printf 'host pub\n' > "$old/etc/ssh/ssh_host_ed25519_key.pub"
printf 'old config\n' > "$old/etc/ssh/sshd_config"
printf 'new config\n' > "$new/etc/ssh/sshd_config"
printf 'ssh-ed25519 AAAA operator\n' > "$old/home/atc-deploy/.ssh/authorized_keys"
# The new slot's passwd names the deploy user. The test runs unprivileged, so
# the ids are the runner's own: chown to them succeeds, and a hook that skips
# the chown or names another file fails below.
mkdir -p "$new/etc"
printf 'atc-deploy:x:%s:%s::/home/atc-deploy:/bin/sh\n' "$(id -u)" "$(id -g)" > "$new/etc/passwd"

# A logging chown first on PATH: an unprivileged test cannot change an owner,
# so the log is how the test sees what the hook asked for.
mkdir -p "$tmp/stub"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$tmp/chown.log" > "$tmp/stub/chown"
chmod +x "$tmp/stub/chown"

# Run under a narrow umask, so the hook's own `umask 022` is what decides the
# mode of a parent directory it creates.
(
  umask 077
  PATH="$tmp/stub:$PATH" ATC_HOOK_SOURCE_ROOT="$old" RAUC_SLOT_CLASS=rootfs RAUC_SLOT_MOUNT_POINT="$new" \
    sh "$HOOK" slot-post-install
) > "$tmp/out" 2>&1 || {
  fail "the hook exited non-zero: $(cat "$tmp/out")"
}
# The fixture new slot has no /usr/local/libexec, so the hook created it. The
# podman resolver refuses a writable parent, and podman must traverse it.
[ "$(stat -c %a "$new/usr/local/libexec")" = 755 ] ||
  fail "the hook created /usr/local/libexec at mode $(stat -c %a "$new/usr/local/libexec"), not 755"
[ "$(stat -c %a "$new/usr/local/libexec/atc-podman")" = "$(stat -c %a "$old/usr/local/libexec/atc-podman")" ] ||
  fail "the carried atc-podman directory changed its mode"

for f in etc/atc/ca.pem etc/atc/enroll.token etc/systemd/system/atcd.service \
  etc/systemd/system/atcd.service.d/10-groups.conf \
  etc/systemd/system/user@2001.service.d/90-atc.conf etc/sudoers.d/atc-shell \
  var/lib/systemd/linger/atc-hooks etc/ssh/ssh_host_ed25519_key \
  etc/sysctl.d/70-atc-podman-rootless.conf etc/apparmor.d/atc_podman \
  usr/local/libexec/atc-podman/provisioned.json "$helpers_rel/newuidmap" \
  etc/systemd/system/user@2001.service.d/50-atc-podman-delegate.conf \
  usr/local/libexec/.atcd-settings-restore \
  etc/ssh/ssh_host_ed25519_key.pub home/atc-deploy/.ssh/authorized_keys; do
  cmp -s "$old/$f" "$new/$f" || fail "the hook did not carry /$f"
done
[ "$(readlink "$new/usr/local/bin/atcd")" = /var/atc/channel/agency/atcd/delivery/current/atcd/atcd ] ||
  fail "the hook did not carry the /usr/local/bin/atcd link"
grep -qxF -- "-R $(id -u):$(id -g) $new/home/atc-deploy/.ssh" "$tmp/chown.log" ||
  fail "the hook did not hand the carried ~/.ssh to the deploy user: $(cat "$tmp/chown.log" 2> /dev/null)"
[ "$(stat -c %a "$new/$helpers_rel/newuidmap")" = 4750 ] ||
  fail "the carried podman helper lost its mode: $(stat -c %a "$new/$helpers_rel/newuidmap")"
[ "$(stat -c %a "$new/usr/local/libexec/atc-podman/provisioned.json")" = 644 ] ||
  fail "the carried podman pin is not 0644"
grep -qx 'new config' "$new/etc/ssh/sshd_config" ||
  fail "the hook replaced the sshd_config the new image ships"
[ "$(readlink "$new/etc/systemd/system/multi-user.target.wants/atcd.service")" = \
  /etc/systemd/system/atcd.service ] || fail "the hook did not carry the wants link"
for f in etc/systemd/system/masked.service etc/systemd/system/multi-user.target.wants/telnetd.service \
  etc/systemd/system/serial-getty@.service.d etc/systemd/system/user@.service.d; do
  if [ -e "$new/$f" ] || [ -L "$new/$f" ]; then
    fail "the hook carried /$f, which the image owns"
  fi
done
grep -qx 'image' "$new/etc/atc/image.conf" ||
  fail "the hook lost a file the new image ships under /etc/atc"
grep -qx 'new image unit' "$new/etc/systemd/system/image.service" ||
  fail "the hook replaced a unit the new image ships"
if [ "$(grep -c . "$new/etc/subuid")" != 2 ] || ! grep -qx 'atc-hooks:200000:65536' "$new/etc/subuid"; then
  fail "the hook did not merge /etc/subuid: $(cat "$new/etc/subuid")"
fi

# A device that never ran `atcd --setup-rootless` gets none of its state: the
# hook carries a path only when the old slot has it, so an update does not turn
# rootless podman on.
plain_old="$tmp/plain-old" plain_new="$tmp/plain-new"
mkdir -p "$plain_old/etc/atc" "$plain_new/etc"
printf 'ca\n' > "$plain_old/etc/atc/ca.pem"
ATC_HOOK_SOURCE_ROOT="$plain_old" RAUC_SLOT_CLASS=rootfs RAUC_SLOT_MOUNT_POINT="$plain_new" \
  sh "$HOOK" slot-post-install > /dev/null 2>&1 || fail "the hook failed on a device with no rootless setup"
for f in etc/sysctl.d/70-atc-podman-rootless.conf etc/apparmor.d/atc_podman usr/local/libexec/atc-podman; do
  if [ -e "$plain_new/$f" ]; then
    fail "the hook created /$f on a device that never ran setup-rootless"
  fi
done
cmp -s "$plain_old/etc/atc/ca.pem" "$plain_new/etc/atc/ca.pem" ||
  fail "the hook did not carry /etc/atc on a device with no rootless setup"

# A second run changes nothing: RAUC can retry an install.
ATC_HOOK_SOURCE_ROOT="$old" RAUC_SLOT_CLASS=rootfs RAUC_SLOT_MOUNT_POINT="$new" \
  sh "$HOOK" slot-post-install > /dev/null 2>&1
[ "$(grep -c . "$new/etc/subuid")" = 2 ] || fail "a second run duplicated /etc/subuid lines"

# A failed chown must fail the hook, so that RAUC fails the install instead
# of leaving a key sshd refuses.
printf '#!/bin/sh\nexit 1\n' > "$tmp/stub/chown"
fail_new="$tmp/new-chown-fails"
mkdir -p "$fail_new/etc"
cp "$new/etc/passwd" "$fail_new/etc/passwd"
if PATH="$tmp/stub:$PATH" ATC_HOOK_SOURCE_ROOT="$old" RAUC_SLOT_CLASS=rootfs \
  RAUC_SLOT_MOUNT_POINT="$fail_new" sh "$HOOK" slot-post-install > /dev/null 2>&1; then
  fail "the hook succeeded although chown failed"
fi

if [ "$failures" -gt 0 ]; then
  echo "atc-bundle-hook_test: $failures failure(s)" >&2
  exit 1
fi
echo "atc-bundle-hook_test: all checks passed"
