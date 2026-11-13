# meta-atc

A Yocto layer that puts an atc-managed device in an image. It carries the atcd
binary and the boot-confirm guard. For qemux86-64 it also carries the OS tier.
That is an A/B disk that GRUB boots, RAUC to install an update into the other
slot, and a signed RAUC bundle as the update.

It also builds for the Jetson Orin family (Orin Nano, Orin NX, AGX Orin) on
OE4T meta-tegra. See "Jetson Orin" below.

## Repository layout

The repository root is the layer root. Two directories are not layer content:

| Path | Contents |
|---|---|
| `scripts/` | the builder-box drivers and the repository gates |
| `tests/` | the tests of the layer's scripts, and of the gates |

Consumers pin this layer to one commit. A change here reaches a build only
when its pin moves.

Some checks compare this layer with the atc source: the guard copy, the paths
in `consts.rs`, and the paths that bootstrap writes. They need a checkout of
that source, which this repository's CI does not have. See "Verification".

## Layer contents

| Path | Contents |
|---|---|
| `conf/layer.conf` | `BBFILE_COLLECTIONS`, `LAYERSERIES_COMPAT` |
| `dynamic-layers/tegra/` | appends to meta-tegra recipes, parsed only when meta-tegra is in the build: `panic=5` on the extlinux command line, and the wrapper that runs NVIDIA's i386 flash tools under qemu on an arm64 build host |
| `classes/atc-slot-backend.bbclass` | the slot backend seam: `ATC_SLOT_BACKEND` and the `atc-slot-<backend>` override |
| `recipes-core/atc/atcd_0.1.0.bb` | the atcd binary, per architecture, and the guard |
| `recipes-core/atc/files/` | a copy of the boot-confirm guard |
| `recipes-core/images/atc-image.bb` | systemd, sshd, sudo, a deploy user |
| `recipes-core/images/atc-image-ab.bb` | the same image on an A/B slot layout, disk-booted |
| `recipes-core/images/atc-image-slot.bb` | the same system, as the ext4 image of one slot |
| `recipes-core/images/atc-ab-runtime.inc` | what both A/B images share: mounts, RAUC, users, units |
| `recipes-core/images/atc-tegra.inc` | the image settings for tegra234 machines: the tegraflash archive |
| `recipes-core/bundles/atc-bundle.bb` | the OS update: the slot image in a signed RAUC verity bundle |
| `recipes-core/rauc/` | RAUC's `system.conf` for each slot backend, the keyring install, the D-Bus policy |
| `recipes-core/atc-os/` | the reboot request unit, the trial deadline, the pre-install guard, the GRUB trial predicate, the watchdog drop-in |
| `recipes-bsp/atc-grub-env/` | the A/B `grub.cfg` and its initial environment |
| `recipes-bsp/grub/` | the GRUB built-ins `grub.cfg` needs |
| `recipes-test/` | fault images and bundles for the qemu fault suite. Never ship them |
| `conf/layers.pin` | the pinned commit of each layer this one depends on |
| `wic/atc-ab.wks.in` | the GPT layout: ESP, two rootfs slots, a data partition |

Target machines: `qemux86-64`, `qemuarm64`, and the tegra234 machines of
meta-tegra (for example `jetson-orin-nano-devkit-nvme`).

## Pins

`LAYERSERIES_COMPAT` names `scarthgap`. Pin the poky branch and commit in your builder
configuration. "The current LTS" is not a pin.

`conf/layers.pin` pins every other layer to a 40-character commit. Today that is
`meta-rauc` on `scarthgap`, which carries RAUC 1.15.2. `LAYERDEPENDS_atc` names
`rauc`, so a build without `meta-rauc` fails at parse time.
`scripts/checkout-layers.sh` checks out each pinned commit under
`/cache/layers/`. `meta-rauc-community` stays out: its qemu layer carries
example keys and a GRUB recipe that conflicts with this one.

