"""Example 22.8 - a reproducible run needs a complete snapshot: State.PHYSICS | State.WARMSTART.

box_stack(5) settles for NPRE steps. We snapshot with mjw.get_state, run NPOST steps (reference),
restore with mjw.set_state and run the same NPOST steps again. With QPOS|QVEL or PHYSICS the
replay starts from a different solver warmstart (d.qacc_warmstart keeps the END value of the
reference run), so the Newton solver converges to a slightly different qacc and the replay is
off in the low bits. Adding WARMSTART makes the replay exact on CPU. On a GPU the contact order
is racy, so even a complete snapshot is bitwise only up to the noise that ATOMICS cannot remove:
the notebook prints both modes so you can see your GPU's numbers.
Run: python ex8_snapshot_replay.py [--dump-json PATH]
  --dump-json PATH writes the table (mode, signature, size, max |dqpos|) for the page widget.
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
NPRE, NPOST = 100, 100
S = mjw.State

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
rows = []
print(f"device: {wp.get_device()} | nworld {NWORLD}"
      f" | snapshot at step {NPRE}, replay {NPOST} steps")
for mode in (mjw.DeterminismType.NONE, mjw.DeterminismType.ATOMICS):
    m = mjw.put_model(mjm)
    m.opt.deterministic = mode
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
    qvel = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
    qvel[:, 24] = np.linspace(0.0, 0.3, NWORLD)     # a small push on the top box, per world
    d.qvel.assign(qvel)
    for _ in range(NPRE):
        mjw.step(m, d)
    full = wp.zeros((NWORLD, mujoco.mj_stateSize(mjm, int(S.INTEGRATION))), dtype=float)
    mjw.get_state(m, d, full, int(S.INTEGRATION))  # so every signature starts from the same point
    for name, sig in [("QPOS|QVEL", S.QPOS | S.QVEL), ("PHYSICS", S.PHYSICS),
                      ("PHYSICS|WARMSTART", S.PHYSICS | S.WARMSTART)]:
        mjw.set_state(m, d, full, int(S.INTEGRATION))
        size = mujoco.mj_stateSize(mjm, int(sig))
        buf = wp.zeros((NWORLD, size), dtype=float)   # exact size: get_state does not check it
        mjw.get_state(m, d, buf, int(sig))
        for _ in range(NPOST):
            mjw.step(m, d)
        ref = d.qpos.numpy().copy()
        mjw.set_state(m, d, buf, int(sig))
        for _ in range(NPOST):
            mjw.step(m, d)
        dq = np.abs(d.qpos.numpy() - ref).max()
        exact = d.qpos.numpy().tobytes() == ref.tobytes()
        print(f"{mode.name:7s} {name:18s} size {size:3d}: max |dqpos| = {dq:.3g}  bitwise: {exact}")
        rows.append({"mode": mode.name, "sig": name, "size": size, "dq": float(dq), "exact": exact})
    ovf = d.overflow.numpy()
    print(f"{mode.name:7s} overflow:", "none" if not ovf.any() else ovf)

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "npre": NPRE, "npost": NPOST, "rows": rows}, f,
                  separators=(",", ":"))
    print("wrote", args.dump_json)
