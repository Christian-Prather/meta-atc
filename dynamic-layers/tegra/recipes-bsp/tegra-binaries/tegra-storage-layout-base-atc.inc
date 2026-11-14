# UDA, the user data partition, in the external (NVMe) flash layout: grow it,
# and let the factory flash write it.
#
# atcd's store lives on /var/atc, and it must outlive a slot switch, so it is
# on UDA and not in APP or APP_b. NVIDIA's flash_l4t_t234_nvme.xml and
# flash_l4t_t234_nvme_rootfs_ab.xml (L4T R36.5.2) size UDA at 419430400 bytes,
# 400 MiB, and give it no file. This append:
# - grows UDA to ATC_TEGRA_UDA_SIZE (4 GiB, the qemu figure). A layout whose UDA
#   is already larger keeps its size.
# - names the token DATAFILE as UDA's file. meta-tegra's flash scripts replace
#   it with the image's DATAFILE (atc-uda.ext4, an empty ext4), so every
#   factory flash writes a fresh filesystem to UDA.
#
# The edit is on the installed copy, so no NVIDIA layout file is copied into
# this layer. It acts on an NVMe layout only, for example the layout of
# jetson-orin-nano-devkit-nvme.
# For any other layout it warns, so the build log shows that the store stays
# at the layout's own size. On an NVMe layout it fails the build when UDA is
# missing or not one partition: a silent no-op would ship a 400 MiB store.
ATC_TEGRA_UDA_SIZE ??= "4294967296"

python atc_grow_uda() {
    import os
    import re

    layout = d.getVar('PARTITION_LAYOUT_EXTERNAL') or ''
    if 'nvme' not in layout:
        bb.warn("meta-atc grows UDA in an NVMe layout only, and the external "
                "layout is '%s'. /var/atc keeps the layout's own UDA, with no "
                "file from the flash." % layout)
        return
    path = os.path.join(d.getVar('D'), d.getVar('datadir').lstrip('/'),
                        'l4t-storage-layout', layout)
    with open(path) as f:
        text = f.read()
    blocks = list(re.finditer(r'<partition name="UDA"[^>]*>.*?</partition>', text, re.S))
    if len(blocks) != 1:
        bb.fatal("%s has %d UDA partitions, expected 1" % (layout, len(blocks)))
    block = blocks[0].group(0)

    sizes = list(re.finditer(r'<size>\s*(\d+)\s*</size>', block))
    if len(sizes) != 1:
        bb.fatal("the UDA partition of %s has no single numeric <size>" % layout)
    want = int(d.getVar('ATC_TEGRA_UDA_SIZE'))
    have = int(sizes[0].group(1))
    if have < want:
        s = sizes[0]
        block = block[:s.start()] + "<size> %d </size>" % want + block[s.end():]
        bb.note("%s: UDA grown from %d to %d bytes" % (layout, have, want))

    files = re.findall(r'<filename>\s*(\S*)\s*</filename>', block)
    if not files:
        block = block.replace('</partition>', '    <filename> DATAFILE </filename>\n        </partition>')
    elif files != ['DATAFILE']:
        bb.fatal("the UDA partition of %s already names the file %s" % (layout, files))

    text = text[:blocks[0].start()] + block + text[blocks[0].end():]
    with open(path, 'w') as f:
        f.write(text)
}
do_install[postfuncs] += "atc_grow_uda"
do_install[vardeps] += "ATC_TEGRA_UDA_SIZE"
