# The A/B runtime profile: what lets a slot start atcd and take an OS update.
#
# atc-image-ab.bb (the factory disk) and atc-image-slot.bb (the update) both
# require this file. A slot that lacks any line here boots and then cannot
# confirm, so every update to it reverts.
#
# atcd.service and the atc and atc-hooks users come from the atcd package,
# which atc-image.bb installs, so both slots carry the same ones.

# The slot backend decides what writes the boot state. A line that differs by
# backend carries `:atc-slot-grub` or `:atc-slot-nvbootctrl`.
inherit atc-slot-backend

# RAUC with its system.conf, the keyring and the D-Bus policy (rauc-conf and
# rauc bbappends). atc-os carries the reboot path unit, the trial deadline
# timer, the pre-install guard and the watchdog drop-in.
IMAGE_INSTALL += "rauc rauc-conf atc-os"

# grub-editenv is how RAUC's GRUB backend writes the boot environment. meta-rauc
# adds it only when virtual/bootloader is GRUB, which an EFI qemu machine does
# not set.
IMAGE_INSTALL:append:atc-slot-grub = " grub-editenv"

# atc-nvbootctrl carries RAUC's custom backend, the boot unit and this
# backend's atc-slot-trial. The image cannot install a bundle without it.
# atc-tegra-capsule stages and arms the bundle's UEFI capsule. The bundle hook
# fails an install that carries a capsule when the tool is missing.
IMAGE_INSTALL:append:atc-slot-nvbootctrl = " atc-nvbootctrl atc-tegra-capsule"

# An A/B image without the keyring or the rauc distro feature builds and then
# cannot install anything: rauc-conf is skipped, and the kernel lacks
# dm-verity. So the image is skipped too, with the reason. Skipped, not fatal,
# because bitbake parses this file for every build of the layer, atc-image
# included.
python () {
    keyring = d.getVar('RAUC_KEYRING_FILE') or ''
    if not keyring.startswith('/'):
        raise bb.parse.SkipRecipe("RAUC_KEYRING_FILE must be an absolute path "
                                  "to the CA that signs this image's bundles")
    if 'rauc' not in (d.getVar('DISTRO_FEATURES') or '').split():
        raise bb.parse.SkipRecipe("DISTRO_FEATURES must contain 'rauc', or the "
                                  "kernel cannot install a verity bundle")
    # system-nvbootctrl.conf names APP_b, which only the redundant layout has.
    # A single-APP image would flash, boot, and fail its first install.
    if d.getVar('ATC_SLOT_BACKEND') == 'nvbootctrl' and \
            d.getVar('USE_REDUNDANT_FLASH_LAYOUT') != '1':
        raise bb.parse.SkipRecipe("the nvbootctrl A/B image needs the redundant "
                                  "flash layout, and USE_REDUNDANT_FLASH_LAYOUT is "
                                  "'%s'. Remove ATC_TEGRA_REDUNDANT = \"0\" from "
                                  "the build configuration"
                                  % (d.getVar('USE_REDUNDANT_FLASH_LAYOUT') or ''))
}

# EVERY non-root mount, by PARTLABEL, written here and nowhere else.
#
# The mounts belong to the partition table, so they differ by backend. The
# default adds none, so no mount waits on a partition the table does not have.
atc_install_fstab_entries() {
    bbnote "ATC_SLOT_BACKEND=${ATC_SLOT_BACKEND} adds no mounts to /etc/fstab"
}

# The GRUB backend, from atc-ab.wks.in. The wks gives its parts no
# mountpoints, because wic would then write its own fstab lines naming /dev/sdaN
# on a virtio disk (see atc-ab.wks.in). The slot
# image is built without wic at all. So this function is the single owner of
# /etc/fstab's additions, and it addresses partitions the same way the kernel
# command line and grub.cfg do.
#
# /var/atc is a separate partition so the store survives a slot switch. The
# directory is NOT created in the rootfs: atc-image.bb fails the build if any
# recipe adds it, and systemd creates a missing mount point itself.
#
# The ESP on /boot is where RAUC's `grubenv=/boot/atc/grubenv` points. An
# unmounted ESP leaves RAUC unable to read or mark any slot.
#
# nofail on both, for the reason the nvbootctrl branch below gives: both slots
# share each partition, so a revert does not help, and emergency mode has no
# network. A store that cannot mount gives a board without its store: the atcd
# drop-in (10-atc-store.conf) holds atcd off the empty mount point, and an
# operator can still reach the board over ssh.
#
# The ESP is nofail too. Emergency mode loses every slot and the network. A
# boot without the ESP loses only the boot state: the RAUC drop-in
# (10-atc-boot.conf) holds rauc.service off the empty mount point, so atcd
# cannot mark a slot and the trial deadline cannot read one, and each says so
# in the journal. GRUB reads the ESP itself before Linux starts, so the next
# reboot, from an operator or the watchdog, still reverts a trial that nothing
# marked good.
#
# The device timeout keeps the wait for a missing partition short.
atc_install_fstab_entries:atc-slot-grub() {
    cat >> ${IMAGE_ROOTFS}${sysconfdir}/fstab << EOF
PARTLABEL=atcesp   /boot     vfat  defaults,nofail,x-systemd.device-timeout=30s  0  2
PARTLABEL=atcdata  /var/atc  ext4  defaults,nofail,x-systemd.device-timeout=30s  0  2
EOF
}

