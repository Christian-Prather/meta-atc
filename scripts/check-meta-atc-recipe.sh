#!/usr/bin/env bash
# scripts/check-meta-atc-recipe.sh
#
# Repository-side gate for the meta-atc Yocto layer. Runs with no Yocto builder:
# it reads the recipes, and the atc sources the recipes copy or mirror, and
# fails when the two disagree.
#
# Three drift classes it catches:
#   1. the guard copy in this layer diverging from the atc source's
#      tools/scripts/atcd-boot-confirm.sh;
#   2. a recipe path diverging from the constant that declares it in the atc
#      source's crates/atc-cmd-bootstrap/src/bootstrap_daemon/consts.rs;
#   3. the image recipe losing its refusal to pre-create /var/atc.
#
# Classes 1 and 2 need a checkout of the atc source. Set ATC_MONOREPO to one.
# Without it the gate checks the recipe side of class 2 against the contract
# values below, skips class 1, and says so on stderr.
#
# It does NOT prove anything about a built rootfs. That check needs a Yocto
# builder.
#
# Usage: scripts/check-meta-atc-recipe.sh
#   META_ATC_ROOT   the layer to check. Defaults to this script's repository.
#   ATC_MONOREPO    a checkout of the atc source. Optional; see above.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER="$(cd "${META_ATC_ROOT:-$SCRIPT_DIR/..}" && pwd)"
MONO=""
if [ -n "${ATC_MONOREPO:-}" ]; then
  MONO="$(cd "$ATC_MONOREPO" && pwd)"
fi

GUARD_SRC="$MONO/tools/scripts/atcd-boot-confirm.sh"
GUARD_COPY="$LAYER/recipes-core/atc/files/atcd-boot-confirm.sh"
CONSTS="$MONO/crates/atc-cmd-bootstrap/src/bootstrap_daemon/consts.rs"
DEFAULTS="$MONO/crates/atc-config/src/schema_defaults.rs"
RECIPE="$LAYER/recipes-core/atc/atcd_0.1.0.bb"
IMAGE="$LAYER/recipes-core/images/atc-image.bb"
LAYER_CONF="$LAYER/conf/layer.conf"
TEGRA_INC="$LAYER/recipes-core/images/atc-tegra.inc"
PIN_FILE="$LAYER/conf/layers.pin"

# The on-device paths the recipes hardcode. The atc source owns them. With
# ATC_MONOREPO set, check 2 fails unless the Rust source holds these values.
WANT_STORE_ROOT="/var/atc"
WANT_LIBEXEC_DIR="/usr/local/libexec"
WANT_REMOTE_PATH="/usr/local/bin/atcd"

fail() {
  echo "check-meta-atc-recipe: $*" >&2
  exit 1
}

