"""Example 9.6 - the default budgets overflow on a modest scene: box_stack(6).

A 6-box tower needs 24 contacts x 4 pyramidal rows = 96 efc rows per world, but the default
njmax for a rigid model is 64. The tower sinks, then the solver throws it into the air. With
njmax=128 it simply stands. The bits stay lit after the cause is gone (sticky).
Run: python ex6_default_overflow.py [--dump-json PATH]
  --dump-json PATH writes per-step d.overflow, nefc, nacon and box heights (LED panel).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)


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
NSTEP = 300                                  # 1.5 s at dt = 0.005

mjm = mujoco.MjModel.from_xml_string(box_stack(6))
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0                      # bits only, no printf (see Example 9.10)

dump = {}
for label, njmax in (("defaults", None), ("njmax=128", 128)):
    d = mjw.make_data(mjm, nworld=NWORLD, njmax=njmax)     # nconmax left at its default
    print(f"\n{label}: naconmax={d.naconmax} ({d.naconmax // NWORLD} per world), njmax={d.njmax}")
    rec = {"overflow": [], "nefc": [], "nacon": [], "z": []}
    first = None
    for i in range(NSTEP):
        mjw.step(m, d)
        if first is None and d.overflow.numpy()[0]:
            first = i
            nefc0 = int(d.nefc.numpy()[0])
            print(f"  first overflow at step {i}: nefc[w0]={nefc0} > njmax={d.njmax}")
        if i % 5 == 0:
            rec["overflow"].append(d.overflow.numpy()[:4].tolist())
            rec["nefc"].append(d.nefc.numpy()[:4].tolist())
            rec["nacon"].append(int(d.nacon.numpy()[0]))
            rec["z"].append(d.qpos.numpy()[0, 2::7].round(3).tolist())
        if i in (20, 120, 160) and label == "defaults":
            ov = int(d.overflow.numpy()[0])
            nacon, nefc0 = int(d.nacon.numpy()[0]), int(d.nefc.numpy()[0])
            print(f"  step {i:3d}: nacon={nacon:3d} nefc[w0]={nefc0:3d}"
                  f"  overflow[w0]={ov} = {mjw.OverflowType(ov).name}")
    ov = d.overflow.numpy()
    print("  top box z, world 0:", round(float(d.qpos.numpy()[0, 2 + 7 * 5]), 3))
    print("  nefc per world (last step):", d.nefc.numpy()[:4], "...")
    print("  overflow per world:", ov[:4], "->", mjw.OverflowType(int(ov[0])).name)
    print("  NEFC set:", bool(ov[0] & mjw.OverflowType.NEFC))
    dump[label] = rec

if args.dump_json:
    out = {"nworld": 4, "dt": 5 * float(mjm.opt.timestep), "njmax_default": 64,
           "naconmax_default": 48 * NWORLD, "nworld_run": NWORLD,
           "bits": [t.name for t in mjw.OverflowType], "values": [int(t) for t in mjw.OverflowType],
           "runs": dump}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(dump["defaults"]["nefc"]), "frames per run")
