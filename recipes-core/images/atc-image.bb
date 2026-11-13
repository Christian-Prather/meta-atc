SUMMARY = "Minimal image an atc controller can bootstrap and push to"
DESCRIPTION = "A core image with systemd as init, an SSH server, sudo, and a \
deploy user in the atc group. `atc bootstrap atcd install` reaches this image \
over SSH, renders the systemd unit, and seeds the store-managed atcd."
LICENSE = "MIT"

inherit core-image extrausers

# The Tegra image settings. Each line in the file carries a Tegra override, so a
# qemu build reads nothing from it.
require recipes-core/images/atc-tegra.inc

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL += " \
    atcd \
    sudo \
    shadow \
    util-linux \
    coreutils \
    "

# atc requires systemd: the daemon runs as a systemd service and the boot-confirm
# guard is an ExecStartPre. A sysvinit image cannot host it.
#
# The distro conf normally sets this. It is asserted here so a sysvinit distro
# fails at parse time with a reason, rather than producing an image that boots
# and then cannot run atcd. Keyed on DISTRO_FEATURES, which is what actually
# decides whether systemd is available to install.
python __anonymous() {
    features = (d.getVar('DISTRO_FEATURES') or '').split()
    if 'systemd' not in features:
        bb.fatal("atc-image needs 'systemd' in DISTRO_FEATURES. atcd runs as a "
                 "systemd unit whose ExecStartPre is the A/B boot-confirm guard, "
                 "so a sysvinit image cannot host it.")
}

# The deploy account the controller logs in as. It must be in the `atc` group,
# which the atcd service user owns: `atcd attach` execs the store-managed binary
# as this user, and every store directory is group-traversable, not world.
# See consts.rs::grant_traverse_snippet.
ATC_DEPLOY_USER ?= "atc-deploy"

# A FIXED uid. An OS update carries the deploy user's ~/.ssh into the new slot,
# and sshd refuses a key whose owner is not the account. Two images that
# allocated the uid in another order would lock every operator out.
ATC_DEPLOY_UID ?= "2010"

# Password login is disabled: the password field is `*`, which no password
# matches. The operator installs an SSH public key; a build that needs one
# baked in sets ATC_DEPLOY_SSH_KEY. NOT `usermod -L`: that writes `!`, and this
# image's sshd (no PAM) then refuses EVERY login to the account, a key login
# included. Measured on the qemu A/B image: `Permission denied (publickey,
# password)` with `!`, a key login with `*`.
ATC_DEPLOY_SSH_KEY ?= ""

# `atc` is the only supplementary group, and it is created here because nothing
# else does. Deliberately NOT `-G atc,sudo`: a `sudo` group is a Debian
# convention that Yocto's sudo package does not create, so useradd would fail on
# an unknown group and the deploy account would never exist. Sudo rights come
# from the drop-in below, which grants them by USERNAME and needs no group.
EXTRA_USERS_PARAMS = "\
    groupadd -f atc; \
    useradd -m -u ${ATC_DEPLOY_UID} -G atc -s /bin/sh ${ATC_DEPLOY_USER}; \
    usermod -p '*' ${ATC_DEPLOY_USER}; \
    "

# Passwordless sudo for the deploy user: `atc bootstrap atcd install` runs the
# privileged installer over the same SSH session.
ATC_SUDOERS_FILE = "${IMAGE_ROOTFS}${sysconfdir}/sudoers.d/atc-deploy"

atc_install_deploy_sudoers() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/sudoers.d
    echo "${ATC_DEPLOY_USER} ALL=(ALL) NOPASSWD: ALL" > ${ATC_SUDOERS_FILE}
    chmod 0440 ${ATC_SUDOERS_FILE}
}

