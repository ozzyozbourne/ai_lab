"""Example 26.5 - a USER-gain actuator filled by m.callback.act_gain, and what forcerange does NOT do.

forward.py::fwd_actuation first launches _actuator_force (ctrl clamp, gain, bias, forcerange) and
only then calls m.callback.act_dyn, act_gain and act_bias. For gaintype="user" the kernel leaves
gain = 0 ("GainType.USER: gain stays 0, modified by act_gain_callback"), so its force is 0. The
callback must write the FINAL force into d.actuator_force, and forcerange is not applied again.
Here force = custom_gain(q) * ctrl with custom_gain(q) = 2 + 3 sin(q)^2 and forcerange="-1 1".
C MuJoCo, for comparison, calls its mjcb_act_gain for the gain and then clamps to forcerange.
Run: python ex5_act_gain_callback.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ARM = """
<mujoco model="user_gain_arm">
  <option timestep="0.01"/>
  <worldbody>
    <body name="arm" pos="0 0 1">
      <joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03" mass="1"/>
    </body>
  </worldbody>
  <actuator>
    <general name="u" joint="hinge" gaintype="user" biastype="none"
             forcerange="-1 1" forcelimited="true" ctrlrange="-2 2" ctrllimited="true"/>
  </actuator>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4


@wp.func
def custom_gain(q: float) -> float:
    s = wp.sin(q)
    return 2.0 + 3.0 * s * s


@wp.kernel
def user_gain_force(
    # Data in:
    qpos_in: wp.array2d[float],
    ctrl_in: wp.array2d[float],
    # Data out:
    actuator_force_out: wp.array2d[float],
):
    worldid = wp.tid()
    # actuator 0 drives qpos[0]; ctrl is read raw here (the kernel's clamp is not visible to us)
    actuator_force_out[worldid, 0] = custom_gain(qpos_in[worldid, 0]) * ctrl_in[worldid, 0]


def act_gain(m, d):
    wp.launch(user_gain_force, dim=d.nworld, inputs=[d.qpos, d.ctrl], outputs=[d.actuator_force])


mjm = mujoco.MjModel.from_xml_string(ARM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
print("gaintype USER:", int(mjm.actuator_gaintype[0]) == int(mujoco.mjtGain.mjGAIN_USER),
      "| forcerange:", mjm.actuator_forcerange[0])

q = np.linspace(0.0, 1.2, NWORLD, dtype=np.float32)
u = np.array([0.4, 0.8, -1.0, 1.5], dtype=np.float32)[np.arange(NWORLD) % 4]
d.qpos.assign(q.reshape(NWORLD, 1))
d.ctrl.assign(u.reshape(NWORLD, 1))

mjw.forward(m, d)
print("no callback:   actuator_force =", d.actuator_force.numpy()[:4, 0], "(gain stays 0)")

m.callback.act_gain = act_gain
mjw.forward(m, d)
f = d.actuator_force.numpy()[:, 0]
expected = (2.0 + 3.0 * np.sin(q) ** 2) * u
print("with callback: actuator_force =", f[:4])
print("formula g(q) * ctrl           =", expected[:4])
print("qfrc_actuator (gear 1)        =", d.qfrc_actuator.numpy()[:4, 0])
assert np.allclose(f, expected, atol=1e-5)
assert (np.abs(f) > 1.0).any(), "expected some force outside forcerange"
print("forcerange [-1, 1] reapplied after the callback?", bool((np.abs(f) <= 1.0).all()))

# C MuJoCo: mjcb_act_gain supplies the GAIN; force = gain * ctrl, then forcerange clamps it
mujoco.set_mjcb_act_gain(lambda mm, dd, i: 2.0 + 3.0 * np.sin(dd.qpos[0]) ** 2)
try:
    mjd = mujoco.MjData(mjm)
    c_force = []
    for w in range(4):
        mjd.qpos[0], mjd.ctrl[0] = q[w], u[w]
        mujoco.mj_forward(mjm, mjd)
        c_force.append(float(mjd.actuator_force[0]))
    print("C MuJoCo (gain cb + clamp)    =", np.array(c_force, dtype=np.float32))
finally:
    mujoco.set_mjcb_act_gain(None)
