# The atc changes to this recipe, with the atc distro feature only
# (conf/distro/include/atc.inc).
require ${@bb.utils.contains('DISTRO_FEATURES', 'atc', 'grub-efi-atc.inc', '', d)}
