"""Example 25.8 - apply the tuning checklist to box_stack(8), one knob at a time.

Each row changes one thing relative to the row it builds on and reports world-steps/s, the mean
solver iteration count, the overflow flags and a correctness probe (mean height of the top box
after NSTEP steps; a settled 8-box stack keeps it near 1.5). A faster row that overflows or moves
the probe is not a valid speed-up. Eager stepping on CPU; CUDA-graph replay on GPU (Ch 24).
CPU numbers are CPU numbers: they rank Python + serial kernels, not GPU throughput.
Run: python ex8_tuning_study.py [--dump-json PATH]
"""
import argparse
import json
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.io import override_model     # private API

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 60
NBOX = 8


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


mjm = mujoco.MjModel.from_xml_string(box_stack(NBOX))
m0 = mjw.put_model(mjm)
print(f"box_stack({NBOX}): nv={mjm.nv}, opt.iterations={mjm.opt.iterations}, "
      f"ls_iterations={mjm.opt.ls_iterations}, broadphase={m0.opt.broadphase.name}")
print("launch config m.block_dim (experimental): update_gradient_grad =",
      m0.block_dim.update_gradient_grad, "(nv rounded up to 32, clamped to 32..256),",
      "nxn_broadphase =", m0.block_dim.nxn_broadphase, "| on CPU Warp runs block_dim 1")

# label, sizes (nconmax, njmax), overrides; each row builds on an earlier one
SIZED = (40, 160)
ROWS = [
    ("1 defaults", (None, None), []),
    ("2 + sized nconmax/njmax", SIZED, []),
    ("3 + iterations=10, ls_iterations=10", SIZED, ["opt.iterations=10", "opt.ls_iterations=10"]),
    ("4 + broadphase=sap_tile", SIZED, ["opt.iterations=10", "opt.ls_iterations=10",
                                         "opt.broadphase=sap_tile"]),
    ("5 cost of deterministic=true", SIZED, ["opt.iterations=10", "opt.ls_iterations=10",
                                              "opt.deterministic=true"]),
    ("6 too far: cg, iterations=3", SIZED, ["opt.solver=cg", "opt.iterations=3"]),
]
NAMES = {int(o): o.name for o in mjw.OverflowType if int(o) and int(o) & (int(o) - 1) == 0}


def run(sizes, overrides):
    m = mjw.put_model(mjm)
    if overrides:
        override_model(m, overrides)
    m.opt.warn_overflow = 0                         # wp.static: set before the first launch
    if ON_GPU and not wp.is_conditional_graph_supported():
        m.opt.graph_conditional = False
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=sizes[0], njmax=sizes[1])
    mjw.step(m, d)                                  # warm-up / JIT
    mjw.reset_data(m, d)
    wp.synchronize()
    if ON_GPU:
        with wp.ScopedCapture() as cap:
            mjw.step(m, d)
        mjw.reset_data(m, d)
        step = lambda: wp.capture_launch(cap.graph)          # noqa: E731
    else:
        step = lambda: mjw.step(m, d)                        # noqa: E731
    t0 = time.perf_counter()
    for _ in range(NSTEP):
        step()
    wp.synchronize()
    sps = NWORLD * NSTEP / (time.perf_counter() - t0)
    bits = int(np.bitwise_or.reduce(d.overflow.numpy()))
    flags = "|".join(n for v, n in NAMES.items() if bits & v) or "none"
    top = float(d.qpos.numpy()[:, 7 * (NBOX - 1) + 2].mean())
    return sps, float(d.solver_niter.numpy().mean()), flags, top, d


print(f"\n{'row (CPU eager)' if not ON_GPU else 'row (GPU graph)':<38}{'naconmax':>9}{'njmax':>6}"
      f"{'steps/s':>9}{'niter':>6}{'top z':>7}  overflow")
results = []
for label, sizes, ov in ROWS:
    sps, nit, flags, top, d = run(sizes, ov)
    print(f"{label:<38}{d.naconmax:>9}{d.njmax:>6}{sps:>9,.0f}{nit:>6.1f}{top:>7.3f}  {flags}")
    results.append({"row": label, "naconmax": d.naconmax, "njmax": d.njmax, "sps": round(sps),
                    "niter": round(nit, 2), "top_z": round(top, 3), "overflow": flags})

ok = [r for r in results
      if r["overflow"] == "none" and abs(r["top_z"] - results[1]["top_z"]) < 0.01]
print("\nvalid rows (no overflow, probe unchanged):", ", ".join(r["row"][0] for r in ok))
print("invalid rows:", ", ".join(f"{r['row'][0]} ({r['overflow']}, top z {r['top_z']})"
                                 for r in results if r not in ok))
if ON_GPU:
    best = max(ok, key=lambda r: r["sps"])
    print(f"fastest valid row: {best['row']} ({best['sps'] / results[1]['sps']:.2f}x row 2)")
else:
    sps = [r["sps"] for r in ok]
    print(f"CPU: valid rows differ by {100 * (max(sps) / min(sps) - 1):.0f}% "
          "(timing noise at this size); rank them on a GPU")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "nstep": NSTEP, "device": str(wp.get_device()),
                   "rows": results}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
