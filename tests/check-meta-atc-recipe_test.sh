#!/usr/bin/env bash
# tests/check-meta-atc-recipe_test.sh
#
# Self-test for scripts/check-meta-atc-recipe.sh, the repository-side gate.
#
# The gate's PASSING result is "no drift found", which is also what a gate that
# never really ran produces. So every case here builds a fixture tree, mutates
# exactly one thing, and asserts the gate goes RED on that mutation and GREEN
# without it. A case that cannot go red is not coverage.
#
# The gate resolves the layer from $BASH_SOURCE, so each fixture holds a layer
# at <fixture>/meta-atc with the gate copied into its scripts/.
#
# Usage: check-meta-atc-recipe_test.sh <path-to-check-meta-atc-recipe.sh>
set -euo pipefail

GATE="${1:?usage: check-meta-atc-recipe_test.sh <path-to-check-meta-atc-recipe.sh>}"
GATE="$(cd "$(dirname "$GATE")" && pwd)/$(basename "$GATE")"

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect() {
  local want="$1" name="$2" root="$3" out status
  set +e
  out="$("$root/meta-atc/scripts/check-meta-atc-recipe.sh" 2> "$tmp/stderr")"
  status=$?
  set -e
  if [ "$want" = pass ] && [ "$status" -ne 0 ]; then
    echo "FAIL: $name: expected the gate to PASS, exit $status" >&2
    cat "$tmp/stderr" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$want" = fail ] && [ "$status" -eq 0 ]; then
    echo "FAIL: $name: expected the gate to FAIL, but it passed" >&2
    printf '%s\n' "$out" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok: $name"
}

# Build a fixture tree that the gate should accept.
make_fixture() {
  local root="$1"
  mkdir -p "$root/meta-atc/conf"
  mkdir -p "$root/meta-atc/recipes-core/atc/files"
  mkdir -p "$root/meta-atc/recipes-core/images"

  mkdir -p "$root/meta-atc/scripts"
  cp "$GATE" "$root/meta-atc/scripts/check-meta-atc-recipe.sh"
  chmod +x "$root/meta-atc/scripts/check-meta-atc-recipe.sh"

  printf '%s\n' '#!/usr/bin/env sh' 'echo guard' \
    > "$root/meta-atc/recipes-core/atc/files/atcd-boot-confirm.sh"
  printf '%s\n' '#!/bin/sh' 'echo install' > "$root/meta-atc/recipes-core/atc/files/install-atcd.sh"

  cat > "$root/meta-atc/conf/layer.conf" << 'EOF'
LAYERSERIES_COMPAT_atc = "scarthgap"
LAYERDEPENDS_atc = "core rauc"
LAYERRECOMMENDS_atc = "tegra"
EOF
  cat > "$root/meta-atc/conf/layers.pin" << 'EOF'
# name url branch commit [machine-override]
meta-rauc https://example.invalid/meta-rauc scarthgap d63878f20eba7a85ecf53566e7a3377e78bb46ac
meta-tegra https://example.invalid/meta-tegra scarthgap e7d217e24ca9943e959e80da78a6025fe1373908 tegra234
EOF

  cat > "$root/meta-atc/recipes-core/atc/atcd_0.1.0.bb" << 'EOF'
ATCD_LIBEXEC = "/usr/local/libexec"
ATCD_REMOTE_PATH = "${bindir}/atcd"
ATCD_EXPECTED_ELF_MACHINE:qemux86-64 = "Advanced Micro Devices X86-64"
ATCD_EXPECTED_ELF_MACHINE:qemuarm64 = "AArch64"
ATCD_EXPECTED_ELF_MACHINE:tegra234 = "AArch64"
do_compile[nostamp] = "1"
do_compile() {
    ATC_TRACK="${ATCD_TRACK}" ATC_DOWNLOAD_ONLY="${B}/atcd" \
        sh ${WORKDIR}/install-atcd.sh
}
do_install() {
    actual_machine=$(readelf -h "${B}/atcd")
}
EOF

  mkdir -p "$root/meta-atc/classes"
  cat > "$root/meta-atc/classes/atc-slot-backend.bbclass" << 'EOF'
ATC_SLOT_BACKEND ??= "grub"
OVERRIDES .= ":atc-slot-${ATC_SLOT_BACKEND}"
PACKAGE_ARCH = "${MACHINE_ARCH}"
EOF

  cat > "$root/meta-atc/recipes-core/images/atc-tegra.inc" << 'EOF'
# Tegra settings
IMAGE_FSTYPES:tegra234 = "tegraflash"
TEGRAFLASH_PACKAGE_FORMAT:tegra234 = "tar"
IMAGE_INSTALL:append:tegra234 = " \
    a \
    "
EOF

  cat > "$root/meta-atc/recipes-core/images/atc-image.bb" << 'EOF'
require recipes-core/images/atc-tegra.inc
EXTRA_USERS_PARAMS = "groupadd -f atc; useradd -m -G atc -s /bin/sh deploy;"
ATC_DEPLOY_SSH_KEY ?= ""
atc_install_deploy_ssh_key() {
    chown -R "$deploy_uid:$deploy_gid" "$ssh_dir"
}
atc_refuse_prebuilt_store_root() {
    if [ -e "${IMAGE_ROOTFS}/var/atc" ]; then
        bbfatal "no"
    fi
}
EOF
}

