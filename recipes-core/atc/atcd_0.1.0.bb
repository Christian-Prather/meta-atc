SUMMARY = "atcd, its service, its users and its boot-confirm guard"
DESCRIPTION = "Installs atcd, the current release of ATCD_TRACK, downloaded \
and verified by install-atcd.sh. Also the end state of a device-side \
`atcd install`: the atc and atc-hooks users with fixed ids, atcd.service, \
the store root's owner and mode, the hook user's sudoers rule, subordinate \
ids, linger and stop timeout, and the boot-confirm guard. No step at run \
time edits an account. The first boot on an empty store copies this atcd \
into the store, and atcd updates itself there."
HOMEPAGE = "https://github.com/Christian-Prather/meta-atc"
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

# The guard and install-atcd.sh are copies of atc's own scripts. The atc
# maintainers keep them byte-for-byte equal to the originals.
SRC_URI = "file://atcd-boot-confirm.sh file://install-atcd.sh \
    file://atcd.service file://atcd-store-seed.service file://atcd-store-seed \
    file://atcd.conf file://atcd-hook-user-stop-timeout.conf \
    file://atc-shell.sudoers"

inherit useradd systemd

# Users atc and atc-hooks with FIXED ids, in every image.
#
# The store on /var/atc survives a slot switch, and its files carry numeric
# owners. Two slots that allocated the ids in a different order would hand the
# store to the wrong user after an update. The drop-in for the hook user's
# manager names its uid, so that uid is fixed too.
ATC_GID ?= "2000"
ATC_UID ?= "2000"
ATC_HOOKS_UID ?= "2001"
# The first subordinate id of atc-hooks: the first block `atc bootstrap`
# tries.
ATC_HOOKS_SUBID_BASE ?= "1879048192"

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system -g ${ATC_GID} atc"
# One user per line, so scripts/check-atc-ab-layout.sh can read each.
USERADD_PARAM:${PN} = "\
    --system -u ${ATC_UID} -g atc --home-dir /var/atc --no-create-home --shell /usr/sbin/nologin atc; \
    --system -u ${ATC_HOOKS_UID} -g atc -G atc --home-dir /var/lib/atc-hooks --no-create-home --shell /usr/sbin/nologin atc-hooks \
    "

# Only atcd.service is enabled. It requires atcd-store-seed.service.
SYSTEMD_SERVICE:${PN} = "atcd.service"

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

# Paths the running system uses. They must match what atcd expects:
#   libexec directory  /usr/local/libexec
#   guard              /usr/local/libexec/atcd-boot-confirm.sh
#   remote_path        /usr/local/bin/atcd, a symlink into the store
#   store link         the store's current atcd, which atcd.service runs
ATCD_LIBEXEC = "/usr/local/libexec"
ATCD_GUARD_PATH = "${ATCD_LIBEXEC}/atcd-boot-confirm.sh"
ATCD_REMOTE_PATH = "${bindir}/atcd"
ATCD_LINK_PATH = "/usr/local/bin/atcd"
ATCD_STORE_LINK = "/var/atc/channel/agency/atcd/delivery/current/atcd/atcd"

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

    # The link atc runs over ssh. It points into the store, which the data
    # partition holds, so it dangles until atcd-store-seed fills the store.
    install -d ${D}$(dirname ${ATCD_LINK_PATH})
    ln -sfn ${ATCD_STORE_LINK} ${D}${ATCD_LINK_PATH}

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/atcd.service ${WORKDIR}/atcd-store-seed.service \
        ${D}${systemd_system_unitdir}/
    sed -i 's#@LIBEXECDIR@#${libexecdir}#' ${D}${systemd_system_unitdir}/atcd-store-seed.service
    install -d ${D}${libexecdir}/atcd
    install -m 0755 ${WORKDIR}/atcd-store-seed ${D}${libexecdir}/atcd/
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/atcd.conf ${D}${nonarch_libdir}/tmpfiles.d/

    # The hook user's manager stops in 180 s, not systemd's default 90 s.
    install -d ${D}${systemd_system_unitdir}/user@${ATC_HOOKS_UID}.service.d
    install -m 0644 ${WORKDIR}/atcd-hook-user-stop-timeout.conf \
        ${D}${systemd_system_unitdir}/user@${ATC_HOOKS_UID}.service.d/zz-atc-hook-user-stop-timeout.conf

    # Members of group atc may run a shell as atc-hooks, for `atc` hook
    # commands over ssh.
    install -d ${D}${sysconfdir}/sudoers.d
    install -m 0440 ${WORKDIR}/atc-shell.sudoers ${D}${sysconfdir}/sudoers.d/atc-shell

    # Linger for atc-hooks: hooks run `systemctl --user` services, and the
    # user's manager must run with no login session.
    install -d ${D}${localstatedir}/lib/systemd/linger
    touch ${D}${localstatedir}/lib/systemd/linger/atc-hooks
}

# Subordinate ids for atc-hooks, for rootless podman in hooks. A --system
# user gets none from useradd. Written into the image at rootfs time only. On
# a device that already has an entry, nothing changes.
pkg_postinst:${PN}() {
    for f in $D${sysconfdir}/subuid $D${sysconfdir}/subgid; do
        touch "$f"
        grep -q '^atc-hooks:' "$f" ||
            echo "atc-hooks:${ATC_HOOKS_SUBID_BASE}:65536" >> "$f"
    done
}

# /var/atc is NOT in the package. It is the mount point of the data
# partition. systemd-tmpfiles sets its owner and mode at boot (atcd.conf), and
# atcd-store-seed fills it.
FILES:${PN} = "${ATCD_GUARD_PATH} ${ATCD_REMOTE_PATH} ${ATCD_LINK_PATH} \
    ${systemd_system_unitdir} ${libexecdir}/atcd ${nonarch_libdir}/tmpfiles.d \
    ${sysconfdir}/sudoers.d ${localstatedir}/lib/systemd/linger"

# The sudoers rule needs sudo.
RDEPENDS:${PN} += "sudo"

# The release binary is a static musl ELF: it has no dynamic dependencies for
# bitbake to resolve, and it is not built by this recipe's toolchain.
INSANE_SKIP:${PN} += "already-stripped arch staticdev ldflags"
