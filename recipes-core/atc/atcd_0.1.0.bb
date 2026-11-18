SUMMARY = "atcd and its boot-confirm guard"
DESCRIPTION = "Installs the atcd A/B boot-confirm guard and atcd, the release \
that ATCD_VERSION pins, verified by install-atcd.sh. The recipe \
does NOT install a systemd unit: the unit interpolates the store root, socket \
path, service user and telemetry endpoint of the specific device, so a copy \
baked into an image drifts from render_systemd_unit. First-boot \
`atc bootstrap atcd install` renders it."
HOMEPAGE = "https://github.com/Christian-Prather/meta-atc"
# The layer's files are MIT. atcd, the guard and install-atcd.sh come from the
# atc source, which is MIT OR Apache-2.0.
LICENSE = "MIT | Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# atcd is the static musl binary of the atc release. bitbake does not rebuild
# it, so the image carries the same bytes the fleet runs.
#
# The release is pinned. ATCD_VERSION and ATCD_SHA256 are in the task
# signature, so a new pin rebuilds atcd and every image that holds it, and an
# unchanged pin restores from sstate. do_fetch downloads the binary from its
# content-addressed URL and checks its sha256. do_compile then runs
# install-atcd.sh in local mode, with no network access, against the signed
# index of the pinned release in files/atcd-release/. The script checks the
# ed25519 signature of the index, its track and version, and the sha256 of the
# binary before it writes anything. With the binary in DL_DIR or a mirror, the
# build needs no network.
#
# To take a new release, follow "atcd" in README.md: replace the two index
# files, then set ATCD_VERSION and both ATCD_SHA256 values from the new index.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"

# The track and version of the pinned release. Both must equal the values in
# files/atcd-release/index.json, or install-atcd.sh refuses the index.
ATCD_TRACK = "stable"
ATCD_VERSION = "0.2.4"

# The release target for this build's architecture.
ATCD_TARGET = ""
ATCD_TARGET:x86-64 = "linux-x86_64-musl"
ATCD_TARGET:aarch64 = "linux-aarch64-musl"

# The sha256 of the atcd binary of ATCD_VERSION for each target. It is the
# "digest" of the agency/atcd entry in the signed index, and the blob address.
ATCD_SHA256 = ""
ATCD_SHA256:x86-64 = "064ae9ad001ba1a57fcb88ef3c33b8ae4c1cf05b37260b2bb2228eb289e9f82a"
ATCD_SHA256:aarch64 = "9cfeda114c321a48b55eb397866dd9f786e7caf8ec490506fae9ccc552d6313d"

# atcd has a release for these hosts only. On any other host bitbake skips the
# recipe at parse time, instead of a failed fetch of an empty URL.
COMPATIBLE_HOST = "(x86_64|aarch64).*-linux.*"

# The guard and install-atcd.sh are copies of atc's own scripts. The atc
# maintainers keep them byte-for-byte equal to the originals. The index files
# are the signed index of the pinned release, byte for byte as the origin
# served it. The last entry is the binary. Its file name holds the version and
# the target, so two pins never share one file in DL_DIR.
SRC_URI = "file://atcd-boot-confirm.sh \
           file://install-atcd.sh \
           file://atcd-release/index.json \
           file://atcd-release/index.json.sig \
           https://atc.dev/agency/blobs/sha256/${ATCD_SHA256};downloadfilename=atcd-${ATCD_VERSION}-${ATCD_TARGET};sha256sum=${ATCD_SHA256} \
           "

# An optional fetch credential. See "Fetch credential" in README.md.
#
# The credential is HTTP Basic, from a netrc file. wget reads $HOME/.netrc and
# sends the login and password for the host of that entry only, after the
# server asks for them with a 401. So a build user with an atc.dev entry in
# ~/.netrc needs no setting here. ATCD_NETRC_DIR names another directory that
# holds the .netrc file, for a builder whose credential is not in HOME. The
# recipe then runs wget for its own download with HOME set to that directory.
# --no-hsts stops wget from writing its HSTS cache there.
#
# The secret is in the netrc file only. Never put it in SRC_URI with user= and
# pswd=: SRC_URI is in the task signature, the logs and bitbake -e. The
# directory path is not in the signature either, so two builders with
# different paths share sstate. A binary in DL_DIR or a premirror needs no
# credential, and a mirror host gets none, because the netrc entry names
# atc.dev only.
ATCD_NETRC_DIR ?= ""
python () {
    if d.getVar('ATCD_NETRC_DIR'):
        base = d.getVar('FETCHCMD_wget', False) or '/usr/bin/env wget -t 2 -T 100'
        d.setVar('FETCHCMD_wget', '/usr/bin/env HOME=${ATCD_NETRC_DIR} ' + base + ' --no-hsts')
}
do_fetch[vardepsexclude] += "ATCD_NETRC_DIR FETCHCMD_wget"

