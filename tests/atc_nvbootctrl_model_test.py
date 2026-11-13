#!/usr/bin/env python3
"""A bounded model check of meta-atc's nvbootctrl slot backend.

It runs the real backend (sh) against tests/fixtures/fake-nvbootctrl.sh, the
fake that models the L4T launcher's SR_RF and slot choice. From two start
states it searches every sequence of these events, to a fixed depth:

- the boot unit, with a crash at each nvbootctrl or chattr call, a failed
  verify, a failed set-active-boot-slot or a failed chattr;
- a RAUC install into the other slot (set-state bad, then set-primary), with
  the same faults;
- atcd's confirm or reject of a trial, and the trial deadline;
- mark-active and mark-bad of either slot;
- warm and cold resets, and a kernel panic before the boot unit runs.

A ghost bit per slot records whether its image passed atcd's dwell. The test
fails when a reachable state:

- names a steady slot whose image did not pass the dwell, while the other
  slot holds an image that passed it, is not marked unbootable and is not on
  trial (UNCONFIRMED_STEADY). With no such slot, the steady slot is the last
  image that boots, and the only other choice is the recovery kernel;
- boots the recovery kernel after a cold boot, or after a boot unit that
  succeeded (RECOVERY_KERNEL);
- runs an image that did not pass the dwell with no trial deadline armed
  (UNCONFIRMED_RUNS_NO_DEADLINE);
- loops on reboots that the boot unit requests (REBOOT_LOOP).

An early panic on the only bootable slot may still reach the recovery kernel.
The design records that cost, so the panic events do not count it.

The round-3 review of the backend wrote the first version of this checker. It
found a set-primary order that let a failed install become steady.

Environment: ATC_NVBOOTCTRL_BACKEND and ATC_NVBOOTCTRL_FAKE name the two
scripts. ATC_NVBOOTCTRL_MODEL_DEPTH sets the depth (default 4). Depth 4 is the
least that finds the set-primary order of round 3.

ATC_NVBOOTCTRL_MODEL_CAPSULE=1 adds the UEFI capsule. A fake
atc-tegra-capsule keeps the staged slot and bit 2 of OsIndications. An install
stages a capsule for its slot before set-primary, as the bundle hook does. A
reset with an armed capsule applies it, as UEFI does: the chain that did not
boot becomes active, and the bit and the file go. A "capsule rejected" event
resets with the bit cleared and the chain unchanged. The model found two
defects on this path that the model without it could not reach.

A trial whose partner is marked unbootable has no revert target, so it is not
UNCONFIRMED_RUNS_NO_DEADLINE: a deadline there would only reboot into the same
slot. The backend reports no trial in flight for it.

With the capsule, a "capsule rejected" event also sets a ghost on the slot of
the rejected capsule: its rootfs never got its firmware. A reset that boots
that slot before an install writes it again is REJECTED_IMAGE_BOOTS. A review
found a verify give-up that fell over into it. A crash or a panic
before the boot unit completes is not counted: until the unit's spent row runs,
the slot is normal with a count, as set-primary left it for the capsule, and
nothing on the board can mark it sooner. That is a cost of the capsule as the
switch, like the early panic above.

A slot that runs an unconfirmed image with no deadline is not
UNCONFIRMED_RUNS_NO_DEADLINE when the next reset boots the other slot: the
chain points there, or a capsule for it is armed. A set-primary away from the
booted slot leaves that state until the reboot that follows it. Nor is it when
the other slot's image did not pass the dwell either: a deadline would have no
confirmed image to revert to. Only the repair's start reaches that, after an
install into A that failed before its arm.

A third start state is that repair's start: slot B runs an unconfirmed trial,
and slot A, the steady slot, is marked unbootable. The launcher reaches it when
A fails to boot after a revert. That takes more events than the depth allows
from the other two starts. trial-slot reports no trial, so an install writes A.
"""

import collections
from concurrent.futures import ProcessPoolExecutor
import os
import shutil
import subprocess
import tempfile
import unittest

