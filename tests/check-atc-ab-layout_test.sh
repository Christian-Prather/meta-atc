#!/usr/bin/env bash
# tests/check-atc-ab-layout_test.sh
#
# Self-test for check-atc-ab-layout.sh, the A/B slot contract gate.
#
# The gate's passing result is "the files agree", which is also what a gate
# whose guards are dead produces. Every case here copies the REAL files into a
# fixture, mutates exactly one thing, and requires the gate to go red on it. A
# guard that cannot go red is not coverage, and this repository has found four
# dead ones that way in a sibling gate.
#
# The fixture is a COPY of the real layer, never a hand-written stand-in. A
# hand-written fixture drifts from the files it stands for, and the drift makes
# the self-test pass against a shape the real tree no longer has.
#
# Usage: check-atc-ab-layout_test.sh <path-to-gate> <layer-root>
# shellcheck disable=SC2016  # every literal $NAME here is GRUB or bitbake text to edit
set -euo pipefail

GATE="${1:?usage: check-atc-ab-layout_test.sh <gate> <layer-root>}"
SRC_ROOT="${2:?usage: check-atc-ab-layout_test.sh <gate> <layer-root>}"

GATE="$(cd "$(dirname "$GATE")" && pwd)/$(basename "$GATE")"
SRC_ROOT="$(cd "$SRC_ROOT" && pwd)"

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

WKS_REL="wic/atc-ab.wks.in"
CFG_REL="recipes-bsp/atc-grub-env/files/atc-ab-grub.cfg"
RECIPE_REL="recipes-bsp/atc-grub-env/atc-grub-env_1.0.bb"
GRUB_APPEND_REL="recipes-bsp/grub/grub-efi_%.bbappend"
CONF_REL="recipes-core/rauc/files/system.conf"
TEGRA_CONF_REL="recipes-core/rauc/files/system-nvbootctrl.conf"
OS_RECIPE_REL="recipes-core/atc-os/atc-os_1.0.bb"
SEAM_REL="classes/atc-slot-backend.bbclass"
PRE_INSTALL_REL="recipes-core/atc-os/files/atc-os-pre-install"
SLOT_TRIAL_REL="recipes-core/atc-os/files/atc-slot-trial-grub"
RAUC_CONF_APPEND_REL="recipes-core/rauc/rauc-conf.bbappend"
POLICY_REL="recipes-core/rauc/files/atc-rauc.conf"
RAUC_APPEND_REL="recipes-core/rauc/rauc_%.bbappend"
BUNDLE_REL="recipes-core/bundles/atc-bundle.bb"
RUNTIME_REL="recipes-core/images/atc-ab-runtime.inc"
IMAGE_REL="recipes-core/images/atc-image-ab.bb"
SLOT_REL="recipes-core/images/atc-image-slot.bb"
DEADLINE_REL="recipes-core/atc-os/files/atc-os-trial-deadline"
TIMER_REL="recipes-core/atc-os/files/atc-os-trial-deadline.timer"
PATH_REL="recipes-core/atc-os/files/atc-os-reboot.path"
REBOOT_REL="recipes-core/atc-os/files/atc-os-reboot.service"
WATCHDOG_REL="recipes-core/atc-os/files/10-atc-watchdog.conf"
STORE_DROPIN_REL="recipes-core/atc-os/files/10-atc-store.conf"
KERNEL_REL="recipes-kernel/linux/linux-yocto_%.bbappend"
WDT_CFG_REL="recipes-kernel/linux/files/atc-watchdog.cfg"
LAYER_CONF_REL="conf/layer.conf"
HOOK_REL="recipes-core/bundles/files/atc-bundle-hook"

ALL_REL=("$WKS_REL" "$CFG_REL" "$RECIPE_REL" "$GRUB_APPEND_REL" "$CONF_REL"
  "$POLICY_REL" "$RAUC_APPEND_REL" "$BUNDLE_REL" "$RUNTIME_REL" "$IMAGE_REL"
  "$SLOT_REL" "$DEADLINE_REL" "$TIMER_REL" "$PATH_REL" "$REBOOT_REL"
  "$WATCHDOG_REL" "$KERNEL_REL" "$WDT_CFG_REL" "$TEGRA_CONF_REL"
  "$RAUC_CONF_APPEND_REL" "$OS_RECIPE_REL" "$SEAM_REL" "$PRE_INSTALL_REL"
  "$SLOT_TRIAL_REL" "$LAYER_CONF_REL" "$HOOK_REL" "$STORE_DROPIN_REL")

