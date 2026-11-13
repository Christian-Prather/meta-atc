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

The layer needs systemd. Set this in `local.conf`. It changes the init system
of every image in the build directory:

```
INIT_MANAGER = "systemd"
```

## Set the machine

Set `MACHINE` in `local.conf`:

```
MACHINE = "qemux86-64"
```

| Machine | Slot backend |
|---|---|
| `qemux86-64` | GRUB |
| `qemuarm64` | none: `atc-image` only |
| a meta-tegra `tegra234` machine, for example `jetson-orin-nano-devkit-nvme` | NVIDIA boot control (`nvbootctrl`) |

The layer selects the slot backend from the machine. You do not set it.

To set `MACHINE` from the environment instead, add it to the passthrough list.
Otherwise bitbake drops it and builds `local.conf`'s machine without a warning:

```sh
export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-} MACHINE"
MACHINE=qemux86-64 bitbake atc-image
```

## Supply atcd

The layer does not compile atcd. By default, the atcd recipe downloads the
current `stable` release with `install-atcd.sh`. The script checks the
release signature and the binary's sha256 before the recipe installs it. The
build needs network access to `https://atc.dev`.

To pin a release, or to take another track:

```
ATCD_VERSION = "0.4.2"
ATCD_TRACK = "nightly"
```

Without `ATCD_VERSION`, the download runs on every build, so the image gets
the track's current release. With it, the build fails when the track serves
another version.

To build in your own atcd instead, point the layer at a static binary for the
target architecture:

```
ATCD_BINARY = "/abs/path/to/atcd"
```

For one `local.conf` that serves two architectures, set the per-architecture
names. Each takes priority over `ATCD_BINARY` on its own architecture:

```
ATCD_BINARY_X86_64 = "/abs/path/to/x86_64/atcd"
ATCD_BINARY_AARCH64 = "/abs/path/to/aarch64/atcd"
```

The build fails if the binary's architecture does not match the machine.

For an image with no atcd, set `ATCD_TRACK = ""`. The image then carries
only the guard, and `atc bootstrap atcd install` installs atcd on first
contact.

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
The keys are not in this layer. Supply your own:

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
| `ATCD_TRACK` | `stable` | the release track the atcd download takes. Empty: no atcd |
| `ATCD_VERSION` | empty | the atcd release to require. Empty: the track's current one |
| `ATCD_BINARY`, `ATCD_BINARY_X86_64`, `ATCD_BINARY_AARCH64` | empty | a prebuilt atcd to install in place of the download |
| `ATC_DEPLOY_USER` | `atc-deploy` | the account that atc logs in as |
| `ATC_DEPLOY_SSH_KEY` | empty | an SSH public key to install for that account |
| `ATC_OS_VERSION` | empty | the version that the bundle and `/etc/atc-os-version` carry |
| `ATC_SLOT_KIB` | `1048576` | the size limit of one rootfs slot, in KiB |
| `ATC_TEGRA_REDUNDANT` | `1` | `0` selects meta-tegra's single-rootfs layout. The A/B targets are then skipped |

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
Some checks compare the layer with the atc source. Point `ATC_MONOREPO` at a
checkout of it to run them too:

```sh
ATC_MONOREPO=/path/to/atc-source tests/run.sh
```