# Baseline: an unmutated fixture must pass. Without this the red cases below
# could be red for an unrelated reason.
base="$tmp/base"
make_fixture "$base"
expect pass "clean fixture passes" "$base"

# 2. The recipe's libexec path diverges from atcd's libexec directory.
d2="$tmp/libexec-drift"
make_fixture "$d2"
sed -i 's|ATCD_LIBEXEC = "/usr/local/libexec"|ATCD_LIBEXEC = "/opt/libexec"|' \
  "$d2/meta-atc/recipes-core/atc/atcd_0.1.0.bb"
expect fail "a recipe libexec path off the contract is caught" "$d2"

# 4. The image loses its refusal to pre-create the store root.
d4="$tmp/no-refusal"
make_fixture "$d4"
printf '%s\n' '# refusal removed' > "$d4/meta-atc/recipes-core/images/atc-image.bb"
expect fail "an image that dropped the /var/atc refusal is caught" "$d4"

# 5. The image pre-creates the store root outright.
d5="$tmp/creates-store-root"
make_fixture "$d5"
# shellcheck disable=SC2016  # a bitbake variable, expanded by bitbake, not here
printf '%s\n' 'install -d ${IMAGE_ROOTFS}/var/atc' \
  >> "$d5/meta-atc/recipes-core/images/atc-image.bb"
expect fail "an image that creates /var/atc is caught" "$d5"

# 6. The recipe loses its readelf architecture assertion. Without it a
#    wrong-architecture ELF installs and the build stays green.
d6="$tmp/no-readelf"
make_fixture "$d6"
sed -i 's|readelf -h|file|' "$d6/meta-atc/recipes-core/atc/atcd_0.1.0.bb"
expect fail "a recipe without the readelf assertion is caught" "$d6"

# 7. A machine loses its expected ELF machine name, so nothing can be compared.
d7="$tmp/no-expected-machine"
make_fixture "$d7"
sed -i '/ATCD_EXPECTED_ELF_MACHINE:qemuarm64/d' \
  "$d7/meta-atc/recipes-core/atc/atcd_0.1.0.bb"
expect fail "a machine with no expected ELF name is caught" "$d7"

# 8. LAYERSERIES_COMPAT stops naming a series. "The current LTS" is not a pin.
d8="$tmp/unpinned-series"
make_fixture "$d8"
# shellcheck disable=SC2016  # a bitbake variable: the point is that it is NOT a pin
printf '%s\n' 'LAYERSERIES_COMPAT_atc = "${CURRENT_LTS}"' > "$d8/meta-atc/conf/layer.conf"
expect fail "an unpinned LAYERSERIES_COMPAT is caught" "$d8"

# 9. A baked-in SSH key that is never chowned. ROOTFS_POSTPROCESS runs as the
#    build user, so sshd's StrictModes refuses the key and the bootstrap it
#    exists to enable silently cannot happen.
d10="$tmp/ssh-key-not-chowned"
make_fixture "$d10"
sed -i '/chown -R/d' "$d10/meta-atc/recipes-core/images/atc-image.bb"
expect fail "an SSH key that is never chowned is caught" "$d10"

