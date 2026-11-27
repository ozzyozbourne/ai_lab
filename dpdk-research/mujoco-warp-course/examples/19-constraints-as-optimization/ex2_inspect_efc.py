"""Example 19.2 - read the efc arrays: one row of every category, side by side with MuJoCo C.

The scene has a box resting on a plane (4 contacts, condim 3, pyramidal: 4 rows each), a hinge
with frictionloss that starts past its range (one friction row and one limit row) and a second
hinge tied to the first by a joint equality (one equality row). Rows come out per world in the
fixed category order  equality | friction | limit | contact.
Run: python ex2_inspect_efc.py [--dump-json PATH]
  --dump-json PATH writes the row layout of both worlds for the efc strip (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True, linewidth=100)

SCENE = """
<mujoco model="efc_tour">
  <option timestep="0.005" cone="pyramidal"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="box" pos="0 0 0.099">
      <freejoint/>
      <geom type="box" size=".1 .1 .1" condim="3" friction="0.8"/>
    </body>
    <body name="arm" pos="1 0 1">
      <joint name="hinge" type="hinge" axis="0 1 0" range="-30 30" frictionloss="0.05"/>
      <geom type="capsule" fromto="0 0 0 0 0 -0.5" size="0.03" contype="0" conaffinity="0"/>
    </body>
    <body name="arm2" pos="1.5 0 1">
      <joint name="hinge2" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -0.5" size="0.03" contype="0" conaffinity="0"/>
    </body>
  </worldbody>
  <equality><joint joint1="hinge2" joint2="hinge" polycoef="0 1 0 0 0"/></equality>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 2
TYPE = {int(v): k[len("mjCNSTR_"):] for k, v in mujoco.mjtConstraint.__members__.items()}
STATE = {int(v): k[len("mjCNSTRSTATE_"):] for k, v in mujoco.mjtConstraintState.__members__.items()}

mjm = mujoco.MjModel.from_xml_string(SCENE)
mjd = mujoco.MjData(mjm)
hinge_q = mjm.jnt_qposadr[mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_JOINT, "hinge")]
mjd.qpos[hinge_q] = np.radians(35.0)          # 5 degrees past the +30 degree limit
mujoco.mj_forward(mjm, mjd)

m = mjw.put_model(mjm)
d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=8, njmax=32)
mjw.forward(m, d)

print(f"nv {mjm.nv}  nv_pad {m.nv_pad}  is_sparse {m.is_sparse}  njmax {d.njmax}"
      f"  njmax_pad {d.njmax_pad}  naconmax {d.naconmax}")
print("efc.J", d.efc.J.shape, "| efc.D", d.efc.D.shape, "| efc.force", d.efc.force.shape,
      "| contact.efc_address", d.contact.efc_address.shape)
print("ne", d.ne.numpy(), "nf", d.nf.numpy(), "nl", d.nl.numpy(), "nefc", d.nefc.numpy(),
      "| nacon (all worlds)", d.nacon.numpy())
print(f"MuJoCo C: ne {mjd.ne} nf {mjd.nf} nl {mjd.nl} nefc {mjd.nefc} ncon {mjd.ncon}")

n = int(d.nefc.numpy()[0])
typ = d.efc.type.numpy()[0, :n]
st = d.efc.state.numpy()[0, :n]
idx = d.efc.id.numpy()[0, :n]
force = d.efc.force.numpy()[0, :n]
pos = d.efc.pos.numpy()[0, :n]
D = d.efc.D.numpy()[0, :n]
aref = d.efc.aref.numpy()[0, :n]
print("row  type                 id  state       pos      D        aref     force   C force")
for r in range(n):
    print(f"{r:3d}  {TYPE[typ[r]]:19s} {idx[r]:3d}  {STATE[st[r]]:10s} {pos[r]:7.4f} {D[r]:8.2f}"
          f" {aref[r]:9.3f} {force[r]:8.4f} {mjd.efc_force[r]:8.4f}")
print("max |force - C force| =", f"{np.abs(force - mjd.efc_force).max():.1e}",
      "(float32 vs float64)")
nc = int(d.nacon.numpy()[0])
w0 = d.contact.worldid.numpy()[:nc] == 0
print("contact.efc_address (world 0 contacts):\n", d.contact.efc_address.numpy()[:nc][w0])
print("solver_niter", d.solver_niter.numpy(), "| C", mjd.solver_niter[0])
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    blocks = []
    for w in range(NWORLD):
        ne, nf, nl = int(d.ne.numpy()[w]), int(d.nf.numpy()[w]), int(d.nl.numpy()[w])
        row = [["eq", ne], ["friction", nf], ["limit", nl]]
        ca = d.contact.efc_address.numpy()[:nc]
        cw = d.contact.worldid.numpy()[:nc]
        cons = sorted((int(ca[i, 0]), i) for i in range(nc) if cw[i] == w)
        row += [["contact", 4, f"c{i}"] for _, i in cons]
        blocks.append(row)
    out = {"njmax": int(d.njmax), "rows": blocks,
           "types": [TYPE[t] for t in typ], "states": [STATE[s] for s in st],
           "force": [round(float(v), 4) for v in force]}
    with open(args.dump_json, "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    print("wrote", args.dump_json)
