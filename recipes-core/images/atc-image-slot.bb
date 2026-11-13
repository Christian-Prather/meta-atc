# Resolved through BBPATH, which conf/layer.conf points at LAYERDIR. The slot
# image must be the SAME system the bootstrap image is, or a device that updates
# lands on a rootfs the controller cannot reach.
require recipes-core/images/atc-image.bb
require recipes-core/images/atc-ab-runtime.inc

# SUMMARY and DESCRIPTION are set AFTER the require, on purpose.
#
# bitbake expands a `require` in place, at the line it appears on, and it parses
# the result from the top. atc-image.bb sets both variables with `=`, so a value
# written above this line is overwritten by the parent's, and the slot-specific
# text reaches neither bitbake's output nor the image manifest.
SUMMARY = "One A/B rootfs slot, as the ext4 image an atc bundle carries"
DESCRIPTION = "atc-image built as a bare ext4 filesystem sized to fit one A/B \
rootfs slot, with the same runtime profile as the factory disk. This is the \
image inside the OS update. atc-bundle.bb packs it into a signed RAUC verity \
bundle, and RAUC writes it into the inactive slot. A whole-disk .wic \
provisions a device at the factory and cannot update a running one: it would \
destroy the store, the device identity, and the slot that is currently running."

# Exactly one output type, ext4, which is the slot type in system.conf.
#
# `=` and not `+=` on purpose: the distro default (tar.bz2) and any local.conf
# setting would otherwise ride along. The image no longer has to be
# uncompressed: the bundle compresses it, and RAUC's verity check covers every
# block the device reads from the bundle.
IMAGE_FSTYPES = "ext4"

# The same on tegra234. atc-tegra.inc, which atc-image.bb requires, sets the
# tegraflash archive there, and an override outranks the line above. The slot
# image is the bundle's payload only. The factory flash is atc-image-ab.
IMAGE_FSTYPES:tegra234 = "ext4"

# The kernel lives INSIDE the slot, because GRUB reads it from the slot it
# selected. A shared kernel on the EFI partition would leave a kernel upgrade
# un-rollbackable while the rootfs beside it rolled back. This mirrors
# atc-image-ab.bb, which installs the same package for the same reason. On
# tegra234, L4TLauncher also reads the kernel from the rootfs it boots.
IMAGE_INSTALL += "kernel-image"

# The slot size, in KiB, and the contract this artifact is built against.
#
# 1048576 KiB is 1 GiB, which is the `--fixed-size 1024M` the A/B partition
# table gives each of atcroota and atcrootb. A build for a different layout
# overrides this, and the gates below move with it.
#
# A FILESYSTEM SMALLER THAN ITS PARTITION IS VALID. ext4 records its own size in
# the superblock, and the kernel ignores the tail of the partition. So this
# number is a ceiling, not a target. The artifact should be as small as the
# content allows: every byte of it crosses the link on every update.
ATC_SLOT_KIB ?= "1048576"

# tegra234: the slot is a rootfs partition of meta-tegra's flash layout, and
# ROOTFSPART_SIZE is its size in bytes. The redundant layout halves that value,
# so this limit follows the layout and is not restated here.
ATC_SLOT_KIB:tegra234 = "${@int(d.getVar('ROOTFSPART_SIZE')) // 1024}"

# The sanctioned build-time gate. bitbake computes the root filesystem size from
# the content, the overhead factor and the extra space, then fails the build when
# that size exceeds this value. The unit is KiB, the same unit as ATC_SLOT_KIB.
IMAGE_ROOTFS_MAXSIZE = "${ATC_SLOT_KIB}"

# The OS version this artifact carries. Deliberately MANDATORY.
#
# A controller targets a version and a device reports one. An artifact with no
# version string gives the fleet no answer to "which OS does this device run",
# and the .wic file name is not a substitute: it carries a build timestamp, and
# a name outside the image tells a booted device nothing.
#
# The string is written INSIDE the image, so changing it changes the sha256. The
# artifact digest and the version can therefore never disagree.
ATC_OS_VERSION ?= ""
ATC_OS_VERSION_FILE = "${IMAGE_ROOTFS}${sysconfdir}/atc-os-version"

atc_install_os_version() {
    if [ -z "${ATC_OS_VERSION}" ]; then
        bbfatal "ATC_OS_VERSION is empty. An OS slot artifact must name its own \
version: the controller targets one and the device reports one. Set it in \
local.conf, for example ATC_OS_VERSION = \"2026.09.17-1\"."
    fi
    install -d ${IMAGE_ROOTFS}${sysconfdir}
    printf '%s\n' "${ATC_OS_VERSION}" > ${ATC_OS_VERSION_FILE}
    chmod 0644 ${ATC_OS_VERSION_FILE}
}

