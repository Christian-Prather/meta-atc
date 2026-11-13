SUMMARY = "atcd and its boot-confirm guard"
DESCRIPTION = "Installs the atcd A/B boot-confirm guard and atcd, the current \
release of ATCD_TRACK, downloaded and verified by install-atcd.sh. The recipe \
does NOT install a systemd unit: the unit interpolates the store root, socket \
path, service user and telemetry endpoint of the specific device, so a copy \
baked into an image drifts from render_systemd_unit. First-boot \
`atc bootstrap atcd install` renders it."
HOMEPAGE = "https://github.com/Agency-Tool-Company/meta-atc"
# The layer's files are MIT. atcd, the guard and install-atcd.sh come from the
# atc source, which is MIT OR Apache-2.0.
LICENSE = "MIT | Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# atcd is the static musl binary of the atc release. do_compile runs
# install-atcd.sh in download-only mode for the current release of ATCD_TRACK.
# The script checks the ed25519 signature of the release index and the sha256
# of the binary before it writes anything. bitbake does not rebuild atcd, so
# the image carries the same bytes the fleet runs.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"

# The guard and install-atcd.sh are byte-for-byte copies of the atc source's
# tools/scripts/. scripts/check-meta-atc-recipe.sh fails if a copy differs,
# when ATC_MONOREPO names a checkout of that source.
SRC_URI = "file://atcd-boot-confirm.sh file://install-atcd.sh"

ATCD_TRACK ?= "stable"

# The release target for this build's architecture.
ATCD_TARGET = ""
ATCD_TARGET:x86-64 = "linux-x86_64-musl"
ATCD_TARGET:aarch64 = "linux-aarch64-musl"

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

# readelf for the architecture check. curl and OpenSSL 3 (ed25519 with -rawin)
# for the install script: the native ones, so the build host's versions do not
# matter.
DEPENDS += "binutils-native curl-native openssl-native"

# The download is the only network access after do_fetch. The track's current
# release changes with no change to any variable, so the task runs on every
# build and the image always gets the current release.
do_compile[network] = "1"
do_compile[nostamp] = "1"

do_compile() {
    rm -f ${B}/atcd
    if [ -z "${ATCD_TRACK}" ]; then
        bbfatal "ATCD_TRACK is empty. Set it to a release track, for example stable."
    fi
    if [ -z "${ATCD_TARGET}" ]; then
        bbfatal "atcd has no release for TARGET_ARCH=${TARGET_ARCH}."
    fi
    bbnote "atcd: install-atcd.sh, track ${ATCD_TRACK}, target ${ATCD_TARGET}"
    ATC_TRACK="${ATCD_TRACK}" ATC_TARGET="${ATCD_TARGET}" ATC_DOWNLOAD_ONLY="${B}/atcd" \
        sh ${WORKDIR}/install-atcd.sh ||
        bbfatal "install-atcd.sh could not fetch a verified atcd. It needs network \
access to https://atc.dev."
}

do_install() {
    install -d ${D}${ATCD_LIBEXEC}
    install -m 0755 ${WORKDIR}/atcd-boot-confirm.sh ${D}${ATCD_GUARD_PATH}

    if [ ! -f "${B}/atcd" ]; then
        bbfatal "no atcd at ${B}/atcd. do_compile did not download it."
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
    if ! actual_machine=$(readelf -h "${B}/atcd" 2>&1); then
        bbfatal "readelf could not read ${B}/atcd: ${actual_machine}"
    fi
    actual_machine=$(printf '%s\n' "${actual_machine}" \
        | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
    if [ -z "${actual_machine}" ]; then
        bbfatal "readelf printed no Machine line for ${B}/atcd; \
refusing to install a binary whose architecture cannot be confirmed."
    fi
    if [ "${actual_machine}" != "${ATCD_EXPECTED_ELF_MACHINE}" ]; then
        bbfatal "atcd architecture mismatch for MACHINE=${MACHINE}: \
readelf reports '${actual_machine}', expected '${ATCD_EXPECTED_ELF_MACHINE}'."
    fi

    install -d ${D}${bindir}
    install -m 0755 "${B}/atcd" ${D}${ATCD_REMOTE_PATH}
}

# Deliberately NOT created here. `atcd install-self` creates /var/atc with the
# modes the traverse-grant walk expects; a hardened image umask of 077 otherwise
# produces 0700 directories and breaks `atcd attach` with EACCES.
# See consts.rs::grant_traverse_snippet.
FILES:${PN} = "${ATCD_GUARD_PATH} ${ATCD_REMOTE_PATH}"

# The release binary is a static musl ELF: it has no dynamic dependencies for
# bitbake to resolve, and it is not built by this recipe's toolchain.
INSANE_SKIP:${PN} += "already-stripped arch staticdev ldflags"
