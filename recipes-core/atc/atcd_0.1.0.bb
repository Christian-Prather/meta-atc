SUMMARY = "atcd bootstrap payload: the boot-confirm guard and a prebuilt atcd binary"
DESCRIPTION = "Installs the atcd A/B boot-confirm guard and, when a prebuilt \
binary is supplied, a seed atcd. The recipe does NOT install a systemd unit: \
the unit interpolates the store root, socket path, service user and telemetry \
endpoint of the specific device, so a copy baked into an image drifts from \
render_systemd_unit. First-boot `atc bootstrap atcd install` renders it."
HOMEPAGE = "https://github.com/Agency-Tool-Company/meta-atc"
LICENSE = "CLOSED"

# The binary is the static musl atcd from the atc release build. bitbake
# installs that artifact and does not rebuild atcd, so the image carries the
# same bytes the fleet runs.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"

# The guard is a byte-for-byte copy of the atc source's
# tools/scripts/atcd-boot-confirm.sh. scripts/check-meta-atc-recipe.sh fails if
# the two differ, when ATC_MONOREPO names a checkout of that source.
SRC_URI = "file://atcd-boot-confirm.sh"

# One recipe cannot serve two PACKAGE_ARCH values from one binary, so the binary
# comes in per-architecture. ATCD_BINARY points at a prebuilt musl atcd for the
# target arch; leave it empty to ship the guard alone and let `atc bootstrap`
# seed the binary. do_install FAILS on an architecture mismatch. Without that
# check a wrong-architecture ELF still builds green.
# Two ways to point at a binary, and BOTH must work:
#   * ATCD_BINARY: one build, one machine. The simple case.
#   * ATCD_BINARY_X86_64 / ATCD_BINARY_AARCH64: one local.conf serving both
#     machines, each picked up by the matching architecture.
#
# Deliberately NO `ATCD_BINARY:<machine>` override. Two shapes were tried and
# both were wrong, in opposite directions:
#   * an unconditional override set to the per-arch name overwrites a plain
#     ATCD_BINARY with an empty string, silently producing a guard-only image;
#   * making the per-arch names default back to ATCD_BINARY closes the loop:
#     the override expands to the per-arch name, which expands to ATCD_BINARY,
#     which IS the override. Bitbake expands `${...}` lazily, so that is a real
#     reference cycle, and it hits the plain and the empty paths alike.
# Resolving the choice once, in do_install, has no precedence puzzle to get
# wrong. ATCD_BINARY_RESOLVED is what the install reads.
ATCD_BINARY ?= ""
ATCD_BINARY_X86_64 ?= ""
ATCD_BINARY_AARCH64 ?= ""

# Per-architecture name for THIS machine, empty when the machine has none.
ATCD_BINARY_FOR_ARCH = ""
ATCD_BINARY_FOR_ARCH:qemux86-64 = "${ATCD_BINARY_X86_64}"
ATCD_BINARY_FOR_ARCH:qemuarm64 = "${ATCD_BINARY_AARCH64}"
ATCD_BINARY_FOR_ARCH:tegra234 = "${ATCD_BINARY_AARCH64}"

# The per-architecture name wins when set, otherwise the plain one. Neither
# side refers back to this variable, so there is no cycle.
ATCD_BINARY_RESOLVED = "${@d.getVar('ATCD_BINARY_FOR_ARCH') or d.getVar('ATCD_BINARY') or ''}"

# The ELF machine name readelf must report for this target. A recipe that adds a
# machine must add its expected value here, or do_install refuses the binary.
ATCD_EXPECTED_ELF_MACHINE ?= ""
ATCD_EXPECTED_ELF_MACHINE:qemux86-64 = "Advanced Micro Devices X86-64"
ATCD_EXPECTED_ELF_MACHINE:qemuarm64 = "AArch64"
ATCD_EXPECTED_ELF_MACHINE:tegra234 = "AArch64"

# Paths the running system uses. These mirror
# crates/atc-cmd-bootstrap/src/bootstrap_daemon/consts.rs and must not drift:
#   LIBEXEC_DIR       = "/usr/local/libexec"        (consts.rs)
#   GUARD_REMOTE_PATH = "/usr/local/libexec/atcd-boot-confirm.sh"
#   remote_path       = "/usr/local/bin/atcd"       (schema_defaults.rs)
ATCD_LIBEXEC = "/usr/local/libexec"
ATCD_GUARD_PATH = "${ATCD_LIBEXEC}/atcd-boot-confirm.sh"
ATCD_REMOTE_PATH = "${bindir}/atcd"

