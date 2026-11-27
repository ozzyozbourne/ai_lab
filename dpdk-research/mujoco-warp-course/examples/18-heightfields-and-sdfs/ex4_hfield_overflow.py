"""Example 18.4 - raise the heightfield resolution until the HFIELD overflow bit appears.

A 0.2 m box rests flat on a 1 m x 1 m heightfield with a 2 mm overlap. Every prism under the
box touches it, so the number of candidate prism contacts grows with the square of the
resolution. ccd_hfield_kernel stores at most MJ_MAXCONPAIR candidates per geom pair; when the
buffer is full and another prism remains it stops, sets OverflowType.HFIELD for that world and
prints a warning (once per pair, from the device). The rows are scanned from low y to high y, so
an overflowed pair only "sees" the lower part of the footprint: look at the y range of the
written contacts. The fix is a coarser grid (or a smaller colliding geom). "sub-grid prisms" is
the number of prisms the kernel visits (same index formulas); only touching ones fill the buffer.
Run: python ex4_hfield_overflow.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()


def scene(n):
    flat = " ".join(["0"] * (n * n))
    return f"""
<mujoco model="box_on_hfield">
  <asset><hfield name="flat" nrow="{n}" ncol="{n}" size="0.5 0.5 0.1 0.05"
    elevation="{flat}"/></asset>
  <worldbody>
    <geom name="ground" type="hfield" hfield="flat"/>
    <body name="crate" pos="0.013 0.007 0.098"><freejoint/>
      <geom name="crate" type="box" size="0.1 0.1 0.1"/></body>
  </worldbody>
</mujoco>"""


def subgrid_prisms(n, size=0.5, x=(0.013 - 0.1, 0.013 + 0.1), y=(0.007 - 0.1, 0.007 + 0.1)):
    """Prisms the kernel visits: the same cmin/cmax/rmin/rmax formulas as ccd_hfield_kernel."""
    scale = 0.5 * (n - 1) / size
    cmin = max(0, int(np.floor((x[0] + size) * scale)))
    cmax = min(n - 1, int(np.ceil((x[1] + size) * scale)))
    rmin = max(0, int(np.floor((y[0] + size) * scale)))
    rmax = min(n - 1, int(np.ceil((y[1] + size) * scale)))
    return 2 * (cmax - cmin) * (rmax - rmin)    # rows r in [rmin, rmax), cells c in (cmin, cmax]


print("MJ_MAXCONPAIR =", mujoco.mjMAXCONPAIR, "| box footprint y range: [-0.093, 0.107]")
rows = []
for n in [11, 16, 21, 26, 31]:
    mjm = mujoco.MjModel.from_xml_string(scene(n))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=1, nconmax=16, njmax=64)
    mjw.forward(m, d)
    wp.synchronize()
    nacon = min(int(d.nacon.numpy()[0]), d.naconmax)
    y = d.contact.pos.numpy()[:nacon, 1]
    bits = int(d.overflow.numpy()[0])
    names = [b.name for b in mjw.OverflowType if bits & b] or ["none"]
    cell = 1.0 / (n - 1)
    nprism = subgrid_prisms(n)
    print(f"n = {n:2d} (cell {cell * 100:4.1f} cm, sub-grid {nprism:3d} prisms): "
          f"nacon {nacon}, contact y in [{y.min():+.3f}, {y.max():+.3f}], "
          f"overflow {'|'.join(names)}")
    rows.append({"n": n, "cell": round(cell, 4), "prisms": nprism, "nacon": nacon,
                 "ymin": round(float(y.min()), 3), "ymax": round(float(y.max()), 3),
                 "overflow": bits})

ok = [r["n"] for r in rows if r["overflow"] == 0]
print(f"fix: use at most {max(ok)} x {max(ok)} rows/cols under a geom this size "
      f"(or a smaller geom); finer grids drop part of the footprint.")
print("to silence only the print (the bit is still set): "
      "m.opt.warn_overflow &= ~mjw.OverflowType.HFIELD")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"maxconpair": mujoco.mjMAXCONPAIR, "rows": rows}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
