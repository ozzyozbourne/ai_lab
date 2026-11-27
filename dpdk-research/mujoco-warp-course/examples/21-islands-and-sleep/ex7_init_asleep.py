"""Example 21.7 - start every world asleep without sleep="init" (the cli.py --init_asleep pattern).

4.0.1 rejects body sleep="init", so mujoco_warp/_src/cli.py does this instead: write
mjd.tree_asleep[:] = np.arange(mjm.ntree) on the host (each tree is a sleep cycle of itself) and
then call put_data, which copies the host tree_asleep before it runs mj_kinematics (that call
would reset it). Every world starts asleep; a push wakes only the pushed tree.

Run: python ex7_init_asleep.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2

BODIES = "".join(
    f'<body name="box{i}" pos="{0.5 * i:.2f} 0 0.099"><freejoint/>'
    f'<geom type="box" size=".1 .1 .1"/></body>' for i in range(6))
XML = ('<mujoco><option timestep="0.01" solver="Newton"><flag sleep="enable"/></option>'
       f'<worldbody><geom type="plane" size="5 5 .1"/>{BODIES}</worldbody></mujoco>')

mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)

mjd = mujoco.MjData(mjm)
mjd.tree_asleep[:] = np.arange(mjm.ntree, dtype=np.int32)    # the --init_asleep line
d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=32, njmax=128)
print("after put_data: tree_asleep", d.tree_asleep.numpy()[0],
      "tree_awake", d.tree_awake.numpy()[0])

mjw.step(m, d)
print("after 1 step:   tree_asleep", d.tree_asleep.numpy()[0],
      "ntree_awake", d.ntree_awake.numpy(), "nefc", d.nefc.numpy(), "nacon", d.nacon.numpy())

xfrc = np.zeros((NWORLD, mjm.nbody, 6), dtype=np.float32)
xfrc[0, mjm.body("box4").id, 2] = 200.0                      # lift box 4 in world 0
d.xfrc_applied.assign(xfrc)
mjw.step(m, d)
print("after a push:   tree_asleep", d.tree_asleep.numpy()[0],
      "ntree_awake", d.ntree_awake.numpy(), "nefc", d.nefc.numpy())

ref = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
print("for comparison, make_data starts awake:", ref.tree_asleep.numpy()[0])
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