# The nvbootctrl backend, from NVIDIA's redundant NVMe layout. UDA, the user
# data partition, is outside APP and APP_b, so the store survives a slot
# switch. The tegra-storage-layout-base append in dynamic-layers/tegra grows
# UDA to 4 GiB and names DATAFILE as its file. DATAFILE below is an empty ext4
# (atc-uda.ext4 in the deploy directory), so every factory flash writes a fresh
# store filesystem.
# systemd grows it to the partition at the first boot (x-systemd.growfs).
#
# No x-systemd.makefs. Every factory flash writes a fresh filesystem, so a
# UDA with none is damaged or wiped. An empty store made there would hide that,
# and the board would come up with no enrollment as if it were new. Without
# makefs the mount fails, nofail lets the board boot, and a reflash restores
# UDA.
#
# nofail: a UDA that cannot mount does not stop the boot in emergency mode.
# Both slots share UDA, so a revert would not help, and emergency mode has no
# network. With nofail the board boots without its store: atcd finds no
# enrollment and does not start, and an operator can still reach it over ssh.
# The device timeout keeps the wait for a missing partition short.
#
# The ESP is not here. meta-tegra's setup-nv-boot-control ships boot-efi.mount,
# which mounts PARTLABEL=esp on /boot/efi, where the capsule goes. A second
# definition in fstab would replace that unit.
atc_install_fstab_entries:atc-slot-nvbootctrl() {
    cat >> ${IMAGE_ROOTFS}${sysconfdir}/fstab << EOF
PARTLABEL=UDA  /var/atc  ext4  defaults,nofail,x-systemd.device-timeout=30s,x-systemd.growfs  0  2
EOF
}

# The lab opt-in ATC_RAUC_CHILD_SLOTS (atc-rauc-child-slots.bbclass), on the
# nvbootctrl backend only. The override comes after atc-slot-nvbootctrl in
# OVERRIDES, so this variant replaces the one above.
#
# RAUC keeps its central status on UDA, so the status survives a slot switch.
# It cannot go under /var/atc: atcd owns every name at the store root, and
# the store seed gives the whole tree to user atc. So UDA mounts on /data, the
# store is its directory atc/, which binds onto /var/atc, and RAUC's data
# directory is /data/rauc. atc-tegra-uda makes atc/ in the factory filesystem,
# because a bind mount needs its source before tmpfiles runs. atc-os makes
# /data/rauc with tmpfiles, and holds rauc.service until /data is mounted.
#
# Both mounts are nofail, for the reason the variant above gives. When UDA
# cannot mount, the bind fails with it, and atcd and rauc.service wait on
# their mounts.
atc_install_fstab_entries:atc-rauc-child-slots() {
    cat >> ${IMAGE_ROOTFS}${sysconfdir}/fstab << EOF
PARTLABEL=UDA  /data  ext4  defaults,nofail,x-systemd.device-timeout=30s,x-systemd.growfs  0  2
/data/atc  /var/atc  none  bind,nofail,x-systemd.requires-mounts-for=/data  0  0
EOF
}

ROOTFS_POSTPROCESS_COMMAND += "atc_install_fstab_entries"

# The empty ext4 the factory flash writes to UDA (recipes-bsp/atc-tegra-uda).
# DATAFILE is its name inside the tegraflash archive, and it does not end in
# .ext4: the archive's one .ext4 member is the rootfs, which flash tooling
# reads. A task flag takes no override; on a backend that builds no tegraflash
# image, do_image_tegraflash does not run.
DATAFILE:atc-slot-nvbootctrl = "atc-uda.img"
IMAGE_TEGRAFLASH_DATA:atc-slot-nvbootctrl = "${DEPLOY_DIR_IMAGE}/atc-uda.ext4"
do_image_tegraflash[depends] += "${@'atc-tegra-uda:do_deploy' if d.getVar('ATC_SLOT_BACKEND') == 'nvbootctrl' else ''}"
