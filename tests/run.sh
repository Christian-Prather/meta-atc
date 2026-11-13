#!/usr/bin/env bash
# tests/run.sh
#
# Run every check of this repository that needs no Yocto builder. That is the
# two repository gates and their self-tests, and the self-test of each build
# driver. It is also the tests of the on-device scripts, and the model check of
# the nvbootctrl backend. CI runs this script, and so can you.
#
# Each check runs even when an earlier one fails. The script exits 1 when any
# check failed, and names each one.
#
# Usage: tests/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=()

run() {
  local name="$1"
  shift
  echo "=== $name"
  if "$@"; then
    echo "--- PASS: $name"
  else
    echo "--- FAIL: $name (exit $?)"
    failed+=("$name")
  fi
}

run "recipe gate, real layer" env META_ATC_ROOT="$ROOT" \
  bash "$ROOT/scripts/check-meta-atc-recipe.sh"
run "recipe gate, self-test" bash "$ROOT/tests/check-meta-atc-recipe_test.sh" \
  "$ROOT/scripts/check-meta-atc-recipe.sh"
run "A/B layout gate, real layer" env META_ATC_ROOT="$ROOT" bash "$ROOT/scripts/check-atc-ab-layout.sh"
run "A/B layout gate, self-test" bash "$ROOT/tests/check-atc-ab-layout_test.sh" \
  "$ROOT/scripts/check-atc-ab-layout.sh" "$ROOT"

for s in checkout-layers rauc-test-keys qemu-rauc-proof qemu-rauc-faults tegra-build tegra-proof-artifacts; do
  run "$s --self-test" bash "$ROOT/scripts/$s.sh" --self-test
done

run "bundle hook" bash "$ROOT/tests/atc-bundle-hook_test.sh" \
  "$ROOT/recipes-core/bundles/files/atc-bundle-hook"
run "Tegra capsule tool" bash "$ROOT/tests/atc-tegra-capsule_test.sh" \
  "$ROOT/recipes-bsp/atc-tegra-capsule/files/atc-tegra-capsule" \
  "$ROOT/recipes-core/bundles/files/atc-bundle-hook"
run "atc-os pre-install" bash "$ROOT/tests/atc-os-pre-install_test.sh" \
  "$ROOT/recipes-core/atc-os/files/atc-os-pre-install"
run "GRUB trial predicate" bash "$ROOT/tests/atc-slot-trial-grub_test.sh" \
  "$ROOT/recipes-core/atc-os/files/atc-slot-trial-grub"
run "trial deadline" bash "$ROOT/tests/atc-os-trial-deadline_test.sh" \
  "$ROOT/recipes-core/atc-os/files/atc-os-trial-deadline"
run "Tegra flash tools wrapper" bash "$ROOT/tests/tegra-flashtools-wrapper_test.sh" \
  "$ROOT/dynamic-layers/tegra/recipes-bsp/tegra-binaries/tegra-flashtools-native_%.bbappend"
run "nvbootctrl backend" bash "$ROOT/tests/atc-nvbootctrl-backend_test.sh" \
  "$ROOT/recipes-bsp/atc-nvbootctrl/files/atc-nvbootctrl-backend" \
  "$ROOT/recipes-bsp/atc-nvbootctrl/files/atc-slot-trial-nvbootctrl" \
  "$ROOT/tests/fixtures/fake-nvbootctrl.sh" \
  "$ROOT/recipes-bsp/atc-tegra-capsule/files/atc-tegra-capsule"

model() {
  env ATC_NVBOOTCTRL_BACKEND="$ROOT/recipes-bsp/atc-nvbootctrl/files/atc-nvbootctrl-backend" \
    ATC_NVBOOTCTRL_FAKE="$ROOT/tests/fixtures/fake-nvbootctrl.sh" \
    ATC_NVBOOTCTRL_MODEL_CAPSULE="$1" \
    python3 -I "$ROOT/tests/atc_nvbootctrl_model_test.py"
}
run "nvbootctrl model" model ""
run "nvbootctrl model, with the capsule" model 1

if [ "${#failed[@]}" -gt 0 ]; then
  echo "tests/run.sh: ${#failed[@]} check(s) failed:" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
echo "tests/run.sh: all checks passed"