make_fixture() {
  local root="$1" rel
  for rel in "${ALL_REL[@]}"; do
    mkdir -p "$root/$(dirname "$rel")"
    cp "$SRC_ROOT/$rel" "$root/$rel"
  done
}

expect() {
  local want="$1" name="$2" root="$3" status
  set +e
  META_ATC_ROOT="$root" bash "$GATE" > "$tmp/out" 2> "$tmp/err"
  status=$?
  set -e
  if [ "$want" = pass ] && [ "$status" -ne 0 ]; then
    echo "FAIL: $name: expected PASS, exit $status" >&2
    cat "$tmp/err" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$want" = fail ] && [ "$status" -eq 0 ]; then
    echo "FAIL: $name: expected the gate to FAIL, but it passed" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok: $name"
}

# Copy the real files, apply one sed expression to one file, and require red.
# A mutation that matches nothing is itself a failure: it would report a dead
# guard as live.
mutate() {
  local name="$1" rel="$2" expr="$3" want_text="${4:-}"
  case_n=$((case_n + 1))
  local root="$tmp/case-$case_n"
  make_fixture "$root"
  cp "$root/$rel" "$tmp/before"
  sed -i "$expr" "$root/$rel"
  if cmp -s "$tmp/before" "$root/$rel"; then
    echo "FAIL: $name: the mutation matched nothing, so this case tests nothing" >&2
    failures=$((failures + 1))
    return
  fi
  expect fail "$name" "$root"
  # When the case names the guard it aims at, that guard must be the one
  # that fired. A case that trips a neighbouring guard tests nothing.
  if [ -n "$want_text" ] && ! grep -qF -- "$want_text" "$tmp/err"; then
    echo "FAIL: $name: the gate failed, but not with '$want_text'" >&2
    cat "$tmp/err" >&2
    failures=$((failures + 1))
  fi
}

case_n=0
baseline="$tmp/baseline"
make_fixture "$baseline"
expect pass "the real layer passes" "$baseline"

# Labels and partitions.
mutate "a renamed wks label is caught" "$WKS_REL" 's/--label atcroota/--label atcrootz/'
mutate "a wks part with a mountpoint is caught" "$WKS_REL" \
  's|^part --fstype=ext4 --label atcdata|part /var/atc --fstype=ext4 --label atcdata|'
mutate "a 512 MiB data partition is caught" "$WKS_REL" 's/--fixed-size 4096M/--fixed-size 512M/'
mutate "swapped slot parts in the wks are caught" "$WKS_REL" \
  's/--label atcroota/--label TMP/; s/--label atcrootb/--label atcroota/; s/--label TMP/--label atcrootb/'
mutate "a slot B on the wrong part is caught" "$CFG_REL" 's/^set atc_slot_b_part=gpt3$/set atc_slot_b_part=gpt4/'
mutate "a root found by filesystem label is caught" "$CFG_REL" \
  's/^    set root=(\$atc_disk,\$atc_root_part)$/    search --no-floppy --label $atc_root_label --set=root/'
mutate "a bootname B on slot A's part is caught" "$CFG_REL" \
  '/^if \[ "\$atc_boot" = "B" \]; then$/{n;n;s/atc_slot_b_part/atc_slot_a_part/}'
mutate "a GRUB without regexp is caught" "$GRUB_APPEND_REL" 's/ reboot regexp"/ reboot"/'
mutate "a grub.cfg label the wks does not write is caught" "$CFG_REL" \
  's/^set atc_slot_b_label=atcrootb$/set atc_slot_b_label=atcrootc/'

# system.conf against grub.cfg and the bundle.
mutate "a swapped bootname is caught" "$CONF_REL" '0,/^bootname=A$/s//bootname=B/'
mutate "a slot device by another label is caught" "$CONF_REL" 's#by-partlabel/atcrootb#by-partlabel/atcrootz#'
mutate "a slot type that is not ext4 is caught" "$CONF_REL" '0,/^type=ext4$/s//type=raw/'
mutate "a bootname B that boots slot A is caught" "$CFG_REL" \
  '/^if \[ "\$atc_boot" = "B" \]; then$/{n;s/atc_slot_b_label/atc_slot_a_label/}'
