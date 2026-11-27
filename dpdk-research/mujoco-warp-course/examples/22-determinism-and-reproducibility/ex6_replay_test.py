"""Example 22.6 - a replay test in the style of determinism_test.py::_Replay.

In 4.0.1 collision and make_constraint emit contacts and constraint rows in a racy order on a GPU
(the sorts are stubs), so a contact scene is not bitwise reproducible even with ATOMICS. The test
suite works around this: run A records the full Data after each of those two stages; in run B the
same stages run, the test checks that their INPUTS are bitwise equal and their float OUTPUTS are
equal up to order (sorted bit patterns), and then it overwrites B's outputs with A's recording.
Everything downstream (solver, integrator) can then be compared bitwise under ATOMICS.
On Warp's CPU device the stage order is already fixed, so we inject the GPU's behaviour: a
"shuffler" permutes the contact slots after every collision call. Run B (shuffled, no replay)
drifts away from A; run C (shuffled + replay) is bitwise equal to A.
Both stages are patched with unittest.mock, exactly like the test suite (private API).
Memory: the recording keeps a host copy of every Data array before and after each stage call,
2 stages x 2 snapshots per step, so the tape needs about (size of Data) x 4 x NSTEP bytes of host
RAM. box_stack(5) with nconmax=32, njmax=128 is about 0.04 MB per world, so the GPU budget
(NWORLD=64, NSTEP=30) needs about 0.3 GB; nworld=1024 for 100 steps would need about 16 GB.
Run: python ex6_replay_test.py [--dump-json PATH]
  --dump-json PATH writes the per-step log10 |dqpos| of run B and run C for the chaos chart.
"""
import argparse
import contextlib
import dataclasses
import json
from unittest import mock

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import collision_driver  # private API: patch targets only
from mujoco_warp._src import constraint        # private API: patch targets only


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 64 if ON_GPU else 4     # the replay tape is host RAM: (Data size) x 4 x NSTEP
NSTEP = 30 if ON_GPU else 60
PHYSICS = ("qpos", "qvel", "qacc", "qacc_smooth", "qfrc_constraint", "qfrc_bias", "cacc")


def arrays_of(obj, prefix="d"):
    """All warp arrays reachable from a Data (nested dataclasses), keyed by path."""
    if isinstance(obj, wp.array):
        return {prefix: obj}
    if not dataclasses.is_dataclass(obj):
        return {}
    out = {}
    for name, value in vars(obj).items():
        out.update(arrays_of(value, f"{prefix}.{name}"))
    return out


def snap(arrs):
    return {k: a.numpy().copy() for k, a in arrs.items()}


def sorted_bits(a):
    """Bit patterns in sorted order: equal for two arrays that hold the same values in any order."""
    return np.sort(a.reshape(-1).view(f"u{a.itemsize}"))


class Replay:
    """Record stage outputs in the first run; check and replay them in later runs."""

    def __init__(self, d):
        self.d, self.calls, self.recording, self.i = d, [], True, 0
        self.checked = 0

    def wrap(self, stage, fn):
        def wrapper(*a, **kw):
            arrs = arrays_of(self.d)
            pre = snap(arrs)
            fn(*a, **kw)
            post = snap(arrs)
            if self.recording:
                self.calls.append((stage, pre, post))
                return
            ref_stage, ref_pre, ref_post = self.calls[self.i]
            self.i += 1
            assert stage == ref_stage, (stage, ref_stage)
            bad_in = [k for k in pre if pre[k].tobytes() != ref_pre[k].tobytes()]
            assert not bad_in, f"inputs of {stage} differ: {bad_in[:3]}"
            floats = [k for k, v in post.items() if v.dtype.kind == "f"]
            bad_out = [k for k in floats
                       if sorted_bits(post[k]).tobytes() != sorted_bits(ref_post[k]).tobytes()]
            assert not bad_out, f"float outputs of {stage} differ beyond order: {bad_out[:3]}"
            for k, arr in arrs.items():                # replay: restore run A's exact outputs
                if arr.size:
                    arr.assign(ref_post[k])
            self.checked += 1
        return wrapper

    @contextlib.contextmanager
    def patch(self):
        self.recording, self.i = not self.calls, 0
        with mock.patch.object(collision_driver, "collision",
                               self.wrap("collision", collision_driver.collision)), \
             mock.patch.object(constraint, "make_constraint",
                               self.wrap("make_constraint", constraint.make_constraint)):
            yield


