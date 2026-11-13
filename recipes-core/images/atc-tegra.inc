# Image settings that every Tegra image of this layer shares.
#
# atc-image.bb requires this file, so every image recipe of the layer reads it.
# EVERY line carries a `:tegra234` override, and
# scripts/check-meta-atc-recipe.sh fails on a line without one. A qemu
# image therefore gets nothing from this file. `:atc-slot-nvbootctrl` is not
# enough: atc-image.bb does not inherit atc-slot-backend, so that override
# never applies here.
#
# meta-atc defines no Orin machine. It builds on meta-tegra's machines as they
# are (jetson-orin-nano-devkit-nvme for the farm board), whose tegra234.inc puts
# `tegra234` into MACHINEOVERRIDES. One code path covers Nano, NX and AGX.

# The factory artifact is NVIDIA's flash package, not a disk image. tegraflash
# builds the ext4 rootfs it wraps. The flash layout is NVIDIA's redundant one,
# with two rootfs partitions, APP and APP_b. That choice is machine-wide, so it
# is in conf/layer.conf, not here: the UEFI firmware and the capsule read it too.
IMAGE_FSTYPES:tegra234 = "tegraflash"

# A tar archive, the meta-tegra default, named here so the artifact name is a
# decision of this layer: atc-image-<machine>.rootfs.tegraflash.tar.gz.
TEGRAFLASH_PACKAGE_FORMAT:tegra234 = "tar"

# The tool that reads and orders the UEFI boot entries. The ESP is the one boot
# partition without a second copy, and efibootmgr shows whether UEFI has another
# entry to boot when it is lost.
IMAGE_INSTALL:append:tegra234 = " efibootmgr"

# /var/tmp on the rootfs. atc-image.bb holds the function.
ROOTFS_POSTPROCESS_COMMAND:append:tegra234 = " atc_var_tmp_on_disk"
