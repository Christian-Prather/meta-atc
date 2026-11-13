# shellcheck shell=bash
# The caller sets ACCEL and the timeouts, so they are not assigned here.
# shellcheck disable=SC2153
#
# scripts/lib/qemu-guest.sh
#
# The qemu guest driver for the RAUC proof and the fault suite. This is the
# one place that knows how to boot the A/B disk through OVMF and how to talk to
# its serial console. qemu-rauc-proof.sh and qemu-rauc-faults.sh source it.
#
# THE CONTRACT. The caller defines die(), and sets:
#
#   QEMU             the qemu-system-x86_64 binary
#   ACCEL            kvm or tcg
#   WORK_DIR         where serial.log, qemu.log and qemu-command.txt go
#   BOOT_TIMEOUT     seconds from a reset to the login prompt, under KVM
#   COMMAND_TIMEOUT  seconds for one guest command, under KVM
#   TCG_FACTOR       the multiplier for every timeout under TCG
#
# GUEST_DISK_CACHE sets the cache mode of the A/B disk. The default is qemu's
# own, writeback. The power-cut cases use none. GUEST_DISK_FORMAT is raw by
# default; the end to end boots a qcow2 overlay on a read-only base disk.
#
# THE CONSOLE. The serial console is a TCP chardev with a logfile. Commands go
# in over the socket. Output is read back from the logfile, between two
# markers that each command prints, so a command's output is never confused
# with its echo.
#
# THE NETWORK MODE (qemu-rauc-e2e.sh). With GUEST_NETNS_PID unset, the guest
# has no NIC. With it set to the pid of a container, qemu runs in that
# container's network namespace (`podman unshare nsenter -n`) and gets a passt
# NIC: the guest takes the container's address by DHCP, GUEST_NETNS_DNS is its
# DNS server, and the container's TCP port 22 reaches the guest's sshd. The
# TCP console would then listen inside the namespace, out of this shell's
# reach, so the console is a unix socket and commands go in through socat.

GUEST_LOG=""
GUEST_FD=""
GUEST_PID=""
GUEST_N=0
GUEST_OUT=""
GUEST_DISK_CACHE="${GUEST_DISK_CACHE:-writeback}"
GUEST_DISK_FORMAT="${GUEST_DISK_FORMAT:-raw}"
GUEST_NETNS_PID="${GUEST_NETNS_PID:-}"
GUEST_NETNS_DNS="${GUEST_NETNS_DNS:-}"
GUEST_CONSOLE_SOCK=""
GUEST_CONSOLE_PID=""

# ── Pure helpers (the self-tests drive these) ────────────────────────────────

# A guest timeout for this accelerator.
scaled() {
  local seconds="$1" accel="$2"
  case "$accel" in
    kvm) echo "$seconds" ;;
    tcg) echo $((seconds * TCG_FACTOR)) ;;
    *) die "unknown accelerator '$accel'" ;;
  esac
}

# The NIC arguments, one per line, for DNS server $1. Empty $1, no NIC.
#
# Two passt settings matter here. `--no-map-gw`: passt maps the gateway
# address to the host by default, and the lab DNS server IS the gateway.
# `tcp-ports=22`: the container's port 22 reaches the guest's sshd. The
# container needs net.ipv4.ip_unprivileged_port_start=0 for that bind.
guest_nic_args() {
  if [ -z "$1" ]; then
    echo -nic
    echo none
    return
  fi
  echo -netdev
  echo "passt,id=n0,param=--no-map-gw,dns=$1,tcp-ports=22"
  echo -device
  echo virtio-net-pci,netdev=n0
}

# The output of guest command number $2 in serial log $1: the lines between
# its begin and end markers. Carriage returns are dropped. $3 is the byte of
# the log where the command was sent, 0 by default. Only bytes after it are
# read: a log that a second run appended to holds the same marker numbers.
#
# Each marker is matched at the END of a line. With the terminal echo off, the
# shell prompt and the begin marker share a line. Output with no final newline
# shares a line with the end marker.
marker_output() {
  # awk reads to the end rather than `exit` at the end marker. An early exit
  # can close the pipe while `tr` still writes the prompt after the marker,
  # and under pipefail that SIGPIPE (141) fails the caller with no message.
  tail -c +"$((${3:-0} + 1))" "$1" | tr -d '\r' | awk -v b="__B$2__\$" -v e="__E$2_[0-9]+__\$" '
    done { next }
    !inside && $0 ~ b { inside = 1; next }
    inside && $0 ~ e { sub(e, ""); if ($0 != "") print; done = 1; next }
    inside { print }
  '
}

