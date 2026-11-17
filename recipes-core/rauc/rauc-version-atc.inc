# Only ATC_RAUC_VERSION (conf/distro/include/atc.inc) of this recipe builds.
#
# PREFERRED_VERSION alone fails open. When no recipe has PV equal to the
# preferred version, BitBake logs a note and selects another recipe, here
# meta-rauc's git recipe (PV 1.15.1+git at the pinned commit). The build then
# continues on a RAUC that this layer did not choose.
#
# So every other version is skipped. When no recipe of the pinned version
# exists, a build that needs it stops with "Nothing PROVIDES" and this reason.
# A bbfatal would be wrong here: BitBake parses the git recipe in every build,
# also when it does not select it, so every atc build would stop.
#
# rauc, rauc-native and nativesdk-rauc each require this file, because
# meta-rauc ships each one as a separate recipe, not as a class extension.
python () {
    pv = d.getVar('PV')
    want = d.getVar('ATC_RAUC_VERSION')
    if pv != want:
        raise bb.parse.SkipRecipe("%s is version %s, and the atc distro pins "
                                  "ATC_RAUC_VERSION = \"%s\"" % (d.getVar('PN'), pv, want))
}
