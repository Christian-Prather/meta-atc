# The A/B slot backend: what counts a boot, what records a confirm, and what
# the factory flashes. Everything above it (the bundle, the store, atcd, the
# trial deadline, the pre-install guard) is the same on every machine.
#
#   grub        qemux86-64. grub.cfg counts one trial, RAUC writes grubenv.
#   nvbootctrl  tegra234. NVIDIA's launcher counts the boot, and RAUC's custom
#               backend drives it through nvbootctrl.
#
# A recipe that differs by backend inherits this class and keys the difference
# on `atc-slot-grub` or `atc-slot-nvbootctrl`, never on a machine name. An
# override from a class reaches only the recipes that inherit it, so each
# bbappend that differs by backend inherits it too. A third backend adds one
# value here and one variant per recipe. It edits no existing branch.
#
ATC_SLOT_BACKEND ??= "grub"
ATC_SLOT_BACKEND:tegra234 ??= "nvbootctrl"
OVERRIDES .= ":atc-slot-${ATC_SLOT_BACKEND}"

# The backend is a property of the machine, so whatever a recipe builds on it
# is too. Two machines of one tune can have two backends (qemuarm64 and an
# Orin are both aarch64). A package per tune would then carry one machine's
# system.conf or trial predicate under the other machine's name, and sstate
# would hand it to the wrong build.
PACKAGE_ARCH = "${MACHINE_ARCH}"