# The exit status of guest command number $2, or empty while it still runs.
# $3 is the byte to read from, as for marker_output.
marker_status() {
  tail -c +"$((${3:-0} + 1))" "$1" | tr -d '\r' | sed -n "s/.*__E$2_\\([0-9][0-9]*\\)__\$/\\1/p" | tail -1
}

# One `name=value` from RAUC's `--output-format=shell` text on stdin.
shell_value() {
  sed -n "s/^$1='\\{0,1\\}\\([^']*\\)'\\{0,1\\}\$/\\1/p" | tail -1
}

# The boot status of the booted slot, from RAUC's shell output on stdin.
booted_boot_status() {
  awk -F= '
    { gsub(/'\''/, "", $2) }
    $1 ~ /^RAUC_SLOT_STATE_/ && $2 == "booted" { n = substr($1, 17) }
    $1 ~ /^RAUC_SLOT_BOOT_STATUS_/ { status[substr($1, 23)] = $2 }
    END { if (n != "") print status[n] }
  '
}

# Every guest command in the files $@ must parse as POSIX shell. A command
# with a quoting error is found here, not an hour into a TCG boot. Prints the
# number of commands it parsed.
#
# It reads the literal first argument of each `must` and `guest_run` call. A
# command that holds a `$` is skipped: its text exists only at run time.
guest_commands_parse() {
  local cmd n=0
  while IFS= read -r cmd; do
    n=$((n + 1))
    sh -n -c "$cmd" 2> /dev/null || die "guest command $n does not parse: $cmd"
  done < <(grep -hoE '(must|guest_run) "[^"]+"' "$@" |
    sed -E 's/^(must|guest_run) "//; s/"$//' | grep -v '\$')
  echo "$n"
}

# The self-test of the helpers above. $1 is a scratch directory.
qemu_guest_self_test() {
  local tmp="$1"
  [ "$(scaled 10 kvm)" = 10 ] || die "self-test: kvm scaling"
  [ "$(scaled 10 tcg)" = "$((10 * TCG_FACTOR))" ] || die "self-test: tcg scaling"
  (scaled 10 xen) > /dev/null 2>&1 && die "self-test: an unknown accelerator passed"
  printf 'echo __B3__; x; echo __E3_$?__\r\nroot@q:~# __B3__\r\nRAUC_X=1\r\nlast__E3_7__\r\n__B4__\r\n' > "$tmp/serial.log"
  [ "$(marker_output "$tmp/serial.log" 3)" = "$(printf 'RAUC_X=1\nlast')" ] ||
    die "self-test: marker output: $(marker_output "$tmp/serial.log" 3)"
  [ "$(marker_status "$tmp/serial.log" 3)" = 7 ] || die "self-test: marker status"
  [ -z "$(marker_status "$tmp/serial.log" 4)" ] || die "self-test: an open command has a status"
  # A second run appended to the same log: only the bytes after its offset count.
  local first
  first="$(wc -c < "$tmp/serial.log")"
  printf 'root@q:~# __B3__\r\nSECOND\r\n__E3_0__\r\n' >> "$tmp/serial.log"
  [ "$(marker_output "$tmp/serial.log" 3 "$first")" = SECOND ] ||
    die "self-test: marker output read an earlier run"
  [ "$(marker_status "$tmp/serial.log" 3 "$first")" = 0 ] || die "self-test: marker status of the second run"
  [ "$(printf "RAUC_BOOT_PRIMARY='rootfs.1'\n" | shell_value RAUC_BOOT_PRIMARY)" = rootfs.1 ] ||
    die "self-test: shell_value"
  printf '%s\n' "RAUC_SLOT_STATE_1='inactive'" "RAUC_SLOT_BOOT_STATUS_1='good'" \
    "RAUC_SLOT_STATE_2='booted'" "RAUC_SLOT_BOOT_STATUS_2='bad'" > "$tmp/status"
  [ "$(booted_boot_status < "$tmp/status")" = bad ] || die "self-test: booted_boot_status"
  [ "$(guest_nic_args '' | tr '\n' ' ')" = "-nic none " ] || die "self-test: no NIC without a namespace"
  [ "$(guest_nic_args 10.89.0.1 | sed -n 2p)" = "passt,id=n0,param=--no-map-gw,dns=10.89.0.1,tcp-ports=22" ] ||
    die "self-test: the passt NIC"
  printf '%s\n' 'must "echo ok"' 'guest_run "echo '"'"'open"' > "$tmp/cmds"
  (guest_commands_parse "$tmp/cmds") > /dev/null 2>&1 &&
    die "self-test: a guest command with an open quote parsed"
  return 0
}

