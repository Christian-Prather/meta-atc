#!/usr/bin/env bash
# scripts/check-atc-ab-layout.sh
#
# The A/B slot contract spans files that no compiler reads together:
#
#   wic/atc-ab.wks.in                               partition labels
#   recipes-bsp/atc-grub-env/files/atc-ab-grub.cfg  the slot decision
#   recipes-bsp/atc-grub-env/atc-grub-env_1.0.bb    the initial grubenv
#   recipes-bsp/grub/grub-efi_%.bbappend            GRUB's built-ins
#   recipes-core/rauc/files/system.conf             RAUC's slots
#   recipes-core/rauc/files/atc-rauc.conf           the D-Bus policy
#   recipes-core/rauc/rauc_%.bbappend               the stock policy goes
#   recipes-core/bundles/atc-bundle.bb              the bundle
#   recipes-core/images/atc-ab-runtime.inc          the runtime profile
#   recipes-core/images/atc-image-ab.bb             what reaches the ESP
#   recipes-core/images/atc-image-slot.bb           the slot image
#
# Every failure this gate catches is SILENT at build time. A label renamed in
# the wks and not in grub.cfg still builds an image; it boots to a GRUB rescue
# prompt. A bootname that differs between system.conf and grub.cfg still
# installs; RAUC then marks a slot GRUB never boots. A save that the config
# skips still boots; it just never rolls back.
#
# It does NOT run the GRUB script. No offline tool can. The live proof is
# scripts/qemu-rauc-proof.sh, and scripts/qemu-rauc-faults.sh reaches
# every branch of the decision.
#
# Usage: check-atc-ab-layout.sh
#   META_ATC_ROOT   the layer to read. Defaults to this script's repository.
# shellcheck disable=SC2016  # every literal $NAME here is GRUB or bitbake text to match
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

L="$(cd "${META_ATC_ROOT:-$SCRIPT_DIR/..}" && pwd)"
WKS="$L/wic/atc-ab.wks.in"
GRUB_CFG="$L/recipes-bsp/atc-grub-env/files/atc-ab-grub.cfg"
RECIPE="$L/recipes-bsp/atc-grub-env/atc-grub-env_1.0.bb"
GRUB_APPEND="$L/recipes-bsp/grub/grub-efi_%.bbappend"
SYSTEM_CONF="$L/recipes-core/rauc/files/system.conf"
TEGRA_CONF="$L/recipes-core/rauc/files/system-nvbootctrl.conf"
RAUC_CONF_APPEND="$L/recipes-core/rauc/rauc-conf.bbappend"
OS_RECIPE="$L/recipes-core/atc-os/atc-os_1.0.bb"
SEAM="$L/classes/atc-slot-backend.bbclass"
POLICY="$L/recipes-core/rauc/files/atc-rauc.conf"
RAUC_APPEND="$L/recipes-core/rauc/rauc_%.bbappend"
BUNDLE="$L/recipes-core/bundles/atc-bundle.bb"
RUNTIME="$L/recipes-core/images/atc-ab-runtime.inc"
OS_DIR="$L/recipes-core/atc-os/files"
KERNEL_APPEND="$L/recipes-kernel/linux/linux-yocto_%.bbappend"
WATCHDOG_CFG="$L/recipes-kernel/linux/files/atc-watchdog.cfg"
IMAGE="$L/recipes-core/images/atc-image-ab.bb"
SLOT_IMAGE="$L/recipes-core/images/atc-image-slot.bb"
LAYER_CONF="$L/conf/layer.conf"
HOOK="$L/recipes-core/bundles/files/atc-bundle-hook"

# The seven variables grub.cfg reads, and their fail-closed defaults. The
# initial environment the recipe writes must hold exactly these values.
GRUB_VARS="ORDER A_OK A_TRY B_OK B_TRY ATC_STEADY ATC_TRIAL"
DEFAULTS=("ORDER=A B" "A_OK=1" "A_TRY=0" "B_OK=0" "B_TRY=0" "ATC_STEADY=A" "ATC_TRIAL=none")

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# The body of one GRUB script function. GRUB declares them as
# `function name {` and closes them with a `}` at column 0.
grub_function_body() {
  awk -v fn="$1" '
    $0 ~ "^function " fn " \\{" { inside = 1; next }
    inside && /^\}/ { exit }
    inside { print }
  ' "$GRUB_CFG"
}

# The first line number of the line that is exactly $1 in file $2, or empty.
line_of() {
  grep -m1 -nxF -- "$1" "$2" | cut -d: -f1
}

