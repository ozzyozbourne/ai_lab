# Notebook spec for Chapter 9. Build with:
#   python3 tools/make_notebook.py notebooks/specs/09-contacts-and-buffer-sizing.py
SLUG = "09-contacts-and-buffer-sizing"
TITLE = "Ch 09 · Contacts, Constraint Budgets and Overflow"

CALCULATOR = '''# The sizing calculator of Figure 13 as a Python function (formulas from Example 9.9).
def sizing_calculator(nworld, nconmax, njmax, nv, condim=3, cone="pyramidal", solver="newton"):
    """Print the derived sizes and the memory of the contact pool, efc.J and Newton's h (+ hfactor when nv > 48).

    Exact for a dense J (nv <= 32) and nv <= 48; for nv > 32 the sparse J figure is an upper bound
    (make_data's default njmax_nnz is usually much smaller than njmax * nv).
    """
    def round_up(x, k):
        return (x + k - 1) // k * k
    newton = solver == "newton"
    naconmax = nconmax * nworld
    njmax_pad = round_up(njmax, 16)
    nv_pad = round_up(nv, 4) if nv <= 48 else round_up(nv + int(newton), 16)
    nmaxpyramid = max(1, 2 * (condim - 1))
    rows = 1 if condim == 1 else (2 * (condim - 1) if cone == "pyramidal" else condim)
    slot = 4 * (32 + 6 + nmaxpyramid)              # bytes per pool slot without flex
    contacts = naconmax * slot
    sparse = nv > 32                                # jacobian=AUTO rule (io.is_sparse)
    J = 2 * 4 * nworld * njmax * nv if sparse else nworld * njmax_pad * nv_pad * 4
    h = (2 if nv > 48 else 1) * nworld * nv_pad * nv_pad * 4 if newton else 0   # + hfactor when nv > 48
    print(f"naconmax = {naconmax:,}   njmax_pad = {njmax_pad}   nv_pad = {nv_pad}")
    print(f"rows per contact = {rows} -> {njmax // max(rows, 1)} contacts fit in njmax = {njmax}")
    print(f"contact pool     {contacts / 2**20:10.1f} MiB  ({slot} B per slot)")
    print(f"efc.J {'sparse<=' if sparse else 'dense   '}   {J / 2**20:10.1f} MiB")
    print(f"Newton h{' + hfactor' if nv > 48 else '         '}{h / 2**20:10.1f} MiB  (solver workspace, not in Data)")

sizing_calculator(nworld=8192, nconmax=32, njmax=128, nv=30)

# Optional: sliders (ipywidgets is preinstalled on Colab)
try:
    import ipywidgets as widgets
    widgets.interact(sizing_calculator,
                     nworld=widgets.IntSlider(8192, 1024, 65536, 1024),
                     nconmax=widgets.IntSlider(32, 4, 512, 4), njmax=widgets.IntSlider(128, 16, 2048, 16),
                     nv=widgets.IntSlider(30, 1, 120), condim=[1, 3, 4, 6],
                     cone=["pyramidal", "elliptic"], solver=["newton", "cg"])
except ImportError:
    print("skipped: ipywidgets not installed")
'''

EX1_STUB = '''# Exercise 9.1: size box_stack(10) for 8192 worlds (box_stack is defined by Example 9.8 above)
import math
LADDER = [(2 + k % 2) * 2 ** (k // 2 + 3) for k in range(19)]
TARGET_NWORLD = 8192
mjm = mujoco.MjModel.from_xml_string(box_stack(10))
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0
worst_con = worst_efc = None             # measure with 4 worlds, 200 steps, nconmax=256, njmax=1024
nconmax = njmax = None                   # 1.25 x worst, rounded up to the ladder
if worst_con is not None and nconmax is not None:
    naconmax = nconmax * TARGET_NWORLD
    assert nconmax in LADDER and njmax in LADDER
    assert nconmax >= 1.25 * worst_con and njmax >= 1.25 * worst_efc
    assert naconmax == nconmax * TARGET_NWORLD
    # ... and a 4-world check run with (nconmax, njmax): assert not d.overflow.numpy().any()
    print("all checks passed")
else:
    print("skipped: fill in worst_con, worst_efc, nconmax and njmax, then run this cell again")
'''

