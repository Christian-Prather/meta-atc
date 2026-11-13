# A FAULT BUNDLE for scripts/qemu-rauc-faults.sh. Never ship it.
#
# atc-bundle with an EMPTY ext4 filesystem in its rootfs slot. It is signed and
# compatible, so RAUC installs it. GRUB then finds no kernel in the slot, its
# `linux` command fails, and grub.cfg reboots. The next boot finds the trial
# spent and boots the last confirmed slot.
require recipes-core/bundles/atc-bundle.bb

FILESEXTRAPATHS:prepend := "${THISDIR}/../../recipes-core/bundles/files:"

SUMMARY = "Fault bundle: an empty ext4 slot with no kernel"

DEPENDS += "e2fsprogs-native"

# Not an image recipe: the `file` flag names a filesystem this recipe makes in
# WORKDIR, and the `depends` flag replaces the class's dependency on an image.
RAUC_SLOT_rootfs = "atc-empty-rootfs"
RAUC_SLOT_rootfs[file] = "atc-empty-rootfs.ext4"
RAUC_SLOT_rootfs[depends] = "e2fsprogs-native:do_populate_sysroot"

# No post-install hook. The hook carries device state into the new slot's
# /etc. On an empty filesystem it fails or passes depending on what the running
# slot holds: without sshd host keys to carry, nothing creates /etc and the
# merge of /etc/subuid fails. The case needs the slot written whatever the
# running slot holds, so that GRUB meets a slot with no kernel.
unset RAUC_SLOT_rootfs[hooks]

do_atc_empty_rootfs() {
    rm -f ${WORKDIR}/atc-empty-rootfs.ext4
    mke2fs -t ext4 -q -F ${WORKDIR}/atc-empty-rootfs.ext4 64M
}

addtask atc_empty_rootfs after do_prepare_recipe_sysroot before do_configure
