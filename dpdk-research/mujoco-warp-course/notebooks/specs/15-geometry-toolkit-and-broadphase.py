# Notebook spec for Chapter 15. Build with:
#   python3 tools/make_notebook.py notebooks/specs/15-geometry-toolkit-and-broadphase.py
SLUG = "15-geometry-toolkit-and-broadphase"
TITLE = "Ch 15 · Collision I: Geometry Toolkit, Pair Filtering and the Broadphase"

PLOT_EX8 = '''# Plot the timings of Example 15.8 (uses `rows` from the cell above). CPU timings say nothing
# about GPU performance: on a Colab GPU this plot shows YOUR crossover between NXN and SAP.
try:
    import matplotlib.pyplot as plt
except ImportError:
    print("skipped: matplotlib not installed")
else:
    ns = [r["n"] for r in rows]
    for name in ["NXN", "SAP_TILE", "SAP_SEGMENTED"]:
        plt.loglog(ns, [r[name] for r in rows], "o-", label=name)
    plt.xlabel("geoms per world (n)")
    plt.ylabel("mjw.collision time [ms]")
    plt.title(f"{wp.get_device()}, nworld={NWORLD}")
    plt.legend()
    plt.show()
'''

EX1_STUB = '''# Exercise 15.1: a robot that touches the floor but not itself (no <exclude> allowed)
import mujoco
import numpy as np
import mujoco_warp as mjw

LINK_BITS = 'contype="1" conaffinity="1"'      # <- your answer (these defaults keep l1-l3: change them)
ROBOT = f"""
<mujoco>
  <worldbody>
    <geom name="floor" type="plane" size="3 3 .1"/>
    <body name="l1" pos="0 0 .3"><joint type="hinge" axis="0 1 0"/>
      <geom name="l1" type="capsule" fromto="0 0 0 .4 0 0" size=".05" {LINK_BITS}/>
      <body name="l2" pos=".4 0 0"><joint type="hinge" axis="0 1 0"/>
        <geom name="l2" type="capsule" fromto="0 0 0 .4 0 0" size=".05" {LINK_BITS}/>
        <body name="l3" pos=".4 0 0"><joint type="hinge" axis="0 1 0"/>
          <geom name="l3" type="capsule" fromto="0 0 0 .4 0 0" size=".05" {LINK_BITS}/>
        </body>
      </body>
    </body>
  </worldbody>
</mujoco>"""
mjm = mujoco.MjModel.from_xml_string(ROBOT)
m = mjw.put_model(mjm)
names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]
kept = {(names[i], names[j]) for i, j in m.nxn_geom_pair_filtered.numpy()}
try:
    assert kept == {("floor", "l1"), ("floor", "l2"), ("floor", "l3")}, kept
    print("ok")
except AssertionError:
    print("not solved yet: kept pairs are", sorted(kept))
'''

EX1_SOL = EX1_STUB.replace(
    "try:\n    assert kept", "assert kept").replace(
    "    print(\"ok\")\nexcept AssertionError:\n    print(\"not solved yet: kept pairs are\", sorted(kept))\n",
    "print(\"ok\")\n").replace("LINK_BITS = 'contype=\"1\" conaffinity=\"1\"'      # <- your answer (these defaults keep l1-l3: change them)",
                           "LINK_BITS = 'contype=\"2\" conaffinity=\"1\"'      # links: (2&1)|(2&1)=0; floor: (2&1)|(1&1)=1")

EX2_COMMON = '''TWO_BOXES = """
<mujoco><worldbody>
  <body name="a"><freejoint/><geom type="box" size=".3 .1 .05"/></body>
  <body name="b"><freejoint/><geom type="box" size=".2 .2 .02"/></body>
</worldbody></mujoco>"""


def quat_to_mat(q):            # MuJoCo (w, x, y, z)
    w, x, y, z = q
    return np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                     [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                     [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])

'''
EX2_CHECK = '''
mjm = mujoco.MjModel.from_xml_string(TWO_BOXES)
m = mjw.put_model(mjm)
m.opt.broadphase_filter = mjw.BroadphaseFilter.OBB
d = mjw.make_data(mjm, nworld=1, nconmax=8, njmax=32)
rng = np.random.default_rng(0)
agree = npass = 0
h1, h2 = mjm.geom_size[0], mjm.geom_size[1]
for k in range(20):
    q = np.zeros(14); q[3] = 1.0
    q[7:10] = rng.uniform(-0.45, 0.45, 3)
    qb = rng.normal(size=4); q[10:14] = qb / np.linalg.norm(qb)
    d.qpos.assign(q[None].astype(np.float32))
    mjw.kinematics(m, d); mjw.collision(m, d)
    mj = int(d.ncollision.numpy()[0]) == 1
    mine = obb_sat_3d(q[0:3], np.eye(3), h1, q[7:10], quat_to_mat(q[10:14]), h2)
    agree += mine == mj; npass += mj
print(agree, npass)
assert agree == 20
'''
EX2_CHECK_STUB = (
    "\nif obb_sat_3d(np.zeros(3), np.eye(3), np.ones(3), np.zeros(3), np.eye(3), np.ones(3)) is None:\n"
    "    print(\"not solved yet: obb_sat_3d returns None\")\n"
    "else:\n"
    "    try:\n"
    + "".join("        " + ln + "\n" for ln in EX2_CHECK.strip("\n").splitlines())
    + "        print(\"Exercise 15.2 passed\")\n"
    "    except (AssertionError, TypeError) as e:\n"
    "        print(\"not solved yet: fewer than 20 poses agree with _obb_filter\", e)\n")
