"""Example 9.4 - contact forces with mjw.contact_force, checked against Newton's law and C MuJoCo.

PLAYGROUND settles for 2 s. mjw.contact_force turns each contact's efc forces into a 6-D
force:torque, here in the world frame. The floor must hold up the 1 kg ball with ~9.81 N and the
8 kg box with ~78.5 N. get_data_into copies one world (and only its contacts) into an MjData.
Run: python ex4_contact_force.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

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
NSTEP = 200                                   # 2 s at dt = 0.01: everything has settled

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
for _ in range(NSTEP):
    mjw.step(m, d)

# one force:torque per contact slot; slots past nacon stay zero (the kernel returns early)
ids = wp.array(np.arange(d.naconmax), dtype=int)
force = wp.zeros(d.naconmax, dtype=wp.spatial_vector)
mjw.contact_force(m, d, ids, True, force)    # to_world_frame=True

n = min(int(d.nacon.numpy()[0]), d.naconmax)
f = force.numpy()[:n]                         # (n, 6): force xyz, then torque xyz
world = d.contact.worldid.numpy()[:n]
geom1 = d.contact.geom.numpy()[:n, 1]         # geom[0] = floor; geom[1] is pushed along +normal
ball_geom = mjm.body_geomadr[mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "ball")]
box_geom = mjm.body_geomadr[mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")]

g = -mjm.opt.gravity[2]
for name, gid, body in (("ball", ball_geom, "ball"), ("box", box_geom, "box")):
    mass = mjm.body_mass[mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, body)]
    sel = (geom1 == gid) & (world == 0)
    fz = f[sel, 2].sum()
    print(f"world 0 {name}: {sel.sum()} contact(s), total normal force {fz:7.3f} N"
          f"   m*g = {mass * g:7.3f} N")

per_world_ball = np.zeros(NWORLD)
np.add.at(per_world_ball, world[geom1 == ball_geom], f[geom1 == ball_geom, 2])
print("ball support force, first 4 worlds:", per_world_ball[:4])

# cross-check world 0 against C MuJoCo's mj_contactForce on the copied MjData
mjd = mujoco.MjData(mjm)
mjw.get_data_into(mjd, mjm, d, world_id=0)
print("get_data_into(world 0): mjd.ncon =", mjd.ncon, "(the pool holds", n, "contacts in total)")
c_force = np.zeros(6)
fz_c = 0.0
for i in range(mjd.ncon):
    mujoco.mj_contactForce(mjm, mjd, i, c_force)          # contact frame: normal first
    if mjd.contact.geom[i][1] == ball_geom:
        fz_c += (c_force[:3] @ mjd.contact.frame[i].reshape(3, 3))[2]
print(f"C mj_contactForce, ball: {fz_c:7.3f} N")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
