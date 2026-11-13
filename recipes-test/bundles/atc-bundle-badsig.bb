# A FAULT BUNDLE for scripts/qemu-rauc-faults.sh. Never ship it.
#
# atc-bundle signed under a CA that the image keyring does NOT trust. RAUC must
# refuse it, and the slots must not change. rauc-test-keys.sh writes the
# untrusted key, and qemu-rauc-proof.sh names it in local.conf.
require recipes-core/bundles/atc-bundle.bb

FILESEXTRAPATHS:prepend := "${THISDIR}/../../recipes-core/bundles/files:"

SUMMARY = "Fault bundle: signed under an untrusted CA"

ATC_RAUC_UNTRUSTED_KEY_FILE ??= ""
ATC_RAUC_UNTRUSTED_CERT_FILE ??= ""
RAUC_KEY_FILE = "${ATC_RAUC_UNTRUSTED_KEY_FILE}"
RAUC_CERT_FILE = "${ATC_RAUC_UNTRUSTED_CERT_FILE}"

python () {
    if not d.getVar('ATC_RAUC_UNTRUSTED_KEY_FILE') or not d.getVar('ATC_RAUC_UNTRUSTED_CERT_FILE'):
        raise bb.parse.SkipRecipe(
            "ATC_RAUC_UNTRUSTED_KEY_FILE and ATC_RAUC_UNTRUSTED_CERT_FILE must "
            "name the untrusted test key, set in local.conf. "
            "cloud/yocto-builder/rauc-test-keys.sh writes it.")
}
