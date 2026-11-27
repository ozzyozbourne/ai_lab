# Notebook spec for Chapter 11. Build with:
#   python3 tools/make_notebook.py notebooks/specs/11-equations-of-motion-kinematics-mass-matrix.py
SLUG = "11-equations-of-motion-kinematics-mass-matrix"
TITLE = "Ch 11 · Equations of Motion, Kinematics and the Mass Matrix"

SPY = r'''# Interactive spy plot of the HUMANOID mass matrix: CSR lower triangle (as stored in d.M) and its
# mirror. Move the ROW slider (ipywidgets, preinstalled on Colab) to see which columns one CSR row
# stores: the ancestors of that dof. Without ipywidgets the cell draws ROW = 20 once; edit ROW and re-run.
import mujoco
import numpy as np
from etils import epath
try:
    import matplotlib.pyplot as plt
except ImportError:
    plt = None
    print("skipped: matplotlib not installed")

hum = mujoco.MjModel.from_xml_path(
    str(epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"))


def spy(ROW=20):
    pattern = np.zeros((hum.nv, hum.nv))
    for i in range(hum.nv):
        cols = hum.M_colind[hum.M_rowadr[i]:hum.M_rowadr[i] + hum.M_rownnz[i]]
        pattern[i, cols] = 2 if i == ROW else 1       # stored (lower triangle)
        pattern[cols, i] = np.maximum(pattern[cols, i], 0.4)  # mirrored (upper, not stored)
    cols = hum.M_colind[hum.M_rowadr[ROW]:hum.M_rowadr[ROW] + hum.M_rownnz[ROW]]
    print(f"row {ROW} ({hum.body(int(hum.dof_bodyid[ROW])).name}): CSR adr {hum.M_rowadr[ROW]}, "
          f"nnz {hum.M_rownnz[ROW]}, columns {cols.tolist()}")
    if plt is not None:
        fig, ax = plt.subplots(figsize=(5.5, 5.5))
        ax.imshow(pattern, cmap="Greens", vmin=0, vmax=2)
        ax.set_title(f"HUMANOID M: nC = {hum.nC} stored of {hum.nv * hum.nv}, row {ROW}")
        ax.set_xlabel("column (dof)")
        ax.set_ylabel("row (dof)")
        plt.show()


try:
    import ipywidgets as widgets
    widgets.interact(spy, ROW=widgets.IntSlider(value=20, min=0, max=hum.nv - 1, description="ROW"))
except ImportError:
    print("static fallback: ipywidgets not installed (try ROW = 6, 15, 20, 26)")
    spy(ROW=20)
'''

EX1_STUB = r'''# Exercise 11.1: c(q, qdot) for the PENDULUM with your own two-sweep NumPy RNE.
# Run Example 11.2 first (it defines PENDULUM). Fill in my_rne and make the assert pass.
mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
NWORLD = 8
d = mjw.make_data(mjm, nworld=NWORLD)
rng = np.random.default_rng(7)
d.qpos.assign(rng.uniform(-np.pi, np.pi, (NWORLD, 2)).astype(np.float32))
d.qvel.assign(rng.uniform(-3, 3, (NWORLD, 2)).astype(np.float32))
mjw.forward(m, d)


def my_rne(q, qd, xanchor, xipos):
    """Return c = [tau1, tau2] for qacc = 0 (Coriolis + centrifugal + gravity)."""
    ...  # forward sweep: w1, w2, a_c1, a_c2 (gravity trick: base accelerates up by g)
    ...  # backward sweep: forces F2, F1 and the torques about each hinge axis


q, qd = d.qpos.numpy(), d.qvel.numpy()
xa, xi = d.xanchor.numpy(), d.xipos.numpy()
if my_rne(q[0], qd[0], xa[0], xi[0]) is None:
    print("my_rne returns None: fill in the two sweeps, then re-run this cell (or open the solution).")
else:
    mine = np.array([my_rne(q[w], qd[w], xa[w], xi[w]) for w in range(NWORLD)])
    assert np.abs(mine - d.qfrc_bias.numpy()).max() < 1e-4
    print("Exercise 11.1 passed")
'''