mutate "a non-grub backend is caught" "$CONF_REL" 's/^bootloader=grub$/bootloader=efi/'
mutate "plain bundles allowed is caught" "$CONF_REL" 's/^bundle-formats=verity$/bundle-formats=plain verity/'
mutate "a grubenv path GRUB does not read is caught" "$CONF_REL" 's#^grubenv=/boot/atc/grubenv$#grubenv=/boot/grubenv#'
mutate "a grubenv the image does not place is caught" "$IMAGE_REL" 's#atc-grub-env/grubenv;atc/grubenv#atc-grub-env/grubenv;grubenv#'
mutate "a bundle compatible that differs is caught" "$BUNDLE_REL" 's/^RAUC_BUNDLE_COMPATIBLE = .*/RAUC_BUNDLE_COMPATIBLE = "atc-other"/'
mutate "a plain bundle is caught" "$BUNDLE_REL" 's/^RAUC_BUNDLE_FORMAT = .*/RAUC_BUNDLE_FORMAT = "plain"/'
mutate "a bundle of the wrong image is caught" "$BUNDLE_REL" 's/^RAUC_SLOT_rootfs = .*/RAUC_SLOT_rootfs = "atc-image"/'
mutate "a bundle with no post-install hook is caught" "$BUNDLE_REL" '/^RAUC_SLOT_rootfs\[hooks\]/d'

# The D-Bus policy and the stock units.
mutate "a policy that does not admit atc is caught" "$POLICY_REL" 's/<policy user="atc">/<policy user="atcd">/'
mutate "a policy where root cannot own the name is caught" "$POLICY_REL" '/<allow own=/d'
mutate "a default context that allows is caught" "$POLICY_REL" 's/<deny send_destination/<allow send_destination/'
mutate "a stock policy that stays is caught" "$RAUC_APPEND_REL" '/rm -f .*de\.pengutronix\.rauc\.conf/d'
mutate "a rauc-mark-good that stays is caught" "$RAUC_APPEND_REL" '/^RRECOMMENDS:\${PN}:remove/d'

# The root-side units.
mutate "a trial deadline that is not 15 minutes is caught" "$TIMER_REL" 's/^OnBootSec=15min$/OnBootSec=1h/'
mutate "a trial deadline that never reboots is caught" "$DEADLINE_REL" 's/exec systemctl --no-block reboot/exit 0/'
mutate "a blocking reboot in the deadline is caught" "$DEADLINE_REL" 's/systemctl --no-block reboot/systemctl reboot/'
mutate "a blocking reboot in the reboot service is caught" "$REBOOT_REL" 's/--no-block reboot/reboot/'
mutate "a system.conf with no pre-install handler is caught" "$CONF_REL" '/^pre-install=/d' "no atc pre-install handler"
mutate "a bundle install-check is caught" "$BUNDLE_REL" '$a RAUC_BUNDLE_HOOKS[hooks] = "install-check"' "turns off RAUC's compatible check"
mutate "a trial deadline that reboots a slot not on trial is caught" "$DEADLINE_REL" 's/^if \[ "\$trial" != "\$slot" \]; then$/if false; then/' "not on trial"
mutate "a reboot path on another file is caught" "$PATH_REL" 's#^PathExists=.*#PathExists=/run/reboot#'
mutate "a reboot before the request is removed is caught" "$REBOOT_REL" '/^ExecStart=\/bin\/rm/d'

# The atcd drop-in that waits for the store mount.
mutate "an atcd drop-in without RequiresMountsFor is caught" "$STORE_DROPIN_REL" '/^RequiresMountsFor=\/var\/atc$/d' "RequiresMountsFor=/var/atc"
mutate "an atcd drop-in installed for another unit is caught" "$OS_RECIPE_REL" 's#/atcd.service.d/#/atcd-old.service.d/#' "install the atcd store drop-in"
mutate "an atcd drop-in the recipe never fetches is caught" "$OS_RECIPE_REL" '/file:\/\/10-atc-store.conf/d' "fetch the atcd store drop-in"

# The watchdog.
mutate "a watchdog drop-in at another timeout is caught" "$WATCHDOG_REL" 's/^RuntimeWatchdogSec=30s$/RuntimeWatchdogSec=0/'
mutate "a watchdog driver left out of the kernel is caught" "$WDT_CFG_REL" 's/^CONFIG_I6300ESB_WDT=y$/# CONFIG_I6300ESB_WDT is not set/'
mutate "a fragment the kernel never applies is caught" "$KERNEL_REL" 's/^SRC_URI:append:qemux86-64 = /SRC_URI:append:qemuarm64 = /'

