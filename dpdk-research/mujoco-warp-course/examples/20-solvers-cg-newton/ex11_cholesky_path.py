"""Example 20.11 - which Newton Cholesky path a model takes, by nv.

solver.py::_cholesky_factorize_solve picks one of three paths from nv alone:
  nv <= types.H_ONE_TILE_MAX (48)            one tile: wp.tile_cholesky on the whole nv_pad^2 H
  nv <= solver._SPARSE_BLOCK_CHOLESKY_DIM (96) blocked Cholesky over 16x16 tiles
  nv >  96                                    blocked Cholesky that skips all-zero 16x16 tiles
We print the path, nv_pad, the Jacobian layout and the per-world H workspace for four models,
run one Newton forward on each (all paths work on CPU), and, on a GPU only, time the step.
For box_stack(20) we also print which 16x16 tiles of H = M + J' D J are nonzero.
Run: python ex11_cholesky_path.py [--dump-json PATH]
"""
import argparse
import json
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import solver, types  # private API: thresholds and ConstraintState

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
</mujoco>
"""


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


def path_name(nv):
    if nv <= types.H_ONE_TILE_MAX:
        return "one tile"
    if nv <= solver._SPARSE_BLOCK_CHOLESKY_DIM:
        return "blocked 16x16"
    return "sparse tiles"


def dense_J(d, mjm):
    """Decode efc.J of world 0 into a dense (nefc, nv) array (dense or CSR storage)."""
    n = min(int(d.nefc.numpy()[0]), d.njmax)
    J = d.efc.J.numpy()[0]
    if J.shape[0] != 1 or d.efc.J_rownnz.shape[1] == 0:
        return J[:n, :mjm.nv].astype(np.float64)
    out = np.zeros((n, mjm.nv))
    nnz, adr = d.efc.J_rownnz.numpy()[0], d.efc.J_rowadr.numpy()[0]
    col = d.efc.J_colind.numpy()[0, 0]
    for r in range(n):
        sl = slice(adr[r], adr[r] + nnz[r])
        out[r, col[sl]] = J[0, sl]
    return out


parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()
ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 1

print(f"thresholds: H_ONE_TILE_MAX = {types.H_ONE_TILE_MAX}, "
      f"_SPARSE_BLOCK_CHOLESKY_DIM = {solver._SPARSE_BLOCK_CHOLESKY_DIM}, "
      f"tile = {types.TILE_SIZE_JTDAJ_DENSE}")
print(f"{'model':14s} {'nv':>3s} {'nv_pad':>6s} {'J':>6s} {'path':>14s} {'H/world':>9s} "
      f"{'nefc':>4s} {'niter':>5s}  timing")
models = [("playground", PLAYGROUND, 8, 32), ("box_stack(5)", box_stack(5), 32, 128),
          ("box_stack(10)", box_stack(10), 64, 256), ("box_stack(20)", box_stack(20), 128, 512)]
dump = {}
for name, xml, nconmax, njmax in models:
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm)                 # Newton is the default solver
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=nconmax, njmax=njmax)
    for _ in range(60):
        mjw.step(m, d)
    timing = "skipped on CPU: timing is GPU-only here"
    if ON_GPU:
        wp.synchronize()
        t0 = time.perf_counter()
        for _ in range(100):
            mjw.step(m, d)
        wp.synchronize()
        timing = f"{(time.perf_counter() - t0) / 100 * 1e3:.2f} ms/step, nworld={NWORLD}"
    hbytes = m.nv_pad * m.nv_pad * 4
    print(f"{name:14s} {m.nv:3d} {m.nv_pad:6d} {'sparse' if m.is_sparse else 'dense':>6s} "
          f"{path_name(m.nv):>14s} {hbytes / 1024:7.1f}KB {int(d.nefc.numpy()[0]):4d} "
          f"{int(d.solver_niter.numpy()[0]):5d}  {timing}")
    if name == "box_stack(20)":
        mjd = mujoco.MjData(mjm)
        mjw.get_data_into(mjd, mjm, d)
        M = np.zeros((mjm.nv, mjm.nv))
        mujoco.mj_fullM(mjm, mjd, M)
        J = dense_J(d, mjm)
        n = J.shape[0]
        act = d.efc.state.numpy()[0, :n] == int(types.ConstraintState.QUADRATIC)
        Dact = d.efc.D.numpy()[0, :n] * act
        H = M + J.T @ (Dact[:, None] * J)
        t = types.TILE_SIZE_JTDAJ_DENSE
        nt = m.nv_pad // t
        Hp = np.zeros((m.nv_pad, m.nv_pad))
        Hp[:mjm.nv, :mjm.nv] = H
        tiles = [[int(np.any(Hp[i*t:(i+1)*t, j*t:(j+1)*t] != 0)) for j in range(nt)]
                 for i in range(nt)]
        upper = [tiles[i][j] for i in range(nt) for j in range(i, nt)]
        print(f"  H tiles ({nt}x{nt}, upper triangle): {sum(upper)} of {len(upper)} nonzero")
        for row in tiles:
            print("   ", " ".join("#" if v else "." for v in row))
        dump = {"nv": mjm.nv, "nv_pad": m.nv_pad, "tile": t, "tiles": tiles}

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
