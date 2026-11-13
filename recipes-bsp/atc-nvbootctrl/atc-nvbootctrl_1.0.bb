SUMMARY = "The nvbootctrl slot backend of the atc OS update tier, on Jetson"
DESCRIPTION = "RAUC's custom bootloader backend over nvbootctrl and the UEFI \
slot variables, the boot unit that records each boot's slot state, and the \
trial predicate that atc-os reads. \
tests/atc-nvbootctrl-backend_test.sh runs the backend against a \
fake nvbootctrl and a fake efivarfs directory."
HOMEPAGE = "https://github.com/Christian-Prather/meta-atc"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://atc-nvbootctrl-backend \
    file://atc-slot-trial-nvbootctrl \
    file://atc-tegra-slot-boot.service \
    "

S = "${WORKDIR}"

# nvbootctrl and the L4T launcher come from meta-tegra. A qemux86-64 image uses
# RAUC's grub backend.
COMPATIBLE_MACHINE = "(tegra)"

inherit systemd

SYSTEMD_SERVICE:${PN} = "atc-tegra-slot-boot.service"

do_install() {
    install -d ${D}${nonarch_libdir}/rauc
    install -m 0755 ${WORKDIR}/atc-nvbootctrl-backend ${D}${nonarch_libdir}/rauc/

    install -d ${D}${libexecdir}/atc-os
    install -m 0755 ${WORKDIR}/atc-slot-trial-nvbootctrl ${D}${libexecdir}/atc-os/atc-slot-trial

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/atc-tegra-slot-boot.service ${D}${systemd_system_unitdir}/

    install -d ${D}${ATC_SYSTEMD_ADMIN_DIR}
    ln -sf /dev/null ${D}${ATC_SYSTEMD_ADMIN_DIR}/nv_update_verifier.service
}

# Mask nv_update_verifier.service in each image that installs this package.
# That service runs `nvbootctrl verify` on every boot, so it confirms a trial
# as soon as userspace starts, before atcd's dwell. That is the fault that
# rauc-mark-good has on the GRUB backend. atc-tegra-slot-boot.service takes
# its place: it verifies a steady boot and never a trial.
#
# The mask is per image, not per machine. Only the A/B image installs this
# package, so the non-redundant Orin image keeps the verifier. Without it, a
# single-slot device boots the recovery kernel when its retries run out.
ATC_SYSTEMD_ADMIN_DIR = "${sysconfdir}/systemd/system"

FILES:${PN} += " \
    ${nonarch_libdir}/rauc/atc-nvbootctrl-backend \
    ${libexecdir}/atc-os/atc-slot-trial \
    ${ATC_SYSTEMD_ADMIN_DIR}/nv_update_verifier.service \
    "

# tegra-redundant-boot-base installs /usr/sbin/nvbootctrl.
# setup-nv-boot-control-service installs the unit that writes
# /etc/nv_boot_control.conf, which nvbootctrl reads. util-linux-flock and
# e2fsprogs install flock and chattr, which busybox has only in some
# configurations. diffutils installs cmp, which reads a variable back after a
# failed `chattr +i`. The backend also runs dd, mktemp, sed, tail, tr and wc.
RDEPENDS:${PN} = "tegra-redundant-boot-base setup-nv-boot-control-service util-linux-flock e2fsprogs diffutils"