# The runtime profile.
mutate "a slot image without the runtime profile is caught" "$SLOT_REL" '/^require .*atc-ab-runtime\.inc$/d'
mutate "a factory image without the runtime profile is caught" "$IMAGE_REL" '/^require atc-ab-runtime\.inc$/d'
mutate "a dropped data-partition mount is caught" "$RUNTIME_REL" '/^PARTLABEL=atcdata/d'
mutate "a dropped ESP mount is caught" "$RUNTIME_REL" '/^PARTLABEL=atcesp/d'
mutate "a profile without RAUC is caught" "$RUNTIME_REL" 's/^IMAGE_INSTALL += "rauc /IMAGE_INSTALL += "/'
mutate "an atc user with a free id is caught" "$RUNTIME_REL" 's/useradd --system -u \${ATC_UID} /useradd --system /'
mutate "users appended after the base groupadd are caught" "$RUNTIME_REL" 's/^EXTRA_USERS_PARAMS:prepend = /EXTRA_USERS_PARAMS:append = /'

# grub.cfg: the defaults and the read.
mutate "a wrong fail-closed default is caught" "$CFG_REL" '/^function atc_set_defaults {/,/^}/ s/set B_OK=0/set B_OK=1/'
mutate "defaults set after the read are caught" "$CFG_REL" '0,/^atc_set_defaults$/{/^atc_set_defaults$/d}'
mutate "an unchecked domain is caught" "$CFG_REL" '/if \[ "\$B_TRY" != "0"/,+2d'
mutate "a read with no clear first is caught" "$CFG_REL" '/^function atc_load_env {/,/^}/ {/^ *atc_clear_env$/d}'
mutate "a variable the clear misses is caught" "$CFG_REL" '/^ *set ATC_STEADY=invalid$/d'
mutate "a bad read that keeps its values is caught" "$CFG_REL" '/^function atc_load_env {/,/^}/ {/^ *atc_set_defaults$/d}'
mutate "a load that skips a variable is caught" "$CFG_REL" 's/^\( *load_env --file .*\) ATC_TRIAL$/\1/'
mutate "a save that skips a variable is caught" "$CFG_REL" 's/ ATC_STEADY ATC_TRIAL; then$/ ATC_STEADY; then/'

# grub.cfg: the branches.
mutate "a missing both-bad branch is caught" "$CFG_REL" 's/^if \[ -z "\$atc_head" \]; then$/if false; then/'
mutate "a confirm after the head is chosen is caught" "$CFG_REL" \
  's/^if \[ "\$atc_confirmed" = "1" \]; then$/if false; then/' "lacks 'if [ \"\$atc_confirmed\" = \"1\" ]; then'"
mutate "a confirm that keeps the old steady slot is caught" "$CFG_REL" '/^    set ATC_STEADY=\$ATC_TRIAL$/d' "lacks '    set ATC_STEADY="
mutate "a confirm that keeps the trial is caught" "$CFG_REL" \
  '/^if \[ "\$atc_confirmed" = "1" \]; then$/,/^fi$/{/set ATC_TRIAL=none/d}' "The decision is: load"
mutate "a confirm of slot A that never fires is caught" "$CFG_REL" \
  '/A_TRY" = "0" \]; then$/{n;s/set atc_confirmed=1/set atc_confirmed=0/}' "The decision is: load"
mutate "a confirm that does not save is caught" "$CFG_REL" \
  '/^if \[ "\$atc_confirmed" = "1" \]; then$/,/^fi$/{s/    if ! atc_save_env; then/    if false; then/}' "The decision is: load"
mutate "a confirm that ignores TRY is caught" "$CFG_REL" 's/ -a "\$B_TRY" = "0" \]; then$/ ]; then/' "-a \"\$B_TRY\" = \"0\""
mutate "a head that takes a bad slot is caught" "$CFG_REL" 's/"\$atc_slot" = "A" -a "\$A_OK" = "1"/"$atc_slot" = "A" -a "$A_OK" = "0"/' "choose the head"
mutate "a steady branch that boots another slot is caught" "$CFG_REL" \
  '/^elif \[ "\$atc_head" = "\$ATC_STEADY" \]; then$/{n;n;s/set atc_boot=\$atc_head/set atc_boot=B/}' "set atc_boot=\$atc_head"
