#!/usr/bin/env bash
# scripts/checkout-layers.sh
#
# Check out the layers that conf/layers.pin names, each at its pinned
# commit, under <cache>/layers/<name>. Print one checked-out path per line on
# stdout. Run this ON THE BOX, as the build user. The proof scripts run it.
#
# WHY A PIN AND NOT A BRANCH. A branch moves under a build, so two builds of one
# tree would differ with nothing in the tree to say why. The pin is 40 hex
# characters, and this script refuses any other shape, so a short hash cannot
# match two commits.
#
# IDEMPOTENT. A checkout that is already at its pin is only read. A missing one
# is cloned, and one at another commit is fetched and moved, which needs write
# access to it.
#
# WHICH LAYERS. A pin line without a fifth field goes into every build. A line
# with one, for example `tegra234`, goes into a build only when that build
# passes `--for tegra234`. So a qemu build never parses meta-tegra.
#
# Usage:
#   ./checkout-layers.sh                  check out the layers every build needs
#   ./checkout-layers.sh --for <override> also check out the layers for <override>
#   ./checkout-layers.sh --self-test      needs no box and no network
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="${CACHE_DIR:-/cache}"
PIN_FILE="${LAYERS_PIN:-$LAYER_ROOT/conf/layers.pin}"

die() {
  echo "checkout-layers: $*" >&2
  exit 1
}

