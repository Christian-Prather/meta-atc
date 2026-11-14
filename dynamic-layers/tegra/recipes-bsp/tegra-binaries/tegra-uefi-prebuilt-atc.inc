# The prebuilt UEFI's deploy waits for meta-atc's retry-count overlay, the same
# dependency as the edk2-firmware-tegra append. A build that sets
# PREFERRED_PROVIDER_virtual/bootloader = "tegra-uefi-prebuilt" deploys the UEFI
# from this recipe, and the tegraflash image and the capsule then read the
# overlay after this deploy.
do_deploy[depends] += "${@'atc-tegra-bootcontrol:do_deploy' if bb.utils.to_boolean(d.getVar('USE_REDUNDANT_FLASH_LAYOUT')) else ''}"