mutate "a dropped disk lookup is caught" "$CFG_REL" '/^regexp --set=1:atc_disk/d' "disk from the ESP"
mutate "a load that ignores validation is caught" "$CFG_REL" 's/^    if atc_env_valid; then$/    if true; then/' "act on atc_env_valid"
mutate "a spent branch that does not mark the slot bad is caught" "$CFG_REL" \
  '/^elif \[ "\$atc_head" = "\$ATC_TRIAL" \]; then$/,/^else$/{/set B_OK=0/d}' "spent branch does not 'set B_OK=0'"
mutate "a both-bad branch that keeps the trial is caught" "$CFG_REL" \
  '/^if \[ -z "\$atc_head" \]; then$/,/^elif/{s/set ATC_TRIAL=none/set ATC_TRIAL=$ATC_TRIAL/}' "if [ -z"
mutate "a steady branch that keeps the trial is caught" "$CFG_REL" \
  '/^elif \[ "\$atc_head" = "\$ATC_STEADY" \]; then$/,/^elif/{s/set ATC_TRIAL=none/set ATC_TRIAL=$ATC_TRIAL/}' "ATC_STEADY\" ]; then' does not 'set ATC_TRIAL=none'"
mutate "a spent branch that never saves is caught" "$CFG_REL" \
  '/^elif \[ "\$atc_head" = "\$ATC_TRIAL" \]; then$/,/^else$/{s/if ! atc_save_env; then/if true; then/}' "spent branch does not 'if ! atc_save_env"
mutate "a spent branch with ORDER reversed is caught" "$CFG_REL" 's/set ORDER="\$ATC_STEADY \$atc_head"/set ORDER="$atc_head $ATC_STEADY"/' "spent branch does not 'set ORDER"
mutate "a spent branch that keeps the trial is caught" "$CFG_REL" \
  '/^elif \[ "\$atc_head" = "\$ATC_TRIAL" \]; then$/,/^else$/ s/set ATC_TRIAL=none/set ATC_TRIAL=$atc_head/'
mutate "a new trial that does not record TRY=1 is caught" "$CFG_REL" '/^        set A_TRY=1$/d'
mutate "a new trial that boots on a failed save is caught" "$CFG_REL" \
  '/^else$/,/^fi$/ s/set atc_boot=\$ATC_STEADY/set atc_boot=$atc_head/'
mutate "a discarded save status is caught" "$CFG_REL" '0,/^ *if ! atc_save_env; then$/s//    atc_save_env\n    if true; then/'

# grub.cfg: the console and the boot.
mutate "a config with no output terminal is caught" "$CFG_REL" '/terminal_output /d'
mutate "a BIOS fallback at the wrong speed is caught" "$CFG_REL" 's/serial --unit=0 --speed=115200/serial --unit=0 --speed=9600/'
mutate "a config that does not branch on the platform is caught" "$CFG_REL" \
  's/^if \[ "\$grub_platform" = "efi" \]; then$/if true; then/'
mutate "a console order that silences a headless boot is caught" "$CFG_REL" \
  's/^set atc_console=.*/set atc_console="console=ttyS0,115200 console=tty0"/'
mutate "an unchecked linux load is caught" "$CFG_REL" 's/^if ! linux \(.*\); then$/linux \1\nif false; then/'
mutate "a kernel command line without rauc.slot is caught" "$CFG_REL" 's/ rauc\.slot=\$atc_boot//'
mutate "a kernel command line without panic=5 is caught" "$CFG_REL" 's/ panic=5//'
mutate "the old atc.slot= is caught" "$CFG_REL" 's/rauc\.slot=\$atc_boot/rauc.slot=$atc_boot atc.slot=a/'
mutate "a config that never boots is caught" "$CFG_REL" '/^boot$/d'
mutate "no reboot after a failed boot is caught" "$CFG_REL" '$d'
mutate "a GRUB without reboot is caught" "$GRUB_APPEND_REL" 's/ echo reboot regexp"/ echo regexp"/'