# One `key=value` from an INI section of system.conf. $1 section, $2 key.
conf_value() {
  awk -v sec="[$1]" -v key="$2" '
    /^\[/ { inside = ($0 == sec); next }
    inside && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$SYSTEM_CONF"
}

# The quoted value of `NAME = "value"` in a recipe. $1 name, $2 file.
bb_value() {
  sed -n "/^$1 = \"\\(.*\\)\"\$/{s//\\1/p;q;}" "$2"
}

for f in "$WKS" "$GRUB_CFG" "$RECIPE" "$GRUB_APPEND" "$SYSTEM_CONF" "$TEGRA_CONF" \
  "$RAUC_CONF_APPEND" "$OS_RECIPE" "$SEAM" "$OS_DIR/atc-slot-trial-grub" "$POLICY" \
  "$RAUC_APPEND" "$BUNDLE" "$RUNTIME" "$IMAGE" "$SLOT_IMAGE" \
  "$OS_DIR/atc-os-trial-deadline" "$OS_DIR/atc-os-trial-deadline.timer" \
  "$OS_DIR/atc-os-reboot.path" "$OS_DIR/atc-os-reboot.service" \
  "$OS_DIR/10-atc-store.conf" "$KERNEL_APPEND" "$WATCHDOG_CFG" "$LAYER_CONF" "$HOOK"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f" >&2
    exit 1
  fi
done

# ── Labels: the wks, grub.cfg and system.conf name the same partitions ───────

for label in atcesp atcroota atcrootb atcdata; do
  if ! grep -qE -- "--label $label\\b" "$WKS"; then
    fail "the wks declares no partition labelled '$label'"
  fi
done

for label in atcesp atcroota atcrootb; do
  if ! grep -qE "^set atc_(esp|slot_a|slot_b)_label=$label\$" "$GRUB_CFG"; then
    fail "grub.cfg does not bind the label '$label', which the wks writes"
  fi
done

# grub.cfg finds a slot by its partition NUMBER, because a slot that RAUC
# wrote carries no filesystem label. So the order of the parts is the contract.
wks_order="$(sed -n 's/^part .*--label \([a-z]*\) .*/\1/p' "$WKS" | tr '\n' ' ')"
[ "$wks_order" = "atcesp atcroota atcrootb atcdata " ] ||
  fail "the wks parts are '$wks_order', not 'atcesp atcroota atcrootb atcdata'." \
    "grub.cfg boots slot A from gpt2 and slot B from gpt3"
grep -qx 'set atc_slot_a_part=gpt2' "$GRUB_CFG" ||
  fail "grub.cfg does not boot slot A from gpt2, the wks's second part"
grep -qx 'set atc_slot_b_part=gpt3' "$GRUB_CFG" ||
  fail "grub.cfg does not boot slot B from gpt3, the wks's third part"
grep -qx '    set root=($atc_disk,$atc_root_part)' "$GRUB_CFG" ||
  fail "grub.cfg does not set root from the ESP's disk and the slot's part." \
    "A filesystem label search finds no slot that RAUC wrote"

if grep -qE '^part +/[^ ]' "$WKS"; then
  fail "a wks part declares a mountpoint other than /, so wic writes an fstab" \
    "line naming /dev/sdaN on a virtio disk and the boot stalls 90 seconds"
fi

data_mib="$(sed -n 's/.*--label atcdata .*--fixed-size \([0-9][0-9]*\)M.*/\1/p' "$WKS")"
if [ -z "$data_mib" ] || [ "$data_mib" -lt 4096 ]; then
  fail "atcdata is '${data_mib:-unset}' MiB. The store holds the bundle plus a 1 GiB" \
    "margin, so it needs at least 4096 MiB"
fi

# ── system.conf against grub.cfg: the bootnames and the slot devices ────────

# Each RAUC slot's bootname must be the name grub.cfg puts in rauc.slot=, and
# its device must be the label grub.cfg boots for that name.
check_slot() {
  local section="$1" bootname="$2" label="$3" var="$4"
  [ "$(conf_value "$section" bootname)" = "$bootname" ] ||
    fail "system.conf [$section] does not have bootname=$bootname"
  [ "$(conf_value "$section" device)" = "/dev/disk/by-partlabel/$label" ] ||
    fail "system.conf [$section] does not name /dev/disk/by-partlabel/$label"
  [ "$(conf_value "$section" type)" = ext4 ] ||
    fail "system.conf [$section] is not type=ext4, the slot image type"
  grep -qE "^ *set atc_root_label=\\\$$var\$" "$GRUB_CFG" ||
    fail "grub.cfg never boots \$$var"
}
check_slot slot.rootfs.0 A atcroota atc_slot_a_label
check_slot slot.rootfs.1 B atcrootb atc_slot_b_label

b_branch="$(sed -n '/^if \[ "\$atc_boot" = "B" \]; then$/{n;N;p;q;}' "$GRUB_CFG" | tr -d ' ')"
if [ "$b_branch" != "$(printf '%s\n' 'setatc_root_label=$atc_slot_b_label' 'setatc_root_part=$atc_slot_b_part')" ]; then
  fail "grub.cfg does not map bootname B to atcrootb, so rauc.slot= and the" \
    "booted partition can disagree"
fi

[ "$(conf_value system bootloader)" = grub ] || fail "system.conf does not select the grub backend"
[ "$(conf_value system bundle-formats)" = verity ] ||
  fail "system.conf accepts plain bundles; a plain bundle over 2 GiB is CVE-2026-34155"

grubenv="$(conf_value system grubenv)"
grub_env="$(sed -n 's/^set atc_env=//p' "$GRUB_CFG")"
if [ "$grubenv" != "/boot$grub_env" ]; then
  fail "system.conf grubenv='$grubenv' is not the ESP file grub.cfg reads" \
    "('/boot$grub_env'). RAUC and GRUB would keep two environments"
fi
if ! grep -q "atc-grub-env/grubenv;${grub_env#/}" "$IMAGE"; then
  fail "the image does not place the grubenv at ${grub_env#/} on the ESP"
fi

# ── The bundle against system.conf ───────────────────────────────────────────

[ "$(bb_value RAUC_BUNDLE_COMPATIBLE "$BUNDLE")" = "$(conf_value system compatible)" ] ||
  fail "the bundle's RAUC_BUNDLE_COMPATIBLE is not system.conf's compatible; RAUC" \
    "refuses every bundle"
[ "$(bb_value RAUC_BUNDLE_FORMAT "$BUNDLE")" = verity ] ||
  fail "the bundle is not verity, and system.conf accepts verity only"
[ "$(bb_value RAUC_SLOT_rootfs "$BUNDLE")" = atc-image-slot ] ||
  fail "the bundle's rootfs is not atc-image-slot"
# The trial guard is a DEVICE handler. A bundle install-check would replace
# RAUC's own compatible check, and a bundle built without it would skip it.
[ "$(conf_value handlers pre-install)" = /usr/libexec/atc-os/atc-os-pre-install ] ||
  fail "system.conf names no atc pre-install handler, so an install during a" \
    "trial overwrites the revert slot"
if grep -q 'RAUC_BUNDLE_HOOKS\[hooks\]' "$BUNDLE"; then
  fail "the bundle declares hooks; an install-check turns off RAUC's compatible check"
fi
grep -qE '^RAUC_SLOT_rootfs\[hooks\] = "post-install"$' "$BUNDLE" ||
  fail "the bundle runs no post-install hook, so the new slot has no atcd unit"

# ── The D-Bus policy ─────────────────────────────────────────────────────────

policy_block() {
  awk -v open="$1" 'index($0, open) { inside = 1; next } inside && /<\/policy>/ { exit } inside { print }' "$POLICY"
}
grep -q '<allow send_destination="de.pengutronix.rauc"/>' < <(policy_block '<policy user="atc">') ||
  fail "the D-Bus policy does not let user atc call RAUC"
grep -q '<allow own="de.pengutronix.rauc"/>' < <(policy_block '<policy user="root">') ||
  fail "the D-Bus policy does not let root own the RAUC name"
grep -q '<deny send_destination="de.pengutronix.rauc"/>' < <(policy_block '<policy context="default">') ||
  fail "the D-Bus policy's default context does not deny RAUC"
if grep -q '<allow' < <(policy_block '<policy context="default">'); then
  fail "the D-Bus policy's default context allows something"
fi
grep -q 'rm -f .*de\.pengutronix\.rauc\.conf' "$RAUC_APPEND" ||
  fail "rauc_%.bbappend keeps the stock policy, which lets any user call RAUC"
grep -qx 'RRECOMMENDS:${PN}:remove = "${PN}-mark-good"' "$RAUC_APPEND" ||
  fail "rauc_%.bbappend keeps rauc-mark-good, which confirms every trial that" \
    "reaches userspace"

# ── The root-side units: the trial deadline and the reboot request ───────────

grep -qx 'OnBootSec=15min' "$OS_DIR/atc-os-trial-deadline.timer" ||
  fail "the trial deadline timer does not fire 15 minutes after boot"
grep -q 'rauc status --output-format=shell' "$OS_DIR/atc-os-trial-deadline" ||
  fail "the trial deadline does not read rauc status"
grep -qE '^ *exec systemctl --no-block reboot$' "$OS_DIR/atc-os-trial-deadline" ||
  fail "the trial deadline never reboots, so an unconfirmed trial stays up"
grep -qxF 'if [ "$trial" != "$slot" ]; then' "$OS_DIR/atc-os-trial-deadline" ||
  fail "the trial deadline reboots a slot that is not on trial, which loops" \
    "every 15 minutes on a lost boot environment"
grep -qx 'PathExists=/var/atc/os/reboot-request' "$OS_DIR/atc-os-reboot.path" ||
  fail "the reboot path unit does not watch /var/atc/os/reboot-request"
rm_at="$(line_of 'ExecStart=/bin/rm -f /var/atc/os/reboot-request' "$OS_DIR/atc-os-reboot.service")"
reboot_at="$(line_of 'ExecStart=/bin/systemctl --no-block reboot' "$OS_DIR/atc-os-reboot.service")"
if [ -z "$rm_at" ] || [ -z "$reboot_at" ] || [ "$rm_at" -gt "$reboot_at" ]; then
  fail "the reboot service does not remove the request before it reboots, so" \
    "the next boot reboots again"
fi

# atcd's binary and its store are under /var/atc, the data partition. On the
# nvbootctrl backend that mount is nofail, so a slow or missing UDA does not
# stop the boot. Without this drop-in, atcd.service then starts against an
# empty /var/atc on the rootfs and fails. The Rust bootstrap renders
# atcd.service, so the image orders it with a drop-in in /usr/lib, which the
# bundle hook never carries.
if ! grep -qx '\[Unit\]' "$OS_DIR/10-atc-store.conf" ||
  ! grep -qx 'RequiresMountsFor=/var/atc' "$OS_DIR/10-atc-store.conf"; then
  fail "the atcd drop-in does not require the /var/atc mount (RequiresMountsFor=/var/atc in [Unit])"
fi
grep -qF 'file://10-atc-store.conf' "$OS_RECIPE" ||
  fail "atc-os does not fetch the atcd store drop-in"
grep -qxF '    install -m 0644 ${WORKDIR}/10-atc-store.conf ${D}${systemd_system_unitdir}/atcd.service.d/' "$OS_RECIPE" ||
  fail "atc-os does not install the atcd store drop-in in atcd.service.d"

# The watchdog the drop-in feeds. poky's qemux86-64 kernel does not build the
# i6300esb driver, so without the fragment RuntimeWatchdogSec arms nothing.
grep -qx 'RuntimeWatchdogSec=30s' "$OS_DIR/10-atc-watchdog.conf" ||
  fail "the watchdog drop-in does not set RuntimeWatchdogSec=30s"
grep -qx 'CONFIG_I6300ESB_WDT=y' "$WATCHDOG_CFG" ||
  fail "the kernel fragment does not build the i6300esb driver in"
grep -qx 'SRC_URI:append:qemux86-64 = " file://atc-watchdog.cfg"' "$KERNEL_APPEND" ||
  fail "the kernel bbappend does not apply the watchdog fragment on qemux86-64"

# ── The runtime profile ──────────────────────────────────────────────────────

for img in "$IMAGE" "$SLOT_IMAGE"; do
  grep -qE '^require (recipes-core/images/)?atc-ab-runtime\.inc$' "$img" ||
    fail "$(basename "$img") does not require atc-ab-runtime.inc"
done
# The GRUB mounts are the body of that backend's variant of the fstab
# function. A line outside it would reach a Tegra slot, whose flash layout has
# no atcesp and no atcdata, and the boot would wait on a missing partition.
grub_fstab="$(sed -n '/^atc_install_fstab_entries:atc-slot-grub() {$/,/^}$/p' "$RUNTIME")"
grep -q '^PARTLABEL=atcdata  */var/atc ' <<< "$grub_fstab" ||
  fail "the runtime profile mounts no PARTLABEL=atcdata on /var/atc on atc-slot-grub," \
    "so the store would live inside the slot being replaced"
grep -q '^PARTLABEL=atcesp  */boot ' <<< "$grub_fstab" ||
  fail "the runtime profile mounts no PARTLABEL=atcesp on /boot on atc-slot-grub, so" \
    "RAUC cannot reach the boot environment"
# The nvbootctrl mounts are the body of that backend's variant. NVIDIA's
# redundant NVMe layout has UDA outside APP and APP_b, and the store goes there.
nv_fstab="$(sed -n '/^atc_install_fstab_entries:atc-slot-nvbootctrl() {$/,/^}$/p' "$RUNTIME")"
grep -q '^PARTLABEL=UDA  */var/atc  *ext4  *[^ ]*x-systemd\.growfs' <<< "$nv_fstab" ||
  fail "the runtime profile mounts no PARTLABEL=UDA on /var/atc with x-systemd.growfs on" \
    "atc-slot-nvbootctrl, so the Tegra store lives inside the slot being replaced"
if grep -q 'PARTLABEL=' < <(sed -e '/^atc_install_fstab_entries:atc-slot-grub() {$/,/^}$/d' \
  -e '/^atc_install_fstab_entries:atc-slot-nvbootctrl() {$/,/^}$/d' "$RUNTIME" | grep -v '^#'); then
  fail "the runtime profile mounts a PARTLABEL outside a backend variant," \
    "so one backend's slot waits on a partition its layout does not have"
fi
grep -q '^PARTLABEL=UDA  */var/atc  *ext4  *[^ ]*\bnofail\b' <<< "$nv_fstab" ||
  fail "the Tegra UDA mount has no nofail, so a UDA that cannot mount drops both" \
    "slots into emergency mode, with no network"
for want in 'DATAFILE:atc-slot-nvbootctrl = "atc-uda.img"' \
  'IMAGE_TEGRAFLASH_DATA:atc-slot-nvbootctrl = "${DEPLOY_DIR_IMAGE}/atc-uda.ext4"'; do
  grep -qxF -- "$want" "$RUNTIME" ||
    fail "the Tegra image does not flash atc-uda.ext4 to UDA, so a reflash keeps the old store"
done
if grep -qE 'PARTLABEL=(atcesp|atcdata)' <<< "$nv_fstab"; then
  fail "the nvbootctrl mounts name a GRUB partition"
fi
for pkg in rauc rauc-conf atc-os; do
  grep -qE "^IMAGE_INSTALL \\+= \"([^\"]* )?$pkg( [^\"]*)?\"" "$RUNTIME" ||
    fail "the runtime profile does not install $pkg"
done
# Each backend brings its own writer of the boot state, keyed on the seam.
grep -qx 'inherit atc-slot-backend' "$RUNTIME" ||
  fail "the runtime profile does not inherit atc-slot-backend, so its backend lines never apply"
grep -qE '^IMAGE_INSTALL:append:atc-slot-grub = " grub-editenv"$' "$RUNTIME" ||
  fail "the runtime profile does not install grub-editenv on atc-slot-grub alone"
for pkg in atc-nvbootctrl atc-tegra-capsule; do
  grep -qE "^IMAGE_INSTALL:append:atc-slot-nvbootctrl = \" ([^\"]* )?$pkg( [^\"]*)?\"\$" "$RUNTIME" ||
    fail "the runtime profile does not install $pkg on atc-slot-nvbootctrl"
done
if grep -q 'atc_install_fstab_entries' "$IMAGE" "$SLOT_IMAGE"; then
  fail "an image recipe writes fstab lines itself; the runtime profile owns them"
fi
for want in 'useradd --system -u ${ATC_UID} -g atc ' 'useradd --system -u ${ATC_HOOKS_UID} -g atc '; do
  grep -qF -- "$want" "$RUNTIME" ||
    fail "the runtime profile does not run '$want', so the slots can disagree" \
      "about who owns the store"
done
grep -qE '^EXTRA_USERS_PARAMS:prepend = ' "$RUNTIME" ||
  fail "the runtime profile does not PREPEND its users, so atc-image.bb's" \
    "groupadd -f atc gives the group a free id first"

# ── grub.cfg: the defaults and the read ──────────────────────────────────────

defaults_body="$(grub_function_body atc_set_defaults)"
for entry in "${DEFAULTS[@]}"; do
  name="${entry%%=*}" value="${entry#*=}"
  case "$value" in *" "*) value="\"$value\"" ;; esac
  grep -qx " *set $name=$value" <<< "$defaults_body" ||
    fail "grub.cfg's fail-closed defaults do not set $name=$value"
