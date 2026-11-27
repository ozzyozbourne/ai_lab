"""Example 1.2 - the smallest possible MJWarp model: an empty <mujoco/> moved to the device.

This is the tutorial's install check: if put_model works, MuJoCo, Warp and MJWarp all agree.
Run: python ex2_empty_model.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

mjm = mujoco.MjModel.from_xml_string("<mujoco/>")  # host model (C MuJoCo, float64)
m = mjw.put_model(mjm)                              # device model (Warp arrays, float32)

print("type(mjm)         :", type(mjm).__name__)
print("type(m)           :", type(m).__module__ + "." + type(m).__name__)
print("m.nq, m.nv        :", m.nq, m.nv)
print("m.nbody           :", m.nbody, "(the world body always exists)")
print("m.opt.timestep    :", type(m.opt.timestep).__name__, m.opt.timestep.dtype.__name__,
      m.opt.timestep.shape, m.opt.timestep.numpy())
print("mjm.opt.timestep  :", type(mjm.opt.timestep).__name__, mjm.opt.timestep)
print("device            :", m.opt.timestep.device)
