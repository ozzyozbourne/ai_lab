"""Example 9.8 - size nconmax and njmax from a measurement rollout (the sizing recipe).

1. Run the scene with generous budgets. 2. Track the worst case per world: contacts (bincount of
contact.worldid) and constraint rows (nefc). 3. Add a 25% margin and round up to the valid-size
ladder. 4. Re-run with the new sizes and confirm there is no overflow.
Run: python ex8_size_from_rollout.py [--dump-json PATH]
  --dump-json PATH writes per-step contact and row counts of 8 worlds (sizing chart).
"""
import argparse
import json
import math

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


# the same ladder io.py uses for its defaults: 16, 24, 32, 48, 64, 96, ... 8192
LADDER = [(2 + k % 2) * 2 ** (k // 2 + 3) for k in range(19)]


def round_up_ladder(x):
    return next((v for v in LADDER if v >= x), int(x))


parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 300

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0


def rollout(nconmax, njmax, seed=0):
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=nconmax, njmax=njmax)
    rng = np.random.default_rng(seed)
    qpos = np.tile(mjm.qpos0, (NWORLD, 1))
    for i in range(5):                                    # shift each box sideways a little
        qpos[:, 7 * i:7 * i + 2] += rng.uniform(-0.09, 0.09, (NWORLD, 2)) * (i > 0)
    d.qpos.assign(qpos)
    max_con = np.zeros(NWORLD, dtype=int)
    max_efc = np.zeros(NWORLD, dtype=int)
    trace = {"con": [], "efc": []}
    for i in range(NSTEP):
        mjw.step(m, d)
        n = min(int(d.nacon.numpy()[0]), d.naconmax)      # one host read per step: measuring only
        con = np.bincount(d.contact.worldid.numpy()[:n], minlength=NWORLD)
        max_con = np.maximum(max_con, con)
        max_efc = np.maximum(max_efc, d.nefc.numpy())
        if i % 5 == 0:
            trace["con"].append(con[:8].tolist())
            trace["efc"].append(d.nefc.numpy()[:8].tolist())
    return d, max_con, max_efc, trace


d, max_con, max_efc, trace = rollout(nconmax=256, njmax=1024)
print(f"measurement run: nworld={NWORLD}, {NSTEP} steps, nconmax=256, njmax=1024")
print("worst contacts per world:", max_con[:8], " max:", max_con.max())
print("worst nefc per world:    ", max_efc[:8], " max:", max_efc.max())
print("measurement run overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

nconmax = round_up_ladder(math.ceil(1.25 * max_con.max()))
njmax = round_up_ladder(math.ceil(1.25 * max_efc.max()))
print(f"recommended: nconmax={nconmax}, njmax={njmax}  (max * 1.25, rounded up to the ladder)")
print("mjw defaults for this model would be: nconmax=48, njmax=64")

d2, _, _, _ = rollout(nconmax, njmax, seed=1)               # check on a fresh draw of the scene
print("check run with the new sizes, other seed: overflow",
      "none" if not d2.overflow.numpy().any() else d2.overflow.numpy())

mjd = mujoco.MjData(mjm)                                  # C MuJoCo reference, unperturbed tower
worst = [0, 0]
for _ in range(NSTEP):
    mujoco.mj_step(mjm, mjd)
    worst = [max(worst[0], mjd.ncon), max(worst[1], mjd.nefc)]
print(f"C MuJoCo, unperturbed tower: max ncon={worst[0]}, max nefc={worst[1]}")

if args.dump_json:
    out = {"dt": 5 * float(mjm.opt.timestep), "nworld_run": NWORLD, "con": trace["con"],
           "efc": trace["efc"], "max_con": int(max_con.max()), "max_efc": int(max_efc.max()),
           "nconmax": nconmax, "njmax": njmax, "default_nconmax": 48, "default_njmax": 64}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(trace["con"]), "frames")