done

defaults_line="$(grep -m1 -n '^atc_set_defaults$' "$GRUB_CFG" | cut -d: -f1)"
load_line="$(grep -m1 -n '^atc_load_env$' "$GRUB_CFG" | cut -d: -f1)"
if [ -z "$defaults_line" ] || [ -z "$load_line" ] || [ "$defaults_line" -gt "$load_line" ]; then
  fail "grub.cfg does not set its defaults before it reads the environment"
fi

valid_body="$(grub_function_body atc_env_valid)"
for var in $GRUB_VARS; do
  grep -qE "^ +if \\[ \"\\\$$var\" != " <<< "$valid_body" ||
    fail "grub.cfg's validity check does not constrain \$$var"
done

load_body="$(grub_function_body atc_load_env)"
clear_at="$(grep -m1 -n 'atc_clear_env' <<< "$load_body" | cut -d: -f1)"
read_at="$(grep -m1 -n 'load_env --file' <<< "$load_body" | cut -d: -f1)"
if [ -z "$read_at" ]; then
  fail "grub.cfg's atc_load_env reads no environment"
elif [ -z "$clear_at" ] || [ "$clear_at" -gt "$read_at" ]; then
  fail "grub.cfg reads the environment without clearing the variables first," \
    "so a partial block inherits the defaults"