# 10. The recipe fetches atcd some other way than install-atcd.sh, so neither
#     the release signature nor the sha256 is checked.
d11="$tmp/no-install-script"
make_fixture "$d11"
sed -i '/ATC_DOWNLOAD_ONLY/d' "$d11/meta-atc/recipes-core/atc/atcd_0.1.0.bb"
expect fail "a recipe that does not fetch atcd with install-atcd.sh is caught" "$d11"

# 12. A backtick inside a bbfatal message. Those bodies are SHELL, so a backtick
#     is command substitution: the build would try to RUN the command named in
#     its own error message. Invisible without a Yocto build, and the same
#     phrases appear harmlessly in comments two lines away.
d13="$tmp/backtick-in-message"
make_fixture "$d13"
# shellcheck disable=SC2016  # the backtick is the defect under test
printf '%s\n' 'do_x() { bbfatal "run `atc bootstrap` first"; }' \
  >> "$d13/meta-atc/recipes-core/images/atc-image.bb"
expect fail "a backtick in a bbfatal message is caught" "$d13"

# 12b. The SAME defect on a backslash CONTINUATION line, which is how every real
#      message in these recipes is written. A line-anchored pattern matches the
#      bbfatal line only and misses this. The guard was DEAD exactly this way,
#      and the single-line case above stayed green while the real recipe was
#      broken. This case is what makes the guard's coverage real.
d13b="$tmp/backtick-in-continued-message"
make_fixture "$d13b"
# shellcheck disable=SC2016,SC1003  # the backtick is the defect under test, and
# the trailing backslash is a bitbake line continuation, not a quote escape
printf '%s\n%s\n' 'do_x() { bbfatal "first line \' \
  'and then `atc bootstrap` on the next"; }' \
  >> "$d13b/meta-atc/recipes-core/images/atc-image.bb"
expect fail "a backtick on a continuation line is caught" "$d13b"

# 13. A backtick in a plain COMMENT is fine and must NOT fail. Without this the
#     guard above could be a blanket backtick ban, which would be unusable.
d14="$tmp/backtick-in-comment"
make_fixture "$d14"
# shellcheck disable=SC2016  # a comment, deliberately containing a backtick
printf '%s\n' '# see `atc bootstrap atcd install` for the seeding path' \
  >> "$d14/meta-atc/recipes-core/images/atc-image.bb"
expect pass "a backtick in a comment is allowed" "$d14"

# 14. The recipe installs onto the path bootstrap SYMLINKS, making a second real
#     atcd on the device. The gate's comment claimed to check this while nothing
#     read the recipe at all, so the drift landed green.
d15="$tmp/recipe-installs-onto-symlink-path"
make_fixture "$d15"
sed -i 's|^ATCD_REMOTE_PATH = .*|ATCD_REMOTE_PATH = "/usr/local/bin/atcd"|' \
  "$d15/meta-atc/recipes-core/atc/atcd_0.1.0.bb"
expect fail "a recipe installing onto the symlink path is caught" "$d15"

# 15. The download is cached, so a new release never reaches the image and the
#     build reports success.
d16="$tmp/no-nostamp"
make_fixture "$d16"
sed -i '/do_compile\[nostamp\]/d' "$d16/meta-atc/recipes-core/atc/atcd_0.1.0.bb"
expect fail "a recipe without do_compile[nostamp] is caught" "$d16"

# 16. The deploy user is put in a `sudo` group. Yocto does not create one, so
#     useradd fails on an unknown group and the account every push depends on is
#     never made. The image still "builds"; the failure shows up as a bootstrap
#     that cannot log in.
d17="$tmp/sudo-group"
make_fixture "$d17"
sed -i 's|useradd -m -G atc |useradd -m -G atc,sudo |' \
  "$d17/meta-atc/recipes-core/images/atc-image.bb"
expect fail "a deploy user in a sudo group is caught" "$d17"

# 17. A layer pin that is a short hash, and one with a missing field.
d18="$tmp/short-pin"
make_fixture "$d18"
sed -i 's/d63878f20eba7a85ecf53566e7a3377e78bb46ac/d63878f/' "$d18/meta-atc/conf/layers.pin"
expect fail "a short-hash layer pin is caught" "$d18"

d19="$tmp/three-field-pin"
make_fixture "$d19"
sed -i 's/ scarthgap / /' "$d19/meta-atc/conf/layers.pin"
expect fail "a layer pin with no branch is caught" "$d19"