EX2_STUB = ("# Exercise 15.2: your 6-axis OBB test against _obb_filter\n" + EX2_COMMON +
            "def obb_sat_3d(c1, R1, h1, c2, R2, h2, margin=0.0):\n"
            "    ...                        # your code: True if no face axis separates the boxes\n" + EX2_CHECK_STUB)
EX2_SOL = ("# Exercise 15.2 solution (expected output: 20 6)\n" + EX2_COMMON +
           "def obb_sat_3d(c1, R1, h1, c2, R2, h2, margin=0.0):\n"
           '    """6 face axes only, like _obb_filter (no edge-edge cross axes)."""\n'
           "    for n in list(R1.T) + list(R2.T):\n"
           "        r1 = np.sum(np.abs(h1 * (R1.T @ n)))\n"
           "        r2 = np.sum(np.abs(h2 * (R2.T @ n)))\n"
           "        if r1 + r2 + margin < abs((c2 - c1) @ n):\n"
           "            return False\n"
           "    return True\n" + EX2_CHECK)

EX3_CHECK = '''
for n in (2, 5, 8, 50):
    for k in range(n * (n - 1) // 2):
        i, j = pair_of(n, k)
        assert 0 <= i < j < n and upper_tri_index(n, i, j) == k
mjm = mujoco.MjModel.from_xml_string(
    '<mujoco><worldbody><geom type="plane" size="1 1 .1"/>'
    + "".join(f'<body pos="{k} 0 1"><freejoint/><geom size=".1"/></body>' for k in range(6))
    + '</worldbody></mujoco>')
m = mjw.put_model(mjm)
pairs = m.nxn_geom_pair.numpy()
assert all(tuple(pairs[k]) == pair_of(mjm.ngeom, k) for k in range(len(pairs)))
print("ok:", len(pairs), "rows checked")
'''
EX3_HEAD = '''def upper_tri_index(n, i, j):
    i, j = (j, i) if j < i else (i, j)
    return (i * (2 * n - i - 3)) // 2 + j - 1

'''
EX3_CHECK_STUB = (
    "\nif pair_of(2, 0) is None:\n"
    "    print(\"not solved yet: pair_of returns None\")\n"
    "else:\n"
    "    try:\n"
    + "".join("        " + ln + "\n" for ln in EX3_CHECK.strip("\n").splitlines())
    + "    except (AssertionError, TypeError) as e:\n"
    "        print(\"not solved yet:\", type(e).__name__, e)\n")
EX3_STUB = ("# Exercise 15.3: invert upper_tri_index\n" + EX3_HEAD +
            "def pair_of(n, k):\n    ...                                          # your code\n" + EX3_CHECK_STUB)
EX3_SOL = ("# Exercise 15.3 solution (expected output: ok: 21 rows checked)\n" + EX3_HEAD +
           "def pair_of(n, k):\n"
           '    """Inverse of upper_tri_index: packed row k -> (i, j) with i < j."""\n'
           "    i = 0\n"
           "    while upper_tri_index(n, i, n - 1) < k:     # last entry of row i\n"
           "        i += 1\n"
           "    return i, k - upper_tri_index(n, i, i + 1) + i + 1\n" + EX3_CHECK)