fi
grep -q 'atc_set_defaults' <<< "$load_body" ||
  fail "grub.cfg's atc_load_env does not restore the defaults on a bad read"

for var in $GRUB_VARS; do
  grep -qx " *set $var=invalid" < <(grub_function_body atc_clear_env) ||
    fail "grub.cfg's atc_clear_env does not clear $var to a value no domain accepts"
done

for verb in load_env save_env; do
  listed="$(grep -m1 -oE "$verb --file \(\\\$atc_esp\)\\\$atc_env .*" "$GRUB_CFG" |
    sed -E 's/;? *then$//' | cut -d' ' -f4-)"
  [ "$listed" = "$GRUB_VARS" ] ||
    fail "grub.cfg's $verb names '$listed', not the seven variables '$GRUB_VARS'"
done

# ── grub.cfg: the five branches ──────────────────────────────────────────────

# The confirm runs BEFORE the head is chosen, so an install into the other
# slot after a mark-good still starts a trial of that slot.
EXPECT_SEQUENCE=(
  'atc_load_env'
  'if [ "$ATC_TRIAL" = "A" -a "$A_OK" = "1" -a "$A_TRY" = "0" ]; then'
  '    set atc_confirmed=1'
  'if [ "$ATC_TRIAL" = "B" -a "$B_OK" = "1" -a "$B_TRY" = "0" ]; then'
  '    set atc_confirmed=1'
  'if [ "$atc_confirmed" = "1" ]; then'
  '    set ATC_STEADY=$ATC_TRIAL'
  '    set ATC_TRIAL=none'
  '    if ! atc_save_env; then'
  '        if [ "$atc_slot" = "A" -a "$A_OK" = "1" ]; then'
  '            set atc_head=A'
  '        if [ "$atc_slot" = "B" -a "$B_OK" = "1" ]; then'
  '            set atc_head=B'
  'if [ -z "$atc_head" ]; then'
  'elif [ "$atc_head" = "$ATC_STEADY" ]; then'
  '    set atc_boot=$atc_head'
  'elif [ "$atc_head" = "$ATC_TRIAL" ]; then'
)
previous=0
for line in "${EXPECT_SEQUENCE[@]}"; do
  at="$(awk -v after="$previous" -v want="$line" 'NR > after && $0 == want { print NR; exit }' "$GRUB_CFG")"
  if [ -z "$at" ]; then
    fail "grub.cfg lacks '$line' after line $previous. The decision is: load," \
      "confirm a marked trial, choose the head, then both-bad, steady, spent"
    break
  fi
  previous="$at"
