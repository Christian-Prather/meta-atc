# Run NVIDIA's flash tools on an arm64 build host, through qemu-user.
#
# The L4T tarball ships tegrahost_v2, tegrabct_v2, tegrasign_v2 and the other
# flash tools as 32-bit i386 executables, statically linked. The capsule
# (tegra-uefi-capsules) and the tegraflash image run them at build time. The
# builder box is an arm64 Graviton, where the kernel refuses them with "Exec
# format error".
#
# On an aarch64 build host, this append renames each i386 or x86-64 tool to
# <tool>.real and installs a wrapper under the tool's own name. The wrapper
# runs the tool under qemu-native's qemu-i386 or qemu-x86_64. Callers find the
# tools by name on PATH, so they need no change. A static tool needs no x86
# sysroot. qemu-native is a native dependency, so it is in the sysroot of each
# recipe that uses these tools. The host needs no binfmt_misc entry.
#
# Measured on the builder box (c7g, Amazon Linux 2023) on 2026-11-11: each of
# the six *_v2 tools printed its usage text under qemu-native's qemu-i386.
# Amazon Linux's qemu-user-static-x86 ships qemu-x86_64 only, not qemu-i386.
#
# An x86-64 build host runs the tools directly, and this append changes nothing
# there. The tegraflash archive copies the tools, wrappers included, so each
# wrapper runs its tool directly when the machine is not aarch64.
DEPENDS:append = "${@' qemu-native' if d.getVar('BUILD_ARCH') == 'aarch64' else ''}"

do_install:append() {
    if [ "${BUILD_ARCH}" != "aarch64" ]; then
        return
    fi
    for tool in ${D}${BINDIR}/*; do
        [ -f "$tool" ] && [ ! -L "$tool" ] || continue
        # The ELF magic, then e_machine at offset 18: 3 is i386, 62 is x86-64.
        [ "$(head -c 4 "$tool" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || continue
        case "$(od -An -tu2 -j18 -N2 "$tool" | tr -d ' ')" in
            3) qemu=qemu-i386 ;;
            62) qemu=qemu-x86_64 ;;
            *) continue ;;
        esac
        name="$(basename "$tool")"
        mv "$tool" "$tool.real"
        # The tegraflash archive copies these tools, and the flash host is
        # x86-64. There the wrapper runs the tool directly, without qemu.
        #
        # The wrapper finds the tool through its own resolved path, not
        # through $0. initrd-flash links tegrarcm_v2 into rcmboot_blob/ and
        # runs it from there, where no <tool>.real exists beside the link.
        cat > "$tool" << EOF
#!/bin/sh
real="\$(readlink -f "\$0").real"
case "\$(uname -m)" in
    aarch64 | arm64) exec $qemu "\$real" "\$@" ;;
esac
exec "\$real" "\$@"
EOF
        chmod 0755 "$tool"
    done
}
