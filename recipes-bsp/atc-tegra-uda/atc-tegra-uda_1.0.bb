SUMMARY = "An empty ext4 filesystem for the Jetson store partition, UDA"
DESCRIPTION = "Deploys atc-uda.ext4, a small empty ext4 image. The tegraflash \
image writes it to UDA through meta-tegra's DATAFILE, so every factory flash \
gives /var/atc a fresh filesystem, with no store from an earlier image. \
systemd grows it to the partition at the first boot (x-systemd.growfs)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(tegra)"

DEPENDS = "e2fsprogs-native"
INHIBIT_DEFAULT_DEPS = "1"

inherit deploy nopackages

# Small, so the archive and the flash stay small. growfs takes it to the 4 GiB
# of the partition.
ATC_UDA_IMAGE_MB ?= "32"

do_configure[noexec] = "1"

do_compile() {
    rm -f ${B}/atc-uda.ext4
    dd if=/dev/zero of=${B}/atc-uda.ext4 bs=1M count=0 seek=${ATC_UDA_IMAGE_MB}
    # A 4 KiB block and the default usage type: mke2fs picks smaller blocks
    # and the "small" type for a 32 MiB file, and growfs keeps them at 4 GiB.
    mkfs.ext4 -F -q -b 4096 -T default -L atcdata -E root_owner=0:0 ${B}/atc-uda.ext4
}

do_deploy() {
    install -D -m 0644 ${B}/atc-uda.ext4 ${DEPLOYDIR}/atc-uda.ext4
}

addtask deploy before do_build after do_compile
