"""Example 22.5 - a contact scene under NONE, ATOMICS and ALL, and how chaos amplifies low bits.

Part 1: box_stack(5) with a sideways push that topples the stack, NWORLD worlds, two runs per
mode. We print max |dqpos| between the runs and whether the raw contact slot order differed,
without asserting anything: on a GPU the slot order of contacts and constraint rows is still
racy in 4.0.1, because the CONTACTS and CONSTRAINT sorts are `pass` stubs
(collision_driver._sort_contacts, constraint._sort_constraints). So ALL behaves like ATOMICS, and
neither promises bitwise equal contact scenes. On Warp's CPU device every run matches.
Part 2 (the chaos amplifier): run B starts 1 ulp (float32) away in one coordinate, the size of
the noise a GPU reduction leaves behind. We record max |dqpos| per world over NCHAOS steps, on
NCHAOS_WORLD worlds only (the chart needs a few curves, and the per-step host copies stay small).
Run: python ex5_contact_scene_differences.py [--dump-json PATH]
  --dump-json PATH writes the per-world log10 |dqpos| curves for the chaos-amplifier chart.
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
NSTEP = 200 if ON_GPU else 40
NCHAOS = 400                                   # steps for part 2 (2 s of simulated time)
NCHAOS_WORLD = 64 if ON_GPU else 8             # worlds for part 2: 2 x 400 x 64 x 35 x 4 B = 7 MB of traces

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
DT = mjw.DeterminismType
rng = np.random.default_rng(0)
qvel0 = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
qvel0[:, 24] = rng.uniform(0.8, 1.6, NWORLD)   # push the top box (body 5, dof 24 = x velocity)


def rollout(mode, nstep, qpos_nudge=None, trace=None, nworld=NWORLD):
    m = mjw.put_model(mjm)
    m.opt.deterministic = mode
    d = mjw.make_data(mjm, nworld=nworld, nconmax=32, njmax=128)
    if qpos_nudge is not None:
        d.qpos.assign(qpos_nudge)
    d.qvel.assign(qvel0[:nworld])
    for i in range(nstep):
        mjw.step(m, d)
        if trace is not None:                  # host copy every step: fine for this demo
            trace.append(d.qpos.numpy().copy())
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    order = (d.contact.worldid.numpy()[:n].copy(), d.contact.geom.numpy()[:n].copy())
    assert not d.overflow.numpy().any(), "overflow: raise nconmax/njmax"
    return d.qpos.numpy().copy(), order


print(f"device: {wp.get_device()} | nworld {NWORLD} | {NSTEP} steps per run")
for mode in (DT.NONE, DT.ATOMICS, DT.ALL):
    qa, oa = rollout(mode, NSTEP)
    qb, ob = rollout(mode, NSTEP)
    differ = len(oa[0]) != len(ob[0]) or not all(np.array_equal(x, y) for x, y in zip(oa, ob))
    print(f"{mode.name:8s} (={int(mode)}) max |dqpos| run A vs B = {np.abs(qa - qb).max():.3g}"
          f" | contact order differed: {differ} | contacts {len(oa[0])}")

# Part 2: a 1-ulp nudge in the top box's z, the size of a reordered float32 sum
qpos1 = np.tile(mjm.qpos0, (NCHAOS_WORLD, 1)).astype(np.float32)
qpos1[:, 30] = np.nextafter(qpos1[:, 30], np.float32(1.0))    # body 5 z (qpos 28..34)
ta, tb = [], []
rollout(DT.NONE, NCHAOS, trace=ta, nworld=NCHAOS_WORLD)
rollout(DT.NONE, NCHAOS, qpos_nudge=qpos1, trace=tb, nworld=NCHAOS_WORLD)
dq = np.abs(np.array(ta) - np.array(tb)).max(axis=2)          # (NCHAOS, NCHAOS_WORLD)
print(f"1-ulp nudge: initial |dz| = {abs(float(qpos1[0, 30]) - float(np.float32(mjm.qpos0[30]))):.2e} m"
      " (vs run A's float32 start)")
for s in (1, 10, 50, 100, 200, 400):
    print(f"  after {s:3d} steps: max |dqpos| over worlds = {dq[s - 1].max():.2e}")

if args.dump_json:
    sl = list(range(0, NCHAOS, 5))
    curves = np.round(np.log10(np.maximum(dq[sl], 1e-12)), 3).T.tolist()
    out = {"nworld": NCHAOS_WORLD, "dt": 5 * float(mjm.opt.timestep), "nstep": NCHAOS, "decim": 5,
           "log10_dq": curves, "push": [round(float(v), 3) for v in qvel0[:NCHAOS_WORLD, 24]]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(sl), "frames")
