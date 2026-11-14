# The atc changes to this recipe, with the atc distro feature only
# (conf/distro/include/atc.inc).
require ${@bb.utils.contains('DISTRO_FEATURES', 'atc', 'tegra-flashtools-native-atc.inc', '', d)}
