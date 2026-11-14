# Build `echo`, `reboot` and `regexp` into the GRUB EFI binary.
#
# `regexp` takes the disk name out of the ESP's device name, and grub.cfg
# finds each slot by its partition number on that disk.
#
# `reboot` is the revert path for a slot that cannot load. atc-ab-grub.cfg runs
# it after a failed `linux` or `boot`. Without the module, an empty rootfs
# stops at a GRUB prompt, the spent trial is never read, and nothing reverts.
#
# THE CONFIG'S MESSAGES ARE THE DEMONSTRATION, and without this module they do
# not exist. atc-ab-grub.cfg announces a trial boot and a revert with `echo`,
# and poky's default GRUB_BUILDIN does not carry that command. GRUB then runs
# the whole slot state machine correctly and answers every `echo` with:
#
#   error: can't find command `echo'.
#
# So the slot flips, the count is spent, the revert happens, and the operator
# watching the console sees none of it.
#
# THAT ERROR WAS ITSELF INVISIBLE, which is why this took a second boot to find.
# OVMF sends its own DEBUG output to the serial port but puts ConOut on the
# graphics adapter, and GRUB writes to ConOut. With a VGA device present the
# error went to a console nobody was watching, and the symptom was a GRUB that
# printed nothing at all rather than a GRUB reporting a missing command. Booting
# with `-vga none` leaves OVMF no graphics adapter, ConOut falls back to serial,
# and the error appears. scripts/qemu-rauc-proof.sh passes that flag
# for the same reason.
#
# `test` is NOT added here, though the config leans on it just as hard. It is
# already built in: the slot comparisons worked on the image that could not
# echo, which is the whole reason the failure was silent.
GRUB_BUILDIN:append = " echo reboot regexp"