EX1_SOLUTION = '''import math
LADDER = [(2 + k % 2) * 2 ** (k // 2 + 3) for k in range(19)]
TARGET_NWORLD = 8192
mjm = mujoco.MjModel.from_xml_string(box_stack(10))
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0


def measure(nconmax, njmax, nworld=4, nstep=200):
    d = mjw.make_data(mjm, nworld=nworld, nconmax=nconmax, njmax=njmax)
    worst_con, worst_efc = 0, 0
    for _ in range(nstep):
        mjw.step(m, d)
        n = min(int(d.nacon.numpy()[0]), d.naconmax)
        per_world = np.bincount(d.contact.worldid.numpy()[:n], minlength=nworld)
        worst_con = max(worst_con, int(per_world.max()))
        worst_efc = max(worst_efc, int(d.nefc.numpy().max()))
    return worst_con, worst_efc, d


worst_con, worst_efc, _ = measure(nconmax=256, njmax=1024)
nconmax = next(v for v in LADDER if v >= math.ceil(1.25 * worst_con))
njmax = next(v for v in LADDER if v >= math.ceil(1.25 * worst_efc))
naconmax = nconmax * TARGET_NWORLD
print(f"worst: {worst_con} contacts, {worst_efc} rows -> nconmax={nconmax}, njmax={njmax}, naconmax={naconmax}")
assert nconmax in LADDER and njmax in LADDER
assert nconmax >= 1.25 * worst_con and njmax >= 1.25 * worst_efc
assert naconmax == nconmax * TARGET_NWORLD
_, _, d = measure(nconmax, njmax)
assert not d.overflow.numpy().any(), "check run overflowed"
print("all checks passed")
'''

EX2_STUB = '''# Exercise 9.2: count contacts per world on the device (CONTACT_SCENE is defined by Example 9.1)
@wp.kernel
def count_contacts(nacon: wp.array(dtype=int), naconmax: int,
                   worldid: wp.array(dtype=int), counts: wp.array(dtype=int)):
    cid = wp.tid()
    # your code: skip unused slots, then one atomic add (replace the return below)
    return


IMPLEMENTED = False                           # set to True once the kernel body is written
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(CONTACT_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[1::2, 9] += 0.5                          # odd worlds: lift the box
d.qpos.assign(qpos)
mjw.forward(m, d)
if IMPLEMENTED:
    counts = wp.zeros(d.nworld, dtype=int)
    wp.launch(count_contacts, dim=d.naconmax,
              inputs=[d.nacon, d.naconmax, d.contact.worldid], outputs=[counts])
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    assert np.array_equal(counts.numpy(), np.bincount(d.contact.worldid.numpy()[:n], minlength=d.nworld))
    print("match")
else:
    print("skipped: write the kernel body and set IMPLEMENTED = True")
'''

EX2_SOLUTION = '''@wp.kernel
def count_contacts(nacon: wp.array(dtype=int), naconmax: int,
                   worldid: wp.array(dtype=int), counts: wp.array(dtype=int)):
    cid = wp.tid()                                   # one thread per pool slot
    if cid >= wp.min(nacon[0], naconmax):            # slot unused (or counter past capacity)
        return
    wp.atomic_add(counts, worldid[cid], 1)


NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(CONTACT_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[1::2, 9] += 0.5
d.qpos.assign(qpos)
mjw.forward(m, d)
counts = wp.zeros(d.nworld, dtype=int)
wp.launch(count_contacts, dim=d.naconmax,
          inputs=[d.nacon, d.naconmax, d.contact.worldid], outputs=[counts])
n = min(int(d.nacon.numpy()[0]), d.naconmax)
expected = np.bincount(d.contact.worldid.numpy()[:n], minlength=d.nworld)
print("kernel:  ", counts.numpy())
print("bincount:", expected)
assert np.array_equal(counts.numpy(), expected)
print("match")
'''

STRETCH = '''# Stretch: the smallest nconmax with no overflow for TERRAIN (plan model M7).
# The first run compiles the heightfield and convex colliders (about a minute on CPU).
from mujoco_warp._src import io as mjw_io     # private API: only to print the defaults
TERRAIN = """
<mujoco model="terrain">
  <option timestep="0.005"/>
  <asset>
    <hfield name="bumps" nrow="5" ncol="5" size="1 1 .2 .1"
      elevation="0 0 0 0 0  0 .5 1 .5 0  0 1 0 1 0  0 .5 1 .5 0  0 0 0 0 0"/>
    <mesh name="tetra" vertex="0 0 0  .2 0 0  0 .2 0  0 0 .2"/>
  </asset>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="ground" type="hfield" hfield="bumps"/>
    <body name="ball" pos="0.2 0.1 .6"><freejoint/><geom type="sphere" size=".08"/></body>
    <body name="ellipsoid" pos="-0.3 0.2 .6"><freejoint/><geom type="ellipsoid" size=".1 .07 .05"/></body>
    <body name="cyl" pos="0.3 -0.3 .6"><freejoint/><geom type="cylinder" size=".06 .05"/></body>
    <body name="tetra" pos="-0.3 -0.3 .6"><freejoint/><geom type="mesh" mesh="tetra"/></body>
  </worldbody>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(TERRAIN)
print("defaults:", mjw_io._default_nconmax(mjm), mjw_io._default_njmax(mjm))
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0
# your sweep here: for nconmax in [...]: make_data(nworld=2, nconmax=..., njmax=128), 300 steps,
# record max d.nacon and print describe_overflow(d)
'''

