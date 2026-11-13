# A FAULT IMAGE for scripts/qemu-rauc-faults.sh. Never ship it.
#
# atc-image-slot with an /sbin/init that exits at once. The kernel then panics
# ("Attempted to kill init"), and `panic=5` on the GRUB command line reboots
# it. That is a panic in early userspace: the trial boot never reaches a mark,
# so GRUB finds the trial spent and boots the last confirmed slot.
require recipes-core/images/atc-image-slot.bb

SUMMARY = "Fault image: an atc slot whose init exits, so the kernel panics"
DESCRIPTION = "atc-image-slot with /sbin/init replaced by a script that exits \
1. The qemu fault suite installs it to prove that a kernel panic in a trial \
slot reverts to the last confirmed slot."

atc_fault_init_exits() {
    rm -f ${IMAGE_ROOTFS}${base_sbindir}/init
    printf '#!/bin/sh\necho "atc-fault-panic: init exits"\nexit 1\n' \
        > ${IMAGE_ROOTFS}${base_sbindir}/init
    chmod 0755 ${IMAGE_ROOTFS}${base_sbindir}/init
}

ROOTFS_POSTPROCESS_COMMAND += "atc_fault_init_exits"
