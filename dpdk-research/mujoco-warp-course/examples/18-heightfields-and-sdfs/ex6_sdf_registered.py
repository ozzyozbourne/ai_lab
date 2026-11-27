"""Example 18.6 - register Warp versions of the SDF plugins FIRST, then nutbolt.xml collides.

register_sdf_plugins(mjw) (a helper shipped in mujoco_warp.test_data) builds @wp.func versions
of user_sdf / user_sdf_grad that dispatch on the plugin type id (nut, bolt, torus, gear) and
assigns them to mujoco_warp._src.collision_sdf. Warp reads those module globals when it compiles
the SDF kernel, so the patch must come before the first put_model / forward / step in the
process. Fresh process: run this file as its own process (in a notebook: !python ex6_...py).

This file also starts a second child process with --late that does it in the WRONG order: one
forward with the placeholders, then register, then forward again. The second forward still has
nacon 0, because the compiled SDF kernel already holds the placeholder.
Run: python ex6_sdf_registered.py
"""
import subprocess
import sys

LATE = "--late" in sys.argv

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp.test_data.collision_sdf.utils import register_sdf_plugins  # private API
from etils import epath

np.set_printoptions(precision=4, suppress=True)

if not LATE:
    sdf_types = register_sdf_plugins(mjw)      # BEFORE any MJWarp kernel is compiled
    print("registered plugin type ids:", {k.name: v for k, v in sdf_types.items()})

NUTBOLT = epath.resource_path("mujoco_warp") / "test_data/collision_sdf/nutbolt.xml"
mjm = mujoco.MjModel.from_xml_path(str(NUTBOLT))
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)


def nacon_after_forward():
    mjw.forward(m, d)
    wp.synchronize()
    return int(d.nacon.numpy()[0])


if LATE:
    n0 = nacon_after_forward()                 # compiles the SDF kernel with the placeholders
    register_sdf_plugins(mjw)                  # too late for this process
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=1)
    n1 = nacon_after_forward()
    print(f"late registration: nacon before {n0}, after register + new put_model {n1}",
          file=sys.stderr)
    sys.exit(0)

mjd = mujoco.MjData(mjm)
mujoco.mj_forward(mjm, mjd)
nacon = nacon_after_forward()
print(f"opt.sdf_initpoints {m.opt.sdf_initpoints}, opt.sdf_iterations {m.opt.sdf_iterations}")
attr = m.plugin_attr.numpy()
print(f"plugin_attr (first 2 of {attr.shape[1]} slots): "
      f"{attr[:, :2].astype(float).round(4).tolist()}")
print(f"geom_plugin_index {m.geom_plugin_index.numpy().tolist()}, "
      f"m.plugin {m.plugin.numpy().tolist()}")
print(f"MuJoCo C : ncon  = {mjd.ncon}")
print(f"MJWarp   : nacon = {nacon}")
g = d.contact.geom.numpy()[:nacon]
dist = d.contact.dist.numpy()[:nacon]
names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, i) for i in range(mjm.ngeom)]
for (a, b), r in zip(g, dist):
    print(f"  {names[a]:>6s} - {names[b]:<5s} dist {r:+.5f}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

late = subprocess.run([sys.executable, "-I", __file__, "--late"], capture_output=True, text=True)
for line in late.stderr.splitlines():
    if "CUDA" not in line:
        print(line)
print("placeholder ERROR lines printed by the late process:",
      sum(l.startswith("ERROR") for l in late.stdout.splitlines()))