done

grep -qx "    if atc_env_valid; then" < <(grub_function_body atc_load_env) ||
  fail "grub.cfg's atc_load_env does not act on atc_env_valid"
grep -qE '^regexp --set=1:atc_disk .* "\$atc_esp"$' "$GRUB_CFG" ||
  fail "grub.cfg does not take the slots' disk from the ESP's device name"

# The region of one branch: from its line to the next branch keyword.
branch_body() {
  awk -v start="$1" 'NR == start { inside = 1; next } inside && /^(elif|else|fi)/ { exit } inside { print }' "$GRUB_CFG"
}
spent_at="$(line_of 'elif [ "$atc_head" = "$ATC_TRIAL" ]; then' "$GRUB_CFG")"
new_at="$(awk -v after="${spent_at:-0}" 'NR > after && /^else$/ { print NR; exit }' "$GRUB_CFG")"
if [ -n "$spent_at" ]; then
  spent="$(branch_body "$spent_at")"
  for want in 'set A_OK=0' 'set B_OK=0' 'set ORDER="$ATC_STEADY $atc_head"' 'set ATC_TRIAL=none' 'set atc_boot=$ATC_STEADY' 'if ! atc_save_env; then'; do
    grep -qF -- "$want" <<< "$spent" ||
      fail "grub.cfg's spent branch does not '$want', so a failed trial is retried"
  done
fi
# A stale ATC_TRIAL is the hazard the confirm-first order exists for: a later
# install into that slot would read as a mark-good. So every branch that ends a
# trial clears it and acts on the save.
for branch in 'if [ -z "$atc_head" ]; then' 'elif [ "$atc_head" = "$ATC_STEADY" ]; then'; do
  at="$(line_of "$branch" "$GRUB_CFG")"
  [ -n "$at" ] || continue
  body="$(branch_body "$at")"
  for want in 'set ATC_TRIAL=none' 'if ! atc_save_env; then'; do
    grep -qF -- "$want" <<< "$body" ||
      fail "grub.cfg's branch '$branch' does not '$want', so a stale trial stays"
  done
