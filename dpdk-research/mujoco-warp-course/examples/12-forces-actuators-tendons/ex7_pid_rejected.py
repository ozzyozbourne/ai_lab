"""Example 12.7 - MuJoCo 4's <pid> actuator compiles, but MJWarp 4.0.1 rejects it.

io.py::put_model checks every actuator's trntype, dyntype, gaintype and biastype with np.isin
against MJWarp's own enums (types.TrnType, DynType, GainType, BiasType) and raises
NotImplementedError naming the MuJoCo enum values it does not support. A <pid> actuator has
gaintype mjGAIN_PID, which mjw.GainType does not list.
Run: python ex7_pid_rejected.py
"""
import mujoco
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

PID = """
<mujoco model="pid">
  <worldbody>
    <body>
      <joint name="j" type="hinge"/>
      <geom type="sphere" size=".1"/>
    </body>
  </worldbody>
  <actuator>
    <pid joint="j" kp="1"/>
  </actuator>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(PID)
print("compiled in mujoco", mujoco.__version__, ": gaintype",
      mujoco.mjtGain(mjm.actuator_gaintype[0]).name, "| biastype",
      mujoco.mjtBias(mjm.actuator_biastype[0]).name, "| nu =", mjm.nu)
try:
    mjw.put_model(mjm)
except NotImplementedError as e:
    print("NotImplementedError:", e)
print("mjw.DynType: ", [t.name for t in mjw.DynType])
print("mjw.GainType:", [t.name for t in mjw.GainType])
print("mjw.BiasType:", [t.name for t in mjw.BiasType])
print("MuJoCo has   ", [n for n in mujoco.mjtGain.__members__], "(mjGAIN_PID is missing in mjw)")