`meta-tegra` is pinned to `scarthgap` at `e7d217e24ca9`, which carries L4T
R36.5.2. Its pin line has a fifth field, `tegra234`. A plain
`checkout-layers.sh` leaves it out, and `checkout-layers.sh --for tegra234`
adds it. So a qemu build never parses meta-tegra. `layer.conf` names `tegra` in
`LAYERRECOMMENDS_atc`, not in `LAYERDEPENDS_atc`, so a build without meta-tegra
still parses.

## Add the layer

```sh
bitbake-layers add-layer /path/to/meta-atc
MACHINE=qemux86-64 bitbake atc-image
```

`MACHINE` in the environment is not enough on its own. bitbake builds its
datastore from a filtered copy of the environment. So the value must be on the
passthrough list. A value that is not on it is dropped, and the build then uses
`local.conf`'s machine without a warning:

```sh
export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-} MACHINE"
```

## The distro must use systemd

`atc-image` refuses to parse unless `systemd` is in `DISTRO_FEATURES`. atcd runs
as a systemd unit whose `ExecStartPre` is the boot-confirm guard, so a sysvinit
image cannot host it.

poky's default `DISTRO` is `poky`, which is **sysvinit**, so a stock build
directory fails at parse time with that message. Add one line to `local.conf`:

```
INIT_MANAGER = "systemd"
```

This changes the init system for every image in that build directory, which is
why the layer does not set it.

Supply a prebuilt atcd through `ATCD_BINARY` in `local.conf`. The builder
scripts (`qemu-rauc-proof.sh`, `tegra-build.sh`) write `local.conf` on every
run, so for them set the script's `ATCD_BINARY` input instead. The recipe
installs the static musl atcd from the atc release build. It does not rebuild
atcd, so the image carries the same bytes as the fleet.

Run `file` on the binary before you point a recipe at it:

```sh
file ./atcd   # want: "ELF 64-bit ... statically linked, stripped"
```

Then point the recipe at the result. For one machine, name the binary directly:

```
ATCD_BINARY = "/abs/path/to/atcd"
```

To serve both machines from one `local.conf`, set the per-architecture names.
Each is picked up by its matching machine, and takes priority over the plain
name there:

```
ATCD_BINARY_X86_64 = "/abs/path/to/x86_64/atcd"
ATCD_BINARY_AARCH64 = "/abs/path/to/aarch64/atcd"
```

Both may stay empty. The image then carries the guard alone, and
`atc bootstrap atcd install` seeds the binary on first contact.

## The OS update: a RAUC bundle

An OS update is a signed RAUC bundle, `atc-bundle-<machine>.raucb`. It carries
one ext4 slot image, `atc-image-slot`, which is the same system as `atc-image`
plus the A/B runtime profile. RAUC on the device checks the signature against
its keyring, the `compatible` string against `system.conf`, and every block it
reads through dm-verity. Then it writes the image into the slot that is not
booted, and puts that slot first in GRUB's `ORDER`.

Set these in `local.conf` before you build:

```
DISTRO_FEATURES:append = " rauc"
ATC_OS_VERSION = "2026.11.09-1"
RAUC_KEYRING_FILE = "/cache/atc-rauc-keys/ca.cert.pem"
RAUC_KEY_FILE = "/cache/atc-rauc-keys/signing.key.pem"
RAUC_CERT_FILE = "/cache/atc-rauc-keys/signing.cert.pem"
```

```sh
MACHINE=qemux86-64 bitbake atc-image-ab atc-bundle
```

`DISTRO_FEATURES` must carry `rauc`. That feature enables dm-verity, squashfs
and loop devices in the kernel, and a verity bundle cannot install without them.

**The keys are not in this layer.** Put test keys on the builder's `/cache`.
`scripts/qemu-rauc-proof.sh` refuses to build without them. The recipe gate
fails on any `*.pem`, `*.key` or `*.crt` in the layer. The production PKI is not
decided.

Four rules govern the slot image. Change one and the update path breaks.

| Rule | Why |
|---|---|
| ext4 | `system.conf` declares both slots `type=ext4` |
| No larger than the slot | RAUC writes it to a partition of a fixed size |
| Slot agnostic | GRUB selects the slot with `root=PARTLABEL=`, so the filesystem names none |
| Carries the kernel | GRUB reads the kernel from the slot, so a kernel upgrade rolls back with its rootfs |

