SUMMARY = "atcd, its service, its users and its boot-confirm guard"
DESCRIPTION = "Installs atcd, the release that ATCD_VERSION pins, verified by \
install-atcd.sh. Also the end state of a device-side `atcd install`: the atc \
and atc-hooks users with fixed ids, atcd.service, the store root's owner and \
mode, the hook user's sudoers rule, subordinate ids, linger and stop timeout, \
and the boot-confirm guard. No step at run time edits an account. The first \
boot on an empty store copies this atcd into the store, and atcd updates \
itself there."
HOMEPAGE = "https://github.com/Christian-Prather/meta-atc"
# One license for each package. The atcd binary in ${PN} is closed-source:
# CLOSED, Yocto's name for a license with no text to ship. The guard in
# ${PN}-boot-confirm is an atc script, which is MIT OR Apache-2.0. The units
# and configuration files in ${PN}-service are the layer's own files, which
# are MIT. install-atcd.sh only runs at build time and is in no package.
#
# license.bbclass and license_image.bbclass expect no text for CLOSED, so
# LIC_FILES_CHKSUM names MIT only.
LICENSE = "CLOSED & (MIT | Apache-2.0)"
LICENSE:${PN} = "CLOSED"
LICENSE:${PN}-boot-confirm = "MIT | Apache-2.0"
LICENSE:${PN}-service = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# A product must accept the atcd license before bitbake builds atcd. Without
# LICENSE_FLAGS_ACCEPTED += "commercial_atcd" bitbake skips the recipe at parse
# time, and an image that installs atcd names this message as the reason.
# Note: bitbake also accepts the flag when LICENSE_FLAGS_ACCEPTED holds the
# plain word "commercial".
LICENSE_FLAGS = "commercial_atcd"
LICENSE_FLAGS_DETAILS[commercial_atcd] = 'The atcd binary is closed-source \
(LICENSE CLOSED). To accept its license, set \
LICENSE_FLAGS_ACCEPTED += "commercial_atcd" in local.conf or the distro \
configuration. See "atcd license" in the meta-atc README.'

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
ATCD_TRACK = "nightly"
ATCD_VERSION = "0.2.6-rc.202611202013.g2c7d0dfbc381"

# The layer's own files for the device-side install: the units, the store
# seed, the tmpfiles entry, the hook user's stop timeout and sudoers rule.
ATCD_LAYER_FILES = "file://atcd.service file://atcd-store-seed.service \
    file://atcd-store-seed file://atcd.conf \
    file://atcd-hook-user-stop-timeout.conf file://atc-shell.sudoers"

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

USERADD_PACKAGES = "${PN}-service"
GROUPADD_PARAM:${PN}-service = "--system -g ${ATC_GID} atc"
# One user per line, so scripts/check-atc-ab-layout.sh can read each.
USERADD_PARAM:${PN}-service = "\
    --system -u ${ATC_UID} -g atc --home-dir /var/atc --no-create-home --shell /usr/sbin/nologin atc; \
    --system -u ${ATC_HOOKS_UID} -g atc -G atc --home-dir /var/lib/atc-hooks --no-create-home --shell /usr/sbin/nologin atc-hooks \
    "

# Only atcd.service is enabled. It requires atcd-store-seed.service.
SYSTEMD_PACKAGES = "${PN}-service"
SYSTEMD_SERVICE:${PN}-service = "atcd.service"

# Follow a track instead of the pin. FOR DEVELOPMENT ONLY. See "Follow a track"
# in README.md.
#
# ATCD_FOLLOW_TRACK names a track, for example "nightly". Each parse then reads
# the current signed index of that track from ATCD_BASE_URL, like
# SRCREV = "${AUTOREV}". The recipe sets ATCD_TRACK to that track, and takes
# ATCD_VERSION, both ATCD_SHA256 values and ATCD_GUARD_SHA256 from the index.
# A release with no guard entry skips the recipe. So a new release
# changes the task signature and rebuilds atcd and the image. The index and its
# signature go to ATCD_FOLLOW_DIR, one directory for each version, and
# do_compile checks them with install-atcd.sh as for a pin.
#
# The parse needs network access. With BB_NO_NETWORK = "1", or a host that
# BB_ALLOWED_NETWORKS does not name, bitbake skips the recipe. The same layer
# commit gives a new atcd after each release, so do not use this for a
# product image.
ATCD_FOLLOW_TRACK ?= ""
ATCD_BASE_URL ?= "https://atc.dev/agency"
ATCD_FOLLOW_DIR ?= "${DL_DIR}/atcd-follow"
# The parse writes ATCD_FOLLOW_DIR, also in the workers of fakeroot tasks.
# pseudo must not track it, or a file that a later parse replaces makes pseudo
# abort with an inode mismatch.
PSEUDO_IGNORE_PATHS .= ",${ATCD_FOLLOW_DIR}"

# The release target for this build's architecture.
ATCD_TARGET = ""
ATCD_TARGET:x86-64 = "linux-x86_64-musl"
ATCD_TARGET:aarch64 = "linux-aarch64-musl"

