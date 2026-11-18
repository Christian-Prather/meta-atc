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
ATCD_TRACK = "stable"
ATCD_VERSION = "0.2.4"
ATCD_SHA256:x86-64 = "064ae9ad..."
ATCD_SHA256:aarch64 = "9cfeda11..."
```

`do_fetch` downloads the binary from `https://atc.dev/agency/blobs/sha256/<sha256>`
and checks its sha256. `do_compile` then runs `install-atcd.sh` with no network
access, against the signed index of the release in
`recipes-core/atc/files/atcd-release/`. The script checks the index signature,
the track, the version and the binary's sha256 before the recipe installs it.

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

2. Read the version and the two atcd digests from the index:

   ```sh
   python3 -c 'import json; d = json.load(open("index.json")); print(d["track"], d["version"]); [print(t, e["digest"]) for t, e in sorted(d["artifacts"]["agency/atcd"].items())]'
   ```

3. Set `ATCD_TRACK` and `ATCD_VERSION` to those values. Set
   `ATCD_SHA256:x86-64` to the `linux-x86_64-musl` digest and
   `ATCD_SHA256:aarch64` to the `linux-aarch64-musl` digest, without the
   `sha256:` prefix.

4. Run `tests/run.sh`. The recipe gate fails when the recipe and the index do
   not agree. The build checks the signature.

For another track, replace `stable` in the URLs and set `ATCD_TRACK` to match.

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
no text. The recipe makes two packages:

| Package | Holds | License |
|---|---|---|
| `atcd` | the atcd binary | `CLOSED` |
| `atcd-boot-confirm` | the boot-confirm guard | `MIT \| Apache-2.0` |

`atcd` depends on `atcd-boot-confirm`, so `IMAGE_INSTALL += "atcd"` installs
both.

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