done

if [ -z "$new_at" ]; then
  fail "grub.cfg has no new-trial branch"
else
  new="$(branch_body "$new_at")"
  for want in 'set ATC_TRIAL=$atc_head' 'set A_TRY=1' 'set B_TRY=1' 'if ! atc_save_env; then' 'set atc_boot=$ATC_STEADY'; do
    grep -qF -- "$want" <<< "$new" ||
      fail "grub.cfg's new-trial branch does not '$want'. A trial must record TRY=1" \
        "before the boot, and boot the steady slot when the record fails"
  done
fi

if grep -qE '^ +atc_save_env$' "$GRUB_CFG"; then
  fail "grub.cfg calls atc_save_env and discards its status, so a trial can" \
    "start without its count reaching the disk"
fi

# ── grub.cfg: the console and the boot ───────────────────────────────────────

term_line="$(grep -m1 -n '^ *terminal_output ' "$GRUB_CFG" | cut -d: -f1)"
first_echo_line="$(grep -m1 -n '^ *echo ' "$GRUB_CFG" | cut -d: -f1)"
if [ -z "$term_line" ]; then
  fail "grub.cfg never selects an output terminal, so a -nographic boot is silent"
elif [ -n "$first_echo_line" ] && [ "$term_line" -gt "$first_echo_line" ]; then
  fail "grub.cfg selects its output terminal after its first echo"
fi
grep -qE '^if \[ "\$grub_platform" = "efi" \]; then$' "$GRUB_CFG" ||
  fail "grub.cfg does not branch on grub_platform, so EFI or BIOS prints nothing"
grep -qE '^ +serial --unit=0 --speed=115200$' "$GRUB_CFG" ||
  fail "grub.cfg's non-EFI branch does not open serial unit 0 at 115200"
console_args="$(grep -m1 -oE '^set atc_console="[^"]*"' "$GRUB_CFG")"
grep -qE 'console=ttyS0[^ ]*"$' <<< "$console_args" ||
  fail "ttyS0 is not the LAST console, so a headless boot goes silent and has" \
    "no serial login"

linux_line="$(grep -m1 -n '^if ! linux /boot/bzImage ' "$GRUB_CFG" | cut -d: -f1)"
if [ -z "$linux_line" ]; then
  fail "grub.cfg does not test the result of 'linux', so an empty rootfs stops" \
    "at a GRUB prompt and nothing reverts"
else
  grep -qE '^ +reboot$' < <(sed -n "$linux_line,\$p" "$GRUB_CFG") ||
    fail "grub.cfg does not reboot after a failed 'linux'"
  for arg in 'root=PARTLABEL=$atc_root_label' 'rauc.slot=$atc_boot' 'panic=5'; do
    grep -qF -- "$arg" < <(sed -n "${linux_line}p" "$GRUB_CFG") ||
      fail "the kernel command line lacks '$arg'"
  done
  last_save="$(grep -n 'atc_save_env; then$' "$GRUB_CFG" | tail -1 | cut -d: -f1)"
  if [ -n "$last_save" ] && [ "$last_save" -gt "$linux_line" ]; then
    fail "grub.cfg saves the environment after 'linux', too late to count a boot"
  fi
fi
if grep -q 'atc\.slot=' "$GRUB_CFG"; then
  fail "grub.cfg still writes the old atc.slot=; RAUC reads rauc.slot="
fi
boot_line="$(grep -m1 -n '^boot$' "$GRUB_CFG" | cut -d: -f1)"
if [ -z "$boot_line" ]; then
  fail "grub.cfg never calls 'boot'"
elif ! grep -qx 'reboot' < <(sed -n "$boot_line,\$p" "$GRUB_CFG"); then
  fail "grub.cfg does not reboot after a failed 'boot'"
fi

for module in echo reboot regexp; do
  grep -qE "^GRUB_BUILDIN:append = \".*\\b$module\\b" "$GRUB_APPEND" ||
    fail "GRUB_BUILDIN does not add '$module', which grub.cfg runs"
done

# ── The image recipe and the initial environment ─────────────────────────────

grep -qx 'inherit atc-slot-backend' "$IMAGE" ||
  fail "atc-image-ab does not inherit atc-slot-backend, so its GRUB lines never apply"
grep -qE '^QB_DEFAULT_KERNEL:atc-slot-grub = "none"$' "$IMAGE" ||
  fail "the image does not set QB_DEFAULT_KERNEL = \"none\", so runqemu boots -kernel"
grep -qE '^QB_FSINFO:atc-slot-grub = "wic:no-kernel-in-fs"$' "$IMAGE" || fail "the image does not set QB_FSINFO"
grep -qE '^EFI_PROVIDER:atc-slot-grub = "grub-efi"$' "$IMAGE" || fail "the image does not select grub-efi"
grep -qE '^IMAGE_FSTYPES:append:atc-slot-grub = " wic"$' "$IMAGE" ||
  fail "the image builds no wic on atc-slot-grub, or builds one on every backend"
grep -qE '^WKS_FILE:atc-slot-grub = "atc-ab.wks.in"$' "$IMAGE" ||
  fail "the image does not name atc-ab.wks.in on atc-slot-grub alone"
# A plain GRUB line would reach a Tegra image: EFI_PROVIDER would replace
# meta-tegra's L4TLauncher with GRUB, and the wks would find no ESP layout.
if grep -qE '^(EFI_PROVIDER|WKS_FILE|IMAGE_EFI_BOOT_FILES|QB_[A-Z_]+)( |:append )' "$IMAGE"; then
  fail "atc-image-ab sets a GRUB, wic or qemu variable without :atc-slot-grub"
fi
grep -q 'atc-grub-env/grub.cfg;EFI/BOOT/grub.cfg' "$IMAGE" ||
  fail "the image does not overwrite the generated EFI/BOOT/grub.cfg"

[ "$(bb_value GRUB_ENVBLK_SIZE "$RECIPE")" = 1024 ] ||
  fail "the recipe does not write a 1024-byte environment block"
[ "$(bb_value GRUB_ENVBLK_HEADER "$RECIPE")" = "# GRUB Environment Block" ] ||
  fail "the recipe writes the wrong environment block header"
grep -q 'bbfatal' "$RECIPE" || fail "the recipe cannot fail on an oversized block"
if grep -q '\$((' < <(grep -v '^[[:space:]]*#' "$RECIPE"); then
  fail "the recipe uses arithmetic expansion, which bitbake's shell parser refuses"
fi

# The initial grubenv must be the defaults, so a first boot that reads it and
# one that cannot read it reach the same slot.
initial="$(sed -n '/atc_write_envblk \${DEPLOYDIR}\/atc-grub-env\/grubenv/,/^$/p' "$RECIPE" |
  grep -oE '"[^"]*"' | tr -d '"')"
