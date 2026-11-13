SUMMARY = "GRUB A/B slot selection for atc, with RAUC as the writer"
DESCRIPTION = "Deploys the A/B grub.cfg and its one environment block for the \
EFI system partition. The config is the bootloader tier: it is the only code \
that can count a boot that never reached userspace. RAUC writes the same \
environment from userspace through grub-editenv."
HOMEPAGE = "https://github.com/Christian-Prather/meta-atc"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://atc-ab-grub.cfg"

S = "${WORKDIR}"

inherit deploy

# The ESP files are consumed by the IMAGE. wic copies them out of
# DEPLOY_DIR_IMAGE through IMAGE_EFI_BOOT_FILES, which atc-image-ab.bb sets, so
# they are deployed rather than packaged into the rootfs.
#
# The GRUB environment block format, and why it is generated here rather than
# with grub-editenv. The block is a fixed 1024 bytes: a header line, then one
# `name=value` line per variable, then `#` padding to the end. grub-editenv
# writes exactly that. Generating it with printf keeps a native grub dependency
# out of this recipe, and it makes the initial state READABLE in a diff. The
# format is stable, and check-atc-ab-layout.sh asserts the size and the header
# so a drifted format cannot ship silently.
GRUB_ENVBLK_SIZE = "1024"
GRUB_ENVBLK_HEADER = "# GRUB Environment Block"

# Write one GRUB environment block. $1 is the destination, the rest are
# `name=value` entries.
#
# A block that would exceed 1024 bytes is a FAILURE, not a truncation. GRUB
# reads a fixed-size block, so a truncated one loses whichever variable fell off
# the end, and the config would then boot on a partially-read environment. That
# is the exact state the config's fail-closed defaults exist to refuse, and it
# must not be reachable by building.
atc_write_envblk() {
    dest="$1"
    shift
    printf '%s\n' "${GRUB_ENVBLK_HEADER}" > "$dest"
    for entry in "$@"; do
        printf '%s\n' "$entry" >> "$dest"
    done

    used=$(wc -c < "$dest")
    if [ "$used" -gt "${GRUB_ENVBLK_SIZE}" ]; then
        bbfatal "GRUB environment block $dest is $used bytes, over the ${GRUB_ENVBLK_SIZE}-byte limit"
    fi

    # awk, and NOT shell arithmetic expansion. bitbake parses every shell
    # function with its own parser to work out task dependencies, and that
    # parser raises NotImplementedError on the arithmetic-expansion token. The
    # recipe then fails at PARSE time, before any task runs, and the traceback
    # names the parser rather than the line. Measured on poky scarthgap
    # 77d1feb3, where it stopped the first build of this layer.
    #
    # `expr` is the other obvious substitute and is wrong here. It exits
    # non-zero when the result is 0, and bitbake runs shell tasks under `set -e`,
    # so a block that needed no padding would fail the task.
    pad=$(awk -v total="${GRUB_ENVBLK_SIZE}" -v used="$used" 'BEGIN { print total - used }')
    if [ "$pad" -gt 0 ]; then
        printf '%*s' "$pad" '' | tr ' ' '#' >> "$dest"
    fi

    final=$(wc -c < "$dest")
    if [ "$final" -ne "${GRUB_ENVBLK_SIZE}" ]; then
        bbfatal "GRUB environment block $dest is $final bytes, expected ${GRUB_ENVBLK_SIZE}"
    fi
}

do_deploy() {
    install -d ${DEPLOYDIR}/atc-grub-env
    install -m 0644 ${WORKDIR}/atc-ab-grub.cfg ${DEPLOYDIR}/atc-grub-env/grub.cfg

    # The initial state: boot slot A, slot A confirmed, no trial in flight.
    #
    # It matches the config's fail-closed defaults on purpose. A first boot that
    # cannot read the environment and a first boot that reads it must reach the
    # same slot. RAUC's backend also needs every one of the first five names:
    # `grub-editenv list` without one of them makes `rauc status` fail.
    atc_write_envblk ${DEPLOYDIR}/atc-grub-env/grubenv \
        "ORDER=A B" "A_OK=1" "A_TRY=0" "B_OK=0" "B_TRY=0" \
        "ATC_STEADY=A" "ATC_TRIAL=none"
}

addtask deploy after do_install before do_build

# The ESP content is deployed, not packaged, so this recipe ships no package.
# The image reaches it through do_image_wic[depends] in atc-image-ab.bb.
do_install[noexec] = "1"

# qemux86-64 ONLY, and the narrowness is the point.
#
# atc-ab-grub.cfg loads `/boot/bzImage`, which is the x86 kernel image name.
# qemuarm64 installs `/boot/Image`, so a MACHINE=qemuarm64 build of
# atc-image-ab used to be ACCEPTED and produced a disk whose bootloader cannot
# find a kernel. The failure surfaces at the GRUB prompt on a guest, not at
# build time, which is the most expensive place to learn it.
#
# The config also selects slots by PARTLABEL and expects an EFI system
# partition, neither of which is portable to a board with its own boot chain.
# A new machine adds its own config and widens this line with it.
COMPATIBLE_MACHINE = "qemux86-64"
