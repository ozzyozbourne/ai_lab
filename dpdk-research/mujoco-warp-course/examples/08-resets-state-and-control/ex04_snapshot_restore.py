"""Example 8.4 - snapshot and restore the state of every world with get_state / set_state.

Two free boxes rest on a plane. After 150 steps we snapshot, run 30 steps (reference), restore,
run the same 30 steps again and compare. A QPOS|QVEL snapshot is "almost" exact; adding the
solver warmstart (State.PHYSICS | State.WARMSTART) makes the replay bitwise identical.
Run: python ex04_snapshot_restore.py [--dump-json PATH]
  --dump-json PATH writes mj_stateSize of every State bit for MOCAP_TARGET and PLAYGROUND
  (Rule D, state-packing widget).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

TWO_BOXES = """
<mujoco model="two_boxes">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="box1" pos="0 0 0.3" euler="10 20 0">
      <freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="box2" pos="0.05 0 0.6" euler="0 15 30">
      <freejoint/><geom type="box" size=".1 .1 .1"/></body>
  </worldbody>
</mujoco>
"""

MOCAP_TARGET = """
<mujoco model="mocap_target">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="target" mocap="true" pos="0 0 0.5">
      <geom type="box" size=".05 .05 .05" contype="0" conaffinity="0" rgba="0 1 0 .3"/>
    </body>
    <body name="box" pos="0 0 0.5">
      <freejoint/>
      <geom name="box" type="box" size=".05 .05 .05" mass="0.5" rgba=".3 .3 1 1"/>
    </body>
  </worldbody>
  <equality><weld body1="box" body2="target" solref="0.02 1"/></equality>
</mujoco>
"""

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8


# --- the helpers this chapter adds to my_env.py (same code as my_env_step08.py) ---
def snapshot(m, d, mjm, sig, buf=None):
    """Copy the state components in `sig` of every world into a (nworld, size) array."""
    size = mujoco.mj_stateSize(mjm, int(sig))
    if buf is None:
        buf = wp.zeros((d.nworld, size), dtype=float)
    # get_state does NOT check the size: an undersized buffer is written out of bounds.
    assert buf.shape == (d.nworld, size), f"state buffer {buf.shape} != {(d.nworld, size)}"
    mjw.get_state(m, d, buf, int(sig))
    return buf


def restore(m, d, mjm, buf, sig, active=None):
    """Write a snapshot back (optionally only where the per-world bool mask `active` is True)."""
    assert buf.shape == (d.nworld, mujoco.mj_stateSize(mjm, int(sig)))
    mjw.set_state(m, d, buf, int(sig), active)


mjm = mujoco.MjModel.from_xml_string(TWO_BOXES)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
for _ in range(150):  # boxes land and stack: contacts and warmstart are active
    mjw.step(m, d)
print("constraint rows (nefc) in world 0 after 150 steps:", int(d.nefc.numpy()[0]))

S = mjw.State
base = snapshot(m, d, mjm, S.INTEGRATION)    # everything, so each test starts from the same state
for name, sig in [("QPOS | QVEL", S.QPOS | S.QVEL),
                  ("PHYSICS", S.PHYSICS),
                  ("PHYSICS | WARMSTART", S.PHYSICS | S.WARMSTART),
                  ("TIME|PHYSICS|WARMSTART", S.TIME | S.PHYSICS | S.WARMSTART),
                  ("INTEGRATION", S.INTEGRATION)]:
    restore(m, d, mjm, base, S.INTEGRATION)
    buf = snapshot(m, d, mjm, sig)            # 1. snapshot
    for _ in range(30):                       # 2. reference rollout
        mjw.step(m, d)
    ref_q, ref_t = d.qpos.numpy().copy(), d.time.numpy().copy()
    restore(m, d, mjm, buf, sig)              # 3. restore (warmstart/time stay at the end values
    for _ in range(30):                       #    unless sig contains them) and replay
        mjw.step(m, d)
    dq = np.abs(d.qpos.numpy() - ref_q).max()
    same_t = bool(np.array_equal(d.time.numpy(), ref_t))
    print(f"{name:22s} size {mujoco.mj_stateSize(mjm, int(sig)):3d}  max |dqpos| = {dq:.3g}"
          f"  time replayed exactly: {same_t}")

print("State.PHYSICS =", int(S.PHYSICS), "includes TIME?", bool(S.PHYSICS & S.TIME))
print("State.FULLPHYSICS includes TIME?", bool(S.FULLPHYSICS & S.TIME))
try:
    snapshot(m, d, mjm, S.QPOS, buf=wp.zeros((NWORLD, 3), dtype=float))
except AssertionError as e:
    print("undersized buffer caught:", e)
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    bits = ["TIME", "QPOS", "QVEL", "ACT", "HISTORY", "WARMSTART", "CTRL", "QFRC_APPLIED",
            "XFRC_APPLIED", "EQ_ACTIVE", "MOCAP_POS", "MOCAP_QUAT", "USERDATA", "PLUGIN", "PLASTIC"]
    out = {"bits": {b: int(getattr(mujoco.mjtState, "mjSTATE_" + b)) for b in bits},
           "composites": {c: int(getattr(S, c)) for c in
                          ["PHYSICS", "FULLPHYSICS", "USER", "INTEGRATION"]},
           "models": {}}
    for mname, xml in [("MOCAP_TARGET", MOCAP_TARGET), ("PLAYGROUND", PLAYGROUND)]:
        mm = mujoco.MjModel.from_xml_string(xml)
        out["models"][mname] = {b: mujoco.mj_stateSize(mm, out["bits"][b]) for b in bits}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
