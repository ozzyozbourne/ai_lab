"""Example 11.10 - mjw.jac: the Jacobian of the pendulum tip, per world, vs mujoco.mj_jacSite.

mjw.jac(m, d, jacp, jacr, point, body) fills jacp/jacr of shape (nworld, 3, nv) for one point per
world (point: wp.array of vec3, body: wp.array of int, both length nworld). It needs subtree_com
and cdof, so run kinematics + com_pos (or fwd_position / forward) first. Here every world has its
own random pose and we ask for the tip site's Jacobian.
Run: python ex10_site_jacobian.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""
ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
rng = np.random.default_rng(4)
qpos = rng.uniform(-np.pi, np.pi, (NWORLD, mjm.nq))
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)
mjw.com_pos(m, d)

site = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_SITE, "tip")
point = wp.array(d.site_xpos.numpy()[:, site], dtype=wp.vec3)          # (nworld,) vec3
body = wp.full(NWORLD, int(mjm.site_bodyid[site]), dtype=int)          # (nworld,) int
jacp = wp.zeros((NWORLD, 3, mjm.nv), dtype=float)
jacr = wp.zeros((NWORLD, 3, mjm.nv), dtype=float)
mjw.jac(m, d, jacp, jacr, point, body)

mjd = mujoco.MjData(mjm)
jp, jr = np.zeros((3, mjm.nv)), np.zeros((3, mjm.nv))
err = 0.0
for w in range(NWORLD):
    mjd.qpos[:] = qpos[w]
    mujoco.mj_kinematics(mjm, mjd)
    mujoco.mj_comPos(mjm, mjd)
    mujoco.mj_jacSite(mjm, mjd, jp, jr, site)
    err = max(err, np.abs(jacp.numpy()[w] - jp).max(), np.abs(jacr.numpy()[w] - jr).max())
print("jacp shape:", jacp.shape, " world 0 q =", qpos[0])
print("world 0 jacp (rows x, y, z; columns hinge1, hinge2):\n", jacp.numpy()[0])
print("world 0 jacr:\n", jacr.numpy()[0])
print(f"max |mjw.jac - mj_jacSite| over {NWORLD} worlds: {err:.2e}")
v_tip = jacp.numpy()[0] @ np.array([1.0, 0.0])
print("tip velocity for qdot = (1, 0):", v_tip, " |v| =", round(float(np.linalg.norm(v_tip)), 4),
      "= distance hinge1 -> tip")
