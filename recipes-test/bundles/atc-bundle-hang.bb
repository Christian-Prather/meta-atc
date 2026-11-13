# A FAULT BUNDLE for scripts/qemu-rauc-faults.sh. Never ship it.
#
# atc-bundle with the hang image in its rootfs slot. It is signed and
# compatible, so RAUC installs it. The trial boot then stops feeding the
# watchdog.
require recipes-core/bundles/atc-bundle.bb

FILESEXTRAPATHS:prepend := "${THISDIR}/../../recipes-core/bundles/files:"

SUMMARY = "Fault bundle: a slot that stops feeding the watchdog"

RAUC_SLOT_rootfs = "atc-image-slot-hang"
