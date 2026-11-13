# The RAUC system configuration and the keyring for an atc A/B image.
#
# system.conf: two ext4 slots by PARTLABEL, the GRUB
# backend on the one environment file, and verity bundles only. A plain bundle
# over 2 GiB is the CVE-2026-34155 case, so `bundle-formats=verity` refuses
# plain bundles outright.
#
# That file is the GRUB backend's. The nvbootctrl backend (tegra234) installs
# system-nvbootctrl.conf in its place: `bootloader=custom`, whose handler wraps
# nvbootctrl, on meta-tegra's APP and APP_b partitions. Both install at the one
# path RAUC reads, /etc/rauc/system.conf.
#
# The keyring is NOT in this layer. scripts/check-meta-atc-recipe.sh fails
# on any *.pem, *.key or *.crt in this layer. local.conf names it with an
# absolute path. Test keys live on the builder's /cache. The production PKI is
# an open question.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The class also makes the package machine-specific: the system.conf it
# installs differs by backend.
inherit atc-slot-backend

ATC_RAUC_SYSTEM_CONF = "system.conf"
ATC_RAUC_SYSTEM_CONF:atc-slot-nvbootctrl = "system-nvbootctrl.conf"

# The base recipe fetches the keyring through SRC_URI and installs a copy of
# meta-rauc's example CA when nothing overrides it. Both are replaced: the
# keyring is read from its absolute path, and nothing else lands in /etc/rauc.
SRC_URI = "file://${ATC_RAUC_SYSTEM_CONF}"

RAUC_KEYRING_FILE ??= ""

# Skipped, not fatal, without a keyring. bitbake parses every recipe in every
# layer, so a fatal here would stop a build of atc-image, which never installs
# RAUC. An image that does need the keyring then fails with this reason.
python () {
    keyring = d.getVar('RAUC_KEYRING_FILE')
    if not keyring or not keyring.startswith('/'):
        raise bb.parse.SkipRecipe(
            "RAUC_KEYRING_FILE must be an absolute path to the CA that signs "
            "this image's bundles, set in local.conf. It is '%s'. "
            "scripts/rauc-test-keys.sh writes a test CA to "
            "/cache/atc-rauc-keys/ca.cert.pem." % (keyring or ''))
}

# A new keyring at the same path must rebuild this package, not come back
# stale from sstate.
do_install[file-checksums] += "${RAUC_KEYRING_FILE}:True"

do_install() {
    install -d ${D}${sysconfdir}/rauc
    install -m 0644 ${WORKDIR}/${ATC_RAUC_SYSTEM_CONF} ${D}${sysconfdir}/rauc/system.conf
    install -m 0644 ${RAUC_KEYRING_FILE} ${D}${sysconfdir}/rauc/keyring.pem
}

# One compatible string per Tegra MACHINE. An Orin NX and an Orin Nano rootfs
# carry different device trees and firmware, so RAUC must refuse a bundle for the
# other board. atc-bundle.bb sets the same `atc-${MACHINE}`. A placeholder left
# in the file would make RAUC refuse every bundle, so its survival fails the
# build.
do_install:append:atc-slot-nvbootctrl() {
    sed -i 's/@MACHINE@/${MACHINE}/' ${D}${sysconfdir}/rauc/system.conf
    if grep -q '@MACHINE@' ${D}${sysconfdir}/rauc/system.conf; then
        bbfatal "system.conf still holds @MACHINE@ after the substitution"
    fi
}
