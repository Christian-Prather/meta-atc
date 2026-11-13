SUMMARY = "L4T bootcontrol overlay: one boot per rootfs trial"
DESCRIPTION = "Sets the UEFI variable RootfsRetryCountMax to 1 through a \
bootcontrol overlay, the mechanism meta-tegra uses for RootfsRedundancyLevel. \
A new rootfs slot then gets one boot. If it does not confirm, the L4T launcher \
marks it unbootable and boots the other slot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(tegra)"

DEPENDS = "dtc-native"
SRC_URI = "file://L4TConfiguration-AtcRootfsRetryCountMax.dtsi"

inherit deploy

do_configure[noexec] = "1"

do_compile() {
    dtc -Idts -Odtb -o ${B}/L4TConfiguration-AtcRootfsRetryCountMax.dtbo \
        ${WORKDIR}/L4TConfiguration-AtcRootfsRetryCountMax.dtsi
}

do_install[noexec] = "1"

# The flash package and the capsule read the overlay from DEPLOY_DIR_IMAGE by
# name. The edk2-firmware-tegra append in dynamic-layers/tegra makes the UEFI
# deploy, which both of them depend on, wait for this one.
do_deploy() {
    install -D -m 0644 -t ${DEPLOYDIR} ${B}/L4TConfiguration-AtcRootfsRetryCountMax.dtbo
}

addtask deploy before do_build after do_compile