d20="$tmp/no-rauc-pin"
make_fixture "$d20"
sed -i '/^meta-rauc /d' "$d20/meta-atc/conf/layers.pin"
expect fail "a pin file without meta-rauc is caught" "$d20"

d21="$tmp/no-rauc-dependency"
make_fixture "$d21"
sed -i 's/^LAYERDEPENDS_atc = .*/LAYERDEPENDS_atc = "core"/' "$d21/meta-atc/conf/layer.conf"
expect fail "a layer that does not depend on rauc is caught" "$d21"

# 17b. meta-tegra is optional: pinned for tegra234 only, recommended, never a
#      dependency. Each shape below would put it into, or require it for, a
#      qemu build.
d28="$tmp/tegra-pin-for-every-build"
make_fixture "$d28"
sed -i 's/ tegra234$//' "$d28/meta-atc/conf/layers.pin"
expect fail "a meta-tegra pin without the tegra234 override is caught" "$d28"

d29="$tmp/rauc-pin-scoped"
make_fixture "$d29"
sed -i '/^meta-rauc /s/$/ tegra234/' "$d29/meta-atc/conf/layers.pin"
expect fail "a meta-rauc pin scoped to one machine is caught" "$d29"

d30="$tmp/bad-override"
make_fixture "$d30"
sed -i 's/ tegra234$/ Tegra_234/' "$d30/meta-atc/conf/layers.pin"
expect fail "a pin with a malformed machine override is caught" "$d30"

d31="$tmp/six-field-pin"
make_fixture "$d31"
sed -i 's/ tegra234$/ tegra234 extra/' "$d31/meta-atc/conf/layers.pin"
expect fail "a pin with six fields is caught" "$d31"

d32="$tmp/tegra-dependency"
make_fixture "$d32"
sed -i 's/^LAYERDEPENDS_atc = .*/LAYERDEPENDS_atc = "core rauc tegra"/' "$d32/meta-atc/conf/layer.conf"
expect fail "a layer that depends on tegra is caught" "$d32"

d33="$tmp/no-tegra-recommend"
make_fixture "$d33"
sed -i '/^LAYERRECOMMENDS_atc/d' "$d33/meta-atc/conf/layer.conf"
expect fail "a layer that does not recommend tegra is caught" "$d33"

d34="$tmp/no-tegra-elf"
make_fixture "$d34"
sed -i '/^ATCD_EXPECTED_ELF_MACHINE:tegra234/d' "$d34/meta-atc/recipes-core/atc/atcd_0.1.0.bb"
expect fail "no expected ELF machine for tegra234 is caught" "$d34"

# 17c. atc-tegra.inc reaches every image, so each line needs a Tegra override.
d35="$tmp/tegra-inc-plain-line"
make_fixture "$d35"
printf '%s\n' 'IMAGE_FSTYPES = "tegraflash"' >> "$d35/meta-atc/recipes-core/images/atc-tegra.inc"
expect fail "a plain line in atc-tegra.inc is caught" "$d35"

d36="$tmp/tegra-inc-other-override"
make_fixture "$d36"
printf '%s\n' 'IMAGE_FSTYPES:qemux86-64 = "wic"' >> "$d36/meta-atc/recipes-core/images/atc-tegra.inc"
expect fail "a non-Tegra override in atc-tegra.inc is caught" "$d36"

d37="$tmp/tegra-inc-inherit"
make_fixture "$d37"
printf '%s\n' 'inherit atc-slot-backend' >> "$d37/meta-atc/recipes-core/images/atc-tegra.inc"
expect fail "an inherit in atc-tegra.inc is caught" "$d37"

d38="$tmp/tegra-inc-not-required"
make_fixture "$d38"
sed -i '/^require recipes-core\/images\/atc-tegra.inc$/d' "$d38/meta-atc/recipes-core/images/atc-image.bb"
expect fail "an atc-image.bb that does not require atc-tegra.inc is caught" "$d38"

d39="$tmp/tegra-inc-missing"
make_fixture "$d39"
mv "$d39/meta-atc/recipes-core/images/atc-tegra.inc" "$d39/atc-tegra.inc.moved"
expect fail "a missing atc-tegra.inc is caught" "$d39"

