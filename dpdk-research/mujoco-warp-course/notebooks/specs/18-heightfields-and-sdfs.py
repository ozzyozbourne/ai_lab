# Notebook spec for Chapter 18. Build with:
#   python3 tools/make_notebook.py notebooks/specs/18-heightfields-and-sdfs.py
SLUG = "18-heightfields-and-sdfs"
TITLE = "Ch 18 · Collision IV: Heightfields, SDFs and User SDF Plugins"
EX = f"examples/{SLUG}"

FRESH = (
    "## Why some examples run as `!python file.py`\n"
    "MJWarp's SDF kernel calls `collision_sdf.user_sdf` / `user_sdf_grad`. Warp builds that kernel the first "
    "time it launches **in this process**, using whatever function those names point to at that moment. A patch "
    "assigned later is ignored by the already-built kernel (Example 18.6 shows it: `nacon` stays 0).\n\n"
    "So every example that registers or patches an SDF runs in a **fresh process**: a `%%writefile` cell puts "
    "the script on disk and `!python` runs it. Alternative: put the patch in the very first code cell after "
    "setup, or use *Runtime > Restart session* and run the patching cell before anything else."
)

EX1_STUB = '''# Exercise 18.1: the finest heightfield grid a 0.15 m box can sit on without HFIELD overflow.
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HALF = 0.15          # box half-size (bigger than in Example 18.4)


def hfield_overflow(n, half=HALF):
    """Return the HFIELD overflow bit after one mjw.forward for a box resting on an n x n grid."""
    ...                 # build the scene of Example 18.4 with box size `half`, forward, read d.overflow


N = ...                 # the largest n (5..41) with no HFIELD overflow
assert hfield_overflow(N) == 0, "still overflowing"
assert all(hfield_overflow(k) for k in range(N + 1, 42)), "you can go finer"
print("ok")'''

EX1_SOL = '''HALF = 0.15
from functools import cache


@cache                  # the checks below ask for the same n again
def hfield_overflow(n, half=HALF):
    flat = " ".join(["0"] * (n * n))
    xml = f"""<mujoco><asset><hfield name="f" nrow="{n}" ncol="{n}" size="0.5 0.5 0.1 0.05"
      elevation="{flat}"/></asset><worldbody><geom type="hfield" hfield="f"/>
      <body pos="0.013 0.007 {half - 0.002}"><freejoint/>
      <geom type="box" size="{half} {half} {half}"/></body></worldbody></mujoco>"""
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0
    d = mjw.make_data(mjm, nworld=1, nconmax=16, njmax=64)
    mjw.forward(m, d)
    return int(d.overflow.numpy()[0]) & mjw.OverflowType.HFIELD


# scan from fine to coarse and keep the first clean resolution; overflow is not monotonic
# in n (n = 15 overflows, n = 16 does not), so a coarse-to-fine scan would stop too early
N = next(n for n in range(41, 4, -1) if not hfield_overflow(n))
print("finest clean grid:", N)
assert hfield_overflow(N) == 0, "still overflowing"
assert all(hfield_overflow(k) for k in range(N + 1, 42)), "you can go finer"
print("ok")'''

