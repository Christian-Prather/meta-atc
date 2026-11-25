SUMMARY = "The atc OS update: atc-image-slot in a signed RAUC verity bundle"
DESCRIPTION = "Packs the atc-image-slot ext4 image into a RAUC bundle that a \
device installs into its inactive slot. The bundle reaches the device as an \
ordinary store blob. The device's RAUC checks the signature against its \
keyring, the compatible string against system.conf, and every block it reads \
through dm-verity."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit bundle atc-slot-backend

SRC_URI = "file://atc-bundle-hook"

# verity, and nothing else. system.conf refuses plain bundles
# (`bundle-formats=verity`), because a plain bundle over 2 GiB is the
# CVE-2026-34155 case.
RAUC_BUNDLE_FORMAT = "verity"

# Must equal `compatible=` in recipes-core/rauc/files/system.conf. RAUC refuses
# a bundle whose compatible string differs. scripts/check-atc-ab-layout.sh
# fails when the two disagree.
RAUC_BUNDLE_COMPATIBLE = "atc-qemux86-64"

# The nvbootctrl backend's system.conf carries `compatible=atc-@MACHINE@`, which
# rauc-conf.bbappend fills in. One string per machine stops an Orin NX bundle from
# reaching an Orin Nano, whose device tree and firmware differ.
RAUC_BUNDLE_COMPATIBLE:atc-slot-nvbootctrl = "atc-${MACHINE}"

# The version the slot image writes into /etc/atc-os-version. atc-image-slot.bb
# refuses an empty one, and this recipe does too, so a bundle cannot name a
# version its image does not carry.
ATC_OS_VERSION ?= ""
RAUC_BUNDLE_VERSION = "${ATC_OS_VERSION}"

python () {
    if not d.getVar('ATC_OS_VERSION'):
        raise bb.parse.SkipRecipe(
            "ATC_OS_VERSION is empty. The bundle names the OS version its slot "
            "image carries; set it in local.conf, for example "
            "ATC_OS_VERSION = \"2026.11.09-1\".")
    # The bundle's capsule and its slot image are both redundant-layout
    # firmware and rootfs. A board flashed with the single-APP layout has no
    # APP_b to install into.
    if d.getVar('ATC_SLOT_BACKEND') == 'nvbootctrl' and \
            d.getVar('USE_REDUNDANT_FLASH_LAYOUT') != '1':
        raise bb.parse.SkipRecipe(
            "the nvbootctrl bundle needs the redundant flash layout, and "
            "USE_REDUNDANT_FLASH_LAYOUT is '%s'. Remove ATC_TEGRA_REDUNDANT = "
            "\"0\" from the build configuration"
            % (d.getVar('USE_REDUNDANT_FLASH_LAYOUT') or ''))
}

RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs = "atc-image-slot"
RAUC_SLOT_rootfs[fstype] = "ext4"
RAUC_SLOT_rootfs[hooks] = "post-install"

RAUC_BUNDLE_HOOKS[file] = "atc-bundle-hook"

# The nvbootctrl backend: the bundle also carries the UEFI capsule that
# tegra-uefi-capsules builds from the same BSP as the slot image. An extra file
# sits in the bundle's squashfs, so dm-verity and the signature cover it like
# the image. The hook stages it on the ESP at slot-post-install, and the
# backend arms it as the last step of set-primary. UEFI then writes the
# inactive boot chain and boots it, and the rootfs follows, so the firmware and
# the rootfs of this bundle go live together.
RAUC_BUNDLE_EXTRA_FILES:append:atc-slot-nvbootctrl = " tegra-bl.cap"
RAUC_BUNDLE_EXTRA_DEPENDS:append:atc-slot-nvbootctrl = " tegra-uefi-capsules"

