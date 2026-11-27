"""Example 24.6 - the knob board: which Option changes a captured graph sees.

For each knob we capture one step of box_stack(3) (CG solver, so the solver iterates), change
the knob, and run 10 steps three ways from the same saved state:
  graph   - replay the graph captured BEFORE the change
  new     - eager mjw.step with the new value
  old     - eager mjw.step with the old value (run before the change)
and count the Warp modules loaded by the first eager step after the change (new compiled code).
Verdict: live (graph == new), recapture (graph == old, no new code),
recompile + recapture (new code was compiled; the old graph cannot contain it).
The module count reads warp._src.context.user_modules (private Warp API, may change). Run it in a
fresh process (the notebook runs it with !python): a second run in the same Python session, or a
session that already used a value, finds those modules loaded (+mod 0).
Run: python ex6_knob_board.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from warp._src import context as wp_context      # private: only to count loaded modules

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 2
NSTEP = 10
SIG = int(mjw.State.INTEGRATION)

mjm = mujoco.MjModel.from_xml_string(box_stack(3))
mjm.opt.solver = mujoco.mjtSolver.mjSOL_CG       # CG iterates more than Newton: knobs show
mjm.opt.tolerance = 1e-10                        # put_model clamps this to 1e-6 (float32)


def set_array(arr, value):
    arr.fill_(value)                             # in place: same array object, new contents


KNOBS = [  # (field, what we do, function applying the change)
    ("timestep", "fill_(0.002)", lambda m: set_array(m.opt.timestep, 0.002)),
    ("gravity", "fill_((0, 0, -3))", lambda m: set_array(m.opt.gravity, wp.vec3(0.0, 0.0, -3.0))),
    ("tolerance", "fill_(0.1)", lambda m: set_array(m.opt.tolerance, 0.1)),
    ("iterations", "= 2", lambda m: setattr(m.opt, "iterations", 2)),
    ("ls_iterations", "= 1", lambda m: setattr(m.opt, "ls_iterations", 1)),
    ("integrator", "= RK4", lambda m: setattr(m.opt, "integrator", int(mjw.IntegratorType.RK4))),
    ("warn_overflow", "= ALL", lambda m: setattr(m.opt, "warn_overflow",
                                                  int(mjw.OverflowType.ALL))),
]


def loaded_modules():
    return sum(len(mod.execs) for mod in wp_context.user_modules.values())


def measure(change):
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0                      # quiet baseline (and a knob we test below)
    if wp.get_device().is_cuda and not wp.is_conditional_graph_supported():
        m.opt.graph_conditional = False          # Rule G fallback (CUDA < 12.4)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
    for _ in range(20):                          # let the boxes land, then kick them
        mjw.step(m, d)
    rng = np.random.default_rng(0)
    qvel = d.qvel.numpy()
    qvel[:, 0::6] += rng.normal(0.0, 1.0, (NWORLD, 3))
    d.qvel.assign(qvel)
    state = wp.zeros((NWORLD, mujoco.mj_stateSize(mjm, SIG)), dtype=float)
    mjw.get_state(m, d, state, SIG)
    with wp.ScopedCapture() as capture:
        mjw.step(m, d)
    graph = capture.graph

    def rollout(fn):
        mjw.set_state(m, d, state, SIG)
        for _ in range(NSTEP):
            fn()
        wp.synchronize()
        return d.qpos.numpy().copy()

    old = rollout(lambda: mjw.step(m, d))
    change(m)
    replay = rollout(lambda: wp.capture_launch(graph))
    before = loaded_modules()
    new = rollout(lambda: mjw.step(m, d))
    return replay, new, old, loaded_modules() - before


rows = []
print(f"device: {wp.get_device()}, nworld {NWORLD}, {NSTEP} steps per comparison")
print(f"{'knob':<14} {'change':<17} {'|g-new|':>9} {'|g-old|':>9} {'|new-old|':>9} "
      f"{'+mod':>4}  verdict")
for field, what, change in KNOBS:
    g, new, old, nmod = measure(change)
    e_gn, e_go, e_no = (float(np.abs(a - b).max()) for a, b in ((g, new), (g, old), (new, old)))
    if e_no > 0 and e_gn <= 0.1 * e_no:
        verdict = "live"
    elif nmod > 0:
        verdict = "recompile + recapture"
    elif e_no > 0 and e_go <= 0.1 * e_no:
        verdict = "recapture"
    else:
        verdict = "no visible effect"
    rows.append({"field": field, "change": what, "graph_vs_new": e_gn, "graph_vs_old": e_go,
                 "new_vs_old": e_no, "new_modules": nmod, "verdict": verdict})
    print(f"{field:<14} {what:<17} {e_gn:>9.2e} {e_go:>9.2e} {e_no:>9.2e} {nmod:>4}  {verdict}")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "nworld": NWORLD, "nstep": NSTEP,
                   "rows": [{k: (float(f"{v:.3g}") if isinstance(v, float) else v)
                             for k, v in r.items()} for r in rows]}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