atc_install_deploy_ssh_key() {
    if [ -z "${ATC_DEPLOY_SSH_KEY}" ]; then
        return
    fi
    ssh_dir="${IMAGE_ROOTFS}/home/${ATC_DEPLOY_USER}/.ssh"
    install -d -m 0700 "${ssh_dir}"
    echo "${ATC_DEPLOY_SSH_KEY}" > "${ssh_dir}/authorized_keys"
    chmod 0600 "${ssh_dir}/authorized_keys"

    # This step runs in do_image under pseudo, so the files land owned by
    # root. sshd refuses a key it does not trust the ownership of, and
    # StrictModes rejects a .ssh whose owner is not the logging-in user. So an
    # unfixed owner silently blocks the bootstrap this key exists to enable.
    #
    # Resolve the IDs from the rootfs's OWN /etc/passwd. The deploy account is
    # created by EXTRA_USERS_PARAMS inside the image, so its uid/gid exist only
    # there. A host `install -o` would need a host account of the same name and
    # would fail, or worse, pick a different id that happens to exist.
    deploy_uid=$(awk -F: -v u="${ATC_DEPLOY_USER}" '$1==u{print $3}' \
        "${IMAGE_ROOTFS}${sysconfdir}/passwd")
    deploy_gid=$(awk -F: -v u="${ATC_DEPLOY_USER}" '$1==u{print $4}' \
        "${IMAGE_ROOTFS}${sysconfdir}/passwd")
    if [ -z "$deploy_uid" ] || [ -z "$deploy_gid" ]; then
        bbfatal "could not resolve ${ATC_DEPLOY_USER} in the rootfs passwd; \
the SSH key would be left with the build user's ownership and sshd would \
refuse it."
    fi
    chown -R "$deploy_uid:$deploy_gid" "$ssh_dir"
}

# The image must NOT pre-create /var/atc. `atcd install-self` creates it with the
# modes the traverse-grant walk expects; a hardened umask otherwise gives 0700
# directories and `atcd attach` fails EACCES. This check fails the build if some
# other recipe adds it.
atc_refuse_prebuilt_store_root() {
    if [ -e "${IMAGE_ROOTFS}/var/atc" ]; then
        bbfatal "/var/atc exists in the rootfs. It must be created by \
'atcd install-self' on the device, not baked into the image: a 0700 store root \
breaks 'atcd attach' with EACCES. See consts.rs::grant_traverse_snippet."
    fi
}

# `atc bootstrap atcd install` links /usr/local/bin/atcd into the store with a
# plain `ln -s`, and atc reaches atcd through that path over ssh. poky creates
# no /usr/local/bin, so without this the install fails with ATC-E0416.
atc_install_local_bin() {
    install -d -m 0755 ${IMAGE_ROOTFS}/usr/local/bin
}

# /var/tmp as a directory on the rootfs. poky's base-files links it into
# /var/volatile, which is a tmpfs, so a file staged there is lost at a reboot.
# VOLATILE_TMP_DIR does not change that link: it covers /tmp only.
# atc-tegra.inc runs this on tegra234. The qemu images keep poky's link.
atc_var_tmp_on_disk() {
    if [ -L ${IMAGE_ROOTFS}${localstatedir}/tmp ]; then
        rm ${IMAGE_ROOTFS}${localstatedir}/tmp
    fi
    install -d -m 1777 ${IMAGE_ROOTFS}${localstatedir}/tmp
}

# The deploy user's password field must be `*`. extrausers runs usermod with
# its failure ignored, so a broken edit would leave `!`, and sshd would then
# refuse the key login with no build error.
#
# An IMAGE_PREPROCESS step, not a ROOTFS_POSTPROCESS one: extrausers creates
# the user in a postprocess step that runs after this layer's, so the account
# does not exist yet there. Measured: the field read empty.
atc_assert_deploy_password_field() {
    field=$(awk -F: -v u="${ATC_DEPLOY_USER}" '$1==u{print $2}' \
        "${IMAGE_ROOTFS}${sysconfdir}/shadow")
    if [ "$field" != "*" ]; then
        bbfatal "${ATC_DEPLOY_USER}'s password field is '$field', not '*'. \
sshd refuses a key login to an account whose field starts with '!'."
    fi
}

# Both read the deploy user's entry, so both run after extrausers created it.
IMAGE_PREPROCESS_COMMAND += "atc_install_deploy_ssh_key atc_assert_deploy_password_field"

ROOTFS_POSTPROCESS_COMMAND += " \
    atc_install_local_bin \
    atc_install_deploy_sudoers \
    atc_refuse_prebuilt_store_root \
    "
