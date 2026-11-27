"""Example 11.12 (going deeper) - how factor_m routes each block of M: m.M_tiles and qLD.

M is block diagonal: one block per kinematic tree (io.py::_m_blocks uses tree_dofadr/tree_dofnum).
io.py::m_block_layout classifies each block:
  compact   size <= 6 and diagonal-only (nnz == size)   -> reciprocal diagonal, no factor stored
  scalar    size <= 6 and full lower triangle            -> _small_cholesky_factorize_block
  tile      7 .. 64 dofs (M_BLOCK_DENSE_MAX), or a size <= 6 block that is neither compact
            nor a full triangle                          -> _tile_cholesky_factorize_block
  sparse    > 64 dofs                                    -> sparse L'DL (_factor_i_sparse)
put_model turns this into m.M_tiles (TileSet(size, adr, elemid); empty elemid = scalar path),
m.qLD_block_adr (packed offset or the sentinels -2 compact / -1 sparse), m.qLD_block_total and
m.qLD_updates (the sparse level schedule) and m.is_sparse. At the end one fwd_position call on the
HUMANOID measures how much the tile Cholesky factor fills in (threshold printed).
Run: python ex12_m_tiles.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""

def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


def two_arms(n=30):
    """A free base with two hinge chains of n links each: one tree of 6 + 2n dofs."""
    def chain(k, side):
        if k == n:
            return ""
        return (f'<body pos="0 {side * 0.05:.2f} -.05"><joint type="hinge" axis="1 0 0"/>'
                f'<geom type="capsule" fromto="0 0 0 0 0 -.05" size=".01"/>{chain(k + 1, side)}'
                f'</body>')
    return (f'<mujoco model="two_arms"><worldbody><body pos="0 0 3"><freejoint/>'
            f'<geom type="box" size=".1 .1 .1"/>{chain(0, 1)}{chain(0, -1)}</body>'
            f'</worldbody></mujoco>')


HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
models = {
    "PENDULUM": mujoco.MjModel.from_xml_string(PENDULUM),
    "HUMANOID": mujoco.MjModel.from_xml_path(str(HUMANOID_PATH)),
    "box_stack(5)": mujoco.MjModel.from_xml_string(box_stack(5)),
    "two_arms(30)": mujoco.MjModel.from_xml_string(two_arms(30)),
}
PATH = {-2: "compact", -1: "sparse"}
dump = {}
for name, mjm in models.items():
    m = mjw.put_model(mjm)
    adr = m.qLD_block_adr.numpy()
    tiles = [(t.size, t.adr.numpy().tolist(), int(t.elemid.size)) for t in m.M_tiles]
    scalar_starts = {a for t in m.M_tiles if t.elemid.size == 0 for a in t.adr.numpy().tolist()}
    blocks = []
    for start, size in zip(mjm.tree_dofadr, mjm.tree_dofnum):
        a = int(adr[start])
        kind = PATH.get(a, "scalar" if int(start) in scalar_starts else "tile")
        blocks.append({"start": int(start), "size": int(size), "kind": kind, "qld": a})
    nlev = [int(u.size) for u in m.qLD_updates]
    print(f"{name}: nv = {mjm.nv}, nC = {mjm.nC}, ntree = {mjm.ntree}, is_sparse = "
          f"{m.is_sparse}")
    print(f"  M_tiles (size, adr, elemid.size) = {tiles}")
    print(f"  blocks = {[(b['start'], b['size'], b['kind']) for b in blocks]}")
    print(f"  qLD_block_total = {m.qLD_block_total}, qLD_updates: {len(nlev)} levels, "
          f"updates per level = {nlev[:8]}{' ...' if len(nlev) > 8 else ''}")
    dump[name] = {"nv": int(mjm.nv), "blocks": blocks, "qld_total": int(m.qLD_block_total),
                  "levels": nlev}

mjm6 = mujoco.MjModel.from_xml_string(box_stack(6))
m6 = mjw.put_model(mjm6)
d6 = mjw.make_data(mjm6, nworld=1, nconmax=48, njmax=192)
print(f"box_stack(6): nv = {mjm6.nv} > 32 -> is_sparse = {m6.is_sparse}, "
      f"d.efc.J.shape = {d6.efc.J.shape}")
mjm5 = models["box_stack(5)"]
m5 = mjw.put_model(mjm5)
d5 = mjw.make_data(mjm5, nworld=1, nconmax=40, njmax=160)
print(f"box_stack(5): nv = {mjm5.nv} <= 32 -> is_sparse = {m5.is_sparse}, "
      f"d.efc.J.shape = {d5.efc.J.shape}")

# Fill-in of the HUMANOID factor at qpos0: d.qLD holds the packed 27 x 27 tile factor U (M = U^T U).
mjh = models["HUMANOID"]
mh = mjw.put_model(mjh)
dh = mjw.make_data(mjh, nworld=1)
mjw.fwd_position(mh, dh)                     # kinematics, crb -> d.M, then factor_m -> d.qLD
nv = mjh.nv
U = dh.qLD.numpy()[0][:nv * nv].reshape(nv, nv)
iu = np.triu_indices(nv)
upper = np.abs(U[iu])
print(f"HUMANOID factor U (upper triangle, {upper.size} slots): "
      f"{int((upper != 0).sum())} nonzero, {int((upper > 1e-6).sum())} with |U_ij| > 1e-6; "
      f"M stores {mjh.nC} (structural)")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