# The ELF machine name readelf must report for this target. A recipe that adds a
# machine must add its expected value here, or do_install refuses the binary.
ATCD_EXPECTED_ELF_MACHINE ?= ""
ATCD_EXPECTED_ELF_MACHINE:qemux86-64 = "Advanced Micro Devices X86-64"
ATCD_EXPECTED_ELF_MACHINE:qemuarm64 = "AArch64"
ATCD_EXPECTED_ELF_MACHINE:tegra234 = "AArch64"

# Paths the running system uses. They must match what atcd expects:
#   libexec directory  /usr/local/libexec
#   guard              /usr/local/libexec/atcd-boot-confirm.sh
#   remote_path        /usr/local/bin/atcd, a symlink that bootstrap makes
ATCD_LIBEXEC = "/usr/local/libexec"
ATCD_GUARD_PATH = "${ATCD_LIBEXEC}/atcd-boot-confirm.sh"
ATCD_REMOTE_PATH = "${bindir}/atcd"

S = "${WORKDIR}"

# Only the guard is arch-independent. The binary makes the package
# machine-specific, so the whole package is.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# readelf for the architecture check. OpenSSL 3 (ed25519 with -rawin) for the
# install script: the native one, so the build host's version does not matter.
# In local mode the script needs no curl.
DEPENDS += "binutils-native openssl-native"

do_compile() {
    rm -f ${B}/atcd
    if [ -z "${ATCD_TARGET}" ] || [ -z "${ATCD_SHA256}" ]; then
        bbfatal "atcd has no pinned release for TARGET_ARCH=${TARGET_ARCH}."
    fi
    # The file names that the local mode of install-atcd.sh reads.
    local_dir=${B}/atcd-local
    mkdir -p $local_dir
    cp ${WORKDIR}/atcd-release/index.json ${WORKDIR}/atcd-release/index.json.sig $local_dir/
    cp ${WORKDIR}/atcd-${ATCD_VERSION}-${ATCD_TARGET} $local_dir/atcd-${ATCD_TARGET}
    bbnote "atcd: install-atcd.sh, track ${ATCD_TRACK}, version ${ATCD_VERSION}, target ${ATCD_TARGET}"
    ATC_TRACK="${ATCD_TRACK}" ATC_VERSION="${ATCD_VERSION}" ATC_TARGET="${ATCD_TARGET}" \
        ATC_LOCAL_DIR="$local_dir" ATC_DOWNLOAD_ONLY="${B}/atcd" \
        sh ${WORKDIR}/install-atcd.sh ||
        bbfatal "install-atcd.sh refused atcd ${ATCD_VERSION} for ${ATCD_TARGET}. \
The index in files/atcd-release/ must be the signed index of that release, \
and ATCD_TRACK, ATCD_VERSION and ATCD_SHA256 must match it."
    rm -f $local_dir/atcd-${ATCD_TARGET}
}

do_install() {
    install -d ${D}${ATCD_LIBEXEC}
    install -m 0755 ${WORKDIR}/atcd-boot-confirm.sh ${D}${ATCD_GUARD_PATH}

    if [ ! -f "${B}/atcd" ]; then
        bbfatal "no atcd at ${B}/atcd. do_compile did not verify one."
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
FILES:${PN} = "${ATCD_GUARD_PATH} ${ATCD_REMOTE_PATH}"

# The release binary is a static musl ELF: it has no dynamic dependencies for
# bitbake to resolve, and it is not built by this recipe's toolchain.
INSANE_SKIP:${PN} += "already-stripped arch staticdev ldflags"
