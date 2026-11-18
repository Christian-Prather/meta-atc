# The A/B slot backend: what counts a boot, what records a confirm, and what
# the factory flashes. Everything above it (the bundle, the store, atcd, the
# trial deadline, the pre-install guard) is the same on every machine.
# atc-slot-backend-map.bbclass maps each machine to its backend: `grub`,
# `nvbootctrl`, or `none`.
#
# A recipe that differs by backend inherits this class and keys the difference
# on `atc-slot-grub` or `atc-slot-nvbootctrl`, never on a machine name. An
# override from a class reaches only the recipes that inherit it, so each
# bbappend that differs by backend inherits it too. A third backend adds one
# value to the map and one variant per recipe. It edits no existing branch.
#
inherit atc-slot-backend-map
OVERRIDES .= ":atc-slot-${ATC_SLOT_BACKEND}"

# Every recipe that inherits this class differs by backend, so on `none` it
# has nothing to build. It is skipped with the reason, not failed: bitbake
# parses every recipe of the layer, and atc-image builds on that machine.
python () {
    if d.getVar('ATC_SLOT_BACKEND') == 'none':
        raise bb.parse.SkipRecipe(
            "MACHINE '%s' has no A/B slot backend (ATC_SLOT_BACKEND is 'none'), "
            "so it has no atc A/B update path. atc-image and atcd still build. "
            "atc-slot-backend-map.bbclass lists the machines with a backend"
            % d.getVar('MACHINE'))
}

# The backend is a property of the machine, so whatever a recipe builds on it
# is too. Two machines of one tune can have two backends (qemuarm64 and an
# Orin are both aarch64). A package per tune would then carry one machine's
# system.conf or trial predicate under the other machine's name, and sstate
# would hand it to the wrong build.
PACKAGE_ARCH = "${MACHINE_ARCH}"
