# A FAULT BUNDLE for scripts/qemu-rauc-faults.sh. Never ship it.
#
# atc-bundle with a `compatible` string that system.conf does not name. It is
# signed under the trusted CA, so only the compatible check can refuse it. RAUC
# must refuse it, and the slots must not change.
require recipes-core/bundles/atc-bundle.bb

FILESEXTRAPATHS:prepend := "${THISDIR}/../../recipes-core/bundles/files:"

SUMMARY = "Fault bundle: a compatible string the device does not accept"

RAUC_BUNDLE_COMPATIBLE = "atc-other"