# rg exits 0 on match, 1 on no match, >=2 on an operational failure. A gate whose
# finding is "no match" must not read an unreadable file as a clean result, so
# >=2 aborts rather than returning empty.
#
# `search` prints matches and returns rg's 0/1. It must NOT swallow the status
# into a bare `return 0`: callers write `search ... || fail`, and a helper that
# always succeeds turns every one of those guards into a no-op that still reads
# like a check. Four guards here were dead exactly that way until the self-test
# mutated them and they stayed green.
search() {
  local pattern="$1" file="$2" out status
  set +e
  out="$(rg -n -e "$pattern" "$file" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ge 2 ]; then
    fail "rg failed (exit $status) on '$file': $out"
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# `search` returns 1 on no-match, which `set -e` would abort on when the caller
# only wants the text. Use this where absence is not itself a failure.
search_optional() {
  search "$@" || true
}

for f in "$GUARD_COPY" "$RECIPE" "$IMAGE" "$LAYER_CONF" "$PIN_FILE" "$TEGRA_INC"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
if [ -n "$MONO" ]; then
  for f in "$GUARD_SRC" "$CONSTS" "$DEFAULTS"; do
    [ -f "$f" ] || fail "missing required file in ATC_MONOREPO: $f"
  done
else
  echo "check-meta-atc-recipe: ATC_MONOREPO is not set. Skipped check 1 and the source half of check 2." >&2
fi

# 1. The guard copy must be byte-for-byte identical. The recipe installs the copy,
#    so a divergence puts a different guard on the device than the one the atc
#    binary embeds through include_str!.
if [ -n "$MONO" ] && ! cmp -s "$GUARD_SRC" "$GUARD_COPY"; then
  echo "check-meta-atc-recipe: the meta-atc guard copy has drifted." >&2
  diff -u "$GUARD_SRC" "$GUARD_COPY" >&2 || true
  fail "copy $GUARD_SRC to $GUARD_COPY"
fi

# 2. Every path the recipe hardcodes must match the constant that declares it.
#    Read the value out of the Rust source rather than restating it here: a
#    restated copy drifts silently, and this gate catches that.
# The value may sit on the declaring line (`const X: &str = "v";`) or on a later
# one (a `fn` returning `"v".into()`), so take the first quoted string at or after
# the declaration rather than assuming either shape.
extract_rust_str() {
  local name="$1" file="$2" start value
  start="$(search_optional "$name" "$file" | head -1 | cut -d: -f1)"
  [ -n "$start" ] || fail "could not find $name in $file"
  # One sed reads lines start to start+4 and quits on the first quoted string.
  # A `tail | head -5` pipe could close on tail mid-write, and pipefail then
  # failed the check on a long source file.
  value="$(sed -n "$start,$((start + 4))"'{/.*"\([^"]*\)".*/{s//\1/p;q;};}' "$file")"
  [ -n "$value" ] || fail "could not extract a string value for $name in $file"
  printf '%s' "$value"
}

store_root="$WANT_STORE_ROOT"
libexec_dir="$WANT_LIBEXEC_DIR"
remote_path="$WANT_REMOTE_PATH"
if [ -n "$MONO" ]; then
  store_root="$(extract_rust_str 'const STORE_ROOT' "$CONSTS")"
  guard_path="$(extract_rust_str 'const GUARD_REMOTE_PATH' "$CONSTS")"
  libexec_dir="$(extract_rust_str 'const LIBEXEC_DIR' "$CONSTS")"
  remote_path="$(extract_rust_str 'fn default_daemon_remote_path' "$DEFAULTS")"

  [ "$store_root" = "$WANT_STORE_ROOT" ] ||
    fail "STORE_ROOT is now '$store_root'; update meta-atc and this gate together"
  [ "$libexec_dir" = "$WANT_LIBEXEC_DIR" ] ||
    fail "LIBEXEC_DIR is now '$libexec_dir'; update meta-atc and this gate together"
fi

recipe_libexec="$(search_optional '^ATCD_LIBEXEC = ' "$RECIPE" | sed -n 's/.*"\(.*\)".*/\1/p')"
[ "$recipe_libexec" = "$libexec_dir" ] ||
  fail "ATCD_LIBEXEC='$recipe_libexec' but consts.rs LIBEXEC_DIR='$libexec_dir'"

# GUARD_REMOTE_PATH is LIBEXEC_DIR + the filename the recipe installs.
if [ -n "$MONO" ]; then
  [ "$guard_path" = "$libexec_dir/atcd-boot-confirm.sh" ] ||
    fail "GUARD_REMOTE_PATH='$guard_path' does not sit under LIBEXEC_DIR='$libexec_dir'"
fi

# The recipe writes the binary to ${bindir}/atcd. bindir is /usr/bin in a stock
# Yocto image, while the daemon default remote_path is /usr/local/bin/atcd. They
# differ ON PURPOSE: remote_path is a convenience symlink `atc bootstrap` makes,
# not a second copy. Assert the recipe says so, so nobody "fixes" one to match
# the other and creates two atcd binaries on the device.
if [ -n "$MONO" ]; then
  search 'convenience' "$CONSTS" > /dev/null ||
    fail "consts.rs no longer describes remote_path as a symlink; recheck the recipe"
  [ "$remote_path" = "$WANT_REMOTE_PATH" ] ||
    fail "default_daemon_remote_path is now '$remote_path'; recheck meta-atc's ATCD_REMOTE_PATH"
fi

# The recipe half of that claim, which the two checks above do NOT cover: they
# read the Rust side only, so a recipe "corrected" onto remote_path landed green
# while the comment claimed otherwise.
recipe_remote_path="$(search_optional '^ATCD_REMOTE_PATH = ' "$RECIPE" |
  sed -n 's/.*"\(.*\)".*/\1/p')"
[ -n "$recipe_remote_path" ] ||
  fail "the recipe has no ATCD_REMOTE_PATH; it would install the binary nowhere"
if [ "$recipe_remote_path" = "$remote_path" ]; then
  fail "the recipe installs to '$recipe_remote_path', the same path bootstrap \
SYMLINKS. That makes a second real atcd on the device; install to \${bindir}/atcd"
fi

# 3. The image must refuse a pre-created store root, and must not create one.
search 'atc_refuse_prebuilt_store_root' "$IMAGE" > /dev/null ||
  fail "atc-image.bb lost atc_refuse_prebuilt_store_root; /var/atc could be baked in"
if search "install -d .*${store_root}\b" "$IMAGE" > /dev/null; then
  fail "atc-image.bb creates $store_root; atcd install-self must create it on the device"
fi
if search "install -d .*${store_root}\b" "$RECIPE" > /dev/null; then
  fail "atcd recipe creates $store_root; atcd install-self must create it on the device"
fi

# 3b. A baked-in SSH key must be chowned to the deploy user. The step runs
#     under pseudo, so an unfixed owner leaves the key owned by root, and sshd's
#     StrictModes then refuses it. That silently blocks the bootstrap the key
#     exists to enable. No rootfs is needed to see the omission.
if search 'ATC_DEPLOY_SSH_KEY' "$IMAGE" > /dev/null; then
  search 'chown' "$IMAGE" > /dev/null ||
    fail "atc-image.bb installs an SSH key but never chowns it; \
sshd refuses a key owned by the build user"
fi

# 3c. No `ATCD_BINARY:<machine>` override. Two shapes were tried there and both
#     were wrong: an unconditional override silently discards a plain
#     ATCD_BINARY, and one that defaults back to it forms a real reference cycle
#     (the override expands to the per-arch name, which expands to the override).
#     do_install reads ATCD_BINARY_RESOLVED, which no bitbake evaluation can
#     resolve into a loop. Neither failure is visible without a Yocto build, so
#     the shape itself is what this pins.
if search '^ATCD_BINARY:' "$RECIPE" > /dev/null; then
  fail "the recipe overrides ATCD_BINARY per machine. That shape either drops a \
plain ATCD_BINARY or forms a reference cycle; resolve into ATCD_BINARY_RESOLVED instead"
fi
search '^ATCD_BINARY_RESOLVED' "$RECIPE" > /dev/null ||
  fail "the recipe lost ATCD_BINARY_RESOLVED; do_install would read an unresolved binary path"

# 3d. No backtick inside a bbnote/bbfatal message. Those run in a SHELL function,
#     so a backtick is command substitution, not quoting: a message reading
#     "`atc bootstrap atcd install` seeds the binary" makes the build try to RUN
#     that command. The habit comes from Markdown, the recipes are full of the
#     same phrases in comments where it is harmless, and no linter here parses
#     bitbake shell. Comments and DESCRIPTION/SUMMARY are not shell, so only the
#     message lines are checked.
# These messages routinely span backslash CONTINUATION lines, and the backtick
# usually lands on a later one. A line-anchored pattern matches the `bbfatal`
# line only and reads as a clean check while seeing nothing. This guard was
# DEAD that way until a mutation on the real recipe stayed green. So join the
# continuations first, then match each logical line.
for bb_file in "$RECIPE" "$IMAGE"; do
  # Process substitution, not a pipe: `rg -q` exits on the first match, which
  # would SIGPIPE the producer and hand 141 to the pipeline under pipefail,
  # reporting FAILURE on the input it MATCHED, at random.
  if rg -q '^[^#]*bb(note|warn|fatal|error).*`' \
    < <(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$bb_file"); then
    fail "$(basename "$bb_file") has a backtick in a bbnote/bbfatal message. \
That is command substitution in the build shell. Use single quotes"
  fi
done

# 3e. The host binary's BYTES must be in do_install's signature. ATCD_BINARY
#     points outside bitbake's control, so without file-checksums only the path
#     STRING is hashed: rebuilding atcd to the same path reuses the cached
#     package and ships the OLD binary while the build reports success.
search 'do_install\[file-checksums\]' "$RECIPE" > /dev/null ||
  fail "the recipe does not declare do_install[file-checksums] for ATCD_BINARY; \
a rebuilt binary at the same path would be served stale from sstate"

# 3f. No `sudo` group in EXTRA_USERS_PARAMS. That group is a Debian convention;
#     Yocto's sudo package does not create it, so `useradd -G atc,sudo` fails on
#     an unknown group and the deploy account never exists, and every
#     push depends on it. Sudo rights come from the sudoers drop-in, granted by
#     username, so the group buys nothing even where it happens to exist.
if search 'useradd .*-G [^ ]*\bsudo\b' "$IMAGE" > /dev/null; then
  fail "atc-image.bb puts the deploy user in a 'sudo' group. Yocto does not \
create one, so useradd fails and the account is never made; the sudoers drop-in \
already grants sudo by username"
fi

# 4. The recipe must keep an architecture assertion. Without it a
#    wrong-architecture ELF installs and the image still builds green.
search 'readelf -h' "$RECIPE" > /dev/null ||
  fail "the atcd recipe lost its readelf architecture assertion"
for machine in qemux86-64 qemuarm64 tegra234; do
  search "ATCD_EXPECTED_ELF_MACHINE:${machine}" "$RECIPE" > /dev/null ||
    fail "no expected ELF machine for $machine; a wrong-arch binary would install silently"
done

# 5. LAYERSERIES_COMPAT must name a series. "The current LTS" is not a pin.
search '^LAYERSERIES_COMPAT_atc = "[a-z]+"' "$LAYER_CONF" > /dev/null ||
  fail "layer.conf must pin LAYERSERIES_COMPAT_atc to a named series"

# 6. Every layer pin is `name url branch commit [machine-override]`, and the
#    commit is 40 hex characters. A branch or a short hash moves under a build,
#    so two builds of one tree would differ with nothing in the tree to say why.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'*) continue ;;
  esac
  read -r -a fields <<< "$line"
  [ "${#fields[@]}" -eq 4 ] || [ "${#fields[@]}" -eq 5 ] ||
    fail "layers.pin line '$line' is not 'name url branch commit [machine-override]'"
  [[ "${fields[3]}" =~ ^[0-9a-f]{40}$ ]] ||
    fail "layers.pin pins ${fields[0]} to '${fields[3]}', which is not 40 hex characters"
  if [ "${#fields[@]}" -eq 5 ]; then
    [[ "${fields[4]}" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
      fail "layers.pin gives ${fields[0]} the machine override '${fields[4]}', \
which is not lowercase letters, digits and '-'"
  fi
done < "$PIN_FILE"
search '^meta-rauc [^ ]+ [^ ]+ [0-9a-f]{40}$' "$PIN_FILE" > /dev/null ||
  fail "layers.pin does not pin meta-rauc for every build, and LAYERDEPENDS_atc needs it"

# 6b. meta-tegra is pinned for the tegra234 builds ONLY. A pin without the
#     override puts meta-tegra into the qemu builds, and its bbappends then
#     change their recipe set.
search '^meta-tegra [^ ]+ [^ ]+ [0-9a-f]{40} tegra234$' "$PIN_FILE" > /dev/null ||
  fail "layers.pin does not pin meta-tegra with the tegra234 override; a qemu \
build would then parse meta-tegra"

# 7. The layer depends on meta-rauc, so a build without it fails at parse time
#    and names the missing layer.
search '^LAYERDEPENDS_atc = ".*\brauc\b' "$LAYER_CONF" > /dev/null ||
  fail "layer.conf does not list rauc in LAYERDEPENDS_atc"

# 7b. meta-tegra is optional. LAYERDEPENDS would make every qemu build fail
#     without it, so it is named in LAYERRECOMMENDS only.
if search '^LAYERDEPENDS_atc = ".*\btegra\b' "$LAYER_CONF" > /dev/null; then
  fail "layer.conf lists tegra in LAYERDEPENDS_atc; a qemu build would then need meta-tegra"
fi
search '^LAYERRECOMMENDS_atc = ".*\btegra\b' "$LAYER_CONF" > /dev/null ||
  fail "layer.conf does not list tegra in LAYERRECOMMENDS_atc"

# 8. No key material in the layer. The test keys live on the builder's /cache,
#    and the production PKI is an open question. A key committed here is a key
#    every clone of the repository can sign with. `find -L` so the check also
#    sees through a layer of symbolic links.
keys="$(find -L "$LAYER" -type f \( -name '*.pem' -o -name '*.key' -o -name '*.crt' \) -print)"
[ -z "$keys" ] || fail "key material in the layer: $keys"

# 9. No `name;` entry in a *_COMMAND list. bitbake reads each word of the list
#    as a variable to hash, so `atc_install_os_version;` names an empty
#    variable and the real function drops out of the task signature. Then an
#    edit to the function, or a new ATC_OS_VERSION, reuses the old image from
#    the stamps. Measured: four bundles built with four versions all carried one
#    slot image, whose /etc/atc-os-version named the first. Scarthgap separates
#    the names with spaces, as poky's own entries do.
#
#    Parsed, not grepped: each *_COMMAND assignment (=, +=, ?=, :append,
#    :prepend) is joined across its `\` continuation lines, and its quoted value
#    must hold no ';'. A `fi;` in a shell function is not a list, and passes.
# shellcheck disable=SC2016  # the $ fields belong to awk
semis="$(find -L "$LAYER" -type f \( -name '*.bb' -o -name '*.inc' -o -name '*.bbappend' \
  -o -name '*.bbclass' -o -name '*.conf' \) -print0 | xargs -0 -r awk '
  FNR == 1 { inside = 0 }
  !inside && /^[ \t]*[A-Z_]+_COMMANDS?(:[A-Za-z0-9_-]+)*[ \t]*(\+|\?\??|:|\.)?=[+.]?[ \t]*["\047]/ {
    inside = 1; value = ""; start = FILENAME ":" FNR
  }
  inside {
    line = $0
    cont = sub(/\\[ \t]*$/, "", line)
    value = value " " line
    if (!cont) {
      v = value
      sub(/^[^"\047]*["\047]/, "", v)
      sub(/["\047][^"\047]*$/, "", v)
      if (index(v, ";")) print start ": " v
      inside = 0
    }
  }
')"
[ -z "$semis" ] || fail "a *_COMMAND list entry ends in ';', which drops it from the task hash: $semis"

# 10. atc-tegra.inc holds the Tegra image settings, and atc-image.bb requires
#     it, so every image of the layer reads it, the qemu images included. Each
#     line must therefore carry the `:tegra234` override. A plain line would
#     change a qemu image, and `:atc-slot-nvbootctrl` never applies here,
#     because atc-image.bb does not inherit atc-slot-backend. Lines are joined
#     across their `\` continuations first, so a continuation cannot hide a
#     plain assignment.
search '^require recipes-core/images/atc-tegra\.inc$' "$IMAGE" > /dev/null ||
  fail "atc-image.bb does not require atc-tegra.inc, so a Tegra image gets no tegraflash archive"
plain="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$TEGRA_INC" |
  awk '/^[ \t]*(#|$)/ { next }
    $1 !~ /^[A-Za-z0-9_]+(:[A-Za-z0-9_-]+)*:tegra234(:[A-Za-z0-9_-]+)*$/ { print }')"
[ -z "$plain" ] || fail "atc-tegra.inc has a line without the :tegra234 override, which \
reaches the qemu images or never applies: $plain"

# 11. Every bbappend outside dynamic-layers/ is on this list. Each one appends
#     an oe-core or meta-rauc recipe, which every build has. A bbappend for a
#     meta-tegra recipe lives under dynamic-layers/tegra/, which BBFILES_DYNAMIC
#     adds only when the `tegra` collection is in the build. In the plain
#     BBFILES it would be an append with no recipe in a qemu build, and the
#     qemu parse fails. A list and not a name pattern: meta-tegra's recipe
#     names (edk2-firmware-tegra, linux-jammy-nvidia-tegra, cuda-toolkit) have
#     no common prefix. Add a line here only for a recipe that every build has.
ALLOWED_APPENDS="recipes-bsp/grub/grub-efi_%.bbappend
recipes-core/rauc/rauc-conf.bbappend
recipes-core/rauc/rauc_%.bbappend
recipes-kernel/linux/linux-yocto_%.bbappend"
appends="$(cd "$LAYER" && find -L . -path ./dynamic-layers -prune -o -type f -name '*.bbappend' -print |
  sed 's|^\./||' | LC_ALL=C sort)"
stray="$(LC_ALL=C comm -23 <(printf '%s\n' "$appends") \
  <(printf '%s\n' "$ALLOWED_APPENDS" | LC_ALL=C sort) | sed '/^$/d')"
[ -z "$stray" ] || fail "a bbappend outside dynamic-layers/ that is not on the list in \
check 11. An append for a meta-tegra recipe breaks the qemu parse; put it under \
dynamic-layers/tegra/: $stray"
if [ -d "$LAYER/dynamic-layers/tegra" ]; then
  search '^BBFILES_DYNAMIC \+= "tegra:\$\{LAYERDIR\}/dynamic-layers/tegra/' "$LAYER_CONF" > /dev/null ||
    fail "layer.conf has no BBFILES_DYNAMIC entry for dynamic-layers/tegra/, so its appends never apply"
fi

# 12. A file that keys a line on an atc-slot-* override inherits
#     atc-slot-backend. The class is what defines the override, and it also
#     makes the recipe's package machine-specific. Without it, the line never
#     applies, and a package whose content differs by backend is shared between
#     two machines of one tune. A .inc qualifies when it inherits the class
#     itself. Comment lines do not count.
set +e
seam_users="$(rg -l -L -g '*.bb' -g '*.bbappend' -g '*.inc' -e '^[^#]*:atc-slot-' "$LAYER" 2>&1)"
status=$?
set -e
[ "$status" -le 1 ] || fail "rg failed (exit $status) on $LAYER: $seam_users"
for f in $seam_users; do
  search '^inherit (.* )?atc-slot-backend( .*)?$' "$f" > /dev/null ||
    fail "${f#"$LAYER"/} keys a line on an atc-slot-* override but does not inherit atc-slot-backend. \
The override never applies there, and its package is not machine-specific"
done
search '^PACKAGE_ARCH = "\$\{MACHINE_ARCH\}"$' "$LAYER/classes/atc-slot-backend.bbclass" > /dev/null ||
  fail "atc-slot-backend.bbclass does not set PACKAGE_ARCH to MACHINE_ARCH, so a package \
that differs by backend is shared between two machines of one tune"

echo "check-meta-atc-recipe: OK"