CELLS = [
    ["md", "## What this notebook covers\n"
           "Every code cell below is the same file as on the chapter page (`examples/09-contacts-and-buffer-sizing/`). "
           "On a GPU the budgets grow automatically (`NWORLD = 4096 if ON_GPU else 8`). Numbers you see on a GPU differ "
           "from the CPU outputs on the page in contact order, which world starves, and timings."],
    ["md", "### The running project\n`my_env.py` after Chapter 9: Ch 6 `make_worlds`, Ch 8 resets and snapshots, "
           "and this chapter's `describe_overflow(d)` (Example 9.7)."],
    ["writefile", "my_env.py", "examples/09-contacts-and-buffer-sizing/my_env_step09.py"],
    ["md", "## 2. The Contact struct and the shared pool\n"
           "`d.contact` has one flat buffer of `naconmax` slots shared by all worlds; each contact stores its "
           "`worldid`. `d.nacon` (shape `(1,)`) is a global counter that can exceed the capacity: always read "
           "`n = min(d.nacon.numpy()[0], d.naconmax)`."],
    ["example", "ex1_read_contacts.py", "9.1"],
    ["md", "Group the pool per world with `np.bincount` (counts) and `np.minimum.at` (deepest penetration)."],
    ["example", "ex2_per_world.py", "9.2"],
    ["md", "## 3. Which way the normal points\n`geom[0]` has the lower GeomType; `frame[0]` points from "
           "`geom[0]` to `geom[1]`."],
    ["example", "ex3_normal_direction.py", "9.3"],
    ["md", "## 4. Friction cones, rows per contact and contact forces\n"
           "A condim-c contact costs `2(c-1)` rows with the default pyramidal cone (`c` with elliptic). "
           "`mjw.contact_force` turns a contact's rows back into a 6-D force:torque."],
    ["example", "ex4_contact_force.py", "9.4"],
    ["md", "## 6. Starvation: a shared pool is not fair\nTwo worlds, six boxes each, a pool of 8 slots."],
    ["example", "ex5_overflow_starvation.py", "9.5"],
    ["md", "## 7. Detecting and decoding overflow\nThe default `njmax = 64` is too small for a 6-box tower "
           "(96 rows). The bits are sticky until `reset_data`."],
    ["example", "ex6_default_overflow.py", "9.6"],
    ["md", "Decode the bits by looping over `mjw.OverflowType` (never a hand-written list)."],
    ["example", "ex7_decode_overflow.py", "9.7"],
    ["md", "The same function from the running project:"],
    ["code", "import importlib\nimport my_env\nimportlib.reload(my_env)\nprint(my_env.describe_overflow(d))"],
    ["md", "## 8. A sizing recipe\nMeasure the worst case, add 25%, round up to the ladder, check periodically."],
    ["example", "ex8_size_from_rollout.py", "9.8"],
    ["md", "## 9. What oversizing costs\nMemory formulas checked against the real allocation."],
    ["example", "ex9_memory_estimate.py", "9.9"],
    ["md", "### The sizing calculator\nThe page's calculator widget as a function, with optional sliders."],
    ["code", CALCULATOR],
    ["md", "## 10. Silencing warnings without losing the bits\n`m.opt.warn_overflow` gates only the device "
           "printf; it is read through `wp.static`, so each new value recompiles some kernels. In a notebook the "
           "device text may show up late or only in the runtime log."],
    ["example", "ex10_warn_mask.py", "9.10"],
    ["md", "## 11. Not every contact is a constraint: ContactType bits\nCollision sensors add SENSOR contacts: "
           "they use pool slots but no constraint rows."],
    ["example", "ex11_sensor_contacts.py", "9.11"],
    ["md", "## Exercise 9.1: size a 10-box tower for 8192 worlds\nMeasure `box_stack(10)` with 4 worlds for 200 "
           "steps, pick `nconmax`/`njmax` (worst x 1.25, rounded up to the ladder), confirm with a check run."],
    ["code", EX1_STUB],
    ["solution", EX1_SOLUTION, "Exercise 9.1"],
    ["md", "## Exercise 9.2: count contacts per world on the device\nOne thread per pool slot, an atomic add per "
           "world, compared with `np.bincount`."],
    ["code", EX2_STUB],
    ["solution", EX2_SOLUTION, "Exercise 9.2"],
    ["md", "## Stretch: the smallest nconmax for TERRAIN\nCompare the heightfield defaults with what the scene "
           "needs. Reference result on CPU (2 worlds, 300 steps): defaults 192/1536; no overflow from nconmax = 6 "
           "(at most 6 contacts and 24 rows per world). With a 25% margin and the ladder (which starts at 16): "
           "nconmax = 16 (1.25 x 6 = 7.5), njmax = 32 (1.25 x 24 = 30)."],
    ["code", STRETCH],
]