# ── The guest driver ─────────────────────────────────────────────────────────

log_size() {
  stat -c %s "$GUEST_LOG" 2> /dev/null || echo 0
}

guest_alive() {
  [ -n "$GUEST_PID" ] && kill -0 "$GUEST_PID" 2> /dev/null
}

# Wait until extended regex $1 appears in the serial log after byte $3, for at
# most $2 seconds. GUEST_POLL sets the poll interval, 2 seconds by default.
guest_wait() {
  local re="$1" timeout="$2" from="$3" deadline
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if grep -Eq -- "$re" < <(tail -c +"$((from + 1))" "$GUEST_LOG" | tr -d '\r'); then
      return 0
    fi
    guest_alive || die "qemu exited while waiting for /$re/. See $GUEST_LOG"
    sleep "${GUEST_POLL:-2}"
  done
  echo "FAIL: no /$re/ on the serial console in ${timeout}s. See $GUEST_LOG" >&2
  return 1
}

guest_send() {
  printf '%s\n' "$1" >&"$GUEST_FD"
}

# Log in as root on the serial console, from byte $1 of the log.
guest_login() {
  local from="$1"
  guest_wait 'login: ' "$(scaled "$BOOT_TIMEOUT" "$ACCEL")" "$from" || return 1
  # Wait for the prompt from HERE, not from $from. The shell that ran `reboot`
  # prints one more prompt before it dies. A match on that prompt would send
  # the next command into the login program, which drops it.
  from="$(log_size)"
  guest_send root
  guest_wait 'root@[^ ]*:~# ' "$(scaled "$COMMAND_TIMEOUT" "$ACCEL")" "$from" || return 1
  # Quiet the kernel on the console and stop the terminal echo, so the log
  # holds command output only.
  guest_send 'dmesg -n 1; stty -echo'
}

# Run $1 in the guest and wait up to $2 seconds. The output lands in
# GUEST_OUT, and the return value is the command's exit status.
guest_run() {
  local cmd="$1" timeout="${2:-$(scaled "$COMMAND_TIMEOUT" "$ACCEL")}" from status
  GUEST_N=$((GUEST_N + 1))
  from="$(log_size)"
  guest_send "echo __B${GUEST_N}__; { $cmd ; } 2>&1; echo __E${GUEST_N}_\$?__"
  guest_wait "__E${GUEST_N}_[0-9]+__\$" "$timeout" "$from" || return 125
  GUEST_OUT="$(marker_output "$GUEST_LOG" "$GUEST_N" "$from")"
  status="$(marker_status "$GUEST_LOG" "$GUEST_N" "$from")"
  printf '  $ %s\n' "$cmd"
  # Indent each line by two spaces, so the command's output stands apart.
  [ -n "$GUEST_OUT" ] && printf '%s\n' "$GUEST_OUT" | sed 's/^/    /'
  printf '  (exit %s)\n' "$status"
  return "$status"
}

# Run $1 and fail unless it exits 0.
must() {
  guest_run "$@" || die "guest command failed: $1"
}

# Fail unless the last command's output matches extended regex $1.
expect_out() {
  grep -Eq -- "$1" <<< "$GUEST_OUT" || die "expected /$1/ in the output above"
}