# The lab opt-in ATC_RAUC_CHILD_SLOTS (atc-rauc-child-slots.bbclass), on the
# nvbootctrl backend only. system-nvbootctrl-child-slots.conf gives each
# rootfs two child slots, kernel on A_kernel/B_kernel and dtb on
# A_kernel-dtb/B_kernel-dtb. The bundle writes both, with the files that
# tegraflash writes to those partitions at the factory flash, from the same
# build. L4TLauncher reads them when it boots without extlinux.conf, so a slot
# must never get other content.
#
# What meta-tegra writes there (the commit in conf/layers.pin):
#   kernel  IMAGE_TEGRAFLASH_KERNEL, from tegra_kernel_image() in
#           classes-recipe/image_types_tegra.bbclass. With the meta-tegra
#           defaults (INITRAMFS_IMAGE = "tegra-minimal-initramfs",
#           INITRAMFS_IMAGE_BUNDLE = "0") that is
#           ${DEPLOY_DIR_IMAGE}/${INITRAMFS_IMAGE}-${MACHINE}.cboot, an
#           Android boot image of the kernel and the initramfs. The package
#           copies it to boot.img (LNXFILE) for A_kernel and B_kernel.
#   dtb     DTBFILE, the first entry of KERNEL_DEVICETREE. copy_dtbs() takes
#           it from virtual/dtb (nvidia-kernel-oot-dtb), which also deploys
#           it to ${DEPLOY_DIR_IMAGE}/devicetree/. tegra-flash-helper.sh
#           copies it to kernel_<DTBFILE> for A_kernel-dtb and B_kernel-dtb.
# The anonymous function below skips the bundle for any setting where these
# names are not the files tegraflash writes.
RAUC_BUNDLE_SLOTS:append:atc-rauc-child-slots = " kernel dtb"

ATC_KERNEL_DTB ?= "${@d.getVar('DTBFILE') or (os.path.basename(((d.getVar('KERNEL_DEVICETREE') or '').split() or [''])[0]))}"

RAUC_SLOT_kernel = "${INITRAMFS_IMAGE}"
RAUC_SLOT_kernel[type] = "file"
RAUC_SLOT_kernel[file] = "${INITRAMFS_IMAGE}-${MACHINE}.cboot"
RAUC_SLOT_kernel[depends] = "${INITRAMFS_IMAGE}:do_image_complete"

RAUC_SLOT_dtb = "${PREFERRED_PROVIDER_virtual/dtb}"
RAUC_SLOT_dtb[type] = "file"
RAUC_SLOT_dtb[file] = "devicetree/${ATC_KERNEL_DTB}"

python () {
    if d.getVar('ATC_RAUC_CHILD_SLOTS') != '1':
        return
    reasons = []
    if not d.getVar('INITRAMFS_IMAGE'):
        reasons.append("INITRAMFS_IMAGE is empty, so tegraflash writes the "
                       "kernel recipe's .cboot to A_kernel")
    if bb.utils.to_boolean(d.getVar('INITRAMFS_IMAGE_BUNDLE')):
        reasons.append("INITRAMFS_IMAGE_BUNDLE is 1, so tegraflash writes the "
                       "kernel recipe's bundled .cboot to A_kernel")
    if not d.getVar('PREFERRED_PROVIDER_virtual/dtb'):
        reasons.append("no PREFERRED_PROVIDER_virtual/dtb, so tegraflash takes "
                       "the kernel DTB from another place")
    if not d.getVar('ATC_KERNEL_DTB'):
        reasons.append("KERNEL_DEVICETREE names no DTB")
    if d.getVar('TEGRA_UEFI_DB_KEY') or d.getVar('TEGRA_UEFI_DB_CERT'):
        reasons.append("UEFI signing is on, so tegraflash writes the .signed "
                       "DTB")
    if reasons:
        raise bb.parse.SkipRecipe(
            "ATC_RAUC_CHILD_SLOTS = \"1\" writes the kernel and kernel-dtb "
            "partitions with the meta-tegra default files only: %s"
            % "; ".join(reasons))
}

# qemux86-64 only on the GRUB backend, the same narrowness as
# atc-grub-env_1.0.bb: the compatible string, the GRUB config and the slot labels
# all name this one machine. On the nvbootctrl backend, every Orin machine.
COMPATIBLE_MACHINE = "qemux86-64"
COMPATIBLE_MACHINE:atc-slot-nvbootctrl = "tegra234"
