# The machine to slot backend map, and nothing else.
#
#   none        every machine not named below. atcd and atc-image build, but
#               the machine has no A/B update path: every recipe that
#               inherits atc-slot-backend is skipped, and this layer leaves
#               the rauc and rauc-conf recipes of other layers as they are.
#   grub        qemux86-64. grub.cfg counts one trial, RAUC writes grubenv.
#   nvbootctrl  tegra234. NVIDIA's launcher counts the boot, and RAUC's custom
#               backend drives it through nvbootctrl.
#
# atc-slot-backend inherits this class. So does each bbappend that changes a
# recipe of another layer only on a machine with a backend. That bbappend
# must not inherit atc-slot-backend itself: the class makes the package
# machine-specific, and on `none` the recipe must stay as its layer wrote it.
#
# A product BSP with its own A/B layout keeps `none`, and with it keeps its
# own RAUC configuration. A third backend adds one value here.
ATC_SLOT_BACKEND ??= "none"
ATC_SLOT_BACKEND:qemux86-64 ??= "grub"
ATC_SLOT_BACKEND:tegra234 ??= "nvbootctrl"
