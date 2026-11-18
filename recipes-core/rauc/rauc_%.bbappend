# The atc changes to this recipe, with the atc distro feature only
# (conf/distro/include/atc.inc), and only on a machine with an A/B slot
# backend. They exist for atcd's update path: the D-Bus policy lets user atc
# call RAUC, and only atcd marks a slot good. On `none` a product's RAUC keeps
# its stock policy and its rauc-mark-good.
inherit ${@bb.utils.contains('DISTRO_FEATURES', 'atc', 'atc-slot-backend-map', '', d)}
require ${@'rauc-atc.inc' if (d.getVar('ATC_SLOT_BACKEND') or 'none') != 'none' else ''}