expected="$(printf '%s\n' "${DEFAULTS[@]}")"
[ "$initial" = "$expected" ] ||
  fail "the initial grubenv is not the fail-closed defaults:" \
    "$(tr '\n' ',' <<< "$initial")"

kernel_path="$(grep -m1 -oE 'linux +/boot/[^ ]+' "$GRUB_CFG" | awk '{print $2}')"
machines="$(bb_value COMPATIBLE_MACHINE "$RECIPE")"
if [ "$kernel_path" = "/boot/bzImage" ] && [ "$machines" != "qemux86-64" ]; then
  fail "grub.cfg loads $kernel_path, the x86 kernel name, but COMPATIBLE_MACHINE" \
    "is '$machines'"
fi

# ── The slot backend seam ────────────────────────────────────────────────────
#
# The seam is one variable and one derived override. The GRUB backend is the
# default, so every machine without its own value keeps today's contract.

grep -qx 'ATC_SLOT_BACKEND ??= "grub"' "$SEAM" ||
  fail "atc-slot-backend.bbclass does not default ATC_SLOT_BACKEND to grub"
grep -qx 'ATC_SLOT_BACKEND:tegra234 ??= "nvbootctrl"' "$SEAM" ||
  fail "atc-slot-backend.bbclass does not select nvbootctrl on tegra234"
grep -qxF 'OVERRIDES .= ":atc-slot-${ATC_SLOT_BACKEND}"' "$SEAM" ||
  fail "atc-slot-backend.bbclass does not derive the atc-slot-<backend> override"
for f in "$RAUC_CONF_APPEND" "$OS_RECIPE"; do
  grep -qxE 'inherit (.* )?atc-slot-backend( .*)?' "$f" ||
    fail "$(basename "$f") does not inherit atc-slot-backend, so its backend lines never apply"
done
grep -qE '^inherit (.* )?atc-slot-backend( .*)?$' "$BUNDLE" ||
  fail "atc-bundle.bb does not inherit atc-slot-backend, so its backend lines never apply"

# ── The trial predicate: the one backend call atc-os makes ───────────────────

for f in atc-os-pre-install atc-os-trial-deadline; do
  grep -qF 'SLOT_TRIAL="${ATC_SLOT_TRIAL:-/usr/libexec/atc-os/atc-slot-trial}"' "$OS_DIR/$f" ||
    fail "$f does not ask /usr/libexec/atc-os/atc-slot-trial"
  if grep -qE 'grub-editenv|grubenv|GRUBENV' < <(grep -v '^#' "$OS_DIR/$f"); then
    fail "$f reads the GRUB environment itself; only atc-slot-trial-grub may"
  fi
done
grep -qxF '    install -m 0755 ${WORKDIR}/atc-slot-trial-grub ${D}${libexecdir}/atc-os/atc-slot-trial' "$OS_RECIPE" ||
  fail "atc-os does not install atc-slot-trial-grub at /usr/libexec/atc-os/atc-slot-trial"
grep -qx 'do_install:append:atc-slot-grub() {' "$OS_RECIPE" ||
  fail "atc-os installs atc-slot-trial-grub on every backend; atc-nvbootctrl owns that path on Tegra"
grep -qx 'SRC_URI:append:atc-slot-grub = " file://atc-slot-trial-grub"' "$OS_RECIPE" ||
  fail "atc-os fetches atc-slot-trial-grub on every backend"
grep -qx 'PACKAGE_ARCH = "${MACHINE_ARCH}"' "$SEAM" ||
  fail "atc-slot-backend.bbclass does not make its recipes machine-specific, and two" \
    "machines of one tune can have two backends"

# ── The nvbootctrl system.conf ───────────────────────────────────────────────
#
# NVIDIA's boot chain selects the slot, so RAUC uses the custom backend that
# wraps nvbootctrl. Nothing of the GRUB contract may remain: a grubenv key would
# point RAUC at a file that does not exist on the board.

