# A FAULT IMAGE for scripts/qemu-rauc-faults.sh. Never ship it.
#
# atc-image-slot with one more unit, which stops the watchdog feeder. The
# runtime profile makes systemd (PID 1) the feeder of the i6300esb watchdog,
# and systemd holds /dev/watchdog0 open, so no second process can open it. The
# unit therefore sends SIGSEGV to PID 1. systemd's crash handler freezes PID 1,
# nothing feeds the watchdog, and the watchdog resets the guest. GRUB then
# finds the trial spent and boots the last confirmed slot.
#
# AN APPROXIMATION. The kernel does not hang: only the feeder stops. A real
# kernel hang also stops the feeder, so the reset path is the same and only the
# cause differs.
require recipes-core/images/atc-image-slot.bb

SUMMARY = "Fault image: an atc slot that stops feeding the watchdog"
DESCRIPTION = "atc-image-slot with a unit that freezes systemd, the watchdog \
feeder. The qemu fault suite installs it to prove that the i6300esb watchdog \
resets a hung trial slot and that GRUB then reverts it."

atc_fault_hang_unit() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/multi-user.target.wants
    printf '%s\n' \
        '[Unit]' \
        'Description=atc fault suite: freeze PID 1, the watchdog feeder' \
        '[Service]' \
        'Type=oneshot' \
        "ExecStart=/bin/sh -c 'echo atc-fault-hang: freezing PID 1 > /dev/console; kill -SEGV 1'" \
        > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/atc-fault-hang.service
    ln -sf ../atc-fault-hang.service \
        ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/multi-user.target.wants/atc-fault-hang.service
}

ROOTFS_POSTPROCESS_COMMAND += "atc_fault_hang_unit"