# One artifact must be correct in slot A and in slot B.
#
# GRUB passes `root=PARTLABEL=atcroota` or `...atcrootb` on the kernel command
# line, so the filesystem itself must name no slot. An fstab line that mounted a
# slot by label would pin this image to one of them, and the controller would
# then need two artifacts that differ by one line.
#
# The stock /etc/fstab from base-files carries `/dev/root / auto ...`, which is
# slot agnostic and stays. Only the slot LABELS are refused.
atc_refuse_slot_specific_fstab() {
    fstab="${IMAGE_ROOTFS}${sysconfdir}/fstab"
    if [ ! -f "$fstab" ]; then
        return 0
    fi
    if grep -q 'atcroot' "$fstab"; then
        bbfatal "the rootfs /etc/fstab names a slot label. One slot artifact \
must boot in EITHER slot: GRUB selects the slot with root=PARTLABEL= on the \
kernel command line. Remove the atcroot* line from the fstab."
    fi
}

ROOTFS_POSTPROCESS_COMMAND += " \
    atc_install_os_version \
    atc_refuse_slot_specific_fstab \
    "

# The second size gate, against the file that was actually produced.
#
# IMAGE_ROOTFS_MAXSIZE bounds the size bitbake COMPUTES. This bounds the bytes
# on disk. Both are cheap, and a gate on the computed number alone would not
# notice a filesystem type that rounds up.
#
# awk, and NOT shell arithmetic expansion. bitbake parses every shell function
# with its own parser to work out task dependencies, and that parser raises
# NotImplementedError on the arithmetic-expansion token. The recipe then fails at
# PARSE time, before any task runs. `expr` is the other obvious substitute and is
# also wrong: it exits non-zero when the result is 0, and bitbake runs shell
# tasks under `set -e`.
#
# IT FAILS CLOSED, AND THAT IS DELIBERATE. This layer has no Yocto builder in CI,
# so this check has never been parsed. A check that found no image and returned
# quietly would read exactly like a check that passed. So a missing image is a
# build failure that names the directory it looked in, and the first real build
# reports a wrong assumption instead of hiding it.
# `printf "%d"`, and NOT awk's bare `print`. awk's `print` renders a number
# through OFMT, which is `%.6g`. Implementations disagree about when a large
# integral value escapes that format: mawk 1.3.4, gawk 5.3.2 and busybox awk all
# print 4294967296 for a 4 GiB slot, and older mawk emits `4.29497e+09` instead.
#
# That string would make this gate FAIL OPEN, which is the one outcome the
# comment above forbids. `[ "$bytes" -gt "4.29497e+09" ]` writes "Illegal number"
# to stderr and returns 2. A non-zero status INSIDE an `if` condition does not
# trip `set -e`, so the shell takes the else branch, no bbfatal runs, and an
# oversized image reports that it fits. Measured in `sh` on 2026-09-21.
#
# So the limit is formatted as a decimal integer and then CHECKED. A limit that
# is not all digits stops the build, rather than quietly disarming the gate.
atc_assert_slot_image_fits() {
    limit=$(awk -v kib="${ATC_SLOT_KIB}" 'BEGIN { printf "%d", kib * 1024 }')
    case "$limit" in
        "" | *[!0-9]*)
            bbfatal "the slot byte limit computed from ATC_SLOT_KIB=\
${ATC_SLOT_KIB} is '$limit', which is not a decimal integer. The shell cannot \
compare a size against it, and a comparison that errors inside an 'if' reports \
that the image fits. Set ATC_SLOT_KIB to a positive whole number of KiB."
            ;;
    esac
    found=0
    for img in ${IMGDEPLOYDIR}/*.ext4; do
        if [ ! -f "$img" ]; then
            continue
        fi
        found=1
        bytes=$(wc -c < "$img")
        if [ "$bytes" -gt "$limit" ]; then
            bbfatal "the slot image $img is $bytes bytes, over the $limit-byte \
slot (ATC_SLOT_KIB=${ATC_SLOT_KIB}). The device writes this to a partition of a \
FIXED size: it cannot be written, and a writer that truncated instead would \
produce a slot that passes its sha256 and cannot boot. Cut the rootfs, or raise \
ATC_SLOT_KIB together with the partition table."
        fi
        bbnote "atc slot image $img is $bytes bytes, within the $limit-byte slot."
    done
    if [ "$found" = 0 ]; then
        bbfatal "found no .ext4 image under ${IMGDEPLOYDIR}, so the slot size \
gate checked nothing. Either IMAGE_FSTYPES no longer produces ext4, or this \
function runs before the image type is written. Fix the gate before trusting \
the build."
    fi
}

IMAGE_POSTPROCESS_COMMAND += "atc_assert_slot_image_fits"
