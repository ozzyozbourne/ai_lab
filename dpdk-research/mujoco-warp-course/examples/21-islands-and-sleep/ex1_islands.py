"""Example 21.1 - constraint islands: who is coupled to whom.

Six boxes, one kinematic tree each. Five rest on the floor (each touches only the static floor),
box 3 hangs in the air (no constraint at all). With sleep enabled, mjw.forward runs island
discovery; with sleep disabled it does not, but the public mjw.island(m, d) still works.
C MuJoCo (mj_forward) is printed for comparison: it always computes islands.

Run: python ex1_islands.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2

Z = [0.099, 0.099, 0.099, 0.6, 0.099, 0.099]   # box 3 starts in the air


def boxes_xml(sleep):
    flag = '<flag sleep="enable"/>' if sleep else ""
    bodies = "".join(
        f'<body name="box{i}" pos="{0.5 * i:.2f} 0 {z}"><freejoint/>'
        f'<geom type="box" size=".1 .1 .1"/></body>' for i, z in enumerate(Z))
    return (f'<mujoco><option timestep="0.01" solver="Newton">{flag}</option><worldbody>'
            f'<geom name="floor" type="plane" size="5 5 .1"/>{bodies}</worldbody></mujoco>')


for sleep in (True, False):
    mjm = mujoco.MjModel.from_xml_string(boxes_xml(sleep))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
    print(f"--- sleep {'enabled' if sleep else 'disabled'}: ntree {mjm.ntree}, nv {mjm.nv}")
    print("  island arrays allocated:", "tree_island", d.tree_island.shape,
          "nisland", d.nisland.shape, "efc.island", d.efc.island.shape)
    mjw.forward(m, d)
    print("  after forward:     nisland", d.nisland.numpy()[0],
          "tree_island", d.tree_island.numpy()[0], "nefc", d.nefc.numpy()[0])
    mjw.island(m, d)                        # public entry point: island discovery only
    print("  after mjw.island:  nisland", d.nisland.numpy()[0],
          "tree_island", d.tree_island.numpy()[0])

mjd = mujoco.MjData(mjm)
mujoco.mj_forward(mjm, mjd)
print("C MuJoCo mj_forward: nisland", mjd.nisland, "tree_island", mjd.tree_island)
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