BACKEND = os.environ.get("ATC_NVBOOTCTRL_BACKEND", "")
FAKE = os.environ.get("ATC_NVBOOTCTRL_FAKE", "")
DEPTH = int(os.environ.get("ATC_NVBOOTCTRL_MODEL_DEPTH", "4"))
CAPSULE = os.environ.get("ATC_NVBOOTCTRL_MODEL_CAPSULE", "") == "1"
GUID = "781e084c-a330-417c-b678-38e696380cb9"
SVAR = "AtcSlotState-02a2442b-c5ad-47ce-a9c6-41083c3b727d"

# A wrapper that counts calls, and kills the whole backend process group at
# call CRASH_AT: a crash at that point.
WRAP = r'''#!/bin/bash
d="$(cd "$(dirname "$0")/.." && pwd)"
n=$(( $(cat "$d/ctr") + 1 )); echo $n > "$d/ctr"
if [ -n "${CRASH_AT:-}" ] && [ "$n" -ge "$CRASH_AT" ]; then
  echo crashed > "$d/crashed"
  kill -9 -- -$(ps -o pgid= -p $$ | tr -d ' '); sleep 5
fi
'''
NV = WRAP + r'''
for a in "$@"; do
  if [ "$a" = verify ] && [ -n "${FAIL_VERIFY:-}" ]; then
    v=$(( $(cat "$d/vctr") + 1 )); echo $v > "$d/vctr"
    if [ "$v" -le "$FAIL_VERIFY" ]; then echo "nvbootctrl: verify failed" >&2; exit 1; fi
  fi
  if [ "$a" = set-active-boot-slot ] && [ -n "${FAIL_SETACTIVE:-}" ]; then echo "nvbootctrl: sab failed" >&2; exit 1; fi
done
exec "$d/bin/nvbootctrl.real" "$@"
'''
CH = WRAP + r'''
if [ -n "${CHATTR_FAIL_AT:-}" ] && [ "$n" -eq "$CHATTR_FAIL_AT" ]; then exit 1; fi
exit 0
'''
RB = '#!/bin/sh\necho 1 > "$(dirname "$0")/../rebootreq"\n'
# The fake capsule tool. cap holds the slot of the staged capsule, or nothing.
# osind holds bit 2 of OsIndications.
CAP = WRAP + r'''
cap="$(cat "$d/cap" 2> /dev/null || :)"
bit="$(cat "$d/osind" 2> /dev/null || echo 0)"
case "$1" in
  is-staged) [ -n "$cap" ] && [ "$cap" = "$2" ] ;;
  arm) [ -n "$cap" ] && [ "$cap" = "$2" ] || exit 1; echo 1 > "$d/osind" ;;
  disarm) echo 0 > "$d/osind"; : > "$d/cap" ;;
  clear-bit) echo 0 > "$d/osind" ;;
  armed-slot) if [ -n "$cap" ] && [ "$bit" = 1 ]; then echo "$cap"; else exit 1; fi ;;
  *) exit 2 ;;
esac
'''
SL = '#!/bin/sh\nexit 0\n'

# A state is a tuple:
# (cur, act, magic, rA, rB, stA, stB, atc, ghostA, ghostB, stage, unitok, reboots)
#   stA, stB: 'n' normal or 'u' unbootable. atc: the AtcSlotState text, or None.
#   ghostA, ghostB: 1 when the slot's image passed the dwell.
#   stage: 'pre' after a reset, before the boot unit; 'run' after it started.
#   unitok: 1 when a boot-unit start exited 0 in this boot (the done marker).
#   reboots: boot-unit reboot requests in a row.
#   cap, osind: the staged capsule's slot ('' for none) and OsIndications bit 2.
#   rej: the slot whose capsule UEFI rejected, '' for none (a ghost).


def mkdir_env(d):
    os.makedirs(d + "/bin", exist_ok=True)
    shutil.copy(FAKE, d + "/bin/nvbootctrl.real")
    for name, body in (("nvbootctrl", NV), ("chattr", CH), ("fake-reboot", RB), ("sleep", SL),
                       ("atc-tegra-capsule", CAP)):
        with open(d + "/bin/" + name, "w") as f:
            f.write(body)
    for n in os.listdir(d + "/bin"):
        os.chmod(d + "/bin/" + n, 0o755)


