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

# qemux86-64 only on the GRUB backend, the same narrowness as
# atc-grub-env_1.0.bb: the compatible string, the GRUB config and the slot labels
# all name this one machine. On the nvbootctrl backend, every Orin machine.
COMPATIBLE_MACHINE = "qemux86-64"
COMPATIBLE_MACHINE:atc-slot-nvbootctrl = "tegra234"
