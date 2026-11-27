"""Example 28.1 - one buffer, two views: wp.to_torch(d.qpos) aliases MJWarp memory.

Prints the torch / Warp versions and devices, then shows that a torch view of d.qpos shares
the same memory (same data pointer), that a write from torch is seen by Warp and that a
Warp step is seen by torch, all without a copy. A d.qpos.numpy() snapshot, by contrast, is
a copy: it goes stale after the next step (on a GPU it is also a device-to-host transfer).
Runs on CPU torch; skips if torch is not installed.
Run: python ex1_torch_zero_copy.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

try:
    import torch
except ImportError:
    torch = None
    print("skipped: torch not installed")

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 100

if torch is not None:
    # 1. Version block: Colab's torch is a CUDA 12 build; pip warp-lang 1.19.0 is a CUDA 13
    #    build. Both use the same driver, so the driver (R580+) is what must be new enough.
    print("torch", torch.__version__, "| torch CUDA build:", torch.version.cuda,
          "| torch.cuda.is_available():", torch.cuda.is_available())
    print("warp", wp.__version__, "| warp device:", wp.get_device(),
          "| as torch device:", wp.device_to_torch(wp.get_device()))

    mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)

    # 2. A zero-copy view: no data moves, the tensor points at the Warp allocation.
    q = wp.to_torch(d.qpos)
    print("view:", tuple(q.shape), q.dtype, q.device, "| same memory:", q.data_ptr() == d.qpos.ptr)

    # 3. torch writes, Warp reads: put the ball at a different height in every world.
    q[:, 2] = torch.linspace(0.5, 2.0, NWORLD, device=q.device)
    print("z seen by Warp after the torch write:", d.qpos.numpy()[:4, 2])

    # 4. A host snapshot is a copy, the view is not.
    snapshot = d.qpos.numpy().copy()
    for _ in range(NSTEP):
        mjw.step(m, d)
    wp.synchronize()  # Warp work must finish before torch reads the memory (Example 28.2)
    print(f"after {NSTEP} steps, torch view z:", q[:4, 2].cpu().numpy())
    print("old numpy snapshot z (stale):    ", snapshot[:4, 2])
    print("view still aliases d.qpos:", q.data_ptr() == d.qpos.ptr)
    print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