EX2_STUB = '''%%writefile ex18_2_sphere_sdf.py
# Exercise 18.2: a sphere SDF through the user hook (runs in a fresh process: see the next cell).
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import vec_pluginattr

probe = mujoco.MjModel.from_xml_string("""<mujoco><extension>
  <plugin plugin="mujoco.sdf.torus"><instance name="t"/></plugin></extension>
  <asset><mesh name="tm"><plugin instance="t"/></mesh></asset>
  <worldbody><geom type="sdf" mesh="tm"><plugin instance="t"/></geom></worldbody></mujoco>""")
TORUS_ID = int(probe.plugin[0])

# TODO 1: write @wp.func user_sdf(p, attr, sdf_type) -> float: a sphere of radius attr[1]
# TODO 2: write @wp.func user_sdf_grad(p, attr, sdf_type) -> wp.vec3
# TODO 3: assign both to mjw._src.collision_sdf BEFORE any MJWarp call

A, B, C = 0.1, 0.05, 0.145            # SDF sphere radius, ball radius, centre distance
xml = f"""<mujoco><extension><plugin plugin="mujoco.sdf.torus"><instance name="s">
  <config key="radius1" value="0.0001"/><config key="radius2" value="{A}"/></instance></plugin>
  </extension><asset><mesh name="s"><plugin instance="s"/></mesh></asset><worldbody>
  <body><geom type="sdf" mesh="s"><plugin instance="s"/></geom></body>
  <body pos="0 0 {C}"><freejoint/><geom type="sphere" size="{B}"/></body>
  </worldbody></mujoco>"""
mjm = mujoco.MjModel.from_xml_string(xml)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=64, njmax=256)
mjw.kinematics(m, d)
mjw.collision(m, d)
n = int(d.nacon.numpy()[0])
dist = d.contact.dist.numpy()[:n]
normal = d.contact.frame.numpy()[:n, 0]
best = ...                            # TODO 4: the lowest value max(A, B) can take (analytic)
assert n > 0, "no contact: was the patch applied before the first MJWarp call?"
assert dist.min() >= best - 1e-4, "deeper than the analytic minimum of max(A, B)"
assert dist.max() < 0.0 and dist.min() < best / 2, "contact too shallow"
assert abs(normal[np.argmin(dist), 2]) > 0.9, "deepest normal should follow the centre line"
print("ok")'''

SOL2_SRC = r'''import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import vec_pluginattr

probe = mujoco.MjModel.from_xml_string("""<mujoco><extension>
  <plugin plugin="mujoco.sdf.torus"><instance name="t"/></plugin></extension>
  <asset><mesh name="tm"><plugin instance="t"/></mesh></asset>
  <worldbody><geom type="sdf" mesh="tm"><plugin instance="t"/></geom></worldbody></mujoco>""")
TORUS_ID = int(probe.plugin[0])


@wp.func
def user_sdf(p: wp.vec3, attr: vec_pluginattr, sdf_type: int) -> float:
    if sdf_type == wp.static(TORUS_ID):
        return wp.length(p) - attr[1]          # sphere of radius radius2
    return 0.0


@wp.func
def user_sdf_grad(p: wp.vec3, attr: vec_pluginattr, sdf_type: int) -> wp.vec3:
    if sdf_type == wp.static(TORUS_ID) and wp.length(p) > 1e-9:
        return wp.normalize(p)
    return wp.vec3(0.0, 0.0, 1.0)


mjw._src.collision_sdf.user_sdf = user_sdf          # BEFORE any MJWarp call
mjw._src.collision_sdf.user_sdf_grad = user_sdf_grad

A, B, C = 0.1, 0.05, 0.145            # SDF sphere radius, ball radius, centre distance
xml = f"""<mujoco><extension><plugin plugin="mujoco.sdf.torus"><instance name="s">
  <config key="radius1" value="0.0001"/><config key="radius2" value="{A}"/></instance></plugin>
  </extension><asset><mesh name="s"><plugin instance="s"/></mesh></asset><worldbody>
  <body><geom type="sdf" mesh="s"><plugin instance="s"/></geom></body>
  <body pos="0 0 {C}"><freejoint/><geom type="sphere" size="{B}"/></body>
  </worldbody></mujoco>"""
mjm = mujoco.MjModel.from_xml_string(xml)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=64, njmax=256)
mjw.kinematics(m, d)
mjw.collision(m, d)
n = int(d.nacon.numpy()[0])
dist = d.contact.dist.numpy()[:n]
normal = d.contact.frame.numpy()[:n, 0]
overlap = A + B - C                     # analytic: the lens is 5 mm deep along the centre line
best = -overlap / 2                     # the lowest possible max(A, B), at the lens midpoint
print(f"nacon {n}, min dist {dist.min():+.5f}, analytic bound {best:+.5f}")
assert n > 0, "no contact: was the patch applied before the first MJWarp call?"
assert dist.min() >= best - 1e-4, "deeper than the analytic minimum of max(A, B)"
assert dist.max() < 0.0 and dist.min() < best / 2, "contact too shallow"
assert abs(normal[np.argmin(dist), 2]) > 0.9, "deepest normal should follow the centre line"
print("ok")
'''