EX1_SOL = r'''mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
NWORLD = 8
d = mjw.make_data(mjm, nworld=NWORLD)
rng = np.random.default_rng(7)
d.qpos.assign(rng.uniform(-np.pi, np.pi, (NWORLD, 2)).astype(np.float32))
d.qvel.assign(rng.uniform(-3, 3, (NWORLD, 2)).astype(np.float32))
mjw.forward(m, d)


def my_rne(q, qd, xanchor, xipos):
    """c(q, qdot): RNE with qacc = 0 and the gravity trick (base accelerates up by g)."""
    e = np.array([0.0, 1.0, 0.0])                     # both hinge axes (world y)
    g = -mjm.opt.gravity[2]
    mass = mjm.body_mass[1:3]
    p1, p2 = xanchor[0], xanchor[1]
    c1, c2 = xipos[1], xipos[2]
    # forward sweep (root -> leaf): angular velocity and linear acceleration
    w1 = e * qd[0]
    w2 = w1 + e * qd[1]
    a_p1 = np.array([0.0, 0.0, g])                    # gravity trick
    a_c1 = a_p1 + np.cross(w1, np.cross(w1, c1 - p1))
    a_p2 = a_p1 + np.cross(w1, np.cross(w1, p2 - p1))
    a_c2 = a_p2 + np.cross(w2, np.cross(w2, c2 - p2))
    # backward sweep (leaf -> root): force and moment carried to each joint
    F2 = mass[1] * a_c2                               # alpha = 0 and w x I w = 0 (planar)
    F1 = mass[0] * a_c1
    tau2 = e @ np.cross(c2 - p2, F2)
    tau1 = e @ (np.cross(c1 - p1, F1) + np.cross(c2 - p1, F2))
    return np.array([tau1, tau2])


q, qd = d.qpos.numpy(), d.qvel.numpy()
xa, xi = d.xanchor.numpy(), d.xipos.numpy()
mine = np.array([my_rne(q[w], qd[w], xa[w], xi[w]) for w in range(NWORLD)])
err = np.abs(mine - d.qfrc_bias.numpy()).max()
print("world 0 mine:", mine[0], " qfrc_bias:", d.qfrc_bias.numpy()[0], f" max err {err:.2e}")
assert err < 1e-4
print("Exercise 11.1 passed")
'''

EX2_STUB = r'''# Exercise 11.2: a hub on a free joint with 3 arms of 2 links each. Predict before you run.
def arm(k):
    return (f'<body pos="{np.cos(k * 2.094):.3f} {np.sin(k * 2.094):.3f} 0">'
            f'<joint type="hinge" axis="0 0 1"/><geom type="sphere" size=".05"/>'
            f'<body pos=".3 0 0"><joint type="hinge" axis="0 1 0"/><geom type="sphere" size=".05"/>'
            f'</body></body>')


STAR = ('<mujoco><worldbody><body name="hub" pos="0 0 1"><freejoint/>'
        '<geom type="cylinder" size=".2 .05"/>' + "".join(arm(k) for k in range(3)) +
        '</body></worldbody></mujoco>')
mjm = mujoco.MjModel.from_xml_string(STAR)
m = mjw.put_model(mjm)

nbranch_pred = ...    # your prediction
nvisit_pred = ...     # total body visits of the branch walk = len(m.body_branches)
if nbranch_pred is ... or nvisit_pred is ...:
    print("Replace the two ... with your predictions, then re-run this cell (or open the solution).")
else:
    assert m.nbranch == nbranch_pred, m.nbranch
    assert len(m.body_branches.numpy()) == nvisit_pred
    print("Exercise 11.2 passed")
'''

EX2_SOL = r'''# Exercise 11.2 solution (self-contained: rebuilds the STAR model).
def arm(k):
    return (f'<body pos="{np.cos(k * 2.094):.3f} {np.sin(k * 2.094):.3f} 0">'
            f'<joint type="hinge" axis="0 0 1"/><geom type="sphere" size=".05"/>'
            f'<body pos=".3 0 0"><joint type="hinge" axis="0 1 0"/><geom type="sphere" size=".05"/>'
            f'</body></body>')


STAR = ('<mujoco><worldbody><body name="hub" pos="0 0 1"><freejoint/>'
        '<geom type="cylinder" size=".2 .05"/>' + "".join(arm(k) for k in range(3)) +
        '</body></worldbody></mujoco>')
mjm = mujoco.MjModel.from_xml_string(STAR)
m = mjw.put_model(mjm)

nbranch_pred = 3          # one branch per leaf body: the three outer links
nvisit_pred = 3 * 3       # each branch visits hub + inner link + outer link
assert m.nbranch == nbranch_pred, m.nbranch
assert len(m.body_branches.numpy()) == nvisit_pred
print("nbranch =", m.nbranch, " body_branches =", m.body_branches.numpy().tolist())
print("body_subtreenum =", m.body_subtreenum.numpy().tolist())
print("Exercise 11.2 passed")
'''

