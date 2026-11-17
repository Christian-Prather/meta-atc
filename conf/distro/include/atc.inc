# meta-atc build configuration. Require it from local.conf or from a distro
# conf:
#
#   require conf/distro/include/atc.inc
#
# The `atc` distro feature turns on this layer's changes to recipes of other
# layers (the bbappends). Without this file, adding the layer changes no other
# recipe, as the Yocto Project Compatible rules require.
DISTRO_FEATURES:append = " atc"

# Machine-wide BSP configuration for the Jetson machines. It is global
# configuration, read by every recipe of the build, and not in layer.conf,
# which must not change the build. An image recipe is the wrong place: the
# UEFI firmware (edk2-firmware-tegra) and the capsule (tegra-uefi-capsules) read
# these values too. Set only in the image, the image would be redundant, while
# the capsule wrote a bootloader without RootfsRedundancyLevel=AB and without
# the retry count below.
#
# The redundant layout: two rootfs partitions, APP and APP_b, each paired with
# one QSPI bootloader chain. Every line is a `:tegra234` override, so a qemu
# build gets nothing from it.
#
# ATC_TEGRA_REDUNDANT is the only opt-out. An override-qualified value wins
# over the plain variable whatever their order and strength, so a plain
# `USE_REDUNDANT_FLASH_LAYOUT_DEFAULT = "0"` in a build configuration loses to
# the line below and changes nothing. `ATC_TEGRA_REDUNDANT = "0"` builds
# meta-tegra's single-APP layout: atc-image builds, and atc-image-ab and
# atc-bundle are skipped with the reason, because the nvbootctrl backend needs
# APP_b.
ATC_TEGRA_REDUNDANT ??= "1"
USE_REDUNDANT_FLASH_LAYOUT_DEFAULT:tegra234 = "${ATC_TEGRA_REDUNDANT}"
# One boot per rootfs trial (recipes-bsp/atc-tegra-bootcontrol). It is appended
# after meta-tegra's overlays, so its RootfsRetryCountMax replaces the default.
TEGRA_BOOTCONTROL_OVERLAYS:append:tegra234 = "${@' L4TConfiguration-AtcRootfsRetryCountMax.dtbo' if bb.utils.to_boolean(d.getVar('USE_REDUNDANT_FLASH_LAYOUT')) else ''}"

# The RAUC version. atcd drives RAUC to install and confirm a slot, so this
# layer picks the version, not meta-rauc's default. meta-rauc at the commit
# conf/layers.pin names carries this version and a git recipe. rauc-native
# signs the bundles on the build host, and nativesdk-rauc signs them from an
# SDK, so both get the same version as the device's RAUC. A missed
# PREFERRED_VERSION falls back to the git recipe, so
# recipes-core/rauc/rauc-version-atc.inc skips every other version of the
# three recipes.
ATC_RAUC_VERSION = "1.15.2"
PREFERRED_VERSION_rauc = "${ATC_RAUC_VERSION}"
PREFERRED_VERSION_rauc-native = "${ATC_RAUC_VERSION}"
PREFERRED_VERSION_nativesdk-rauc = "${ATC_RAUC_VERSION}"
