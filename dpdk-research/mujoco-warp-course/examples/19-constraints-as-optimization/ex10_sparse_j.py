"""Example 19.10 - the sparse (CSR) Jacobian vs the dense one, on 6 free boxes (nv 36).

Three stacks of two boxes: each lower box touches the floor (rows touch its 6 dofs) and each
upper box touches the lower one (rows touch 12 dofs). With jacobian="auto", nv 36 > 32 makes
the model sparse: efc.J is one value ribbon of length njmax_nnz per world, indexed by J_rowadr,
J_rownnz and J_colind. Forcing jacobian="dense" stores a (njmax_pad, nv_pad) block per world.
We print the CSR arrays, the descending column order, the shapes and the bytes of each layout.
Run: python ex10_sparse_j.py [--dump-json PATH]
  --dump-json PATH writes the CSR arrays of world 0 for the J-layout figure (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True, linewidth=110)


def stacks(nstack=3, size=0.1):
    bodies = ""
    for s in range(nstack):
        x = 0.5 * s
        for k in range(2):
            z = size + 2 * size * k - 0.0005 * (k + 1)       # 0.5 mm overlap at each interface
            bodies += (f'<body name="b{s}{k}" pos="{x} 0 {z:.4f}"><freejoint/>'
                       f'<geom type="box" size="{size} {size} {size}"/></body>')
    return (f'<mujoco model="stacks"><option timestep="0.005"/><worldbody>'
            f'<geom name="floor" type="plane" size="5 5 .1"/>{bodies}</worldbody></mujoco>')


parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 2
NJMAX = 128

mjm = mujoco.MjModel.from_xml_string(stacks())
results = {}
for mode in ("auto", "dense"):
    mjm.opt.jacobian = mujoco.mjtJacobian.mjJAC_AUTO if mode == "auto" else \
        mujoco.mjtJacobian.mjJAC_DENSE
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=NJMAX)
    mjw.forward(m, d)
    n = int(d.nefc.numpy()[0])
    # float32 values and int32 indices: 4 bytes per entry (the index arrays are empty if dense)
    nbytes = 4 * sum(a.size for a in (d.efc.J, d.efc.J_colind, d.efc.J_rownnz, d.efc.J_rowadr))
    print(f"{mode:5s}: nv {mjm.nv}  is_sparse {m.is_sparse}  nv_pad {m.nv_pad}  njmax {d.njmax}"
          f"  njmax_pad {d.njmax_pad}  njmax_nnz {d.njmax_nnz}  nefc {n}")
    print(f"       efc.J {d.efc.J.shape}  J_rownnz {d.efc.J_rownnz.shape}"
          f"  J_colind {d.efc.J_colind.shape}  -> {nbytes / 1024:.1f} KiB for {NWORLD} worlds")
    results[mode] = dict(m=m, d=d, n=n, nbytes=nbytes)

ds, dd = results["auto"]["d"], results["dense"]["d"]
n = results["auto"]["n"]
rownnz = ds.efc.J_rownnz.numpy()[0, :n]
rowadr = ds.efc.J_rowadr.numpy()[0, :n]
colind = ds.efc.J_colind.numpy()[0, 0]
vals = ds.efc.J.numpy()[0, 0]
print("J_rownnz (world 0):", rownnz)
print("J_rowadr first 12 :", rowadr[:12])
print("used nnz:", int(rownnz.sum()), "of njmax_nnz", ds.njmax_nnz,
      "| rows per rownnz:", dict(zip(*[v.tolist() for v in np.unique(rownnz, return_counts=True)])))
print("nv_pad rule (nv <= 48): round_up(nv, 4) =", (mjm.nv + 3) // 4 * 4)
for r in (0, int(np.argmin(rownnz))):             # a box-box row and a box-floor row
    a, k = rowadr[r], rownnz[r]
    print(f"row {r:2d} colind {colind[a:a + k]}  (descending)")
    print(f"       vals   {vals[a:a + k]}")

# rebuild the dense matrix from CSR and compare with the forced-dense run (same rows?)
Jcsr = np.zeros((n, mjm.nv), dtype=np.float32)
for r in range(n):
    a, k = rowadr[r], rownnz[r]
    Jcsr[r, colind[a:a + k]] = vals[a:a + k]
Jd = dd.efc.J.numpy()[0, :n, :mjm.nv]
key = lambda J: sorted(tuple(np.round(row, 4)) for row in J)          # row order may differ
print("same set of rows in both layouts:", key(Jcsr) == key(Jd))
print(f"bytes ratio dense / sparse: {results['dense']['nbytes'] / results['auto']['nbytes']:.2f}")
for mode in ("auto", "dense"):
    print(f"overflow ({mode}):",
          "none" if not results[mode]["d"].overflow.numpy().any() else
          results[mode]["d"].overflow.numpy())

if args.dump_json:
    s = n                                         # all rows: the figure draws every one
    out = {"nv": mjm.nv, "nv_pad": int(results["dense"]["m"].nv_pad), "nefc": n,
           "njmax": NJMAX, "njmax_pad": int(dd.njmax_pad), "njmax_nnz": int(ds.njmax_nnz),
           "bytes_sparse": int(results["auto"]["nbytes"]), "bytes_dense":
           int(results["dense"]["nbytes"]), "nworld": NWORLD,
           "contact": ds.efc.id.numpy()[0, :s].tolist(),
           "rownnz": rownnz[:s].tolist(), "rowadr": rowadr[:s].tolist(),
           "colind": colind[:int(rowadr[s - 1] + rownnz[s - 1])].tolist(),
           "vals": vals[:int(rowadr[s - 1] + rownnz[s - 1])].round(3).tolist()}
    with open(args.dump_json, "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    print("wrote", args.dump_json)