`ATC_SLOT_KIB` declares the slot size, and both size gates read it. It defaults
to 1 GiB, which is what the A/B partition table gives each slot. A filesystem
smaller than its partition is valid, so treat the number as a ceiling.

**The bundle's post-install hook carries the device-local state.** `atc
bootstrap atcd install` writes `/etc/atc/`, the atcd unit and its drop-ins, a
sudoers file and subordinate ids per device, so no image carries them. RAUC
runs the hook with the new slot mounted, and the hook carries each of them into
it. A path the new image ships stays the new image's. atcd itself runs from the
store, which both slots mount.

The hook also carries three paths that keep the device reachable after the
switch:

- `/usr/local/bin/atcd`, the link atc runs over ssh;
- the sshd host keys, which sshd otherwise makes again at the slot's first
  boot, so every operator's ssh would refuse the device;
- `/home/*/.ssh`, the deploy user's key, unless the image ships one.

The hook also carries what `atcd --setup-rootless` wrote, when a device ran
it. That is the userns sysctl drop-in, the AppArmor profile `atc_podman`, and
the helpers and their pin in `/usr/local/libexec/atc-podman/`. The hook user's
delegate drop-in and linger record go with the bootstrap state. A device
that never ran setup gets none of them, so an update does not turn rootless on.
The image cannot ship the helpers: each device's copy is bound to the podman
digest active in its store.

The deploy user's password field is `*`, not `!`. This image's sshd refuses
every login to an account locked with `!`, a key login included.

**A whole-disk `.wic` is not an update.** It holds a partition table, an EFI
partition, both slots, and an empty data partition. Writing one to a running
device destroys the store, the device identity, and the running slot.

## The EFI partition is not A/B

The slot image carries the kernel and the root filesystem. It never carries
GRUB, `grub.cfg`, or the boot environment. So there is no bootloader update, and
a bad bootloader cannot arrive over the air.

The boot **data** on the EFI partition is one file, `atc/grubenv`. RAUC writes
it with `grub-editenv`, which writes a new file and renames it. A rename on FAT
is not atomic, so a power cut at that moment can lose the file. GRUB then falls
back to its defaults and boots slot A. The boot **code** is single-copy, and it
has no rollback. A bootloader change therefore needs a re-flash or physical
access, which is an attended operation.

A second EFI partition would need a UEFI `BootNext` path to use it. That is not
built.

## Design decisions

**The recipe installs no systemd unit.** The unit interpolates the store root,
the socket path, the service user, and the telemetry endpoint of one device. A
copy baked into an image therefore drifts from the unit that atc renders.
First-boot `atc bootstrap atcd install` renders it instead.

**The image does not pre-create `/var/atc`.** `atcd install-self` creates the
store with the modes the traverse-grant walk expects. A hardened `umask 077`
otherwise produces 0700 directories, and `atcd attach` then fails with EACCES.
`atc-image.bb` fails the build if any recipe adds that directory.

## Paths

These mirror the constants the daemon reads. A change on either side breaks the
other, so the drift test in `scripts/check-meta-atc-recipe.sh` pins them.

| Path | Declared in |
|---|---|
| `/var/atc` | `consts.rs::STORE_ROOT` |
| `/usr/local/libexec/atcd-boot-confirm.sh` | `consts.rs::GUARD_REMOTE_PATH` |
| `/usr/local/bin/atcd` | `schema_defaults.rs::default_daemon_remote_path` |
| `/etc/systemd/system/atcd.service` | rendered on the device, not by this layer |

## A/B slots on qemu

`atc-image` cannot demonstrate an A/B rollback. `runqemu` boots it with
`-kernel`, which skips the firmware and the on-disk
bootloader. There is no bootloader in that story to count a failed boot.

`atc-image-ab` is the same image on a disk that a bootloader reads. Four
partitions: the ESP with GRUB and the boot environment, two rootfs slots seeded
identical, and a 4 GiB data partition mounted at `/var/atc`. The store needs
that partition. An OS update replaces a whole slot. A store inside the slot
would lose the device id, the CAS, and the delivery history on every update.
The update itself lands in the store first, so the partition must hold a bundle
plus a 1 GiB margin.

RAUC drives the slots on the device. `rauc.slot=A` or `rauc.slot=B` on the
kernel command line names the booted slot:

```sh
rauc status                          # the booted slot, the primary, each slot good or bad
rauc install /var/atc/<bundle>.raucb # write the other slot and put it first
rauc status mark-good booted         # confirm the booted slot
```

Only root and user `atc`, which runs atcd, may call RAUC. The image replaces
RAUC's stock D-Bus policy, which lets every local user call it.

**A new slot boots once, on trial.** GRUB spends the trial before it hands off.
If nothing marks the slot good, the next boot reverts to the last confirmed
slot. `atc-os-trial-deadline.timer` reboots an unconfirmed trial 15 minutes
after boot, so a trial in which atcd never starts still reverts. A confirmed
slot does not revert on a later boot that misses a mark: GRUB counts only a
trial. The decision table is in the header of `atc-ab-grub.cfg`.

**The counter is in GRUB.** A kernel that panics never reaches
systemd, so `atcd-boot-confirm.sh` never runs and never counts that failure. The
userspace guard confirms the atcd BINARY. It is not a slot confirm, and it fails
open where the bootloader fails closed.

**atcd does not drive this yet.** The install and the mark are by hand on this
layer.

`scripts/qemu-rauc-proof.sh` runs the whole flow on the builder box.
It builds the disk and two bundles, one of version `<v>-prev` and one of `<v>`.
It fails unless the two bundles carry different slot-image digests, so a build
that reuses a stale slot image cannot pass. It boots the disk and installs the
`<v>` bundle into slot B. Then it checks that slot B boots, that its
`/etc/atc-os-version` reads `<v>`, and that RAUC marks it good. Two more
reboots check that slot B stays the booted slot.

`scripts/qemu-rauc-faults.sh` is the fault suite. It installs the
fault bundles from `recipes-test/`, makes each fault, and checks which slot
boots after it. The faults include a bad signature, no confirm, a kernel panic,
a watchdog reset and a power cut. Every branch of the `grub.cfg` decision has a
case. The script's header gives the commands.

## Jetson Orin

meta-atc defines no Orin machine. It builds on meta-tegra's machines as they
are, and keys every Tegra choice on the `tegra234` override that their
`tegra234.inc` sets. One code path covers Nano, NX and AGX.

### The slot backend seam

`classes/atc-slot-backend.bbclass` sets one variable and one override:

| `ATC_SLOT_BACKEND` | Machines | What counts a boot | RAUC `bootloader=` |
|---|---|---|---|
| `grub` (the default) | qemux86-64 | `grub.cfg`, one trial | `grub`, on `/boot/atc/grubenv` |
| `nvbootctrl` | tegra234 | NVIDIA's launcher | `custom`, `/usr/lib/rauc/atc-nvbootctrl-backend` |

A recipe that differs by backend inherits the class and keys the difference on
`atc-slot-grub` or `atc-slot-nvbootctrl`. The GRUB contract (wic,
`atc-ab.wks.in`, `EFI_PROVIDER`, `grub-editenv`, the ESP and data mounts) is
keyed on `atc-slot-grub`, so a Tegra build never pulls it in.

`atc-os` makes one call into the backend: `/usr/libexec/atc-os/atc-slot-trial`.
It prints the slot that is on trial and not marked good, or `none`, and exits
non-zero when it cannot read the boot state. `atc-os-pre-install` and
`atc-os-trial-deadline` ask it and read no boot state themselves. On
`atc-slot-grub`, atc-os installs `atc-slot-trial-grub` there. On
`atc-slot-nvbootctrl`, the `atc-nvbootctrl` package installs its own copy.

### Build an Orin image

Run `scripts/tegra-build.sh` on the builder box. It checks out the
layers with `--for tegra234`, writes the build directory's configuration, runs
bitbake, and checks the archive:

```sh
POKY_DIR=/opt/poky scripts/tegra-build.sh \
  --machine jetson-orin-nano-devkit-nvme --build-dir /cache/build-tegra atc-image
```

The artifact is `atc-image-<machine>.rootfs.tegraflash.tar.gz` in
`DEPLOY_DIR_IMAGE`. The script fails unless a flash layout in the archive names
the `APP` and `APP_b` partitions. For an NVMe machine that layout is
`external-flash.xml.in`. Flash the archive from an x86-64 host, not from the
arm64 builder.

The script writes `conf/local.conf` on every run. Put your own settings in
`conf/auto.conf` of the build directory, which bitbake reads and the script
never writes. The deploy account works as on qemu: set `ATC_DEPLOY_USER` and
`ATC_DEPLOY_SSH_KEY` there.

The script's `ATCD_BINARY` input names the aarch64 atcd. Its default is
`<cache>/atcd-aarch64`, which is `/cache/atcd-aarch64` on the builder box. The
script refuses to build without it, and prints its sha256 and its `file` type.
Copy the static aarch64 atcd to that path on the box, or set `ATCD_BINARY` to
another path.

On tegra234, `/var/tmp` is a directory on the rootfs, not poky's link into the
`/var/volatile` tmpfs. So a file staged there survives a reboot.

The flash layout is NVIDIA's redundant one: two rootfs partitions, `APP` and
`APP_b`, each paired with one QSPI bootloader chain. `conf/layer.conf` sets it
for every recipe of the build, because the UEFI firmware and the capsule read it
as well as the image. The same file adds an overlay that sets
`RootfsRetryCountMax` to 1, so a new slot gets one boot.

To build meta-tegra's single-`APP` layout, set `ATC_TEGRA_REDUNDANT = "0"` in
the build directory's `conf/auto.conf`. A plain
`USE_REDUNDANT_FLASH_LAYOUT_DEFAULT = "0"` does nothing: layer.conf sets that
variable with a `:tegra234` override, and an override wins over the plain
variable. With the single-`APP` layout, `atc-image` builds, and `atc-image-ab`
and `atc-bundle` are skipped with the reason, because the nvbootctrl backend
needs `APP_b`.

`atc-image` on Orin carries no RAUC. It keeps NVIDIA's
`nv_update_verifier.service`, which confirms each boot.

The A/B image (`atc-image-ab` on `atc-slot-nvbootctrl`) installs
`atc-nvbootctrl` and RAUC's `system-nvbootctrl.conf`. Its slots are `APP` (A)
and `APP_b` (B), and its `compatible` is `atc-${MACHINE}`, so an Orin NX bundle
cannot reach an Orin Nano.

The store is on `UDA`, outside both slots, mounted on
`/var/atc`. A meta-tegra append grows `UDA` from NVIDIA's 400 MiB to 4 GiB.
Every factory flash writes an empty ext4 to it (`atc-uda.ext4`, through
meta-tegra's `DATAFILE`). systemd grows that filesystem to the partition at the
first boot. The mount has `nofail`: a `UDA` that cannot mount does not stop
the boot in emergency mode. The board then boots without its store, and stays
reachable over ssh.

### Firmware and rootfs switch together

The bundle carries `tegra-bl.cap`, the UEFI capsule that `tegra-uefi-capsules`
builds from the same BSP as the slot image. An install runs in this order:

1. RAUC writes the slot image to the inactive `APP` partition.
2. The bundle hook runs `atc-tegra-capsule stage`. It writes the capsule to
   `/boot/efi/EFI/UpdateCapsule/TEGRA_BL.Cap`, bound to the slot it wrote, and
   does not arm it. On a Jetson the hook refuses a bundle with no capsule.
3. RAUC calls the backend's `set-primary` for that slot. Its last step arms
   the capsule: bit 2 of the UEFI variable `OsIndications`.
4. At the reboot, UEFI writes the capsule into the inactive bootloader chain
   and boots that chain. The rootfs slot follows the chain.

**Not yet proven on hardware:** UEFI reads the capsule from the `esp` partition
whichever chain is current, and the layout's `esp_alt` stays empty. No NVIDIA or
meta-tegra source settles it. An install from slot B to slot A on a board
proves or refutes it.

A capsule with no `OsIndications` bit applies nothing. So an install that stops
before step 3 changes nothing at the next reboot, and the next install replaces
the staged file. The boot unit clears the bit at every boot, so a capsule
applies at the one reboot after its install and never later. A capsule staged
for one slot never arms for the other.

NVIDIA's flash tools are i386 executables. On the arm64 builder, a meta-tegra
append runs them under qemu-native.

### The boot partition is a single point of failure

The redundant layout doubles the QSPI bootloader chains and the rootfs. These
parts stay single:

| Part | What it holds | Written in the field | If it is lost |
|---|---|---|---|
| ESP (`esp` on NVMe) | `BOOTAA64.efi`, the L4T launcher; `EFI/UpdateCapsule/` | only the capsule file, during an install | a USB recovery flash, unless UEFI boots `esp_alt`. The R36.5.2 NVMe layout has an `esp_alt` partition, and no test has shown that UEFI falls back to it |
| the UEFI variable store in QSPI | `RootfsStatusSlotA/B`, `BootChainFwNext`, `AtcSlotState` | on every install, confirm and boot | NVIDIA's fault-tolerant write protects one update. An empty store boots chain A |
| the NVMe partition table | the partitions | never | a USB recovery flash |
| `UDA`, the store | atcd's identity, CAS and history | always | the board boots and loses its enrollment |

The ESP is the Tegra form of the qemu ESP, which is single too (see "The EFI
partition is not A/B"). Two rules keep the risk small:

- Only the capsule write touches the ESP in the field. It writes a temporary
  file, syncs, and renames, so a power cut leaves no capsule or a whole one.
  Nothing writes the launcher after the factory flash.
- No slot image carries ESP content, so a bad bundle cannot reach the launcher.

A second ESP needs a custom layout and a boot-order policy. It is not built.

## Verification

One command runs every check that needs no builder. CI runs the same command:

```sh
tests/run.sh
```

It runs these checks:

- the recipe gate against the real layer, and its self-test. The self-test
  mutates each guard and requires the gate to fail;
- the A/B slot contract gate against the real layer, and its self-test;
- the self-test of each builder-box driver in `scripts/`;
- the tests of the atc-os, nvbootctrl, capsule and bundle-hook scripts, against
  fakes of what they call;
- the bounded model check of the nvbootctrl backend.

The gate self-tests and the tree checks are both needed. A self-test alone
proves only that a gate can fail. Without the tree check, real drift lands
green.

Without a checkout of the atc source, two parts do not run, and the output
says so:

- check 1 of the recipe gate (the guard copy), and the source half of check 2
  (the paths in `consts.rs` and `schema_defaults.rs`);
- part 1 of the bundle-hook test (coverage of the paths that bootstrap writes).

To run them here, point `tests/run.sh` at a checkout:

```sh
ATC_MONOREPO=/path/to/atc-source tests/run.sh
```

The layout gate reads the wks, `grub.cfg`, RAUC's `system.conf` and the D-Bus
policy. It also reads the bundle recipe, the runtime profile and the image
recipes. No other check reads these files together.

Every failure it catches still builds an image. A renamed partition label boots
to a GRUB rescue prompt. A bootname that differs
between `system.conf` and `grub.cfg` installs and never boots. A skipped
environment save never rolls back. A missing `QB_DEFAULT_KERNEL` boots a guest
that works and never reaches a bootloader.

A check of a **built rootfs** needs a Yocto builder, so it is not in this
repository. It asserts four things:

- the guard and the binary are present at the declared paths;
- the installed guard matches the atc source's `tools/scripts/atcd-boot-confirm.sh`;
- `readelf` reports the machine's architecture;
- `/var/atc` is absent.
