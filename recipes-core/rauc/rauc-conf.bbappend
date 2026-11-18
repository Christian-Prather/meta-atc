# The atc changes to this recipe, with the atc distro feature only
# (conf/distro/include/atc.inc), and only on a machine with an A/B slot
# backend. On `none` the recipe stays as meta-rauc and the product wrote it:
# its system.conf, its keyring, and its package architecture.
inherit ${@bb.utils.contains('DISTRO_FEATURES', 'atc', 'atc-slot-backend-map', '', d)}
require ${@'rauc-conf-atc.inc' if (d.getVar('ATC_SLOT_BACKEND') or 'none') != 'none' else ''}
