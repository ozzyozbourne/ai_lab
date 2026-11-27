"""Example 12.3 - motor, position and velocity actuators are one formula with different numbers.

forward.py::_actuator_force (one thread per (world, actuator)) computes
    force = gain * ctrl_act + bias,  gain = gainprm[0] (+ gainprm[1]*length + gainprm[2]*velocity)
                                     bias = biasprm[0] + biasprm[1]*length + biasprm[2]*velocity
then clamps it to forcerange. The MJCF shortcuts only fill in gainprm/biasprm:
  <motor>    gain = 1,              bias = 0                    -> force = ctrl
  <position> gain = kp,             bias = -kp*length - kv*vel  -> force = kp*(ctrl - q) - kv*qdot
  <velocity> gain = kv,             bias = -kv*velocity         -> force = kv*(ctrl - qdot)
Run: python ex3_actuator_types.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

THREE = """
<mujoco model="three_actuators">
  <option gravity="0 0 0"/>
  <worldbody>
    <body>
      <joint name="j" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".03" mass="1"/>
    </body>
  </worldbody>
  <actuator>
    <motor    name="motor" joint="j" gear="1"/>
    <position name="pos"   joint="j" kp="20"/>
    <velocity name="vel"   joint="j" kv="3" forcerange="-2 2"/>
  </actuator>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(THREE)
for i in range(mjm.nu):
    a = mjm.actuator(i)
    print(f"{a.name:5s} gaintype={mujoco.mjtGain(a.gaintype[0]).name:12s} "
          f"biastype={mujoco.mjtBias(a.biastype[0]).name:12s} "
          f"gainprm[:3]={a.gainprm[:3]} biasprm[:3]={a.biasprm[:3]}")

m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=3)
# three worlds: (qpos, qvel) states; every world sends ctrl = [0.7, 0.5, 1.0]
d.qpos.assign(np.array([[0.0], [0.2], [-0.1]], dtype=np.float32))
d.qvel.assign(np.array([[0.0], [0.4], [-2.0]], dtype=np.float32))
d.ctrl.assign(np.tile(np.array([0.7, 0.5, 1.0], dtype=np.float32), (3, 1)))
mjw.forward(m, d)

force = d.actuator_force.numpy()
for w, (q, v) in enumerate([(0.0, 0.0), (0.2, 0.4), (-0.1, -2.0)]):
    expect = [0.7, 20 * (0.5 - q), float(np.clip(3 * (1.0 - v), -2, 2))]
    print(f"world {w}: q={q:+.1f} qdot={v:+.1f}  actuator_force={force[w]}  "
          f"formula={np.array(expect)}")
print("qfrc_actuator (sum over actuators, moment = gear = 1):", d.qfrc_actuator.numpy()[:, 0])
print("actuator_length = q * gear:", d.actuator_length.numpy()[:, 0])