guest_reboot() {
  local from
  from="$(log_size)"
  guest_send reboot
  guest_login "$from" || die "the guest did not come back after a reboot"
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Start the guest. $1 is the A/B disk, $2 the OVMF code, $3 the OVMF variables.
# Each further argument is `<name>=<bundle>`: the bundle attaches read-only as
# /dev/disk/by-id/virtio-<name>. A serial number names it, so the guest finds
# it whatever the order of the drives. The serial log is appended to, so a
# guest started again after a kill keeps one log.
guest_start() {
  local disk="$1" code="$2" vars="$3" port i spec name file n=0
  shift 3
  port="$(free_port)"
  GUEST_LOG="$WORK_DIR/serial.log"
  local qemu_args=(
    -machine "q35,i8042=off,accel=$ACCEL" -cpu IvyBridge -smp 4 -m 2048
    -drive "if=pflash,format=qcow2,readonly=on,file=$code"
    -drive "if=pflash,format=qcow2,file=$vars"
    -drive "file=$disk,format=$GUEST_DISK_FORMAT,if=virtio,cache=$GUEST_DISK_CACHE"
  )
  for spec in "$@"; do
    name="${spec%%=*}" file="${spec#*=}" n=$((n + 1))
    qemu_args+=(
      -drive "file=$file,format=raw,if=none,readonly=on,id=bundle$n"
      -device "virtio-blk-pci,drive=bundle$n,serial=$name"
    )
  done
  local nic
  # The NIC follows the namespace: a DNS address alone must not put a passt
  # NIC on this host's own network.
  mapfile -t nic < <(guest_nic_args "${GUEST_NETNS_PID:+$GUEST_NETNS_DNS}")
  qemu_args+=(-device i6300esb -display none -vga none -monitor none "${nic[@]}")
  if [ -n "$GUEST_NETNS_PID" ]; then
    guest_start_in_netns "${qemu_args[@]}"
    return
  fi
  qemu_args+=(
    -chardev "socket,id=ser0,host=127.0.0.1,port=$port,server=on,wait=off,logfile=$GUEST_LOG,logappend=on"
    -serial chardev:ser0
  )
  printf '%q ' "$QEMU" "${qemu_args[@]}" >> "$WORK_DIR/qemu-command.txt"
  echo >> "$WORK_DIR/qemu-command.txt"
  "$QEMU" "${qemu_args[@]}" >> "$WORK_DIR/qemu.log" 2>&1 &
  GUEST_PID=$!
  for i in $(seq 1 30); do
    # Probe in a subshell first: a failed `exec` redirection can end a
    # non-interactive shell.
    if (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null; then
      exec {GUEST_FD}<> "/dev/tcp/127.0.0.1/$port"
      # Drain the socket. The log already holds the bytes, and an unread
      # socket would stall the guest's console once its buffer fills.
      cat <&"$GUEST_FD" > /dev/null &
      return 0
    fi
    guest_alive || die "qemu exited at start (try $i). See $WORK_DIR/qemu.log"
    sleep 1
  done
  die "could not connect to the serial console on port $port"
}

# The network mode's start: qemu runs in the namespace of GUEST_NETNS_PID and
# daemonizes, so `podman unshare` returns, and the pidfile names qemu itself.
# `podman unshare` enters the rootless user and mount namespaces, and nsenter
# the network one. No pid namespace is entered, so the pid is a host pid. The disk
# paths are host paths.
#
# TMPDIR=/tmp: qemu writes passt's pid file under TMPDIR, /var/tmp by default,
# and Ubuntu's AppArmor profile for passt allows writes under /tmp and $HOME
# only. passt then refuses to start, and qemu exits with no NIC.
guest_start_in_netns() {
  local pidfile="$WORK_DIR/qemu.pid" i
  [ -n "$GUEST_NETNS_DNS" ] || die "GUEST_NETNS_PID needs GUEST_NETNS_DNS"
  GUEST_CONSOLE_SOCK="$WORK_DIR/console.sock"
  # A unix socket path holds at most 107 bytes. qemu refuses a longer one, and
  # only qemu.log would say why.
  [ "$(printf '%s' "$GUEST_CONSOLE_SOCK" | wc -c)" -lt 108 ] ||
    die "the console socket path $GUEST_CONSOLE_SOCK is over 107 bytes; choose a shorter work dir"
  rm -f "$pidfile" "$GUEST_CONSOLE_SOCK"
  local args=("$@"
    -chardev "socket,id=ser0,path=$GUEST_CONSOLE_SOCK,server=on,wait=off,logfile=$GUEST_LOG,logappend=on"
    -serial chardev:ser0 -daemonize -pidfile "$pidfile"
  )
  printf '%q ' "$QEMU" "${args[@]}" >> "$WORK_DIR/qemu-command.txt"
  echo >> "$WORK_DIR/qemu-command.txt"
  podman unshare nsenter -t "$GUEST_NETNS_PID" -n env TMPDIR=/tmp "$QEMU" "${args[@]}" \
    >> "$WORK_DIR/qemu.log" 2>&1 || die "qemu did not start in the namespace of $GUEST_NETNS_PID. See $WORK_DIR/qemu.log"
  for i in $(seq 1 30); do
    if [ -s "$pidfile" ] && [ -S "$GUEST_CONSOLE_SOCK" ]; then
      GUEST_PID="$(cat "$pidfile")"
      guest_console_connect
      return 0
    fi
    sleep 1
  done
  die "qemu wrote no pidfile or console socket in 30s (try $i). See $WORK_DIR/qemu.log"
}

# Open the unix console as one connection that lives as long as this shell.
# qemu's socket chardev serves one client at a time, and a client that reads
# nothing stalls the guest's console output (measured: the echo of a command
# stopped mid-line). So socat reads the commands from a FIFO and drains the
# output to /dev/null; the logfile already holds it. socat forks BEFORE this
# shell opens the FIFO, so socat holds no writer of its own. This shell is
# then the only writer: when it exits, socat reads EOF and frees the console.
# Opened the other way round, socat inherits a writer and keeps the console
# until qemu dies (measured: a later `console` call got no answer). No coproc:
# bash 3.2 cannot parse one, and the macOS job parses every tracked script.
guest_console_connect() {
  local fifo="$WORK_DIR/console.in"
  rm -f "$fifo"
  mkfifo "$fifo"
  socat - "UNIX-CONNECT:$GUEST_CONSOLE_SOCK" < "$fifo" > /dev/null 2>&1 &
  GUEST_CONSOLE_PID=$!
  # Read-write, so this open does not block. It also completes socat's
  # read-open, which waits for a writer.
  exec {GUEST_FD}<> "$fifo"
}

# Stop the guest with SIGTERM, or with the signal in $1. SIGKILL is the
# power-cut approximation: qemu flushes nothing, and the guest's page cache
# and every request in flight are lost.
guest_stop() {
  local signal="${1:-TERM}" i
  if guest_alive; then
    kill -s "$signal" "$GUEST_PID" 2> /dev/null || true
    wait "$GUEST_PID" 2> /dev/null || true
    # A daemonized qemu is no child of this shell, so `wait` returns at once.
    for i in $(seq 1 30); do
      guest_alive || break
      sleep 1
    done
    # Only a pid that is still a qemu: in 30 s it can belong to another process.
    if guest_alive && grep -q '^qemu-system' "/proc/$GUEST_PID/comm" 2> /dev/null; then
      kill -s KILL "$GUEST_PID" 2> /dev/null || true
    fi
  fi
  if [ -n "$GUEST_CONSOLE_PID" ]; then
    kill "$GUEST_CONSOLE_PID" 2> /dev/null || true
    GUEST_CONSOLE_PID=""
  fi
  if [ -n "$GUEST_FD" ]; then
    exec {GUEST_FD}>&-
    GUEST_FD=""
  fi
  GUEST_PID=""
}

# Power the guest off from its shell, wait for qemu to exit, then stop it if it
# has not. No end marker is awaited: the shell can die with the guest before
# it prints one, and a wait on the marker would then fail on a clean poweroff.
guest_poweroff() {
  local deadline
  guest_send poweroff
  deadline=$((SECONDS + $(scaled "$COMMAND_TIMEOUT" "$ACCEL")))
  while guest_alive && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
  done
  guest_stop
}

# ── Assertions in the guest ──────────────────────────────────────────────────

# The GRUB environment on the ESP, as `name=value` lines.
read_grubenv() {
  must "grub-editenv /boot/atc/grubenv list"
}

# The booted slot's RAUC boot status must be $1.
expect_booted_status() {
  local status
  must "rauc status --output-format=shell"
  status="$(booted_boot_status <<< "$GUEST_OUT")"
  [ "$status" = "$1" ] || die "RAUC reports the booted slot '$status', expected '$1'"
  echo "ok: RAUC reports the booted slot $1"
}

# GRUB booted slot $1, whose partition label is $2.
expect_slot() {
  local bootname="$1" label="$2"
  must "cat /proc/cmdline"
  expect_out "(^| )rauc\\.slot=$bootname( |\$)"
  expect_out "(^| )root=PARTLABEL=$label( |\$)"
  echo "ok: GRUB booted slot $bootname ($label)"
}
