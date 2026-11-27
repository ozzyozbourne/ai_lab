"""Example 10.12 - actuator_lengthrange after gear randomization: mjw.set_length_range.

A muscle's force-length curve is defined over actuator_lengthrange (Ch 12). If you randomize the
gear (or the joint/tendon range), the length range must follow. In mujoco-warp 4.0.1
set_length_range copies jnt_range or tendon_range * gear for LIMITED joint and tendon
transmissions; every other actuator gets (0, 0), even if the XML gave it a range.
We load test_data/actuation/muscle.xml (one muscle on an unlimited tendon) and add, with MjSpec,
a range to its slide joint and a second muscle that drives that joint.
Run: python ex12_length_range.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

path = epath.resource_path("mujoco_warp") / "test_data/actuation/muscle.xml"
spec = mujoco.MjSpec.from_file(str(path))
joint = spec.joints[0]
joint.name = "slide"
joint.limited = mujoco.mjtLimited.mjLIMITED_TRUE
joint.range = [-0.25, 0.25]
act = spec.add_actuator()
act.name = "joint_muscle"
act.trntype = mujoco.mjtTrn.mjTRN_JOINT
act.target = "slide"
act.set_to_muscle(tausmooth=0.0)
mjm = spec.compile()

NWORLD = 3
# set_length_range launches dim=(nworld, nu) and writes actuator_lengthrange[worldid, actuator]
# WITHOUT the "% batch" wrap, so give the output one row per world.
m = mjw.put_model(mjm, batch_sizes={"actuator_gear": NWORLD, "actuator_lengthrange": NWORLD})
d = mjw.make_data(mjm, nworld=NWORLD)

print("actuators: 0 = tendon muscle (tendon unlimited), 1 = joint muscle (range +-0.25)")
print("lengthrange from the compiler (world 0):\n", m.actuator_lengthrange.numpy()[0])
gear = m.actuator_gear.numpy()
gear[:, :, 0] *= np.array([1.0, 2.0, 3.0])[:, None]        # gear x1, x2, x3 per world
m.actuator_gear.assign(gear)
mjw.set_length_range(m, d)
lr = m.actuator_lengthrange.numpy()
for w in range(NWORLD):
    print(f"world {w}: gear {gear[w, 1, 0]:.0f}  tendon muscle {lr[w, 0]}  joint muscle {lr[w, 1]}")
