"""Example 9.5 - a shared pool is not fair: one world uses up the contacts, the other starves.

Six boxes rest on a plane in 2 worlds. With nconmax=4, njmax=8 the pool has naconmax = 8 slots
for 2 x 24 contacts. We print the counters and the decoded overflow bits, then compare box
heights against a run with nconmax=48, njmax=128.
Run: python ex5_overflow_starvation.py [--dump-json PATH]
  --dump-json PATH writes box heights and overflow bits per frame (replay player + LED panel).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

BOXES = "".join(f'<body pos="{0.25 * i} 0 0.09"><freejoint/>'
                f'<geom type="box" size=".1 .1 .1"/></body>'
                for i in range(6))
SIX_BOXES = f'<mujoco><worldbody><geom type="plane" size="5 5 .1"/>{BOXES}</worldbody></mujoco>'

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 2           # the lesson needs exactly two worlds competing for one small pool
NSTEP = 200          # 0.4 s at the default timestep 0.002

mjm = mujoco.MjModel.from_xml_string(SIX_BOXES)
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0      # silence device printf warnings; bits are still recorded (Ex 9.10)


def run(nconmax, njmax, verbose):
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=nconmax, njmax=njmax)
    print(f"\nnconmax={nconmax}, njmax={njmax} -> naconmax={d.naconmax}, njmax={d.njmax}")
    z, bits, counters = [], [], []
    for i in range(NSTEP):
        mjw.step(m, d)
        if i % 4 == 0:      # decimated host reads: this example is about the counters
            z.append(d.qpos.numpy()[:, 2::7].round(3).tolist())     # z of the 6 free joints
            bits.append(d.overflow.numpy().tolist())
            counters.append([int(d.nacon.numpy()[0]), int(d.ncollision.numpy()[0])]
                            + d.nefc.numpy().tolist())
        if verbose and i < 3:
            names = [mjw.OverflowType(int(b)).name for b in d.overflow.numpy()]
            print(f"step {i}: nacon={d.nacon.numpy()} ncollision={d.ncollision.numpy()}"
                  f" nefc={d.nefc.numpy()} overflow={names}")
    print("box z after 0.4 s:\n", d.qpos.numpy()[:, 2::7])
    print("overflow:", [mjw.OverflowType(int(b)).name for b in d.overflow.numpy()])
    return z, bits, counters


za, bits_a, cnt_a = run(4, 8, verbose=True)
zb, bits_b, cnt_b = run(48, 128, verbose=False)

if args.dump_json:
    dt = 4 * float(mjm.opt.timestep)
    frames = [[a[0], a[1], b[0], b[1]] for a, b in zip(za, zb)]
    out = {"nworld": 4, "dt": dt, "kind": "boxes", "zmin": -1.0, "zmax": 0.3,
           "labels": ["nconmax=4, world 0", "nconmax=4, world 1",
                      "nconmax=48, world 0", "nconmax=48, world 1"],
           "frames": frames, "overflow": bits_a, "counters": cnt_a,
           "counters_names": ["nacon", "ncollision", "nefc w0", "nefc w1"],
           "naconmax": 8, "njmax": 8}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