EX2_SOL = ("SRC = r\'\'\'" + SOL2_SRC + "\'\'\'\n"
           "open(\"ex18_2_solution.py\", \"w\").write(SRC)\n"
           "import subprocess, sys\n"
           "run = subprocess.run([sys.executable, \"ex18_2_solution.py\"], capture_output=True, text=True)\n"
           "print(run.stdout or run.stderr)")

CELLS = [
    ["md", "**Reading order.** The cells follow the chapter page section by section. The example numbers are not sequential (18.1, 18.3, 18.4, 18.2, 18.7, 18.5, 18.6, 18.8, 18.9) because they keep the file names used on the page (`ex2_...py` is Example 18.2), so each cell header matches the page's run notes."],
    ["md", "## 1. Heightfields: the TERRAIN scene\nEvery geom that touches a heightfield goes through the HFIELD "
           "prism kernel (`collision_convex.py::ccd_hfield_kernel_builder`), even a sphere."],
    ["example", "ex1_terrain.py", "18.1"],
    ["md", "## 2. Four contacts, not six\nMJWarp keeps at most 4 contacts per heightfield pair; MuJoCo C keeps "
           "its own selection. Compare physics outcomes, not contact counts."],
    ["example", "ex3_hfield_vs_c.py", "18.3"],
    ["md", "## 3. HFIELD overflow\nAt most `MJ_MAXCONPAIR = 50` touching prisms per pair are collected. The "
           "device warning lines are printed by the kernel (on CPU they can appear after the Python lines)."],
    ["example", "ex4_hfield_overflow.py", "18.4"],
    ["md", "## 4. Build terrain with MjSpec, and the default buffer heuristic\n`io.py::_default_nconmax` adds "
           "`nv * 0.35 * 10` contacts per world when the model has a heightfield. We print the default, then use "
           "explicit, smaller sizes."],
    ["example", "ex2_hfield_spec.py", "18.2"],
    ["code", "# Optional plot: the terrain and where the world-0 balls ended (numbers are printed above).\n"
             "try:\n    import matplotlib.pyplot as plt\n"
             "    plt.imshow(elev, origin='lower', extent=[-1, 1, -1, 1], cmap='terrain')\n"
             "    xy = d.qpos.numpy()[0].reshape(NBALL, 7)[:, :2]\n"
             "    plt.scatter(xy[:, 0], xy[:, 1], c='k', s=12)\n"
             "    plt.title('noise terrain and final world-0 ball positions'); plt.show()\n"
             "except ImportError:\n    print('skipped: matplotlib not installed')"],
    ["md", "## 5. `sdf_initpoints` and `sdf_iterations`\nA mesh with `type=\"sdf\"` and no plugin is sampled from "
           "an octree, so no registration is needed and this runs in the notebook process. Both options are "
           "kernel inputs: changing them does not recompile."],
    ["example", "ex7_sdf_iterations.py", "18.7"],
    ["md", FRESH],
    ["md", "## 6. SDF plugins without registration\nThe script runs its work in a child process and counts the "
           "placeholder ERROR lines."],
    ["writefile", "ex5_sdf_unregistered.py", f"{EX}/ex5_sdf_unregistered.py"],
    ["code", "!python ex5_sdf_unregistered.py"],
    ["md", "## 7. Register first, then collide\n`register_sdf_plugins(mjw)` (shipped test helper, private API) "
           "patches Warp versions of nut, bolt, torus and gear. The script also starts a `--late` child that "
           "registers too late."],
    ["writefile", "ex6_sdf_registered.py", f"{EX}/ex6_sdf_registered.py"],
    ["code", "!python ex6_sdf_registered.py"],
    ["md", "## 8. Your own analytic SDF\nA rounded tile patched into `user_sdf` / `user_sdf_grad`, reusing the "
           "`mujoco.sdf.torus` attribute layout. Fresh process again."],
    ["writefile", "ex8_custom_sdf.py", f"{EX}/ex8_custom_sdf.py"],
    ["code", "!python ex8_custom_sdf.py"],
    ["code", "# Level sets of the rounded tile in the x-z plane (numpy copy of the @wp.func, optional plot).\n"
             "R, r = 0.2, 0.03\nxs = np.linspace(-0.3, 0.3, 241); zs = np.linspace(-0.1, 0.1, 81)\n"
             "X, Z = np.meshgrid(xs, zs)\n"
             "q = np.stack([np.abs(X) - R, np.abs(Z)], -1)\n"
             "phi = np.linalg.norm(np.maximum(q, 0), axis=-1) + np.minimum(q.max(-1), 0) - r\n"
             "print('inside fraction of the window:', round(float((phi < 0).mean()), 3))\n"
             "try:\n    import matplotlib.pyplot as plt\n"
             "    plt.contour(X, Z, phi, levels=np.linspace(-0.03, 0.06, 10)); plt.contour(X, Z, phi, [0], colors='k')\n"
             "    plt.gca().set_aspect('equal'); plt.title('rounded tile: SDF level sets (x-z)'); plt.show()\n"
             "except ImportError:\n    print('skipped: matplotlib not installed')"],
    ["md", "## 9. Part IV checkpoint: falling clutter\nTERRAIN + scatter(30): PRIMITIVE, CONVEX and HFIELD paths. "
           "Find the first overflow with small budgets, fix it, and count contacts per path."],
    ["example", "ex9_checkpoint_clutter.py", "18.9"],
    ["md", "## Exercise 18.1: tune the heightfield resolution\nFind the finest grid on which a box of half-size "
           "0.15 m rests without the HFIELD overflow bit."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 18.1"],
    ["md", "## Exercise 18.2: a sphere SDF through the user hook\nFill in the TODOs, then run the next cell (fresh "
           "process). Hint: for two overlapping spheres, `max(A, B)` is lowest at the middle of the overlap "
           "segment on the centre line."],
    ["code", EX2_STUB],
    ["code", "!python ex18_2_sphere_sdf.py"],
    ["solution", EX2_SOL, "Exercise 18.2"],
    ["md", "## Stretch: a torus SDF\nWrite `torus(p, attr)` and its gradient yourself (`attr[0]` major radius, "
           "`attr[1]` minor radius), patch it in a fresh process, and drop a capsule through the hole. Compare "
           "with `mujoco_warp/test_data/collision_sdf/torus.py`.\n\n"
           "## Part IV review (Ch 15-18)\nAnswer for yourself, then check against the chapter page (the quiz there "
           "gives instant feedback).\n"
           "1. Which stage turns all geom pairs into a short candidate list, and where does it write it? "
           "*(the broadphase, NXN or SAP, into the collision context's pair list, counted by `d.ncollision`)*\n"
           "2. For a pair (BOX, SPHERE) listed in the XML as sphere first, which way does `contact.frame[0]` point? "
           "*(from `geom[0]` to `geom[1]`, where `geom[0]` is the lower type: from the sphere (2) to the box (6))*\n"
           "3. \"CCD overflow - please increase naccdmax\". What ran out? *(the GJK/EPA scratch slots of one "
           "convex or HFIELD pair type; each kernel reserves one with `atomic_add(nccd, geomgeomid, 1)`)*\n"
           "4. Which geom pair has no collision function at all in MJWarp 4.0.1? *(hfield-plane: plane-plane, "
           "plane-hfield and hfield-hfield are not in `MJ_COLLISION_TABLE`)*\n"
           "5. Why does GJK need a support function, and which shapes cannot provide one? *(it explores the "
           "Minkowski difference through extreme points; non-convex shapes such as terrain and SDFs have no useful "
           "one, hence prisms and gradient descent)*\n"
           "6. After a long RL rollout `d.overflow` shows NARROWPHASE, but `nacon < naconmax` now. Is the current "
           "step fine? *(maybe: the bits are sticky and record that some step overflowed; zero `d.overflow` to "
           "monitor per step, as Example 18.9 shows)*\n"],
]
