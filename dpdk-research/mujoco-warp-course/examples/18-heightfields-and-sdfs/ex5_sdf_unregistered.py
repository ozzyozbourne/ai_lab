"""Example 18.5 - an SDF plugin model WITHOUT registration: C finds contacts, MJWarp finds none.

nutbolt.xml (shipped in the wheel) uses the MuJoCo C plugins mujoco.sdf.nut and mujoco.sdf.bolt.
MuJoCo C evaluates them natively. MJWarp cannot run C plugin code inside a Warp kernel: it calls
collision_sdf.user_sdf / user_sdf_grad, which are placeholders that wp.printf an ERROR line and
return 0. With a distance of exactly 0 everywhere, no contact passes the margin test.

Fresh process: the work runs in a child process (this file with --child) so that its device
printf lines (on stdout) can be captured and counted instead of flooding the output. The child
writes its own report to stderr, so the two streams cannot interleave mid-line; the parent prints
the report and a count of each distinct ERROR line. In a notebook run it with
  !python ex5_sdf_unregistered.py
Run: python ex5_sdf_unregistered.py
"""
import collections
import subprocess
import sys

if "--child" not in sys.argv:
    run = subprocess.run([sys.executable, "-I", __file__, "--child"], capture_output=True,
                         text=True)
    for line in run.stderr.splitlines():
        if "CUDA" not in line:                    # skip Warp's "no CUDA driver" notice on CPU
            print(line)
    errors = collections.Counter(l for l in run.stdout.splitlines() if l.strip())
    for line, n in sorted(errors.items()):
        print(f"{n:5d} x  {line}")
    sys.exit(0)

# ---------------- child process ----------------
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath


def report(*a):
    print(*a, file=sys.stderr)


NUTBOLT = epath.resource_path("mujoco_warp") / "test_data/collision_sdf/nutbolt.xml"

mjm = mujoco.MjModel.from_xml_path(str(NUTBOLT))
mjd = mujoco.MjData(mjm)
mujoco.mj_forward(mjm, mjd)
report(f"geom types {[mujoco.mjtGeom(t).name for t in mjm.geom_type]}, "
       f"geom_plugin {mjm.geom_plugin.tolist()}, plugin types {mjm.plugin.tolist()}")
report(f"MuJoCo C : ncon  = {mjd.ncon}")

m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)          # default sizes: an SDF model gets nconmax >= 64
report(f"default naconmax {d.naconmax}, sdf_initpoints {m.opt.sdf_initpoints}, "
       f"sdf_iterations {m.opt.sdf_iterations}")
mjw.forward(m, d)
wp.synchronize()
report(f"MJWarp   : nacon = {int(d.nacon.numpy()[0])}  (user_sdf was never registered)")
