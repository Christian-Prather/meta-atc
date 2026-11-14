# Reboot 5 seconds after a kernel panic, the same bound as grub.cfg's `panic=5`
# on qemu.
#
# L4TLauncher boots the kernel command line in /boot/extlinux/extlinux.conf,
# which this recipe writes from KERNEL_ARGS. meta-tegra's default for the Orin
# machines carries no `panic=`, so a panic halts the board until someone power
# cycles it. With a reboot, a panic in a trial slot is a warm reset, and the
# launcher counts it against the slot and falls back.
#
# Under dynamic-layers/tegra/, which conf/layer.conf adds to BBFILES only when
# meta-tegra is in the build. A qemu build never parses this file.
KERNEL_ARGS:append = " panic=5"