# 17c-2. :atc-slot-nvbootctrl never applies in atc-tegra.inc, so it is refused.
d43="$tmp/tegra-inc-seam-override"
make_fixture "$d43"
printf '%s\n' 'IMAGE_INSTALL:append:atc-slot-nvbootctrl = " x"' >> "$d43/meta-atc/recipes-core/images/atc-tegra.inc"
expect fail "an :atc-slot-nvbootctrl line in atc-tegra.inc is caught" "$d43"

# 17c-3. An allowed plain bbappend passes.
d44="$tmp/allowed-append"
make_fixture "$d44"
mkdir -p "$d44/meta-atc/recipes-core/rauc"
: > "$d44/meta-atc/recipes-core/rauc/rauc_%.bbappend"
expect pass "an allowed plain bbappend passes" "$d44"

# 17d. A meta-tegra bbappend outside dynamic-layers/ breaks the qemu parse. The
#      gate allows a list, so every name not on it goes red, whatever its prefix.
for name in tegra-redundant-boot_%.bbappend l4t-launcher-extlinux.bbappend nvidia-kernel-oot_%.bbappend \
  edk2-firmware-tegra_%.bbappend linux-jammy-nvidia-tegra_%.bbappend cuda-toolkit_%.bbappend; do
  case_n_append=$((${case_n_append:-0} + 1))
  dapp="$tmp/stray-append-$case_n_append"
  make_fixture "$dapp"
  mkdir -p "$dapp/meta-atc/recipes-bsp/x"
  : > "$dapp/meta-atc/recipes-bsp/x/$name"
  expect fail "a stray $name is caught" "$dapp"
done

d41="$tmp/dynamic-append"
make_fixture "$d41"
mkdir -p "$d41/meta-atc/dynamic-layers/tegra/recipes-bsp/uefi"
: > "$d41/meta-atc/dynamic-layers/tegra/recipes-bsp/uefi/l4t-launcher-extlinux.bbappend"
# shellcheck disable=SC2016  # a bitbake variable, written as text
printf '%s\n' 'BBFILES_DYNAMIC += "tegra:${LAYERDIR}/dynamic-layers/tegra/recipes-*/*/*.bbappend"' \
  >> "$d41/meta-atc/conf/layer.conf"
expect pass "a meta-tegra bbappend under dynamic-layers/tegra/ passes" "$d41"

d42="$tmp/dynamic-append-no-entry"
make_fixture "$d42"
mkdir -p "$d42/meta-atc/dynamic-layers/tegra/recipes-bsp/uefi"
: > "$d42/meta-atc/dynamic-layers/tegra/recipes-bsp/uefi/l4t-launcher-extlinux.bbappend"
expect fail "dynamic-layers/tegra/ without a BBFILES_DYNAMIC entry is caught" "$d42"

# 17e. A line keyed on an atc-slot-* override needs the class: it defines the
#      override and makes the package machine-specific.
d45="$tmp/seam-user-without-class"
make_fixture "$d45"
mkdir -p "$d45/meta-atc/recipes-core/rauc"
printf '%s\n' 'SRC_URI:atc-slot-nvbootctrl = "file://x.conf"' > "$d45/meta-atc/recipes-core/rauc/rauc-conf.bbappend"
expect fail "an atc-slot-* line without inherit atc-slot-backend is caught" "$d45"

d46="$tmp/seam-user-with-class"
make_fixture "$d46"
mkdir -p "$d46/meta-atc/recipes-core/rauc"
printf '%s\n' 'inherit atc-slot-backend' 'SRC_URI:atc-slot-nvbootctrl = "file://x.conf"' \
  > "$d46/meta-atc/recipes-core/rauc/rauc-conf.bbappend"
expect pass "an atc-slot-* line with inherit atc-slot-backend passes" "$d46"

d47="$tmp/seam-user-in-comment"
make_fixture "$d47"
mkdir -p "$d47/meta-atc/recipes-core/rauc"
printf '%s\n' '# keyed on :atc-slot-grub elsewhere' > "$d47/meta-atc/recipes-core/rauc/rauc-conf.bbappend"
expect pass "an atc-slot-* name in a comment passes" "$d47"

