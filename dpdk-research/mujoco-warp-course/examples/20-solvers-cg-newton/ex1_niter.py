"""Example 20.1 - solver iterations per world: Newton vs CG, pyramidal vs elliptic cones.

box_stack(5) (nv 30) with njmax=128, so the 80 pyramidal rows fit. Every world starts with its own
random box velocities, so every world needs its own number of solver iterations. We step
NSTEP times for each of the four (solver, cone) combinations and print mean and max solver_niter.
solver and cone are compile-time settings: each combination compiles its own kernels once.
Run: python ex1_niter.py [--dump-json PATH]
  --dump-json PATH writes the per-config, per-world mean niter for the page's bar chart (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


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
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 50

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
rng = np.random.default_rng(0)
qvel0 = rng.normal(0.0, 0.5, size=(NWORLD, mjm.nv)).astype(np.float32)   # world-specific kicks
qvel0[0] = 0.0                                                         # world 0 starts at rest

results = {}
print(f"box_stack(5): nv={mjm.nv}, nworld={NWORLD}, {NSTEP} steps, njmax=128")
print(f"{'solver':7s} {'cone':10s} {'mean niter':>10s} {'max':>4s}  per-world mean niter")
for solver in ("NEWTON", "CG"):
    for cone in ("PYRAMIDAL", "ELLIPTIC"):
        mjm.opt.solver = getattr(mujoco.mjtSolver, f"mjSOL_{solver}")
        mjm.opt.cone = getattr(mujoco.mjtCone, f"mjCONE_{cone}")
        m = mjw.put_model(mjm)
        d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
        d.qvel.assign(qvel0)
        niter = np.zeros((NSTEP, NWORLD), dtype=np.int32)
        for i in range(NSTEP):
            mjw.step(m, d)
            niter[i] = d.solver_niter.numpy()   # one small readback per step (demo only)
        per_world = niter.mean(axis=0)
        with np.printoptions(precision=2, suppress=True):   # local: no global print state
            print(f"{solver:7s} {cone.lower():10s} {niter.mean():10.2f} {niter.max():4d}  "
                  f"{per_world[:8]}")
        ov = d.overflow.numpy()
        if ov.any():
            print("  overflow:", [b.name for b in mjw.OverflowType if (ov & b).any()])
        results[f"{solver.lower()}-{cone.lower()}"] = {
            "mean": round(float(niter.mean()), 3), "max": int(niter.max()),
            "per_world": [round(float(v), 3) for v in per_world[:64]]}
print("nefc in world 0 (last step):", int(d.nefc.numpy()[0]), "rows")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "nstep": NSTEP, "configs": results}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