CELLS = [
    ["md", "## 1. The geometry toolkit\n"
           "Every broadphase test is a cheap, *conservative* question: may this pair touch? Example 15.1 builds the "
           "2-D versions of the tools in plain NumPy: AABB overlap, the separating-axis test (SAT) for two oriented "
           "boxes (4 candidate axes), and closest points between segments (the core of capsule collision). In 3-D, "
           "MJWarp's `_obb_filter` tests only the 6 face normals, not all 15 SAT axes: still conservative, cheaper."],
    ["example", "ex1_toolkit_numpy.py", "15.1"],
    ["md", "## 2-3. The funnel and the static pre-filter\n"
           "`mjw.collision` = broadphase (candidates, counter `d.ncollision`) + narrowphase (contacts, `d.nacon`). "
           "Before any of it, `put_model` builds the pair list once: all `ngeom*(ngeom-1)/2` pairs in "
           "`np.triu_indices` order, column 0 of `m.nxn_pairid` = -2 (never), -1 (default) or an explicit `<pair>` id, "
           "column 1 = collision-sensor id. Example 15.2 defines `scatter(n, seed)` (shared model M9)."],
    ["example", "ex2_scatter.py", "15.2"],
    ["md", "Two geoms can collide only if `(contype1 & conaffinity2) | (contype2 & conaffinity1) != 0`. "
           "This is folded into `nxn_pairid` at model time: editing `m.geom_contype` later does nothing for rigid "
           "geoms. Re-run `put_model` instead."],
    ["example", "ex3_contype.py", "15.3"],
    ["md", "The other masks: same weld body, both bodies dof-less, parent-child (unless `mjDSBL_FILTERPARENT`), and "
           "`<exclude>` (signature `(body1 << 16) + body2`). The example mirrors `put_model` in NumPy and asserts it "
           "agrees. `--dump-json` writes the data of the page's NXN matrix."],
    ["example", "ex4_exclude_parent.py", "15.4"],
    ["md", "`upper_tri_index(n, i, j) = i*(2n - i - 3)//2 + j - 1` maps a pair to its row of `m.nxn_pairid`. SAP "
           "uses it to look pairs up from two geom ids."],
    ["example", "ex5_upper_tri.py", "15.5"],
    ["md", "## 4. The bounding-volume filters\n"
           "`m.opt.broadphase_filter` is a bitmask of `PLANE=1 | SPHERE=2 | AABB=4 | OBB=8` (default 11 = "
           "PLANE|SPHERE|OBB), baked into the kernel with `wp.static`. Filters only change how many candidates reach "
           "the narrowphase, never the contacts."],
    ["example", "ex6_filters.py", "15.6"],
    ["md", "## 6. Sweep and prune in NumPy\n"
           "`sap_broadphase`: project bounding spheres on the fixed axis `normalize(0.5935, 0.7790, 0.1235)` "
           "(planes get `MJ_MAXVAL`), sort each world's lower bounds, `sap_range` (binary search for the first lower "
           "bound greater than my upper bound), `array_scan` (prefix sum over all worlds), then `nsweep = 5*nworld*ngeom` "
           "threads decode work ids into (world, i, j). The NumPy re-implementation must match MJWarp's count."],
    ["example", "ex10_sap_numpy.py", "15.10"],
    ["md", "## 7. Choosing and switching the broadphase\n"
           "`put_model` picks NXN below 250,000 listed pairs, else SAP_TILE below 1000 geoms, else SAP_SEGMENTED. "
           "`m.opt.broadphase` can be switched between calls (new kernels are compiled the first time). "
           "`override_model` is a private API (`mujoco_warp._src.io`)."],
    ["example", "ex7_switch_broadphase.py", "15.7"],
    ["md", "Benchmark: warm up once per configuration, `wp.synchronize()` before reading the clock, take the median. "
           "On a GPU, raise `SIZES` and `NWORLD` and look for the crossover (stretch exercise)."],
    ["example", "ex8_scaling.py", "15.8"],
    ["code", PLOT_EX8],
    ["md", "## 10. Lab: a broadphase-like kernel\n"
           "One thread per (world, filtered pair), like `_nxn_broadphase`: bounding-sphere test plus the plane band, "
           "counted with `wp.atomic_add`. The counts must equal `d.ncollision` under SPHERE and PLANE|SPHERE."],
    ["example", "ex9_sphere_filter_kernel.py", "15.9"],
    ["md", "## Explicit pairs\n"
           "A `<contact><pair>` overrides every static rule (here contype 0) and brings its own margin, gap, condim and "
           "friction."],
    ["example", "ex11_explicit_pair.py", "15.11"],
    ["md", "## Exercise 15.1 (auto-checked)\n"
           "Choose `contype`/`conaffinity` for the three links (same for all) so that only the three floor pairs "
           "survive, without `<exclude>`."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 15.1"],
    ["md", "## Exercise 15.2 (auto-checked)\n"
           "Write the 3-D OBB test with the 6 face axes only and check it against `_obb_filter` (filter = OBB only, so "
           "`d.ncollision == 1` exactly when it passes) on 20 random poses."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 15.2"],
    ["md", "## Exercise 15.3 (auto-checked)\n"
           "Write `pair_of(n, k)`, the inverse of `upper_tri_index`, and check it on every row and against "
           "`m.nxn_geom_pair`."],
    ["code", EX3_STUB],
    ["solution", EX3_SOL, "Exercise 15.3"],
    ["md", "## Stretch: where does SAP beat NXN on your GPU?\n"
           "Run Example 15.8 with sizes 100, 200, 400, ..., 6400 and `NWORLD` 256 and 4096. From n = 4000 up, add "
           "`<size memory=\"1G\"/>` to the `scatter()` MJCF (MuJoCo's default arena is too small and compiling fails "
           "with 'Could not allocate memory'), and expect `put_model` to take tens of seconds. Find the `n` where "
           "SAP_TILE first beats NXN and compare it with the auto rule (250,000 pairs, about 708 geoms). Then place all "
           "bodies on a line perpendicular to the SAP direction (`p @ (0.5935, 0.7790, 0.1235) = const`) and explain "
           "what happens to the number of work packages."],
]