# The image and the recipe.
mutate "a QB_DEFAULT_KERNEL that lets runqemu boot -kernel is caught" "$IMAGE_REL" '/^QB_DEFAULT_KERNEL:atc-slot-grub = "none"$/d'
mutate "a missing QB_FSINFO is caught" "$IMAGE_REL" '/^QB_FSINFO:atc-slot-grub = /d'
mutate "a missing EFI provider is caught" "$IMAGE_REL" '/^EFI_PROVIDER:atc-slot-grub = /d'
mutate "a grub.cfg that never reaches the ESP is caught" "$IMAGE_REL" '/atc-grub-env\/grub.cfg;EFI\/BOOT\/grub.cfg/d'
mutate "an image that writes its own fstab is caught" "$IMAGE_REL" '$a ROOTFS_POSTPROCESS_COMMAND += "atc_install_fstab_entries;"'
mutate "a wrong block size is caught" "$RECIPE_REL" 's/^GRUB_ENVBLK_SIZE = "1024"$/GRUB_ENVBLK_SIZE = "512"/'
mutate "a wrong block header is caught" "$RECIPE_REL" 's/^GRUB_ENVBLK_HEADER = .*/GRUB_ENVBLK_HEADER = "# nope"/'
mutate "a recipe that cannot fail on an oversized block is caught" "$RECIPE_REL" 's/bbfatal/bbwarn/g'
mutate "arithmetic expansion in the recipe is caught" "$RECIPE_REL" 's/pad=$(awk .*/pad=$((total - used))/'
mutate "an initial grubenv that is not the defaults is caught" "$RECIPE_REL" 's/"ATC_STEADY=A" "ATC_TRIAL=none"/"ATC_STEADY=B" "ATC_TRIAL=none"/'
mutate "a COMPATIBLE_MACHINE this config cannot boot is caught" "$RECIPE_REL" \
  's/^COMPATIBLE_MACHINE = .*/COMPATIBLE_MACHINE = "qemux86-64|qemuarm64"/'

# The slot backend seam: the GRUB contract stays on atc-slot-grub, and the
# nvbootctrl backend keeps none of it.
mutate "a seam without the grub default is caught" "$SEAM_REL" \
  's/^ATC_SLOT_BACKEND ??= "grub"$/ATC_SLOT_BACKEND ??= "nvbootctrl"/' "default ATC_SLOT_BACKEND to grub"
mutate "a seam that never derives the override is caught" "$SEAM_REL" '/^OVERRIDES /d' "derive the atc-slot"
mutate "a seam without the tegra234 value is caught" "$SEAM_REL" '/^ATC_SLOT_BACKEND:tegra234/d' "nvbootctrl on tegra234"
mutate "a runtime profile off the seam is caught" "$RUNTIME_REL" '/^inherit atc-slot-backend$/d' "does not inherit atc-slot-backend"
mutate "a grub-editenv for every backend is caught" "$RUNTIME_REL" \
  's/^IMAGE_INSTALL += "rauc rauc-conf atc-os"$/IMAGE_INSTALL += "rauc rauc-conf grub-editenv atc-os"/; /^IMAGE_INSTALL:append:atc-slot-grub = /d' \
  "grub-editenv on atc-slot-grub alone"
mutate "a runtime profile without atc-nvbootctrl is caught" "$RUNTIME_REL" \
  '/^IMAGE_INSTALL:append:atc-slot-nvbootctrl = /d' "atc-nvbootctrl on atc-slot-nvbootctrl"
mutate "a runtime profile without atc-os is caught" "$RUNTIME_REL" \
  's/^IMAGE_INSTALL += "rauc rauc-conf atc-os"$/IMAGE_INSTALL += "rauc rauc-conf"/' "does not install atc-os"
mutate "GRUB mounts for every backend are caught" "$RUNTIME_REL" \
  's/^atc_install_fstab_entries:atc-slot-grub() {$/atc_install_fstab_entries() {/' "outside a backend variant"
mutate "a GRUB variant without the store mount is caught" "$RUNTIME_REL" '/^PARTLABEL=atcdata /d' "PARTLABEL=atcdata"
mutate "an image off the seam is caught" "$IMAGE_REL" '/^inherit atc-slot-backend$/d' "atc-image-ab does not inherit"
mutate "a GRUB EFI provider for every backend is caught" "$IMAGE_REL" \
  's/^EFI_PROVIDER:atc-slot-grub = /EFI_PROVIDER = /' "without :atc-slot-grub"
