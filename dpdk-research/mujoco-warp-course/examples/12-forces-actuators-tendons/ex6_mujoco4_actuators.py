"""Example 12.6 - MuJoCo 4 actuators: nu controls vs nactuator actuators, the DC motor, SO3.

MuJoCo 4 lets one actuator read several control slots. m.nu counts control slots (the width of
d.ctrl), m.nactuator counts actuators. Actuator i reads ctrl[actuator_ctrladr[i] :
actuator_ctrladr[i] + actuator_ctrlnum[i]], and actuator_ctrlspec[i] is a CtrlInput bit mask
(POS=1, VEL=2, FF=4, VOLTAGE=8) saying what those slots mean.
(a) <dcmotor input="voltage">: one slot, force = (K/R) V - (K^2/R) qdot  (util_misc.dcmotor_*).
    A second dcmotor with input="pos vel" and controller="kp ki kd" is a position servo built on
    the motor model: two slots, so nu > nactuator.
(b) an SO3 ball-joint actuator compiles in MuJoCo 4.0.1 but put_model rejects its transmission.
Run: python ex6_mujoco4_actuators.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=5, suppress=True)


def spec_name(v):
    """Decode actuator_ctrlspec; 0 means a classic actuator that reads one plain ctrl."""
    return mjw.CtrlInput(int(v)).name or "0 (plain ctrl)"


DCMOTOR = """
<mujoco model="dcmotor">
  <option gravity="0 0 0"/>
  <worldbody>
    <body>
      <joint name="joint" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".03" mass="1"/>
    </body>
  </worldbody>
  <actuator>
    <dcmotor name="dcmotor" joint="joint" input="voltage" motorconst="0.05" resistance="2.0"/>
  </actuator>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(DCMOTOR)
print("(a) dcmotor: nu =", mjm.nu, "| nactuator =", mjm.nactuator,
      "| actuator_ctrladr =", mjm.actuator_ctrladr, "| actuator_ctrlnum =", mjm.actuator_ctrlnum,
      "| ctrlspec =", spec_name(mjm.actuator_ctrlspec[0]))
print("    dyn/gain/bias:", mjw.DynType(mjm.actuator_dyntype[0]).name,
      mjw.GainType(mjm.actuator_gaintype[0]).name, mjw.BiasType(mjm.actuator_biastype[0]).name,
      "| gainprm[:2] (R, K) =", mjm.actuator_gainprm[0, :2])
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=3)
d.ctrl.fill_(1.0)                                         # 1 V in every world
d.qvel.assign(np.array([[0.0], [10.0], [20.0]], dtype=np.float32))
mjw.forward(m, d)
R, K = 2.0, 0.05
print("    ctrl = 1 V, qvel = [0, 10, 20]: actuator_force =",
      d.actuator_force.numpy()[:, 0].round(5) + 0.0)
print("    formula (K/R)(V - K qdot) =", np.array([K / R * (1 - K * v) for v in (0, 10, 20)]),
      "<- at qdot = V/K = 20 rad/s the back-EMF cancels the voltage")

SERVO = DCMOTOR.replace(
    "</actuator>",
    '  <dcmotor name="servo" joint="joint" input="pos vel" motorconst="0.05" resistance="2.0"\n'
    '             controller="10 0 1"/>\n    <motor name="extra" joint="joint"/>\n  </actuator>')
mjm2 = mujoco.MjModel.from_xml_string(SERVO)
print("    + servo dcmotor (input='pos vel') + motor: nu =", mjm2.nu, "| nactuator =",
      mjm2.nactuator, "| ctrladr =", mjm2.actuator_ctrladr, "| ctrlnum =",
      mjm2.actuator_ctrlnum)
for i in range(mjm2.nactuator):
    a, n = mjm2.actuator_ctrladr[i], mjm2.actuator_ctrlnum[i]
    print(f"      actuator {i} ({mjm2.actuator(i).name:7s}) reads ctrl[{a}:{a + n}] as",
          spec_name(mjm2.actuator_ctrlspec[i]))
m2 = mjw.put_model(mjm2)
d2 = mjw.make_data(mjm2, nworld=1)
d2.ctrl.assign(np.array([[1.0, 0.3, 0.0, 0.5]], dtype=np.float32))
d2.qpos.fill_(0.1)
d2.qvel.fill_(0.2)
mjw.forward(m2, d2)
print("    ctrl = [1, 0.3, 0, 0.5], q = 0.1, qdot = 0.2: actuator_force =",
      d2.actuator_force.numpy()[0], "| servo formula kp(0.3-q) + kd(0-qdot) =",
      round(10 * (0.3 - 0.1) + 1 * (0.0 - 0.2), 5))

SO3 = """
<mujoco model="so3">
  <worldbody>
    <body>
      <joint name="b" type="ball"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".03" mass="1"/>
    </body>
  </worldbody>
  <actuator>
    <general joint="b" gaintype="so3" biastype="so3" gainprm="10" biasprm="0 -10 -1"/>
  </actuator>
</mujoco>
"""
mjm3 = mujoco.MjModel.from_xml_string(SO3)
print("(b) SO3 actuator compiles in MuJoCo: actuator_trntype =", mjm3.actuator_trntype,
      mujoco.mjtTrn(mjm3.actuator_trntype[0]).name, "| nu =", mjm3.nu,
      "| nactuator =", mjm3.nactuator)
try:
    mjw.put_model(mjm3)
except NotImplementedError as e:
    print("    mjw.put_model raises NotImplementedError:", e)
print("    mjw.TrnType:", [t.name for t in mjw.TrnType])
