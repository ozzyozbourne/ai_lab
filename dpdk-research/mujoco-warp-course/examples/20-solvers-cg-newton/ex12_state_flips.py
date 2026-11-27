"""Example 20.12 - constraint state flips per Newton iteration (feeds the state-flip strip).

box_stack(5), one kicked mid-motion state, Newton, cold start (warmstart off). MJWarp does not
expose its per-iteration state, so we rerun the SAME solve with opt.iterations = 0, 1, 2, ... and
read d.efc.state after each run (iterations = 0 shows the states init_context computed at the
start point). A row whose state changes between iteration k-1 and k "flipped". For the pyramidal
cone, a flip into or out of QUADRATIC is exactly what makes _update_gradient_h_incremental add or
subtract one rank-1 term D_i J_i' J_i to the Hessian; iterations without flips take the stable
fast path. We repeat it for the elliptic cone, where contact rows can also be in the CONE state.
DeterminismType.CONTACTS | CONSTRAINT keeps the row order identical between the reruns (Ch 22).
Run: python ex12_state_flips.py [--dump-json PATH]
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

KMAX = 8
NAMES = {int(v): k.replace("mjCNSTRSTATE_", "")
         for k, v in mujoco.mjtConstraintState.__members__.items()}
SHORT = {"SATISFIED": "S", "QUADRATIC": "Q", "LINEARNEG": "-", "LINEARPOS": "+", "CONE": "C"}

dump = {"states": NAMES, "runs": {}}
for cone in ("PYRAMIDAL", "ELLIPTIC"):
    mjm = mujoco.MjModel.from_xml_string(box_stack(5))
    mjm.opt.cone = getattr(mujoco.mjtCone, f"mjCONE_{cone}")
    m = mjw.put_model(mjm)                       # Newton is the default solver
    m.opt.deterministic = int(mjw.DeterminismType.CONTACTS | mjw.DeterminismType.CONSTRAINT)
    d = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
    d.qvel.assign(np.random.default_rng(1).normal(0.0, 0.1, size=(1, mjm.nv)).astype(np.float32))
    for _ in range(20):
        mjw.step(m, d)
    state0 = {k: getattr(d, k).numpy().copy() for k in ("qpos", "qvel", "qacc_warmstart")}

    m.opt.disableflags |= mjw.DisableBit.WARMSTART
    m.opt.warn_overflow = 0
    m.opt.tolerance = wp.array([1e-12], dtype=float)   # do not stop early while logging
    rows, niters = [], []
    for k in range(KMAX + 1):
        m.opt.iterations = k
        for key, v in state0.items():
            getattr(d, key).assign(v)
        mjw.forward(m, d)
        n = int(d.nefc.numpy()[0])
        rows.append(d.efc.state.numpy()[0, :n].copy())
        niters.append(int(d.solver_niter.numpy()[0]))
    n = len(rows[0])
    print(f"\n{cone.lower()}: nefc={n}, Newton cold start, rows by state per iteration k")
    print("  k  niter  flips  quad flips  counts")
    flips_log = []
    for k, st in enumerate(rows):
        counts = {NAMES[s]: int(c) for s, c in zip(*np.unique(st, return_counts=True))}
        if k == 0:
            flips = quad_flips = 0
            flipped = []
        else:
            prev = rows[k - 1]
            flipped = np.nonzero(st != prev)[0].tolist()
            quad = int(mujoco.mjtConstraintState.mjCNSTRSTATE_QUADRATIC)
            quad_flips = int(np.sum((st == quad) != (prev == quad)))
            flips = len(flipped)
        flips_log.append(flipped)
        cstr = ", ".join(f"{name.lower()} {c}" for name, c in counts.items())
        print(f"  {k}  {niters[k]:5d}  {flips:5d}  {quad_flips:10d}  {cstr}")
    first = "".join(SHORT[NAMES[s]] for s in rows[0][:40])
    last = "".join(SHORT[NAMES[s]] for s in rows[-1][:40])
    print(f"  first 40 rows at k=0: {first}")
    print(f"  first 40 rows at k={KMAX}: {last}")
    ov = int(d.overflow.numpy()[0])             # sticky: set by the capped runs k < niter
    print("  overflow:", [b.name for b in mjw.OverflowType if ov & b] or "none",
          "(the bits are sticky: the runs that stopped at k < 4 set ITERATIONS)")
    dump["runs"][cone.lower()] = {"nefc": n, "niter": niters,
                                  "rows": [r.astype(int).tolist() for r in rows],
                                  "flipped": flips_log}

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