mutate "a wic for every backend is caught" "$IMAGE_REL" \
  's/^IMAGE_FSTYPES:append:atc-slot-grub = " wic"$/IMAGE_FSTYPES += "wic"/' "builds no wic on atc-slot-grub"
mutate "a wks for every backend is caught" "$IMAGE_REL" 's/^WKS_FILE:atc-slot-grub = /WKS_FILE = /' "atc-ab.wks.in on atc-slot-grub alone"
mutate "a bundle off the seam is caught" "$BUNDLE_REL" 's/^inherit bundle atc-slot-backend$/inherit bundle/' "atc-bundle.bb does not inherit"
mutate "a bundle with one compatible for every Orin is caught" "$BUNDLE_REL" \
  's/^RAUC_BUNDLE_COMPATIBLE:atc-slot-nvbootctrl = .*/RAUC_BUNDLE_COMPATIBLE:atc-slot-nvbootctrl = "atc-tegra234"/' "nvbootctrl compatible"
mutate "a rauc-conf off the seam is caught" "$RAUC_CONF_APPEND_REL" '/^inherit atc-slot-backend$/d' "rauc-conf.bbappend does not inherit"
mutate "a rauc-conf that never installs the nvbootctrl conf is caught" "$RAUC_CONF_APPEND_REL" \
  '/^ATC_RAUC_SYSTEM_CONF:atc-slot-nvbootctrl/d' "does not install system-nvbootctrl.conf"
mutate "a compatible that is never substituted is caught" "$RAUC_CONF_APPEND_REL" \
  '/sed -i .s\/@MACHINE@/d' "does not substitute @MACHINE@"

# The trial predicate is the one backend call atc-os makes.
mutate "a pre-install that reads grubenv itself is caught" "$PRE_INSTALL_REL" \
  's|^trial="\$("\$SLOT_TRIAL")"|env="$(grub-editenv /boot/atc/grubenv list)"\n&|' "reads the GRUB environment itself"
mutate "a pre-install that asks another predicate is caught" "$PRE_INSTALL_REL" \
  's|/usr/libexec/atc-os/atc-slot-trial|/usr/bin/true|' "does not ask"
mutate "a deadline that asks another predicate is caught" "$DEADLINE_REL" \
  's|/usr/libexec/atc-os/atc-slot-trial|/usr/bin/true|' "does not ask"
mutate "a GRUB predicate on every backend is caught" "$OS_RECIPE_REL" \
  's/^do_install:append:atc-slot-grub() {$/do_install:append() {/' "on every backend"
mutate "a GRUB predicate fetched on every backend is caught" "$OS_RECIPE_REL" \
  's/^SRC_URI:append:atc-slot-grub = /SRC_URI:append = /' "fetches atc-slot-trial-grub on every backend"
mutate "a predicate at another path is caught" "$OS_RECIPE_REL" \
  's|${libexecdir}/atc-os/atc-slot-trial$|${libexecdir}/atc-os/atc-slot-trial-grub|' "does not install atc-slot-trial-grub at"
mutate "a seam that leaves packages per tune is caught" "$SEAM_REL" '/^PACKAGE_ARCH = /d' "machine-specific"

# The nvbootctrl system.conf.
mutate "an nvbootctrl conf on the GRUB backend is caught" "$TEGRA_CONF_REL" \
  's/^bootloader=custom$/bootloader=grub/' "bootloader=custom"
mutate "an nvbootctrl conf with another backend path is caught" "$TEGRA_CONF_REL" \
  's|^bootloader-custom-backend=.*|bootloader-custom-backend=/usr/bin/nvbootctrl|' "atc-nvbootctrl-backend"
mutate "an nvbootctrl conf without the pre-install handler is caught" "$TEGRA_CONF_REL" \
  '/^pre-install=/d' "system-nvbootctrl.conf names no atc pre-install handler"
mutate "an nvbootctrl conf that accepts plain bundles is caught" "$TEGRA_CONF_REL" \
  's/^bundle-formats=verity$/bundle-formats=plain verity/' "system-nvbootctrl.conf accepts plain"
mutate "an nvbootctrl conf with one compatible for every board is caught" "$TEGRA_CONF_REL" \
  's/^compatible=.*/compatible=atc-tegra234/' "atc-@MACHINE@"
mutate "an nvbootctrl conf with a grubenv is caught" "$TEGRA_CONF_REL" \
  's|^\[system\]$|[system]\ngrubenv=/boot/atc/grubenv|' "keeps the GRUB key grubenv"
