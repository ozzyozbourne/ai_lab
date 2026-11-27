"""Example 1.1 - check the environment: versions, the Warp device and the GPU count.

Prints what is installed and which device Warp will use ("cpu" or "cuda:0").
Run: python ex1_env_check.py
"""
import importlib.metadata as md

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

wp.init()  # explicit init: finds the CUDA driver (or not) and picks the default device

print("mujoco.__version__        :", mujoco.__version__)       # import name: mujoco
print("dist mujoco-core          :", md.version("mujoco-core"))  # distribution name: mujoco-core
print("warp.__version__          :", wp.__version__)
print("dist mujoco-warp          :", md.version("mujoco-warp"))
print("numpy                     :", np.__version__)
print("default Warp device       :", wp.get_device())
print("CUDA devices Warp can see :", wp.get_cuda_device_count())
print("mjw.step is callable      :", callable(mjw.step))

# The distribution is called mujoco-core, so asking for "mujoco" fails (the import name is still mujoco).
try:
    md.version("mujoco")
except md.PackageNotFoundError as e:
    print("md.version('mujoco')      : PackageNotFoundError:", e)

if wp.get_cuda_device_count() == 0:
    print("No GPU: everything still runs on Warp's CPU device, just slowly (fine for this course's checks).")
