# The A/B runtime profile: what lets a slot start atcd and take an OS update.
#
# atc-image-ab.bb (the factory disk) and atc-image-slot.bb (the update) both
# require this file. A slot that lacks any line here boots and then cannot
# confirm, so every update to it reverts.
#
# atcd.service is NOT here. `atc bootstrap atcd install` renders it per device,
# so the bundle's post-install hook copies it into the new slot instead.

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

# Users atc and atc-hooks with FIXED ids, in both slots.
#
# The store on /var/atc survives a slot switch, and its files carry numeric
# owners. Two slots that allocated the ids in a different order would hand the
# store to the wrong user after an update. `atc bootstrap` creates these users
# only when they do not exist, so it adopts these.
#
# `:prepend`, and the order matters. atc-image.bb runs `groupadd -f atc` for the
# deploy user's group. That line must find the group already created here, with
# the fixed id, or the group gets the next free id instead.
ATC_GID ?= "2000"
ATC_UID ?= "2000"
ATC_HOOKS_UID ?= "2001"
EXTRA_USERS_PARAMS:prepend = "\
    groupadd -g ${ATC_GID} atc; \
    useradd --system -u ${ATC_UID} -g atc --home-dir /var/atc --no-create-home --shell /usr/sbin/nologin atc; \
    useradd --system -u ${ATC_HOOKS_UID} -g atc -G atc --create-home --home-dir /var/lib/atc-hooks --shell /usr/sbin/nologin atc-hooks; \
    "

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
atc_install_fstab_entries:atc-slot-grub() {
    cat >> ${IMAGE_ROOTFS}${sysconfdir}/fstab << EOF
PARTLABEL=atcesp   /boot     vfat  defaults  0  2
PARTLABEL=atcdata  /var/atc  ext4  defaults  0  2
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

ROOTFS_POSTPROCESS_COMMAND += "atc_install_fstab_entries"

# The empty ext4 the factory flash writes to UDA (recipes-bsp/atc-tegra-uda).
# DATAFILE is its name inside the tegraflash archive, and it does not end in
# .ext4: the archive's one .ext4 member is the rootfs, which the farm flash host
# reads. A task flag takes no override; on a backend that builds no tegraflash
# image, do_image_tegraflash does not run.
DATAFILE:atc-slot-nvbootctrl = "atc-uda.img"
IMAGE_TEGRAFLASH_DATA:atc-slot-nvbootctrl = "${DEPLOY_DIR_IMAGE}/atc-uda.ext4"
do_image_tegraflash[depends] += "${@'atc-tegra-uda:do_deploy' if d.getVar('ATC_SLOT_BACKEND') == 'nvbootctrl' else ''}"