mutate "an nvbootctrl slot B on the wrong partition is caught" "$TEGRA_CONF_REL" \
  's|by-partlabel/APP_b|by-partlabel/APP|' "by-partlabel/APP_b"

# The Tegra store on UDA, and the redundant layout with the capsule (S3).
mutate "a Tegra store without the UDA mount is caught" "$RUNTIME_REL" \
  '/^PARTLABEL=UDA /d' "no PARTLABEL=UDA on /var/atc"
mutate "a UDA mount without growfs is caught" "$RUNTIME_REL" \
  's/,x-systemd\.growfs//' "no PARTLABEL=UDA on /var/atc"
mutate "a UDA mount for every backend is caught" "$RUNTIME_REL" \
  's/^atc_install_fstab_entries:atc-slot-nvbootctrl() {$/atc_install_fstab_entries:other() {/' "no PARTLABEL=UDA on /var/atc"
mutate "a UDA mount without nofail is caught" "$RUNTIME_REL" \
  's/defaults,nofail,/defaults,/' "has no nofail"
mutate "a Tegra image that does not flash UDA is caught" "$RUNTIME_REL" \
  '/^IMAGE_TEGRAFLASH_DATA:atc-slot-nvbootctrl /d' "does not flash atc-uda.ext4"
mutate "a second ext4 member in the archive is caught" "$RUNTIME_REL" \
  's/^DATAFILE:atc-slot-nvbootctrl = "atc-uda.img"$/DATAFILE:atc-slot-nvbootctrl = "atc-uda.ext4"/' \
  "does not flash atc-uda.ext4"
mutate "an A/B image that accepts the single-APP layout is caught" "$RUNTIME_REL" \
  "s/d.getVar('USE_REDUNDANT_FLASH_LAYOUT') != '1'/False/" "atc-ab-runtime.inc does not refuse the single-APP"
mutate "a bundle that accepts the single-APP layout is caught" "$BUNDLE_REL" \
  "s/d.getVar('USE_REDUNDANT_FLASH_LAYOUT') != '1'/False/" "atc-bundle.bb does not refuse the single-APP"
mutate "a runtime profile without the capsule tool is caught" "$RUNTIME_REL" \
  's/ atc-tegra-capsule//' "does not install atc-tegra-capsule"
mutate "a non-redundant default is caught" "$LAYER_CONF_REL" \
  's/^ATC_TEGRA_REDUNDANT ??= "1"$/ATC_TEGRA_REDUNDANT ??= "0"/' "ATC_TEGRA_REDUNDANT to 1"
mutate "an image-level redundant layout is caught" "$LAYER_CONF_REL" \
  '/^USE_REDUNDANT_FLASH_LAYOUT_DEFAULT:tegra234 /d' "USE_REDUNDANT_FLASH_LAYOUT_DEFAULT on tegra234"
mutate "a missing retry-count overlay is caught" "$LAYER_CONF_REL" \
  '/^TEGRA_BOOTCONTROL_OVERLAYS:append:tegra234 /d' "RootfsRetryCountMax overlay"
mutate "a bundle without the capsule is caught" "$BUNDLE_REL" \
  '/^RAUC_BUNDLE_EXTRA_FILES:append:atc-slot-nvbootctrl /d' "does not carry tegra-bl.cap"
mutate "a bundle that never builds the capsule is caught" "$BUNDLE_REL" \
  '/^RAUC_BUNDLE_EXTRA_DEPENDS:append:atc-slot-nvbootctrl /d' "tegra-uefi-capsules"
mutate "a hook that stages another name is caught" "$HOOK_REL" \
  's|/tegra-bl.cap"$|/capsule.cap"|' "does not stage"
mutate "a hook that arms is caught" "$HOOK_REL" \
  's|^\(    "\$tool" stage "\$capsule" .*\)$|\1\n    "$tool" arm B|' "arms the capsule"

missing="$tmp/missing"
make_fixture "$missing"
rm "$missing/$CONF_REL"
expect fail "a missing system.conf is caught" "$missing"

if [ "$failures" -gt 0 ]; then
  echo "check-atc-ab-layout_test: $failures failure(s)" >&2
  exit 1
fi
echo "check-atc-ab-layout_test: all $case_n mutation cases passed"