STRETCH = r'''# Stretch: check your prediction of M_tiles for 3 free spheres + a 7-hinge arm.
def scene(offset):
    frees = "".join(f'<body pos="{i} 0 1"><freejoint/>'
                    f'<geom type="sphere" size=".1" pos="{offset} 0 0"/></body>' for i in range(3))
    links, close = "", ""
    for k in range(7):
        ax = "0 0 1" if k % 2 == 0 else "0 1 0"
        links += (f'<body pos="0 0 .1"><joint type="hinge" axis="{ax}"/>'
                  f'<geom type="capsule" fromto="0 0 0 0 0 .1" size=".02"/>')
        close += "</body>"
    return f'<mujoco><worldbody>{frees}<body pos="0 2 0">{links}{close}</body></worldbody></mujoco>'


for offset in (0.0, 0.05):      # sphere at the body origin, then off-centre
    mjm = mujoco.MjModel.from_xml_string(scene(offset))
    m = mjw.put_model(mjm)
    print(f"offset {offset}: M_tiles =",
          [(t.size, t.adr.numpy().tolist(), t.elemid.size) for t in m.M_tiles],
          "qLD_block_total =", m.qLD_block_total)
    print("   qLD_block_adr =", m.qLD_block_adr.numpy().tolist())
'''

CELLS = [
    ["md", "## How to use this notebook\n"
           "Run the setup cell first. Every example below is the same file as on the chapter page "
           "(`examples/11-equations-of-motion-kinematics-mass-matrix/`). Budgets switch on `ON_GPU`: "
           "small on CPU, large on a Colab GPU. Timings you see are your own device's numbers."],
    ["md", "## 1-2. The equation of motion and the mass matrix\n"
           "`M(q) qacc + c(q, qdot) = tau + J^T f`. Example 11.1 derives `M` and `c` of the double "
           "pendulum by hand (Lagrange) and compares with MuJoCo C; Example 11.2 checks that "
           "`0.5 qvel^T M qvel` is the kinetic energy in every world."],
    ["example", "ex1_two_link_numpy.py", "11.1"],
    ["example", "ex2_kinetic_energy.py", "11.2"],
    ["md", "## 3. Spatial vectors and the com frame\n"
           "`cvel` is (angular, linear) and its linear part is the velocity of the point at the "
           "subtree com of the root."],
    ["example", "ex3_spatial_vectors.py", "11.3"],
    ["md", "## 4-5. Joint math, the kinematics outputs, and the branch walk\n"
           "`smooth.kinematics` launches `_kinematics_branch` with `dim=(nworld, nbranch)`, one thread "
           "per (world, branch) walking root to leaf, then per-body, per-geom and per-site poses."],
    ["example", "ex4_branches.py", "11.4"],
    ["example", "ex5_kinematics_only.py", "11.5"],
    ["md", "### Your own kinematics kernel\nA closed-form planar FK kernel, one thread per world. "
           "Timings are your device's numbers (on CPU they are CPU numbers, not GPU performance)."],
    ["example", "ex11_my_fk_kernel.py", "11.11"],
    ["md", "## 6. Subtrees as contiguous ranges"],
    ["example", "ex6_subtree_ranges.py", "11.6"],
    ["md", "## 7. com_pos: cdof is the Jacobian"],
    ["example", "ex7_cdof_vs_jac.py", "11.7"],
    ["md", "## 8. crb and the CSR mass matrix"],
    ["example", "ex8_csr_to_dense.py", "11.8"],
    ["md", "### Spy plot of the humanoid mass matrix\nDark cells are stored in `d.M` (lower "
           "triangle), pale ones are their mirror. Move the `ROW` slider (static fallback without "
           "ipywidgets: edit `ROW` and re-run)."],
    ["code", SPY],
    ["md", "## 9. factor_m, solve_m, mul_m and jac"],
    ["example", "ex9_solve_mul.py", "11.9"],
    ["example", "ex10_site_jacobian.py", "11.10"],
    ["md", "### The stale-factor trap\nOne factorization per new qpos: compare the four pairings."],
    ["example", "ex13_stale_factor.py", "11.13"],
    ["md", "## 10. Going deeper: the factorization families (`m.M_tiles`, `qLD`)\n"
           "Every field read here is public on `mjw.Model` (`M_tiles`, `qLD_block_adr`, `is_sparse`)."],
    ["example", "ex12_m_tiles.py", "11.12"],
    ["md", "## Exercise 11.1 (auto-checked): your own RNE\nCompute `c(q, qdot)` for the pendulum "
           "with two sweeps over the 2 links and assert it against `d.qfrc_bias` in every world."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 11.1"],
    ["md", "## Exercise 11.2 (auto-checked): predict nbranch\nA free hub with three 2-link arms."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 11.2"],
    ["md", "## Stretch: predict `M_tiles` for 3 free bodies + a 7-dof arm\nWrite your prediction "
           "(sizes, start dofs, which path, `qLD_block_total`) before running the cell."],
    ["code", STRETCH],
]