d48="$tmp/seam-class-per-tune"
make_fixture "$d48"
sed -i '/^PACKAGE_ARCH = /d' "$d48/meta-atc/classes/atc-slot-backend.bbclass"
expect fail "a seam class that leaves packages per tune is caught" "$d48"

# 18. Key material in the layer, in each of the three shapes.
for ext in pem key crt; do
  dk="$tmp/key-$ext"
  make_fixture "$dk"
  mkdir -p "$dk/meta-atc/recipes-core/rauc/files"
  printf 'secret\n' > "$dk/meta-atc/recipes-core/rauc/files/ca.$ext"
  expect fail "a .$ext file under meta-atc/ is caught" "$dk"
done

# 19. A required file is missing entirely. The gate must fail, not skip.
d9="$tmp/missing-recipe"
make_fixture "$d9"
rm "$d9/meta-atc/recipes-core/atc/atcd_0.1.0.bb"
expect fail "a missing recipe is caught, not skipped" "$d9"

# 20. A *_COMMAND entry that ends in ';' drops out of the task hash. Both
#     shapes: one entry on the assignment line, and a continuation line.
d22="$tmp/semicolon-one-line"
make_fixture "$d22"
printf '%s\n' 'ROOTFS_POSTPROCESS_COMMAND += "atc_stamp;"' >> "$d22/meta-atc/recipes-core/images/atc-image.bb"
expect fail "a one-line *_COMMAND entry ending in ';' is caught" "$d22"
d23="$tmp/semicolon-continuation"
make_fixture "$d23"
printf 'IMAGE_POSTPROCESS_COMMAND += " \\\n    atc_stamp; \\\n    "\n' \
  >> "$d23/meta-atc/recipes-core/images/atc-image.bb"
expect fail "a continuation *_COMMAND entry ending in ';' is caught" "$d23"
d24="$tmp/semicolon-two-per-line"
make_fixture "$d24"
printf 'ROOTFS_POSTPROCESS_COMMAND += " \\\n    atc_a; atc_b \\\n    "\n' \
  >> "$d24/meta-atc/recipes-core/images/atc-image.bb"
expect fail "two entries on one continuation line are caught" "$d24"
d25="$tmp/semicolon-column-zero"
make_fixture "$d25"
printf 'ROOTFS_POSTPROCESS_COMMAND += " \\\natc_a; \\\n    "\n' \
  >> "$d25/meta-atc/recipes-core/images/atc-image.bb"
expect fail "an entry at column 0 on a continuation line is caught" "$d25"
d26="$tmp/semicolon-in-conf"
make_fixture "$d26"
printf '%s\n' 'ROOTFS_POSTPROCESS_COMMAND:append = " atc_a;"' >> "$d26/meta-atc/conf/layer.conf"
expect fail "an entry in a .conf is caught" "$d26"
for form in 'ROOTFS_POSTPROCESS_COMMAND:append:qemux86-64 = " atc_a;"' \
  'ROOTFS_POSTPROCESS_COMMAND:append:class-target = " atc_a;"' \
  'ROOTFS_POSTPROCESS_COMMAND .= " atc_a;"' 'ROOTFS_POSTPROCESS_COMMAND ??= "atc_a;"' \
  "ROOTFS_POSTPROCESS_COMMAND += 'atc_a;'" 'OPKG_POSTPROCESS_COMMANDS += "atc_a;"' \
  'ROOTFS_POSTPROCESS_COMMAND =+ "atc_a;"' 'ROOTFS_POSTPROCESS_COMMAND =. "atc_a;"'; do
  case_n_semi=$((${case_n_semi:-0} + 1))
  dform="$tmp/semicolon-form-$case_n_semi"
  make_fixture "$dform"
  printf '%s\n' "$form" >> "$dform/meta-atc/recipes-core/images/atc-image.bb"
  expect fail "the form '$form' is caught" "$dform"
done
d27="$tmp/fi-semicolon"
make_fixture "$d27"
printf 'atc_f() {\n    if true; then\n        :\n    fi;\n}\n' >> "$d27/meta-atc/recipes-core/images/atc-image.bb"
expect pass "a fi; in a shell function passes" "$d27"

if [ "$failures" -gt 0 ]; then
  echo "check-meta-atc-recipe_test: $failures case(s) failed" >&2
  exit 1
fi

echo "check-meta-atc-recipe_test: all cases passed"
