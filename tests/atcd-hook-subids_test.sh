#!/usr/bin/env bash
# tests/atcd-hook-subids_test.sh
#
# Test of recipes-core/atc/files/atcd-hook-subids, the script that gives
# atc-hooks its subordinate ids at rootfs time and at each boot. Each case runs
# the script against a temporary root, with the values that do_install sets.
# The cases cover a read-only-rootfs image, where the image has neither file, a
# normal image, where the postinst already wrote them, and a read-only /etc.
#
# Usage: atcd-hook-subids_test.sh <path-to-atcd-hook-subids>
set -euo pipefail

SRC="${1:?usage: atcd-hook-subids_test.sh <path-to-atcd-hook-subids>}"

failures=0
tmp="$(mktemp -d)"
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT

line="atc-hooks:1879048192:65536"
# The script as do_install installs it.
script="$tmp/atcd-hook-subids"
sed -e 's#@ATC_HOOKS_SUBID_BASE@#1879048192#' -e 's#@ATC_HOOKS_SUBID_COUNT@#65536#' \
  "$SRC" > "$script"

ok() { echo "ok: $1"; }
bad() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# new_root <name>: an empty root with an /etc directory.
new_root() {
  mkdir -p "$tmp/$1/etc"
  printf '%s' "$tmp/$1"
}

# run_script <root>: run the script, keep its exit status, stdout and stderr.
run_script() {
  set +e
  sh "$script" "$1" > "$tmp/out" 2> "$tmp/err"
  status=$?
  set -e
}

# 1. A read-only-rootfs image: shadow left with both files.
r="$(new_root missing)"
run_script "$r"
for f in subuid subgid; do
  if [ "$status" -eq 0 ] && [ "$(cat "$r/etc/$f")" = "$line" ] &&
    [ "$(stat -c %a "$r/etc/$f")" = 644 ]; then
    ok "a missing /etc/$f is made with the range, mode 0644"
  else
    bad "missing /etc/$f: exit $status, content [$(cat "$r/etc/$f" 2> /dev/null)], $(cat "$tmp/err")"
  fi
done

# 2. A second boot changes nothing.
cp "$r/etc/subuid" "$tmp/subuid.before"
run_script "$r"
if [ "$status" -eq 0 ] && cmp -s "$tmp/subuid.before" "$r/etc/subuid" && [ ! -s "$tmp/out" ]; then
  ok "a second run leaves the files as they are"
else
  bad "second run: exit $status, out [$(cat "$tmp/out")]"
fi

# 3. A normal image: the files have an atc-hooks line, also with other values.
r="$(new_root present)"
printf 'root:100000:65536\natc-hooks:200000:1000\n' > "$r/etc/subuid"
printf 'atc-hooks:200000:1000\n' > "$r/etc/subgid"
cp "$r/etc/subuid" "$tmp/present.subuid"
run_script "$r"
if [ "$status" -eq 0 ] && cmp -s "$tmp/present.subuid" "$r/etc/subuid"; then
  ok "an atc-hooks line that is there stays as it is"
else
  bad "present line: exit $status, content [$(cat "$r/etc/subuid")]"
fi

# 4. Other users' lines stay, and the range goes after them.
r="$(new_root others)"
printf 'root:100000:65536\n' > "$r/etc/subuid"
printf 'root:100000:65536' > "$r/etc/subgid"
run_script "$r"
want="$(printf 'root:100000:65536\n%s' "$line")"
if [ "$status" -eq 0 ] && [ "$(cat "$r/etc/subuid")" = "$want" ]; then
  ok "other lines stay, and the range is added after them"
else
  bad "other lines: exit $status, content [$(cat "$r/etc/subuid")]"
fi
if [ "$(cat "$r/etc/subgid")" = "$want" ]; then
  ok "a last line with no newline does not join the range"
else
  bad "no newline: content [$(cat "$r/etc/subgid")]"
fi

# 5. "atc-hooks-old" is another user. Its line does not count.
r="$(new_root prefix)"
printf 'atc-hooks-old:300000:65536\n' > "$r/etc/subuid"
run_script "$r"
if [ "$status" -eq 0 ] && grep -qx "$line" "$r/etc/subuid"; then
  ok "a user whose name starts with atc-hooks does not count"
else
  bad "prefix user: exit $status, content [$(cat "$r/etc/subuid")]"
fi

# 6. A read-only /etc with no range: the script fails and names the file. Root
#    can write a 0555 directory, so the case runs only as another user.
if [ "$(id -u)" -ne 0 ]; then
  r="$(new_root readonly)"
  chmod 0555 "$r/etc"
  run_script "$r"
  if [ "$status" -eq 1 ] && grep -q "cannot write $r/etc/subuid" "$tmp/err" &&
    grep -q "cannot write $r/etc/subgid" "$tmp/err"; then
    ok "a read-only /etc fails the script and names each file"
  else
    bad "read-only /etc: exit $status, err [$(cat "$tmp/err")]"
  fi

  # 7. A read-only /etc that has the ranges is not an error.
  r="$(new_root readonly-present)"
  printf '%s\n' "$line" > "$r/etc/subuid"
  printf '%s\n' "$line" > "$r/etc/subgid"
  chmod 0555 "$r/etc"
  chmod 0444 "$r/etc/subuid" "$r/etc/subgid"
  run_script "$r"
  if [ "$status" -eq 0 ]; then
    ok "a read-only /etc that has the ranges passes"
  else
    bad "read-only /etc with ranges: exit $status, err [$(cat "$tmp/err")]"
  fi
else
  echo "skip: the read-only /etc cases need a user other than root"
fi

# 8. A script that do_install did not fill in refuses to write a placeholder.
r="$(new_root placeholder)"
set +e
sh "$SRC" "$r" > /dev/null 2> "$tmp/err"
status=$?
set -e
if [ "$status" -eq 1 ] && [ ! -e "$r/etc/subuid" ] && grep -q placeholder "$tmp/err"; then
  ok "a script with no values from do_install writes nothing"
else
  bad "placeholder: exit $status, err [$(cat "$tmp/err")]"
fi

if [ "$failures" -gt 0 ]; then
  echo "atcd-hook-subids_test: $failures case(s) failed" >&2
  exit 1
fi
echo "atcd-hook-subids_test: all cases passed"
