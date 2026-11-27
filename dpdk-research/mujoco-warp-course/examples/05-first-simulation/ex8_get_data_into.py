"""Example 5.5 - get_data_into: copy ONE world back into a mujoco.MjData, and what it costs.

get_data_into filters the shared contact pool down to one world, reorders that world's
constraint rows the way C MuJoCo expects (contacts last and contiguous), and copies well over a
hundred device arrays to the host, one .numpy() at a time. Great for rendering or debugging
one world; far too slow for a training loop, where you read whole batched arrays instead.
Run: python ex8_get_data_into.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/>
      <geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/>
      <geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 60
NREP = 20

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()

mjd = mujoco.MjData(mjm)                          # fresh host buffer: ncon = 0, nefc = 0
print("fresh MjData : ncon", mjd.ncon, "nefc", mjd.nefc)
mjw.get_data_into(mjd, mjm, d, world_id=3)
print("world 3      : ncon", mjd.ncon, "nefc", mjd.nefc, "time", round(mjd.time, 4))
print("world 3 qpos :", mjd.qpos)
print("pool holds", int(d.nacon.numpy()[0]), "contacts for all", NWORLD, "worlds; worldids:",
      d.contact.worldid.numpy()[: int(d.nacon.numpy()[0])][:12], "...")
print("world 3 contact geom pairs:", [tuple(int(g) for g in c.geom) for c in mjd.contact])

t0 = time.perf_counter()
for _ in range(NREP):
    mjw.get_data_into(mjd, mjm, d, world_id=3)
t_gdi = (time.perf_counter() - t0) / NREP
t0 = time.perf_counter()
for _ in range(NREP):
    q = d.qpos.numpy()                            # every world's qpos in one copy
t_np = (time.perf_counter() - t0) / NREP
print(f"get_data_into (1 world)     : {t_gdi * 1e3:7.2f} ms per call")
print(f"d.qpos.numpy() (all worlds) : {t_np * 1e3:7.3f} ms per call, shape {q.shape}")
print(f"ratio ~ {t_gdi / t_np:.0f}x (CPU dev box; on a GPU each copy also crosses PCIe)")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
