SUMMARY = "Stage, arm and disarm the Jetson UEFI bootloader capsule"
DESCRIPTION = "atc-tegra-capsule puts the capsule from an OS update bundle on \
the ESP and sets bit 2 of OsIndications. The capsule writes the inactive boot \
chain and switches to it, and the rootfs slot follows, so the firmware and the \
rootfs of one bundle go live together. The bundle hook stages. The RAUC \
nvbootctrl backend arms, as the last step of set-primary."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(tegra)"

SRC_URI = "file://atc-tegra-capsule"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${libexecdir}/atc-os
    install -m 0755 ${WORKDIR}/atc-tegra-capsule ${D}${libexecdir}/atc-os/atc-tegra-capsule
}

# od, dd, cp, mv and sync from coreutils; cmp from diffutils; find from
# findutils; chattr from e2fsprogs, for the immutable flag efivarfs sets.
# setup-nv-boot-control-service ships boot-efi.mount, which mounts the ESP on
# /boot/efi. The tool refuses to stage when that mount is missing.
RDEPENDS:${PN} = "coreutils diffutils findutils e2fsprogs setup-nv-boot-control-service"