nv() { SYSTEM_CONF="$TEGRA_CONF" conf_value "$@"; }
[ "$(nv system bootloader)" = custom ] ||
  fail "system-nvbootctrl.conf does not select bootloader=custom"
[ "$(nv handlers bootloader-custom-backend)" = /usr/lib/rauc/atc-nvbootctrl-backend ] ||
  fail "system-nvbootctrl.conf does not name /usr/lib/rauc/atc-nvbootctrl-backend"
[ "$(nv handlers pre-install)" = /usr/libexec/atc-os/atc-os-pre-install ] ||
  fail "system-nvbootctrl.conf names no atc pre-install handler, so an install" \
    "during a trial overwrites the revert slot"
[ "$(nv system bundle-formats)" = verity ] ||
  fail "system-nvbootctrl.conf accepts plain bundles; a plain bundle over 2 GiB" \
    "is CVE-2026-34155"
[ "$(nv system compatible)" = 'atc-@MACHINE@' ] ||
  fail "the nvbootctrl compatible is not atc-@MACHINE@, so one bundle fits every Orin board"
grep -qF 'RAUC_BUNDLE_COMPATIBLE:atc-slot-nvbootctrl = "atc-${MACHINE}"' "$BUNDLE" ||
  fail "the bundle's nvbootctrl compatible is not atc-\${MACHINE}; RAUC refuses every bundle"
grep -qF 'sed -i '"'"'s/@MACHINE@/${MACHINE}/'"'"'' "$RAUC_CONF_APPEND" ||
  fail "rauc-conf.bbappend does not substitute @MACHINE@ into system-nvbootctrl.conf"
grep -qx 'ATC_RAUC_SYSTEM_CONF:atc-slot-nvbootctrl = "system-nvbootctrl.conf"' "$RAUC_CONF_APPEND" ||
  fail "rauc-conf.bbappend does not install system-nvbootctrl.conf on atc-slot-nvbootctrl"
if grep -qE '^grubenv=' "$TEGRA_CONF"; then
  fail "system-nvbootctrl.conf keeps the GRUB key grubenv"
fi
# ── The redundant Tegra layout and the capsule ───────────────────────────────
#
# system-nvbootctrl.conf names APP_b, which exists only in the redundant layout.
# The layout is machine-wide BSP config, so the UEFI firmware and the capsule
# read the same value as the image. It is redundant unless a build opts out.
grep -qx 'ATC_TEGRA_REDUNDANT ??= "1"' "$LAYER_CONF" ||
  fail "layer.conf does not default ATC_TEGRA_REDUNDANT to 1, so a Tegra build" \
    "has no APP_b for system-nvbootctrl.conf to name"
grep -qx 'USE_REDUNDANT_FLASH_LAYOUT_DEFAULT:tegra234 = "${ATC_TEGRA_REDUNDANT}"' "$LAYER_CONF" ||
  fail "layer.conf does not set USE_REDUNDANT_FLASH_LAYOUT_DEFAULT on tegra234;" \
    "an image-level value builds a non-redundant capsule"
grep -qE '^TEGRA_BOOTCONTROL_OVERLAYS:append:tegra234 = .*L4TConfiguration-AtcRootfsRetryCountMax\.dtbo' "$LAYER_CONF" ||
  fail "layer.conf does not add the RootfsRetryCountMax overlay, so a trial gets three boots"
# The bundle carries the capsule under the name the hook stages.
grep -qx 'RAUC_BUNDLE_EXTRA_FILES:append:atc-slot-nvbootctrl = " tegra-bl.cap"' "$BUNDLE" ||
  fail "the bundle does not carry tegra-bl.cap on atc-slot-nvbootctrl, so firmware and" \
    "rootfs do not switch together"
# The opt-out: a single-APP layout skips the A/B image and the bundle, which
# need APP_b, with the reason. Without the guard they build and fail on the board.
for f in "$RUNTIME" "$BUNDLE"; do
  grep -qF "d.getVar('USE_REDUNDANT_FLASH_LAYOUT') != '1'" "$f" ||
    fail "$(basename "$f") does not refuse the single-APP layout on atc-slot-nvbootctrl"
done
grep -qx 'RAUC_BUNDLE_EXTRA_DEPENDS:append:atc-slot-nvbootctrl = " tegra-uefi-capsules"' "$BUNDLE" ||
  fail "the bundle does not depend on tegra-uefi-capsules on atc-slot-nvbootctrl"
grep -qF 'capsule="${RAUC_BUNDLE_MOUNT_POINT:-}/tegra-bl.cap"' "$HOOK" ||
  fail "the bundle hook does not stage \$RAUC_BUNDLE_MOUNT_POINT/tegra-bl.cap"
# The hook stages. Only the backend's set-primary arms, as its last step.
if grep -qE '"\$tool" arm|oe4t-set-uefi-OSIndications|OsIndications-' < <(grep -v '^ *#' "$HOOK"); then
  fail "the bundle hook arms the capsule; a failed install would leave it armed"
fi

for pair in 'slot.rootfs.0 A APP' 'slot.rootfs.1 B APP_b'; do
  read -r section bootname label <<< "$pair"
  [ "$(nv "$section" bootname)" = "$bootname" ] ||
    fail "system-nvbootctrl.conf [$section] does not have bootname=$bootname"
  [ "$(nv "$section" device)" = "/dev/disk/by-partlabel/$label" ] ||
    fail "system-nvbootctrl.conf [$section] does not name /dev/disk/by-partlabel/$label"
done

if [ "$failures" -gt 0 ]; then
  echo "check-atc-ab-layout: $failures failure(s)" >&2
  exit 1
fi
echo "check-atc-ab-layout: OK"