# The sha256 of the atcd binary of ATCD_VERSION for each target. It is the
# "digest" of the agency/atcd entry in the signed index, and the blob address.
ATCD_SHA256 = ""
ATCD_SHA256:x86-64 = "0eec49f3fe072aa333d4c989c45dfdf11ae096e9a935ba17eb8520df52a3e588"
ATCD_SHA256:aarch64 = "539859d551eef311890aee625ad65a26b7eaee86ee3bf2ed68a9bd264463a5e8"

# The boot-confirm guard of the same release. It is the "digest" of the
# agency/atcd-boot-confirm entry, target "any", in the signed index. do_compile
# refuses a guard that the signed index does not name. In follow mode the
# recipe takes it from the index, like ATCD_SHA256.
ATCD_GUARD_SHA256 = "f91e86a53f5c5b6d7728bf0745f215e9f7bd4e832790b2ed56a068b6ecf549f6"

# The sha256 of install-atcd.sh, the script that verifies the index. It is
# pinned here in both modes: a script that came from the index it verifies
# would prove nothing. It is the "digest" of agency/install-atcd in a signed
# index. To take a new one, see "atcd" in README.md.
ATCD_INSTALLER_SHA256 = "394dbf8f59806ecddf911946c5565605ab8c2a04a4b84385bdb2de966e382a4b"
ATCD_GUARD_FILE = "atcd-boot-confirm-${ATCD_GUARD_SHA256}.sh"
ATCD_INSTALLER_FILE = "install-atcd-${ATCD_INSTALLER_SHA256}.sh"

# atcd has a release for these hosts only. On any other host bitbake skips the
# recipe at parse time, instead of a failed fetch of an empty URL.
COMPATIBLE_HOST = "(x86_64|aarch64).*-linux.*"

# The index files are the signed index of the pinned release, byte for byte
# as the origin served it. The guard, install-atcd.sh and the binary come from
# the release blob store by sha256, and do_fetch checks each one. Each file
# name holds its sha256 or the version and the target, so two pins never share
# one file in DL_DIR.
SRC_URI = "file://atcd-release/index.json \
           file://atcd-release/index.json.sig \
           file://atcd-index-digest.py \
           https://atc.dev/agency/blobs/sha256/${ATCD_SHA256};downloadfilename=atcd-${ATCD_VERSION}-${ATCD_TARGET};sha256sum=${ATCD_SHA256} \
           https://atc.dev/agency/blobs/sha256/${ATCD_GUARD_SHA256};downloadfilename=${ATCD_GUARD_FILE};sha256sum=${ATCD_GUARD_SHA256} \
           https://atc.dev/agency/blobs/sha256/${ATCD_INSTALLER_SHA256};downloadfilename=${ATCD_INSTALLER_FILE};sha256sum=${ATCD_INSTALLER_SHA256} \
           "
SRC_URI += "${ATCD_LAYER_FILES}"

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

# The release target of each ATCD_SHA256 override.
ATCD_FOLLOW_TARGETS = "x86-64:linux-x86_64-musl aarch64:linux-aarch64-musl"

def atcd_follow_track(d):
    import json, os, re, tempfile, urllib.request

    # Parse this recipe again on every run, as AUTOREV does, so that the next
    # build sees a new release.
    d.setVar('__BB_DONT_CACHE', '1')
    track = d.getVar('ATCD_FOLLOW_TRACK')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', track):
        raise bb.parse.SkipRecipe('ATCD_FOLLOW_TRACK is %r, not a track name such as "nightly"' % track)
    url = '%s/%s/index.json' % (d.getVar('ATCD_BASE_URL').rstrip('/'), track)
    try:
        bb.fetch2.check_network_access(d, 'atcd: read the %s index' % track, url)
    except bb.fetch2.NetworkAccess as e:
        raise bb.parse.SkipRecipe('ATCD_FOLLOW_TRACK reads %s at parse time, '
                                  'and network access is off: %s' % (url, e))

    def get(u):
        with urllib.request.urlopen(u, timeout=60) as r:
            return r.read()

    # A release can replace the index between two reads. Read it again after
    # the signature, and use the pair only when both index reads are equal.
    for _ in range(3):
        try:
            index, sig, again = get(url), get(url + '.sig'), get(url)
        except Exception as e:
            raise bb.parse.SkipRecipe('atcd: cannot read %s: %s' % (url, e))
        if index == again:
            break
    else:
        raise bb.parse.SkipRecipe('atcd: %s changed during three reads. Run bitbake again.' % url)

    try:
        doc = json.loads(index)
        if doc['track'] != track:
            raise ValueError('the index is for track %s' % doc['track'])
        version = doc['version']
        if not re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z.+_-]*', version):
            raise ValueError('bad version %r' % version)
        digests = {}
        for pair in d.getVar('ATCD_FOLLOW_TARGETS').split():
            override, target = pair.split(':', 1)
            digest = doc['artifacts']['agency/atcd'][target]['digest']
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
                raise ValueError('bad digest %r for %s' % (digest, target))
            digests[override] = digest.split(':', 1)[1]
        guard = doc['artifacts']['agency/atcd-boot-confirm']['any']['digest']
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', guard):
            raise ValueError('bad digest %r for the boot-confirm guard' % guard)
    except (ValueError, KeyError, TypeError, AttributeError) as e:
        raise bb.parse.SkipRecipe('atcd: cannot use the index at %s: %s' % (url, e))

    # FILESPATH finds atcd-release/ here before the pinned copy in files/.
    # install-atcd.sh still checks the signature in do_compile.
    release = os.path.join(d.getVar('ATCD_FOLLOW_DIR'), track, version)
    dest = os.path.join(release, 'atcd-release')
    bb.utils.mkdirhier(dest)
    # bitbake parses this recipe again for each task. Replace a file only when
    # its bytes differ, so a parse does not touch the files under a task.
    for name, data in (('index.json', index), ('index.json.sig', sig)):
        path = os.path.join(dest, name)
        try:
            with open(path, 'rb') as f:
                if f.read() == data:
                    continue
        except FileNotFoundError:
            pass
        fd, tmp = tempfile.mkstemp(dir=dest, prefix='.tmp-')
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(data)
            os.replace(tmp, path)
        except BaseException:
            os.unlink(tmp)
            raise
    d.prependVar('FILESEXTRAPATHS', release + ':')
    d.setVar('ATCD_TRACK', track)
    d.setVar('ATCD_VERSION', version)
    for override, digest in digests.items():
        d.setVar('ATCD_SHA256:' + override, digest)
    d.setVar('ATCD_GUARD_SHA256', guard.split(':', 1)[1])
    bb.debug(1, 'atcd: following %s at %s' % (track, version))

