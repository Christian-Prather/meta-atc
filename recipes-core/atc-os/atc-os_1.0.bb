SUMMARY = "The root-side units of the atc OS update tier"
DESCRIPTION = "The reboot that atcd requests through a file in the store, the \
15-minute trial deadline, and the systemd watchdog drop-in. atcd runs as user \
atc and drives RAUC over D-Bus; these units are the parts that need root and \
that must work when atcd does not run."
HOMEPAGE = "https://github.com/Agency-Tool-Company/meta-atc"
LICENSE = "CLOSED"

SRC_URI = " \
    file://atc-os-reboot.path \
    file://atc-os-reboot.service \
    file://atc-os-trial-deadline \
    file://atc-os-pre-install \
    file://atc-os-trial-deadline.service \
    file://atc-os-trial-deadline.timer \
    file://10-atc-watchdog.conf \
    file://10-atc-store.conf \
    "

S = "${WORKDIR}"

# The GRUB backend's atc-slot-trial ships here. The nvbootctrl backend's copy
# ships in atc-nvbootctrl, at the same path, so no image installs both.
#
# The class also makes the package machine-specific, because its content
# differs by backend.
inherit atc-slot-backend
SRC_URI:append:atc-slot-grub = " file://atc-slot-trial-grub"

inherit systemd

SYSTEMD_SERVICE:${PN} = "atc-os-reboot.path atc-os-trial-deadline.timer"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/atc-os-reboot.path ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/atc-os-reboot.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/atc-os-trial-deadline.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/atc-os-trial-deadline.timer ${D}${systemd_system_unitdir}/

    install -d ${D}${libexecdir}/atc-os
    install -m 0755 ${WORKDIR}/atc-os-trial-deadline ${D}${libexecdir}/atc-os/
    install -m 0755 ${WORKDIR}/atc-os-pre-install ${D}${libexecdir}/atc-os/

    install -d ${D}${systemd_unitdir}/system.conf.d
    install -m 0644 ${WORKDIR}/10-atc-watchdog.conf ${D}${systemd_unitdir}/system.conf.d/

    # atcd waits for the store mount. On every A/B image: /var/atc is a mount
    # on both backends, and the drop-in only orders atcd after it. It is in
    # /usr/lib, not /etc, so the bundle hook's carry of /etc/systemd/system
    # never meets it, and an update replaces it with the image.
    install -d ${D}${systemd_system_unitdir}/atcd.service.d
    install -m 0644 ${WORKDIR}/10-atc-store.conf ${D}${systemd_system_unitdir}/atcd.service.d/
}

# The systemd class packages the units SYSTEMD_SERVICE names, not the services
# that the path and the timer start.
FILES:${PN} += " \
    ${systemd_system_unitdir} \
    ${libexecdir}/atc-os \
    ${systemd_unitdir}/system.conf.d \
    "

# The trial deadline reads `rauc status`. On the GRUB backend, atc-slot-trial
# reads the boot environment with grub-editenv.
RDEPENDS:${PN} = "rauc"
RDEPENDS:${PN}:append:atc-slot-grub = " grub-editenv"
# On the nvbootctrl backend, atc-nvbootctrl ships atc-slot-trial.
RDEPENDS:${PN}:append:atc-slot-nvbootctrl = " atc-nvbootctrl"

do_install:append:atc-slot-grub() {
    install -m 0755 ${WORKDIR}/atc-slot-trial-grub ${D}${libexecdir}/atc-os/atc-slot-trial
}
