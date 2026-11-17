# The i6300esb watchdog driver, built in, for the qemu A/B images.
#
# The runtime profile sets RuntimeWatchdogSec=30s. systemd needs a watchdog
# device to feed, and qemu gives the guest an i6300esb. poky's qemux86-64
# kernel does not build that driver, so without this fragment the drop-in arms
# nothing and a hung trial slot never resets. Built in, not a module: a module
# that no package pulls in never loads.
#
# qemux86-64 only, both lines. Another machine that builds linux-yocto gets
# the stock kernel recipe, with no change to its signature.
FILESEXTRAPATHS:prepend:qemux86-64 := "${THISDIR}/files:"

SRC_URI:append:qemux86-64 = " file://atc-watchdog.cfg"