def write_state(d, s):
    cur, act, mg, ra, rb, sta, stb, atc = s[:8]
    for sub in ("nvbootctrl", "efivars"):
        p = d + "/" + sub
        if os.path.isdir(p):
            shutil.rmtree(p)
        os.makedirs(p)
    for k, v in (("current", cur), ("active", act), ("magic", mg), ("retry_0", ra),
                 ("retry_1", rb), ("retry_max", 1)):
        with open(f"{d}/nvbootctrl/{k}", "w") as f:
            f.write(f"{v}\n")
    for k in ("calls", "seq"):
        open(f"{d}/nvbootctrl/{k}", "w").close()
    for slot, st in (("A", sta), ("B", stb)):
        with open(f"{d}/efivars/RootfsStatusSlot{slot}-{GUID}", "wb") as f:
            f.write(b"\x07\0\0\0" + (b"\0\0\0\0" if st == "n" else b"\xff\0\0\0"))
    if atc is not None:
        with open(f"{d}/efivars/{SVAR}", "wb") as f:
            f.write(b"\x07\0\0\0" + atc.encode())
    for k in ("ctr", "vctr"):
        with open(f"{d}/{k}", "w") as f:
            f.write("0\n")
    for k in ("rebootreq", "crashed", "lock", "boot.done"):
        if os.path.exists(f"{d}/{k}"):
            os.remove(f"{d}/{k}")
    if s[11] == 1:
        open(f"{d}/boot.done", "w").close()
    write_capsule(d, s)


def write_capsule(d, s):
    """The fake capsule tool's files: the staged slot and bit 2."""
    with open(f"{d}/cap", "w") as f:
        f.write(s[13])
    with open(f"{d}/osind", "w") as f:
        f.write(f"{s[14]}\n")


def read_regs(d, s):
    def g(k):
        with open(f"{d}/nvbootctrl/{k}") as f:
            return int(f.read().strip())

    def st(slot):
        with open(f"{d}/efivars/RootfsStatusSlot{slot}-{GUID}", "rb") as f:
            b = f.read()[4:]
        return "u" if b == b"\xff\0\0\0" else "n"

    p = f"{d}/efivars/{SVAR}"
    atc = None
    if os.path.exists(p):
        with open(p, "rb") as f:
            atc = f.read()[4:].decode(errors="replace")
    with open(f"{d}/cap") as f:
        cap = f.read().strip()
    with open(f"{d}/osind") as f:
        bit = int(f.read().strip() or "0")
    return (g("current"), g("active"), g("magic"), g("retry_0"), g("retry_1"),
            st("A"), st("B"), atc) + tuple(s[8:13]) + (cap, bit, s[15])


def run(d, verb, env_extra=None, timeout=30):
    env = dict(os.environ)
    env.update(PATH=f"{d}/bin:/usr/bin:/bin", ATC_EFIVARS_DIR=f"{d}/efivars",
               ATC_NVBOOTCTRL_LOCK=f"{d}/lock", ATC_NVBOOTCTRL_REBOOT=f"{d}/bin/fake-reboot",
               ATC_NVBOOTCTRL_BOOT_DONE=f"{d}/boot.done",
               ATC_TEGRA_CAPSULE=f"{d}/bin/atc-tegra-capsule" if CAPSULE else f"{d}/no-capsule-tool")
    for k in ("CRASH_AT", "FAIL_VERIFY", "FAIL_SETACTIVE", "CHATTR_FAIL_AT", "ATC_NVBOOTCTRL_RETRY"):
        env.pop(k, None)
    if env_extra:
        env.update(env_extra)
    for k in ("ctr", "vctr"):
        with open(f"{d}/{k}", "w") as f:
            f.write("0\n")
    try:
        p = subprocess.run(["sh", BACKEND] + verb, env=env, capture_output=True, text=True,
                           timeout=timeout, start_new_session=True)
        rc, out = p.returncode, p.stdout.strip()
    except subprocess.TimeoutExpired:
        rc, out = "timeout", ""
    if os.path.exists(f"{d}/crashed"):
        os.remove(f"{d}/crashed")
        rc = "crash"
    return rc, out


