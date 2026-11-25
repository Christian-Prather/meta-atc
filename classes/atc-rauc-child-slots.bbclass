# The ATC_RAUC_CHILD_SLOTS opt-in, and nothing else.
#
# A lab layout for the nvbootctrl backend. It reproduces a RAUC setup where
# each rootfs slot has two child slots and the RAUC status survives a slot
# switch:
#
#   - system.conf adds kernel.0/kernel.1 and dtb.0/dtb.1, with
#     parent=rootfs.0/rootfs.1, on the NVMe partitions A_kernel, B_kernel,
#     A_kernel-dtb and B_kernel-dtb;
#   - atc-bundle writes the kernel boot image and the kernel DTB of the same
#     build into them, the files that tegraflash writes there;
#   - UDA mounts on /data, /data/atc binds onto /var/atc, and RAUC keeps its
#     central status in /data/rauc, outside the store.
#
# Set it in local.conf or auto.conf:
#
#   ATC_RAUC_CHILD_SLOTS = "1"
#
# Unset, empty or "0", it changes nothing: no override is added, and no task
# reads the variable. Any other value, or "1" on a backend other than
# nvbootctrl, skips the recipe with the reason.
#
# A recipe keys each difference on the `atc-rauc-child-slots` override. The
# override comes after `atc-slot-<backend>` in OVERRIDES, so its value wins
# over the backend's value of the same variable.
inherit atc-slot-backend-map

ATC_RAUC_CHILD_SLOTS ??= ""

OVERRIDES .= "${@':atc-rauc-child-slots' if d.getVar('ATC_RAUC_CHILD_SLOTS') == '1' else ''}"

python () {
    value = d.getVar('ATC_RAUC_CHILD_SLOTS') or ''
    if value not in ('', '0', '1'):
        raise bb.parse.SkipRecipe(
            "ATC_RAUC_CHILD_SLOTS is '%s'. Set it to \"1\" to turn the "
            "child-slot layout on, or leave it unset" % value)
    if value == '1' and d.getVar('ATC_SLOT_BACKEND') != 'nvbootctrl':
        raise bb.parse.SkipRecipe(
            "ATC_RAUC_CHILD_SLOTS = \"1\" is for the nvbootctrl backend only "
            "(a tegra234 machine), and MACHINE '%s' has the '%s' backend. "
            "Remove the setting from the build configuration"
            % (d.getVar('MACHINE'), d.getVar('ATC_SLOT_BACKEND')))
}
