# meta-atc

A Yocto layer that builds an atc-managed device image. The image carries atcd
and its boot-confirm guard. With the `rauc` distro feature, the layer also
builds an A/B image and a signed RAUC bundle that updates it.

## Requirements

- poky `scarthgap`
- `meta-rauc`. `LAYERDEPENDS` names it, so a build without it fails at parse
  time
- `meta-tegra`, only for an NVIDIA Jetson machine

`conf/layers.pin` names the tested commit of each layer.
`scripts/checkout-layers.sh` checks them out. Add `--for tegra234` to include
meta-tegra.

## Add the layer

```sh
bitbake-layers add-layer /path/to/meta-atc
```

The layer needs systemd and its own configuration. Set this in `local.conf`, or
in a distro conf. It changes the init system of every image in the build
directory:

```
INIT_MANAGER = "systemd"
require conf/distro/include/atc.inc
```

`atc.inc` sets the `atc` distro feature, which turns on the layer's changes to
recipes of other layers (GRUB, the kernel, RAUC, the meta-tegra BSP), and the
Jetson flash layout. Without it, adding the layer changes no other recipe, and
the atc images are skipped.

The atcd binary is closed-source. A product must also accept its license. See
[atcd license](#atcd-license).

With the feature, each machine gets these changes to other layers' recipes:

| Recipe | `qemux86-64` | `qemuarm64` | `tegra234` |
|---|---|---|---|
| `grub-efi` | `echo`, `reboot` and `regexp` built in | none | none |
| `linux-yocto` | the i6300esb watchdog driver built in | none | not built |
| `rauc` | version `ATC_RAUC_VERSION`, the atc D-Bus policy, no `rauc-mark-good` | the same | the same |
| `rauc-native`, `nativesdk-rauc` | version `ATC_RAUC_VERSION` | the same | the same |
| `rauc-conf` | the GRUB `system.conf` and the keyring | the GRUB `system.conf` and the keyring | the nvbootctrl `system.conf` and the keyring |
| meta-tegra BSP | none | none | the redundant flash layout, one boot per trial, a 4 GiB `UDA`, `panic=5`, and the flash tools under qemu on an arm64 build host |

The layer picks the RAUC version, because atcd drives RAUC. `atc.inc` sets
`ATC_RAUC_VERSION` and the `PREFERRED_VERSION` of `rauc`, `rauc-native` and
`nativesdk-rauc` to it. The layer skips every other version of these three
recipes. If meta-rauc has no recipe of that version, a build that needs RAUC
stops with "Nothing PROVIDES" and names the version. It does not fall back to
the git recipe.

## Set the machine

Set `MACHINE` in `local.conf`:

```
MACHINE = "qemux86-64"
```

| Machine | Slot backend |
|---|---|
| `qemux86-64` | GRUB |
| a meta-tegra `tegra234` machine, for example `jetson-orin-nano-devkit-nvme` | NVIDIA boot control (`nvbootctrl`) |
| every other machine, for example `qemuarm64` or a product BSP | none |

The layer selects the slot backend from the machine. You do not set it.
`classes/atc-slot-backend-map.bbclass` holds the list.

A machine with no backend gets `atc-image` and atcd, but no A/B update path.
bitbake skips `atc-image-ab`, `atc-image-slot`, `atc-bundle` and `atc-os`, and
gives the reason. The layer leaves the `rauc`, `rauc-conf` and `grub-efi`
recipes as their layers wrote them, so a product BSP keeps its own RAUC
configuration.

To set `MACHINE` from the environment instead, add it to the passthrough list.
Otherwise bitbake drops it and builds `local.conf`'s machine without a warning:

```sh
export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-} MACHINE"
MACHINE=qemux86-64 bitbake atc-image
```

## atcd

The layer does not compile atcd. The image gets the atcd release that the
recipe pins, not the newest release. `recipes-core/atc/atcd_0.1.0.bb` pins
the track, the version and the sha256 of each target's binary:

```
ATCD_TRACK = "nightly"
ATCD_VERSION = "0.2.6-rc.202611202013.g2c7d0dfbc381"
ATCD_SHA256:x86-64 = "0eec49f3..."
ATCD_SHA256:aarch64 = "539859d5..."
ATCD_GUARD_SHA256 = "f91e86a5..."
ATCD_PODMAN_SHA256:x86-64 = "5b021086..."
ATCD_PODMAN_SHA256:aarch64 = "54f42723..."
ATCD_INSTALLER_SHA256 = "394dbf8f..."
```

`do_fetch` downloads four files from `https://atc.dev/agency/blobs/sha256/<sha256>`
and checks the sha256 of each: the binary, the boot-confirm guard,
`install-atcd.sh` and the podman bundle (see "podman helpers" below). The layer keeps no copy of the guard or of the script.
`do_compile` then runs `install-atcd.sh` with no network access, against the
signed index of the release in `recipes-core/atc/files/atcd-release/`. The
script checks the index signature, the track, the version and the binary's
sha256. `do_compile` then checks that the signed index names the guard's
sha256 and the podman bundle's sha256, so both are of the same release.

`ATCD_INSTALLER_SHA256` stays pinned in the layer, also when you follow a
track: the script verifies the index, so it must not come from one.

The pin is in the task signature. A new pin rebuilds atcd and the images. An
unchanged pin reuses sstate. With the binary in `DL_DIR` or a mirror, the build
works with `BB_NO_NETWORK = "1"`.

### Take a new atcd release

1. Download the signed index of the track. Do not edit the two files: the
   signature covers their exact bytes.

   ```sh
   cd recipes-core/atc/files/atcd-release
   curl -fsSLO https://atc.dev/agency/stable/index.json
   curl -fsSLO https://atc.dev/agency/stable/index.json.sig
   ```

2. Read the version and the digests from the index:

   ```sh
   python3 -c 'import json; d = json.load(open("index.json")); print(d["track"], d["version"]); [print(p, t, e["digest"]) for p in ("agency/atcd", "agency/atcd-boot-confirm", "agency/install-atcd", "agency/podman") for t, e in sorted(d["artifacts"][p].items())]'
   ```

3. Set `ATCD_TRACK` and `ATCD_VERSION` to those values. Set
   `ATCD_SHA256:x86-64` to the `linux-x86_64-musl` digest,
   `ATCD_SHA256:aarch64` to the `linux-aarch64-musl` digest and
   `ATCD_GUARD_SHA256` to the `agency/atcd-boot-confirm` digest, without the
   `sha256:` prefix. Set `ATCD_PODMAN_SHA256:x86-64` and
   `ATCD_PODMAN_SHA256:aarch64` to the two `agency/podman` digests the same
   way. A new podman digest changes the helper directory in the image. Change `ATCD_INSTALLER_SHA256` only to take a new
   `install-atcd.sh`. Read the script at
   `https://atc.dev/agency/blobs/sha256/<sha256>` before you pin it.

4. Run `tests/run.sh`. The recipe gate fails when the recipe and the index do
   not agree. The build checks the signature.

For another track, replace `stable` in the URLs and set `ATCD_TRACK` to match.

### Follow a track (development only)

To get each new atcd release with no pin change, name the track in
`local.conf`:

```
ATCD_FOLLOW_TRACK = "nightly"
```

Each parse then reads the current signed index of that track, as
`SRCREV = "${AUTOREV}"` reads a branch head. The recipe sets `ATCD_TRACK` to
that track, and takes `ATCD_VERSION` and both `ATCD_SHA256` values from the
index. It takes `ATCD_GUARD_SHA256` from the `agency/atcd-boot-confirm` entry,
and both `ATCD_PODMAN_SHA256` values from the `agency/podman` entry. A release
with no guard entry or no podman entry skips the recipe.

Do not set `ATCD_TRACK` in `local.conf`: the recipe pins it, so the recipe's
value wins. A new release changes the task signature, so the next build
rebuilds atcd and the image. An unchanged release
reuses sstate. The index and its signature are kept in
`${DL_DIR}/atcd-follow/<track>/<version>/`, and `do_compile` checks the
signature with `install-atcd.sh`, as for a pin.

Know the cost before you turn it on:

- The same layer commit builds a different atcd after each release. You
  cannot rebuild an old image from its commit, so do not use this for a
  product image. Read the atcd version that a build took from its log, or with
  `bitbake -e atcd | grep ^ATCD_VERSION=`.
- The parse needs network access. With `BB_NO_NETWORK = "1"`, or with
  `BB_ALLOWED_NETWORKS` set without `atc.dev`, bitbake skips the recipe and
  names the reason.
- bitbake parses the recipe on each run, so each run reads the index once.

`ATCD_BASE_URL` (default `https://atc.dev/agency`) and `ATCD_FOLLOW_DIR`
(default `${DL_DIR}/atcd-follow`) change where the index comes from and where
it is kept.

### Fetch credential

The atcd download can carry a credential. Today the credential is optional:
the blob server accepts a download without one. The atc maintainers may
require a credential later. A build with no credential then fails in
`do_fetch` with an HTTP 401 error.

The credential is a login and a token for HTTP Basic authentication, in a
netrc file:

```
machine atc.dev login <organization id> password <token>
```

Do one of these:

- Put the line in `~/.netrc` of the build user. BitBake's wget fetcher reads
  that file. No setting is necessary.
- Put the line in a file named `.netrc` in another directory, for example a
  secret that your CI mounts. Then set the directory in `local.conf`:

  ```
  ATCD_NETRC_DIR = "/run/secrets/atc"
  ```

  The recipe runs wget for the atcd download with `HOME` set to that
  directory. Other recipes do not see it.

Give the file mode `0600`. Do not commit it.

The token is not in the metadata. It is not in the task signature, sstate,
the logs or `bitbake -e` output. `ATCD_NETRC_DIR` is not in the task
signature, so builders with different directories share sstate. Do not put
the token in `SRC_URI` with `user=` and `pswd=`: those parameters are in all
of those places. The recipe gate refuses them.

wget sends the login and the token only to the host that the netrc line names.
It sends them only after the server asks for them with a 401 response. A
premirror or a mirror gets no credential. A build that finds the binary in
`DL_DIR` or a premirror needs no credential.

`bitbake -c checkuri atcd` reads `~/.netrc` only. It does not use
`ATCD_NETRC_DIR`.

The contract that the blob server must keep:

- A `GET` of `https://atc.dev/agency/blobs/sha256/<sha256>` with no
  `Authorization` header, or with a credential that is not valid, gets
  `401` and `WWW-Authenticate: Basic realm="atc"`. Without that header, wget
  does not send the credential.
- A `GET` with `Authorization: Basic base64(<organization id>:<token>)` and a
  valid pair gets the blob, or a redirect to it. wget does not send the
  credential to the host of a redirect.

### atcd license

The layer's own files are MIT. The atcd binary is not. It is closed-source,
and the recipe declares it as `CLOSED`, Yocto's name for a license that ships
no text. The recipe makes four packages:

| Package | Holds | License |
|---|---|---|
| `atcd` | the atcd binary | `CLOSED` |
| `atcd-boot-confirm` | the boot-confirm guard | `MIT \| Apache-2.0` |
| `atcd-service` | the users, `atcd.service`, the store seed and the configuration files | `MIT` |
| `atcd-podman-helpers` | `newuidmap` and `newgidmap` from the podman bundle | `BSD-3-Clause & MIT` |

`atcd` depends on the other three, so `IMAGE_INSTALL += "atcd"` installs all
four. The podman helpers are shadow-utils (BSD-3-Clause), linked static with
musl (MIT).

The recipe sets `LICENSE_FLAGS = "commercial_atcd"`. To accept the license,
set this in `local.conf` or in the product's distro conf:

```
LICENSE_FLAGS_ACCEPTED += "commercial_atcd"
```

Without it, bitbake skips the atcd recipe at parse time:

```
ERROR: Nothing RPROVIDES 'atcd' (but .../atc-image.bb RDEPENDS on or otherwise requires it)
atcd was skipped: Has a restricted license 'commercial_atcd' which is not listed in your LICENSE_FLAGS_ACCEPTED.
```

`atc.inc` does not accept the license for you: the choice is the product's.
Bitbake also accepts the flag when `LICENSE_FLAGS_ACCEPTED` holds the plain
word `commercial`. The build scripts in `scripts/` accept it in the
`local.conf` they write.

### What the image carries

The image starts atcd at boot. The `atcd-service` package carries what a
device-side install of atcd would write:

- the users `atc` and `atc-hooks` and the group `atc`, with fixed ids (2000,
  2001 and 2000);
- `atcd.service`, enabled, and the boot-confirm guard it runs first;
- the owner and mode of the store root `/var/atc`, set by systemd-tmpfiles at
  boot;
- the `/usr/local/bin/atcd` link, the sudoers rule, subordinate ids and linger
  for `atc-hooks`.

The store is on the data partition. At the first boot on an empty store,
`atcd-store-seed.service` copies the image's atcd into it. atcd then updates
itself inside the store. A later image does not replace the store's atcd.

The subordinate ids of `atc-hooks` (`atc-hooks:1879048192:65536` in
`/etc/subuid` and `/etc/subgid`) are for rootless podman in hooks. The package
postinst writes them into the image, and `atcd-hook-subids.service` writes them
again at each boot when a file has no `atc-hooks` line. The boot unit is
necessary on a `read-only-rootfs` image: that image feature removes the
`shadow` package, which owns both files, so they are not in the image. The unit
writes them on the writable `/etc` (for example an `overlayfs-etc` overlay). On
a read-only `/etc` the unit fails, and its log names the file.

### podman helpers

Rootless podman needs the setuid helpers `newuidmap` and `newgidmap`.
`atcd ctl setup-rootless --provision` installs them as root when the device
has none. It cannot do that on a `read-only-rootfs` image. So the
`atcd-podman-helpers` package puts them into the image, and atcd finds them
there and installs nothing.

The path contract with atcd. `<D>` is the `agency/podman` digest of the
pinned release for the target, 64 lowercase hex characters without
`sha256:`:

| Path | Owner | Mode |
|---|---|---|
| `/usr/local/libexec/atc-podman/` | `root:root` | `0755` |
| `/usr/local/libexec/atc-podman/helpers/` | `root:root` | `0755` |
| `/usr/local/libexec/atc-podman/helpers/<D>/` | `root:root` | `0755` |
| `.../helpers/<D>/newuidmap` | `root:atc` (gid 2000) | `04750` |
| `.../helpers/<D>/newgidmap` | `root:atc` (gid 2000) | `04750` |

Nothing else is under `atc-podman/`: no pin file, no shim, no lock file. The
bytes are `bin/newuidmap` and `bin/newgidmap` of the podman bundle. Their
sha256 and size equal the entries for those paths in the signed manifest.
`do_compile` refuses the build otherwise. With mode `04750` and group `atc`,
members of group `atc` can run them. Other users cannot.

The tree is on the rootfs. It is never on `/var/atc` or other storage that
`atc` can write: root must not run a file that a non-root account can write.
Before it uses the helpers, atcd checks that each directory up to `/` belongs
to root and has no group or world write bit. It checks the modes and the
owners above, and that the files have no ACL. It also checks that their
sha256 equals the signed manifest of the active podman bundle.

Know the limit: atcd uses the image's helpers only while the device's active
podman bundle digest is `<D>`. When atcd takes a newer podman bundle, the
image's helpers no longer match, and a read-only device needs a new image with
the new pin. To take a new bundle, follow "Take a new atcd release" above: it
sets `ATCD_PODMAN_SHA256` from the index.

## Build

| Target | Output |
|---|---|
| `atc-image` | a bootable image: systemd, sshd, sudo, a deploy user, atcd |
| `atc-image-ab` | the same system on an A/B slot layout, for the factory flash |
| `atc-bundle` | a signed RAUC bundle that updates one slot of `atc-image-ab` |

```sh
bitbake atc-image
```

An A/B build needs the `rauc` distro feature, an OS version, and signing keys.
The keys are not in this layer. For a test build,
`scripts/rauc-test-keys.sh <dir>` makes a test CA and a signing pair in
`<dir>`. A product signs with its own keys. Supply them:

```
DISTRO_FEATURES:append = " rauc"
ATC_OS_VERSION = "2026.11.09-1"
RAUC_KEYRING_FILE = "/abs/path/ca.cert.pem"
RAUC_KEY_FILE = "/abs/path/signing.key.pem"
RAUC_CERT_FILE = "/abs/path/signing.cert.pem"
```

```sh
bitbake atc-image-ab atc-bundle
```

Write `atc-image-ab` to a device once. Update it with `atc-bundle` after that. A
whole-disk image written to a running device erases its store and its identity.

## Settings

| Variable | Default | Effect |
|---|---|---|
| `ATC_DEPLOY_USER` | `atc-deploy` | the account that atc logs in as |
| `ATC_DEPLOY_SSH_KEY` | empty | an SSH public key to install for that account |
| `ATC_UID`, `ATC_GID`, `ATC_HOOKS_UID` | `2000`, `2000`, `2001` | the ids of `atc`, its group and `atc-hooks`. Every image of one fleet must use the same values |
| `ATC_OS_VERSION` | empty | the version that the bundle and `/etc/atc-os-version` carry |
| `ATC_SLOT_KIB` | `1048576` | the size limit of one rootfs slot, in KiB |
| `ATC_TEST_RECIPES` | empty | `1` lets the fault bundles and images under `recipes-test/` build. They are signed with `RAUC_KEY_FILE` and do not boot, so set it only with test keys |
| `ATC_TEGRA_REDUNDANT` | `1` | `0` selects meta-tegra's single-rootfs layout. The A/B targets are then skipped |
| `ATCD_NETRC_DIR` | empty | a directory with a `.netrc` file for the atcd download. See "Fetch credential" |

Set them in `local.conf`, or in `conf/auto.conf` when a script writes
`local.conf`.

## Repository layout

The repository root is the layer root. `scripts/` holds build drivers and
repository checks. `tests/` holds their tests. Neither is layer content.

## Test

```sh
tests/run.sh
```

This runs every check that needs no Yocto build. CI runs the same command.

## Contributing

Send patches as pull requests to
<https://github.com/Christian-Prather/meta-atc>. Run `tests/run.sh` first.

Maintainer: Christian Prather <christian@agencytool.company>

## License

The layer is MIT. See [LICENSE](LICENSE). The atcd binary that the layer
downloads is closed-source. See [atcd license](#atcd-license).