python () {
    if d.getVar('ATCD_FOLLOW_TRACK'):
        atcd_follow_track(d)
}

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

# Only the guard is arch-independent. The binary makes the recipe
# machine-specific, so both packages are.
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
        sh ${WORKDIR}/${ATCD_INSTALLER_FILE} ||
        bbfatal "install-atcd.sh refused atcd ${ATCD_VERSION} for ${ATCD_TARGET}. \
The index in atcd-release/ must be the signed index of that release, \
and ATCD_TRACK, ATCD_VERSION and ATCD_SHA256 must match it."
    rm -f $local_dir/atcd-${ATCD_TARGET}
    # install-atcd.sh verified the signature of this index. Read the guard
    # digest at its JSON path, as atcd does. A text search could match a
    # nested object that atcd never reads. python3 is a bitbake host tool
    # (HOSTTOOLS). do_fetch checked that the guard file has this sha256.
    index_guard=$(python3 ${WORKDIR}/atcd-index-digest.py $local_dir/index.json \
        agency/atcd-boot-confirm any) ||
        bbfatal "cannot read the agency/atcd-boot-confirm digest from the signed \
index of atcd ${ATCD_VERSION}."
    [ "$index_guard" = "sha256:${ATCD_GUARD_SHA256}" ] ||
        bbfatal "the signed index of atcd ${ATCD_VERSION} does not name the guard \
${ATCD_GUARD_SHA256}. ATCD_GUARD_SHA256 must be the digest of \
agency/atcd-boot-confirm in atcd-release/index.json."
}

do_install() {
    install -d ${D}${ATCD_LIBEXEC}
    install -m 0755 ${WORKDIR}/${ATCD_GUARD_FILE} ${D}${ATCD_GUARD_PATH}

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

# The guard and the service are in their own packages, so each keeps its open
# license and ${PN} holds the closed-source binary only. ${PN} depends on both,
# so an image that installs atcd gets all three.
PACKAGES =+ "${PN}-boot-confirm ${PN}-service"
FILES:${PN}-boot-confirm = "${ATCD_GUARD_PATH}"

# Subordinate ids for atc-hooks, for rootless podman in hooks. A --system
# user gets none from useradd. Written into the image at rootfs time only. On
# a device that already has an entry, nothing changes.
pkg_postinst:${PN}-service() {
    for f in $D${sysconfdir}/subuid $D${sysconfdir}/subgid; do
        touch "$f"
        grep -q '^atc-hooks:' "$f" ||
            echo "atc-hooks:${ATC_HOOKS_SUBID_BASE}:65536" >> "$f"
    done
}

# /var/atc is NOT in the package. It is the mount point of the data
# partition. systemd-tmpfiles sets its owner and mode at boot (atcd.conf), and
# atcd-store-seed fills it.
FILES:${PN} = "${ATCD_REMOTE_PATH}"
FILES:${PN}-service = "${ATCD_LINK_PATH} \
    ${systemd_system_unitdir} ${libexecdir}/atcd ${nonarch_libdir}/tmpfiles.d \
    ${sysconfdir}/sudoers.d ${localstatedir}/lib/systemd/linger"

RDEPENDS:${PN} += "${PN}-boot-confirm ${PN}-service"
# The sudoers rule needs sudo.
RDEPENDS:${PN}-service += "sudo"

# The release binary is a static musl ELF: it has no dynamic dependencies for
# bitbake to resolve, and it is not built by this recipe's toolchain.
INSANE_SKIP:${PN} += "already-stripped arch staticdev ldflags"