@contextlib.contextmanager
def shuffled_contacts(d, seed):
    """Emulate the GPU: permute the live contact slots after every collision call."""
    rng, inner = np.random.default_rng(seed), collision_driver.collision

    def collision(*a, **kw):
        out = inner(*a, **kw)
        n = min(int(d.nacon.numpy()[0]), d.naconmax)
        perm = rng.permutation(n)
        for f in dataclasses.fields(d.contact):
            arr = getattr(d.contact, f.name)
            if arr.shape and arr.shape[0] == d.naconmax and n:   # skip (0,)-shaped flex fields
                v = arr.numpy()
                v[:n] = v[:n][perm]
                arr.assign(v)
        return out

    with mock.patch.object(collision_driver, "collision", collision):
        yield


mjm = mujoco.MjModel.from_xml_string(box_stack(5))
m = mjw.put_model(mjm)
m.opt.deterministic = mjw.DeterminismType.ATOMICS
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
qvel0 = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
qvel0[:, 24] = np.linspace(0.8, 1.6, NWORLD)              # topple the stack, differently per world
init = snap(arrays_of(d))
init["d.qvel"] = qvel0
DATA_MB = sum(v.nbytes for v in init.values()) / 1e6


def run(label, replay=None, shuffle_seed=None, trace=None):
    for k, arr in arrays_of(d).items():
        if arr.size:
            arr.assign(init[k])
    with contextlib.ExitStack() as st:
        if shuffle_seed is not None:
            st.enter_context(shuffled_contacts(d, shuffle_seed))
        if replay is not None:                 # entered last: wraps the shuffled collision
            st.enter_context(replay.patch())
        for _ in range(NSTEP):
            mjw.step(m, d)
            if trace is not None:
                trace.append(d.qpos.numpy().copy())
    assert not d.overflow.numpy().any(), "overflow: raise nconmax/njmax"
    return {f: getattr(d, f).numpy().copy() for f in PHYSICS}


def compare(r1, r2):
    same = [f for f in PHYSICS if r1[f].tobytes() == r2[f].tobytes()]
    return np.abs(r1["qpos"] - r2["qpos"]).max(), len(same) == len(PHYSICS)


rep = Replay(d)
ta, tb, tc = [], [], []
ref = run("A", replay=rep, trace=ta)
print(f"device: {wp.get_device()} | nworld {NWORLD} | {NSTEP} steps | ATOMICS"
      f" | tape = {DATA_MB:.2f} MB Data x 4 x {NSTEP} = {DATA_MB * 4 * NSTEP / 1e3:.2f} GB host RAM")
print(f"run A (record)           : recorded {len(rep.calls)} stage calls"
      f" ({sum(c[0] == 'collision' for c in rep.calls)} collision,"
      f" {sum(c[0] == 'make_constraint' for c in rep.calls)} make_constraint)")
r = run("A2")
dq, same = compare(ref, r)
print(f"run A2 (plain rerun)     : max |dqpos| = {dq:.3g}, bitwise equal to A: {same}")
r = run("B", shuffle_seed=1, trace=tb)
dq, same = compare(ref, r)
print(f"run B (shuffled slots)   : max |dqpos| = {dq:.3g}, bitwise equal to A: {same}")
r = run("C", replay=rep, shuffle_seed=1, trace=tc)
dq, same = compare(ref, r)
print(f"run C (shuffled + replay): max |dqpos| = {dq:.3g}, bitwise equal to A: {same},"
      f" stage checks passed: {rep.checked}")

dqb = np.abs(np.array(ta) - np.array(tb)).max(axis=(1, 2))
dqc = np.abs(np.array(ta) - np.array(tc)).max(axis=(1, 2))
first = int(np.argmax(dqb > 0)) + 1 if (dqb > 0).any() else None
print(f"shuffled run first differs at step {first} (by {dqb[first - 1] if first else 0:.1e});"
      f" |dqpos| after 10/30/{NSTEP} steps: {dqb[9]:.1e} / {dqb[29]:.1e} / {dqb[-1]:.1e}")

if args.dump_json:
    lg = lambda a: [round(float(np.log10(max(x, 1e-12))), 3) for x in a]
    out = {"nworld": NWORLD, "nstep": NSTEP, "dt": float(mjm.opt.timestep),
           "log10_dq_shuffled": lg(dqb), "log10_dq_replayed": lg(dqc)}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, NSTEP, "frames")