S = "${WORKDIR}"

# Only the guard is arch-independent. The binary makes the package
# machine-specific, so the whole package is.
PACKAGE_ARCH = "${MACHINE_ARCH}"

DEPENDS += "binutils-native"

# The binary is read from a host path OUTSIDE bitbake's control, so its bytes are
# not part of do_install's signature by default. Only the path STRING is. Rebuild
# atcd to the same output path and bitbake reuses the cached package, so the
# image keeps shipping the OLD binary while the build reports success. `file-checksums` puts the file's checksum in the
# signature, so new bytes re-run the task. An empty ATCD_BINARY_RESOLVED yields an
# empty entry, which bitbake ignores.
do_install[file-checksums] += "${ATCD_BINARY_RESOLVED}:True"

do_install() {
    install -d ${D}${ATCD_LIBEXEC}
    install -m 0755 ${WORKDIR}/atcd-boot-confirm.sh ${D}${ATCD_GUARD_PATH}

    if [ -z "${ATCD_BINARY_RESOLVED}" ]; then
        bbnote "ATCD_BINARY is empty: shipping the guard only. \
'atc bootstrap atcd install' seeds the binary on first contact."
        return
    fi

    if [ ! -f "${ATCD_BINARY_RESOLVED}" ]; then
        bbfatal "ATCD_BINARY=${ATCD_BINARY_RESOLVED} does not exist."
    fi

    if [ -z "${ATCD_EXPECTED_ELF_MACHINE}" ]; then
        bbfatal "No ATCD_EXPECTED_ELF_MACHINE for MACHINE=${MACHINE}. \
Add the readelf machine name for this target before installing a binary, \
or a wrong-architecture ELF installs silently."
    fi

    # The architecture assertion. `readelf -h` prints one "Machine:" line; a
    # binary for the wrong target reports a different name and fails the build
    # here rather than at first boot on the device.
    #
    # The NATIVE (unprefixed) readelf from binutils-native, deliberately. It
    # reads any ELF header regardless of target arch, and reading a header is
    # the whole job here. A `${TARGET_PREFIX}readelf` would need
    # binutils-cross-${TARGET_ARCH}, which this recipe does not depend on, and
    # a missing command fails OPEN: the substitution yields an empty string,
    # which then trips the mismatch branch with a confusing message instead of
    # reporting the real problem.
    if ! actual_machine=$(readelf -h "${ATCD_BINARY_RESOLVED}" 2>&1); then
        bbfatal "readelf could not read ${ATCD_BINARY_RESOLVED}: ${actual_machine}"
    fi
    actual_machine=$(printf '%s\n' "${actual_machine}" \
        | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
    if [ -z "${actual_machine}" ]; then
        bbfatal "readelf printed no Machine line for ${ATCD_BINARY_RESOLVED}; \
refusing to install a binary whose architecture cannot be confirmed."
    fi
    if [ "${actual_machine}" != "${ATCD_EXPECTED_ELF_MACHINE}" ]; then
        bbfatal "atcd architecture mismatch for MACHINE=${MACHINE}: \
readelf reports '${actual_machine}', expected '${ATCD_EXPECTED_ELF_MACHINE}'. \
Supply a static musl atcd built for this target."
    fi

    install -d ${D}${bindir}
    install -m 0755 "${ATCD_BINARY_RESOLVED}" ${D}${ATCD_REMOTE_PATH}
}

# Deliberately NOT created here. `atcd install-self` creates /var/atc with the
# modes the traverse-grant walk expects; a hardened image umask of 077 otherwise
# produces 0700 directories and breaks `atcd attach` with EACCES.
# See consts.rs::grant_traverse_snippet.
FILES:${PN} = "${ATCD_GUARD_PATH} ${ATCD_REMOTE_PATH}"

# The prebuilt binary is a static musl ELF: it has no dynamic dependencies for
# bitbake to resolve, and it is not built by this recipe's toolchain.
INSANE_SKIP:${PN} += "already-stripped arch staticdev ldflags"