def fake_boot(d, cold):
    p = subprocess.run([f"{d}/bin/nvbootctrl.real", "fake-boot"] + (["cold"] if cold else []),
                       capture_output=True, text=True, timeout=30)
    return p.returncode


def letter(n):
    return "AB"[n]


def parse(atc):
    if atc is None:
        return None
    try:
        parts = dict(kv.split("=") for kv in atc.split(" "))
    except ValueError:
        return "corrupt"
    if set(parts) != {"steady", "trial", "ok"} or parts["steady"] not in ("A", "B"):
        return "corrupt"
    return parts


def ghost(s, slot):
    return s[8] if slot == "A" else s[9]


def setghost(s, slot, v):
    s = list(s)
    s[8 if slot == "A" else 9] = v
    return tuple(s)


def setf(s, i, v):
    s = list(s)
    s[i] = v
    return tuple(s)


def check(s, label, viol):
    p = parse(s[7])
    if not isinstance(p, dict) or ghost(s, p["steady"]):
        return
    other = "B" if p["steady"] == "A" else "A"
    other_status = s[5] if other == "A" else s[6]
    if ghost(s, other) and other_status == "n" and p["trial"] != other:
        viol.append(("UNCONFIRMED_STEADY", label, s))


def variants(max_points=12):
    v = [("ok", {})]
    for k in range(1, max_points + 1):
        v.append((f"crash@{k}", {"CRASH_AT": str(k)}))
    for k in (1, 3, 9):
        v.append((f"verifyfail{k}", {"FAIL_VERIFY": str(k)}))
    v.append(("sabfail", {"FAIL_SETACTIVE": "1"}))
    for k in range(1, 7):
        v.append((f"chattrfail@{k}", {"CHATTR_FAIL_AT": str(k)}))
    return v


VARS = variants()


def apply_capsule(d):
    """UEFI at a reset with an armed capsule: it writes the chain that is not
    active, makes that chain active, and removes the bit and the file."""
    with open(f"{d}/cap") as f:
        cap = f.read().strip()
    with open(f"{d}/osind") as f:
        bit = f.read().strip()
    if not cap or bit != "1":
        return
    with open(f"{d}/nvbootctrl/active") as f:
        act = int(f.read().strip())
    with open(f"{d}/nvbootctrl/active", "w") as f:
        f.write(f"{1 - act}\n")
    with open(f"{d}/osind", "w") as f:
        f.write("0\n")
    with open(f"{d}/cap", "w") as f:
        f.write("")


def reset(d, s, cold, viol, label, unplanned=False):
    write_state(d, s)
    apply_capsule(d)
    rc = fake_boot(d, cold)
    ns = read_regs(d, s)
    ns = setf(setf(ns, 10, "pre"), 11, 0)
    if rc == 3:
        if cold or s[11] == 1:
            viol.append(("RECOVERY_KERNEL", label, s))
        return None
    if s[15] and letter(ns[0]) == s[15] and not unplanned:
        viol.append(("REJECTED_IMAGE_BOOTS", label, s))
    return ns


