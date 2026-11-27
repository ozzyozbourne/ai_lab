"""Example 12.5 - transmissions: actuator_length and the sparse actuator moment.

smooth.py::transmission computes, per (world, actuator), the actuator length and its moment arm
(d(length)/d(qpos), one row per actuator). MJWarp stores the rows sparsely, per world:
    d.moment_rownnz[w, i]  non-zeros in row i      d.moment_rowadr[w, i]  where row i starts
    d.moment_colind[w, k]  dof of entry k           d.actuator_moment[w, k] value of entry k
We load test_data/actuation/slidercrank.xml (a slider-crank linkage on hinge 0), add with MjSpec
a site actuator (a thrust along the crank site's x axis, tangent to the crank) and a gear-2 joint
motor on the second hinge, and densify the moment rows at 3 crank angles.
Run: python ex5_transmissions.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

PATH = epath.resource_path("mujoco_warp") / "test_data/actuation/slidercrank.xml"
spec = mujoco.MjSpec.from_file(str(PATH))
spec.add_actuator(name="thrust", trntype=mujoco.mjtTrn.mjTRN_SITE, target="cranksite",
                  gear=[1, 0, 0, 0, 0, 0])
spec.add_actuator(name="geared", trntype=mujoco.mjtTrn.mjTRN_JOINT, target="unactuated",
                  gear=[2, 0, 0, 0, 0, 0])
mjm = spec.compile()
print("actuators:", [(mjm.actuator(i).name or f"#{i}",
                      mujoco.mjtTrn(mjm.actuator_trntype[i]).name) for i in range(mjm.nu)],
      "| nv =", mjm.nv)

ANGLES = [0.0, np.pi / 2, np.pi]
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=len(ANGLES))
qpos = np.zeros((len(ANGLES), mjm.nq), dtype=np.float32)
qpos[:, 0] = ANGLES
d.qpos.assign(qpos)
mjw.forward(m, d)


def dense_moment(d, w, nu, nv):
    """Densify world w's sparse moment rows into an (nu, nv) matrix."""
    nnz, adr = d.moment_rownnz.numpy()[w], d.moment_rowadr.numpy()[w]
    col, val = d.moment_colind.numpy()[w], d.actuator_moment.numpy()[w]
    dense = np.zeros((nu, nv))
    for i in range(nu):
        dense[i, col[adr[i]:adr[i] + nnz[i]]] = val[adr[i]:adr[i] + nnz[i]]
    return dense


print("world 0 sparse layout: rownnz", d.moment_rownnz.numpy()[0], "rowadr",
      d.moment_rowadr.numpy()[0], "colind", d.moment_colind.numpy()[0, :4])
for w, a in enumerate(ANGLES):
    M = dense_moment(d, w, mjm.nu, mjm.nv)
    md = mujoco.MjData(mjm)
    md.qpos[:] = qpos[w]
    mujoco.mj_forward(mjm, md)
    Mc = np.zeros((mjm.nu, mjm.nv))
    mujoco.mju_sparse2dense(Mc, md.actuator_moment, md.moment_rownnz, md.moment_rowadr,
                            md.moment_colind)
    print(f"crank angle {np.degrees(a):5.1f} deg: actuator_length = {d.actuator_length.numpy()[w]}"
          f"  max |moment - C| = {np.abs(M - Mc).max():.1e}")
    print("  dense moment rows (slidercrank, thrust, geared):\n ", M.round(4).tolist())

# sweep the crank for the page figure: length and moment arm of the slider-crank actuator
sweep = np.linspace(-np.pi, np.pi, 61)
ds = mjw.make_data(mjm, nworld=len(sweep))
qs = np.zeros((len(sweep), mjm.nq), dtype=np.float32)
qs[:, 0] = sweep
ds.qpos.assign(qs)
mjw.forward(m, ds)
L = ds.actuator_length.numpy()[:, 0]
arm = [dense_moment(ds, w, mjm.nu, mjm.nv)[0, 0] for w in range(len(sweep))]
fd = np.gradient(L, sweep)
print(f"slider-crank sweep over {len(sweep)} worlds: length in [{L.min():.4f}, {L.max():.4f}], "
      f"max |moment - dL/dq (finite diff)| = {np.abs(np.array(arm) - fd)[1:-1].max():.3f}")

if args.dump_json:
    out = {"angle": [round(float(x), 4) for x in sweep], "length": [round(float(x), 4) for x in L],
           "moment": [round(float(x), 4) for x in arm], "crank": 0.2, "rod": 0.25}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
