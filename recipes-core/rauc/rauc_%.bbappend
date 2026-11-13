# Replace RAUC's stock D-Bus policy with the atc one.
#
# The stock policy allows every local user to call RAUC, which means any user
# can install a signed bundle or mark a slot. The atc policy allows root and
# user `atc` only. The stock file is DELETED, not overridden: two policy files
# for one name leave the answer to the include order of dbus-daemon, and a
# reader of one file cannot see it.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://atc-rauc.conf"

do_install:append() {
    rm -f ${D}${datadir}/dbus-1/system.d/de.pengutronix.rauc.conf
    rmdir --ignore-fail-on-non-empty ${D}${datadir}/dbus-1/system.d
    install -d ${D}${sysconfdir}/dbus-1/system.d
    install -m 0644 ${WORKDIR}/atc-rauc.conf ${D}${sysconfdir}/dbus-1/system.d/atc-rauc.conf
}

FILES:${PN}-service += "${sysconfdir}/dbus-1/system.d/atc-rauc.conf"

# No rauc-mark-good. meta-rauc recommends it, and its unit runs
# `rauc status mark-good` on every boot whose command line carries `rauc.slot=`,
# which grub.cfg writes on every boot. A trial would then be confirmed the
# moment it reached userspace, before atcd's dwell and before the trial
# deadline. Only atcd marks a slot good.
RRECOMMENDS:${PN}:remove = "${PN}-mark-good"