class Step:
    """The successors of one state s, built in a scratch directory d."""

    def __init__(self, d, s):
        self.d, self.s = d, s
        self.succ, self.viol = [], []
        self.booted = letter(s[0])
        self.other = "B" if self.booted == "A" else "A"

    def verb(self, vs, env):
        write_state(self.d, self.s)
        rc, out = run(self.d, vs, env)
        rq = os.path.exists(f"{self.d}/rebootreq")
        return rc, out, read_regs(self.d, self.s), rq

    def add_resets(self, ns, label, both=True, extra=None):
        """A crash: a warm and a cold reset from ns."""
        for cold in ((False, True) if both else (False,)):
            r = reset(self.d, ns, cold, self.viol, label + ("+cold" if cold else "+warm"), unplanned=True)
            if r:
                self.succ.append((r if extra is None else setf(r, 12, extra), label + ("+cold" if cold else "+warm")))

    def boot_unit(self):
        unitok, reboots = self.s[11], self.s[12]
        for vn, env in VARS:
            label = f"boot[{vn}]"
            rc, out, ns, rq = self.verb(["boot"], env)
            ns = setf(setf(ns, 10, "run"), 11, 1 if rc == 0 else unitok)
            check(ns, label, self.viol)
            if rq:
                self.requested_reboot(ns, label, reboots)
            elif rc == "crash":
                self.add_resets(ns, label, extra=0)
            else:
                self.succ.append((setf(ns, 12, 0), label))
                if rc == 0:
                    self.after_unit_ok(ns, label)

    def requested_reboot(self, ns, label, reboots):
        if reboots >= 3:
            self.viol.append(("REBOOT_LOOP", label, self.s))
            return
        r = reset(self.d, ns, False, self.viol, label + "+reqreboot")
        if r:
            self.succ.append((setf(r, 12, reboots + 1), label + "+reqreboot"))

    def after_unit_ok(self, ns, label):
        write_state(self.d, ns)
        _, tout = run(self.d, ["trial-slot"])
        partner_status = ns[5] if self.other == "A" else ns[6]
        leaves = ns[1] != ns[0] or (ns[13] == self.other and ns[14] == 1)
        fallback = partner_status != "u" and ghost(ns, self.other)
        if not ghost(ns, self.booted) and tout != self.booted and fallback and not leaves:
            self.viol.append(("UNCONFIRMED_RUNS_NO_DEADLINE", label, self.s))
        reset(self.d, ns, False, self.viol, label + "+then-warm")

    def pre_unit(self):
        r = reset(self.d, self.s, True, self.viol, "pre-cold")
        if r:
            self.succ.append((setf(r, 12, 0), "pre-cold"))
        write_state(self.d, self.s)
        if fake_boot(self.d, False) != 3:
            self.succ.append((setf(setf(read_regs(self.d, self.s), 10, "pre"), 11, 0), "pre-warm(panic)"))

    def install(self):
        for vn, env in VARS:
            label = f"install.bad[{vn}]"
            rc, out, ns, _ = self.verb(["set-state", self.other, "bad"], env)
            ns = setf(ns, 12, 0)
            if rc == 0:
                ns = setghost(ns, self.other, 0)
                if ns[15] == self.other:
                    ns = setf(ns, 15, "")
            check(ns, label, self.viol)
            if rc == "crash":
                self.add_resets(ns, label + "+reset")
            elif rc != 0:
                self.succ.append((ns, label))
            else:
                if CAPSULE:
                    ns = setf(setf(ns, 13, self.other), 14, 0)
                self.install_primary(ns, label, VARS if vn == "ok" else VARS[:1])

    def install_primary(self, ns, label, variants_):
        for vn2, env2 in variants_:
            label2 = f"{label}.primary[{vn2}]"
            write_state(self.d, ns)
            rc2, _ = run(self.d, ["set-primary", self.other], env2)
            ns2 = read_regs(self.d, ns)
            check(ns2, label2, self.viol)
            if rc2 == "crash":
                self.add_resets(ns2, label2 + "+reset")
                continue
            self.succ.append((ns2, label2))
            if rc2 == 0:
                r = reset(self.d, ns2, False, self.viol, label2 + "+reboot")
                if r:
                    self.succ.append((r, label2 + "+reboot"))

    def trial(self):
        for vn, env in VARS:
            label = f"confirm[{vn}]"
            g = setghost(self.s, self.booted, 1)
            write_state(self.d, g)
            rc, _ = run(self.d, ["set-state", self.booted, "good"], env)
            ns = read_regs(self.d, g)
            check(ns, label, self.viol)
            if rc == "crash":
                self.add_resets(ns, label + "+reset")
            else:
                self.succ.append((ns, label))
        for vn, env in VARS[:8]:
            label = f"reject[{vn}]"
            write_state(self.d, self.s)
            run(self.d, ["set-state", self.booted, "bad"], env)
            ns = read_regs(self.d, self.s)
            check(ns, label, self.viol)
            r = reset(self.d, ns, False, self.viol, label + "+reboot")
            if r:
                self.succ.append((r, label + "+reboot"))
        r = reset(self.d, self.s, False, self.viol, "deadline")
        if r:
            self.succ.append((r, "deadline"))

    def admin(self):
        booted, other = self.booted, self.other
        for vs, lab, gfn in ((["set-primary", booted], "mark-active-booted", lambda x: setghost(x, booted, 1)),
                             (["set-primary", other], "mark-active-other", None),
                             (["set-state", other, "bad"], "mark-bad-other", None)):
            write_state(self.d, self.s)
            rc, _ = run(self.d, vs)
            ns = read_regs(self.d, self.s)
            if gfn and rc == 0:
                ns = gfn(ns)
            check(ns, lab, self.viol)
            self.succ.append((ns, lab))

    def running_resets(self):
        for cold in (False, True):
            lab = "run-cold" if cold else "run-warm"
            if self.s[11] or cold:
                r = reset(self.d, self.s, cold, self.viol, lab)
            else:
                write_state(self.d, self.s)
                r = None
                if fake_boot(self.d, cold) != 3:
                    r = setf(setf(read_regs(self.d, self.s), 10, "pre"), 11, 0)
            if r:
                self.succ.append((setf(r, 12, 0), lab))


