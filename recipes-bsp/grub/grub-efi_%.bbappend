# The atc changes to this recipe, with the atc distro feature only
# (conf/distro/include/atc.inc), and only on the GRUB slot backend, whose
# grub.cfg needs the extra built-ins.
inherit ${@bb.utils.contains('DISTRO_FEATURES', 'atc', 'atc-slot-backend-map', '', d)}
require ${@'grub-efi-atc.inc' if d.getVar('ATC_SLOT_BACKEND') == 'grub' else ''}
