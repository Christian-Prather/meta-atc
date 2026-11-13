require atc-image.bb
require atc-ab-runtime.inc

# The factory image of either slot backend. Everything below that names GRUB,
# wic or qemu is the GRUB backend's and carries `:atc-slot-grub`. On
# `atc-slot-nvbootctrl` the factory artifact is the tegraflash archive that
# atc-tegra.inc selects.
inherit atc-slot-backend

SUMMARY = "atc-image on an A/B slot layout, bootable through a real bootloader"
DESCRIPTION = "atc-image written into two rootfs slots on a GPT disk, with GRUB \
and its boot environment on the EFI system partition, RAUC to install into the \
other slot, and the store on a data partition of its own. This is the factory \
disk. atc-image cannot roll back: runqemu boots it with -kernel and never \
reaches a bootloader."

# GRUB reads the kernel out of the SELECTED SLOT, so the kernel has to be in the
# rootfs rather than only on the ESP. A shared kernel on the ESP would leave a
# kernel upgrade un-rollbackable while the rootfs beside it rolled back.
IMAGE_INSTALL += "kernel-image"

# The GRUB config and the environment block are DEPLOYED by atc-grub-env, not
# packaged, and reach the ESP through IMAGE_EFI_BOOT_FILES below.
#
# A task flag takes no override. The line needs none: only the GRUB backend
# builds the wic type, so on another backend do_image_wic does not run.
do_image_wic[depends] += "atc-grub-env:do_deploy"

EFI_PROVIDER:atc-slot-grub = "grub-efi"

IMAGE_FSTYPES:append:atc-slot-grub = " wic"
WKS_FILE:atc-slot-grub = "atc-ab.wks.in"

# Overwrite the grub.cfg that bootimg-efi generates.
#
# The plugin copies IMAGE_EFI_BOOT_FILES into the ESP AFTER it writes its own
# config, so an entry landing on EFI/BOOT/grub.cfg wins. That ordering is the
# whole mechanism, and it is the one thing here that a build can change out from
# under us. check-atc-ab-layout.sh asserts the entry exists; only a real build
# proves it lands. Confirm it after a build with:
#
#   wic ls <image>.wic:1 EFI/BOOT/grub.cfg
#
# and read the first line, which must be this layer's header comment.
#
# The one environment file goes to atc/grubenv. The ESP mounts on /boot, so RAUC
# reaches it as /boot/atc/grubenv, the path system.conf names.
IMAGE_EFI_BOOT_FILES:append:atc-slot-grub = " \
    atc-grub-env/grub.cfg;EFI/BOOT/grub.cfg \
    atc-grub-env/grubenv;atc/grubenv \
    "

# ── Booting it under qemu ────────────────────────────────────────────────────
#
# runqemu passes -kernel by default, which is exactly what makes atc-image
# unable to demonstrate A/B: the firmware and the on-disk bootloader are both
# skipped. Suppressing it is NOT a command-line choice. runqemu's check_kernel()
# only leaves self.kernel empty when QB_DEFAULT_KERNEL is the literal string
# "none", so the image has to say so here. Adding `ovmf` to the command line
# without this still boots a kernel straight off the host filesystem, and the
# proof would silently be the old one.
QB_DEFAULT_KERNEL:atc-slot-grub = "none"
QB_DEFAULT_FSTYPE:atc-slot-grub = "wic"
QB_FSINFO:atc-slot-grub = "wic:no-kernel-in-fs"

# The guest needs its disk writable: the bootloader records the trial boot
# before it boots, so a read-only disk turns the rollback counter into a no-op.
QB_DRIVE_TYPE:atc-slot-grub = "/dev/vda"
