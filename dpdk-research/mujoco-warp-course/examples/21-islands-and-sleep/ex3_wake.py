"""Example 21.3 - what wakes a sleeping tree.

Scene: a stack of two boxes (trees 0 and 1, one island) and three single boxes (trees 2, 3, 4)
spaced 0.1 m apart. We let everything fall asleep, then:
  A. apply xfrc_applied to the bottom stack box in world 0: sleep.wake sees a non-zero applied
     force and wakes the whole sleep cycle (both stack boxes), nothing else;
  B. write a velocity into box 2 in world 1: sleep.wake wakes box 2, it slides into box 3, and
     sleep.wake_collision wakes box 3 when an awake tree touches it.

Run: python ex3_wake.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2

XML = """
<mujoco>
  <option timestep="0.01" solver="Newton"><flag sleep="enable"/></option>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="stack0" pos="0 0 .1"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="stack1" pos="0 0 .3"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="box2" pos=".6 0 .1"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="box3" pos=".9 0 .1"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="box4" pos="1.2 0 .1"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)


def awake_trees(world):
    return [t for t, v in enumerate(d.tree_asleep.numpy()[world]) if v < 0]


for i in range(300):                              # settle until every tree sleeps
    mjw.step(m, d)
    if d.ntree_awake.numpy().max() == 0:
        break
print(f"all asleep after {i + 1} steps; tree_asleep w0 {d.tree_asleep.numpy()[0]}")
print("  (stack0 -> stack1 -> stack0 is one sleep cycle; 2, 3, 4 are self-cycles)")

# A. a force on the bottom stack box, world 0 only
xfrc = np.zeros((NWORLD, mjm.nbody, 6), dtype=np.float32)
xfrc[0, mjm.body("stack0").id, 0] = 5.0           # 5 N along +x
d.xfrc_applied.assign(xfrc)
mjw.step(m, d)
print("A. xfrc_applied on stack0 (w0): awake w0", awake_trees(0), "| awake w1", awake_trees(1))
d.xfrc_applied.zero_()

# B. a velocity written into box 2, world 1 only
qvel = d.qvel.numpy()
qvel[1, mjm.jnt_dofadr[mjm.body("box2").jntadr[0]]] = 2.0   # vx = 2 m/s
d.qvel.assign(qvel)
seen = []
for k in range(12):
    mjw.step(m, d)
    now = awake_trees(1)
    if now != (seen[-1][1] if seen else None):
        seen.append((k, now))
for k, now in seen:
    print(f"B. step {k:2d} after the qvel write: awake w1 {now}")

for i in range(300):                              # everything settles again
    mjw.step(m, d)
    if d.ntree_awake.numpy().max() == 0:
        break
print(f"asleep again after {i + 1} more steps; tree_asleep w1 {d.tree_asleep.numpy()[1]}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
