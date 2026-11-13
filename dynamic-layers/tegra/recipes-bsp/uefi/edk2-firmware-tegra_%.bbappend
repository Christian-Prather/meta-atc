# The UEFI deploy waits for meta-atc's retry-count overlay, as meta-tegra makes
# it wait for l4t-launcher-rootfs-ab-config. The tegraflash image and
# tegra-uefi-capsules depend on virtual/bootloader:do_deploy, so the overlay is
# in DEPLOY_DIR_IMAGE before either reads TEGRA_BOOTCONTROL_OVERLAYS. The
# overlay is in that list only for the redundant layout (conf/layer.conf).
do_deploy[depends] += "${@'atc-tegra-bootcontrol:do_deploy' if bb.utils.to_boolean(d.getVar('USE_REDUNDANT_FLASH_LAYOUT')) else ''}"