def expand(s):
    d = tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR"))
    mkdir_env(d)
    step = Step(d, s)
    try:
        step.boot_unit()
        if s[10] == "pre":
            step.pre_unit()
            return step.succ, step.viol
        write_state(d, s)
        _, tslot = run(d, ["trial-slot"])
        if tslot == "none":
            step.install()
        if tslot == step.booted:
            step.trial()
        step.admin()
        step.running_resets()
        if CAPSULE and s[13] and s[14] == 1:
            r = reset(d, setf(s, 14, 0), False, step.viol, "capsule-rejected")
            if r:
                step.succ.append((setf(setf(r, 12, 0), 15, s[13]), "capsule-rejected"))
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return step.succ, step.viol


def explore(depth):
    starts = [
        (0, 0, 1, 0, 1, "n", "n", None, 1, 1, "pre", 0, 0, "", 0, ""),
        (0, 0, 1, 0, 1, "n", "n", "steady=A trial=none ok=0", 1, 1, "pre", 0, 0, "", 0, ""),
        # The repair's start: B boots its unconfirmed trial, A is unbootable.
        (1, 1, 1, 0, 0, "u", "n", "steady=A trial=B ok=0", 1, 0, "pre", 0, 0, "", 0, ""),
    ]
    seen = {s: (None, "start") for s in starts}
    frontier = list(starts)
    found = collections.OrderedDict()
    workers = min(os.cpu_count() or 1, 16)
    with ProcessPoolExecutor(max_workers=workers) as ex:
        for _ in range(depth):
            if not frontier:
                break
            nxt = []
            for s, (succ, viol) in zip(frontier, ex.map(expand, frontier)):
                for kind, label, src in viol:
                    key = (kind, label.split("[")[0], src[:8])
                    found.setdefault(key, (kind, label, src, s))
                for ns, label in succ:
                    if ns not in seen:
                        seen[ns] = (s, label)
                        nxt.append(ns)
            frontier = nxt

    def path(s):
        steps = []
        while s is not None:
            prev, lab = seen[s]
            steps.append(f"  {lab}: {s}")
            s = prev
        return "\n".join(reversed(steps))

    return [f"{kind} at {label}, from {src}\n{path(at)}" for kind, label, src, at in found.values()], len(seen)


class ModelCheck(unittest.TestCase):
    def test_no_reachable_violation(self):
        self.assertTrue(BACKEND and FAKE, "set ATC_NVBOOTCTRL_BACKEND and ATC_NVBOOTCTRL_FAKE")
        report, states = explore(DEPTH)
        mode = "with the capsule" if CAPSULE else "without the capsule"
        print(f"atc_nvbootctrl_model_test: depth {DEPTH}, {mode}, {states} states, {len(report)} violations")
        self.assertEqual(report, [], "\n\n".join(report))


if __name__ == "__main__":
    unittest.main()