# Print the pin entries as `name url branch commit [override]`, one per line,
# and fail on any line of another shape. Comments and blank lines are skipped.
read_pins() {
  local file="$1" line n=0 name url branch commit override extra
  [ -f "$file" ] || die "no pin file at $file"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      '' | '#'*) continue ;;
    esac
    read -r name url branch commit override extra <<< "$line"
    [ -n "$commit" ] && [ -z "${extra:-}" ] ||
      die "$file:$n: expected 'name url branch commit [override]', got: $line"
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
      die "$file:$n: layer name '$name' is not lowercase letters, digits and '-'"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] ||
      die "$file:$n: commit '$commit' is not 40 hex characters"
    [ -z "$override" ] || [[ "$override" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
      die "$file:$n: machine override '$override' is not lowercase letters, digits and '-'"
    printf '%s %s %s %s%s\n' "$name" "$url" "$branch" "$commit" "${override:+ $override}"
  done < "$file"
}

# The checkout may belong to root, which cloned it over SSM. Reading it as the
# build user then trips git's ownership check, so the read names it safe.
head_of() {
  git -c safe.directory="$1" -C "$1" rev-parse HEAD 2> /dev/null || true
}

checkout_one() {
  local name="$1" url="$2" branch="$3" commit="$4"
  local dir="$CACHE_DIR/layers/$name"
  if [ ! -d "$dir/.git" ]; then
    echo "checkout-layers: cloning $name from $url" >&2
    git clone --quiet --branch "$branch" --single-branch "$url" "$dir" >&2
  fi
  if [ "$(head_of "$dir")" != "$commit" ]; then
    [ -w "$dir" ] || die "$dir is not at $commit and this user cannot write it.
  Run this once as the owner of $dir, or remove $dir and run it again."
    echo "checkout-layers: moving $name to $commit" >&2
    git -C "$dir" fetch --quiet origin "$branch" >&2
    git -C "$dir" checkout --quiet --detach "$commit" >&2
  fi
  [ "$(head_of "$dir")" = "$commit" ] || die "$dir is not at $commit after the checkout"
  # A local edit in the shared checkout would ride along into every build.
  [ -z "$(git -c safe.directory="$dir" -C "$dir" status --porcelain)" ] ||
    die "$dir has local changes; the build would not match the pin"
  echo "$dir"
}

# $1 is the machine override of the build, or empty for a build that has none.
checkout_all() {
  local for_override="${1:-}" pins name url branch commit override
  pins="$(read_pins "$PIN_FILE")"
  [ -n "$pins" ] || die "$PIN_FILE pins no layer"
  if [ -n "$for_override" ]; then
    grep -qE " $for_override\$" <<< "$pins" ||
      die "$PIN_FILE pins no layer for the override '$for_override'"
  fi
  install -d "$CACHE_DIR/layers"
  while read -r name url branch commit override; do
    if [ -n "$override" ] && [ "$override" != "$for_override" ]; then
      continue
    fi
    checkout_one "$name" "$url" "$branch" "$commit"
  done <<< "$pins"
}

# ── Self-test ────────────────────────────────────────────────────────────────

expect_refused() {
  local label="$1" file="$2"
  if (read_pins "$file") > /dev/null 2>&1; then
    echo "FAIL: $label: read_pins accepted it" >&2
    return 1
  fi
}

self_test_parser() {
  local tmp="$1" status=0 good="0123456789abcdef0123456789abcdef01234567"
  printf '# c\n\nmeta-x https://e.invalid/x.git main %s\n' "$good" > "$tmp/ok.pin"
  [ "$(read_pins "$tmp/ok.pin")" = "meta-x https://e.invalid/x.git main $good" ] || {
    echo "FAIL: a valid pin did not parse" >&2
    status=1
  }
  printf 'meta-x u main 0123456\n' > "$tmp/short.pin"
  expect_refused "a short hash" "$tmp/short.pin" || status=1
  printf 'meta-x u main %s\n' "${good^^}" > "$tmp/upper.pin"
  expect_refused "an upper-case hash" "$tmp/upper.pin" || status=1
  printf 'meta-x u %s\n' "$good" > "$tmp/three.pin"
  expect_refused "three fields" "$tmp/three.pin" || status=1
  printf 'meta-x u main %s tegra234\n' "$good" > "$tmp/five.pin"
  [ "$(read_pins "$tmp/five.pin")" = "meta-x u main $good tegra234" ] || {
    echo "FAIL: a pin with a machine override did not parse" >&2
    status=1
  }
  printf 'meta-x u main %s Tegra_234\n' "$good" > "$tmp/badov.pin"
  expect_refused "a bad machine override" "$tmp/badov.pin" || status=1
  printf 'meta-x u main %s tegra234 extra\n' "$good" > "$tmp/six.pin"
  expect_refused "six fields" "$tmp/six.pin" || status=1
  printf 'Meta_X u main %s\n' "$good" > "$tmp/name.pin"
  expect_refused "a bad layer name" "$tmp/name.pin" || status=1
  expect_refused "a missing pin file" "$tmp/absent.pin" || status=1
  return "$status"
}

# A real clone of a local repository: the pin is honoured, a second run only
# reads, and a new pin moves the checkout.
self_test_checkout() {
  local tmp="$1" repo="$1/upstream" first second out
  git init --quiet -b main "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@e.invalid commit --quiet --allow-empty -m one
  first="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" -c user.name=t -c user.email=t@e.invalid commit --quiet --allow-empty -m two
  second="$(git -C "$repo" rev-parse HEAD)"

  printf 'meta-t file://%s main %s\n' "$repo" "$first" > "$tmp/t.pin"
  out="$(CACHE_DIR="$tmp/cache" PIN_FILE="$tmp/t.pin" checkout_all 2> /dev/null)"
  [ "$out" = "$tmp/cache/layers/meta-t" ] || die "self-test: printed '$out'"
  [ "$(head_of "$out")" = "$first" ] || die "self-test: the clone is not at the pin"

  out="$(CACHE_DIR="$tmp/cache" PIN_FILE="$tmp/t.pin" checkout_all 2>&1 > /dev/null)"
  [ -z "$out" ] || die "self-test: a second run at the pin did more than read: $out"

  printf 'meta-t file://%s main %s\n' "$repo" "$second" > "$tmp/t.pin"
  CACHE_DIR="$tmp/cache" PIN_FILE="$tmp/t.pin" checkout_all > /dev/null 2>&1
  [ "$(head_of "$tmp/cache/layers/meta-t")" = "$second" ] ||
    die "self-test: a new pin did not move the checkout"

  # A layer scoped to a machine override: left out of a plain run, checked out
  # with --for, and a --for that names no pinned layer is refused.
  printf 'meta-t file://%s main %s\nmeta-o file://%s main %s tegra234\n' \
    "$repo" "$second" "$repo" "$first" > "$tmp/o.pin"
  out="$(CACHE_DIR="$tmp/cache" PIN_FILE="$tmp/o.pin" checkout_all 2> /dev/null)"
  [ "$out" = "$tmp/cache/layers/meta-t" ] ||
    die "self-test: a plain run checked out a scoped layer: '$out'"
  out="$(CACHE_DIR="$tmp/cache" PIN_FILE="$tmp/o.pin" checkout_all tegra234 2> /dev/null)"
  [ "$out" = "$tmp/cache/layers/meta-t"$'\n'"$tmp/cache/layers/meta-o" ] ||
    die "self-test: --for tegra234 printed '$out'"
  if (CACHE_DIR="$tmp/cache" PIN_FILE="$tmp/o.pin" checkout_all tegra194) > /dev/null 2>&1; then
    die "self-test: --for an override with no pinned layer was accepted"
  fi
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  self_test_parser "$tmp" || die "self-test: the pin parser accepted a bad pin"
  self_test_checkout "$tmp"
  read_pins "$LAYER_ROOT/conf/layers.pin" > /dev/null ||
    die "self-test: the real conf/layers.pin does not parse"
  echo "checkout-layers --self-test: OK"
}

case "${1:-}" in
  --self-test) self_test ;;
  --for) checkout_all "${2:?--for needs a machine override}" ;;
  '') checkout_all ;;
  *) die "unknown argument $1" ;;
esac
