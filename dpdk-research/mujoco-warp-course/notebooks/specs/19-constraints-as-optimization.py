# Notebook spec for Ch 19. Build with:
#   python3 tools/make_notebook.py notebooks/specs/19-constraints-as-optimization.py
SLUG = "19-constraints-as-optimization"
TITLE = "Ch 19 · Constraints as Convex Optimization"

EX1_STUB = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nSCENE = """\n<mujoco><option timestep="0.005" cone="{cone}"/><worldbody>\n  <geom type="plane" size="5 5 .1" condim="{condim}"/>\n  <body pos="0 0 0.099"><freejoint/><geom type="box" size=".1 .1 .1" condim="{condim}"/></body>\n  <body pos="1 0 1"><joint name="h" type="hinge" axis="0 1 0" range="-30 30" frictionloss="0.1"/>\n    <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".03" contype="0" conaffinity="0"/></body>\n  <body name="hang" pos="2 0 1"><freejoint/>\n    <geom type="capsule" fromto="0 0 0 0 0 -.3" size=".02" contype="0" conaffinity="0"/></body>\n</worldbody>\n<equality><connect body1="hang" anchor="0 0 0"/></equality></mujoco>"""\n\n\ndef expected_rows(ncon, condim, cone, ne=3, nf=1, nl=1):\n    ...  # your code: rows for ne + nf + nl + ncon contacts\n\n\n\nfor cone in ("pyramidal", "elliptic"):\n    for condim in (1, 3, 4, 6):\n        mjm = mujoco.MjModel.from_xml_string(SCENE.format(cone=cone, condim=condim))\n        mjd = mujoco.MjData(mjm)\n        mjd.qpos[7] = np.radians(40)          # the hinge starts past its +30 degree limit\n        m = mjw.put_model(mjm)\n        d = mjw.put_data(mjm, mjd, nworld=1, nconmax=8, njmax=64)\n        mjw.forward(m, d)\n        got = int(d.nefc.numpy()[0])\n        assert got == expected_rows(4, condim, cone), (cone, condim, got)\nprint("Exercise 19.1 passed")'
EX1_SOL = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nSCENE = """\n<mujoco><option timestep="0.005" cone="{cone}"/><worldbody>\n  <geom type="plane" size="5 5 .1" condim="{condim}"/>\n  <body pos="0 0 0.099"><freejoint/><geom type="box" size=".1 .1 .1" condim="{condim}"/></body>\n  <body pos="1 0 1"><joint name="h" type="hinge" axis="0 1 0" range="-30 30" frictionloss="0.1"/>\n    <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".03" contype="0" conaffinity="0"/></body>\n  <body name="hang" pos="2 0 1"><freejoint/>\n    <geom type="capsule" fromto="0 0 0 0 0 -.3" size=".02" contype="0" conaffinity="0"/></body>\n</worldbody>\n<equality><connect body1="hang" anchor="0 0 0"/></equality></mujoco>"""\n\n\ndef expected_rows(ncon, condim, cone, ne=3, nf=1, nl=1):\n    if cone == "elliptic":\n        per = condim\n    else:\n        per = 1 if condim == 1 else 2 * (condim - 1)\n    return ne + nf + nl + ncon * per\n\n\nfor cone in ("pyramidal", "elliptic"):\n    for condim in (1, 3, 4, 6):\n        mjm = mujoco.MjModel.from_xml_string(SCENE.format(cone=cone, condim=condim))\n        mjd = mujoco.MjData(mjm)\n        mjd.qpos[7] = np.radians(40)          # the hinge starts past its +30 degree limit\n        m = mjw.put_model(mjm)\n        d = mjw.put_data(mjm, mjd, nworld=1, nconmax=8, njmax=64)\n        mjw.forward(m, d)\n        got = int(d.nefc.numpy()[0])\n        assert got == expected_rows(4, condim, cone), (cone, condim, got)\nprint("Exercise 19.1 passed")'
EX2_STUB = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nTILTED_BOX = """\n<mujoco><option timestep="0.002" cone="pyramidal"/><worldbody>\n  <geom type="plane" size="5 5 .1"/>\n  <body pos="0 0 .098" euler="0 10 0"><freejoint/><geom type="box" size=".1 .1 .1" friction="0.5"/></body>\n</worldbody></mujoco>"""\nmjm = mujoco.MjModel.from_xml_string(TILTED_BOX)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=4, nconmax=8, njmax=32)\nd.qvel.assign(np.array([[v, 0, 0, 0, 0, 0] for v in (0.0, 0.3, 1.0, 3.0)]))\nmjw.forward(m, d)\n\n\ndef check_world(w):\n    ...  # your code: assert the force/activity rule, return the number of active rows\n\n\n\ncounts = [check_world(w) for w in range(d.nworld)]\nprint("active rows per world:", counts)\nassert counts == [8, 6, 6, 2]\nprint("Exercise 19.2 passed")'
EX2_SOL = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nTILTED_BOX = """\n<mujoco><option timestep="0.002" cone="pyramidal"/><worldbody>\n  <geom type="plane" size="5 5 .1"/>\n  <body pos="0 0 .098" euler="0 10 0"><freejoint/><geom type="box" size=".1 .1 .1" friction="0.5"/></body>\n</worldbody></mujoco>"""\nmjm = mujoco.MjModel.from_xml_string(TILTED_BOX)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=4, nconmax=8, njmax=32)\nd.qvel.assign(np.array([[v, 0, 0, 0, 0, 0] for v in (0.0, 0.3, 1.0, 3.0)]))\nmjw.forward(m, d)\n\n\ndef check_world(w):\n    n = int(d.nefc.numpy()[w])\n    J = d.efc.J.numpy()[w, :n, :mjm.nv].astype(np.float64)\n    aref = d.efc.aref.numpy()[w, :n]\n    f = d.efc.force.numpy()[w, :n]\n    jar = J @ d.qacc.numpy()[w] - aref\n    active = jar < 0\n    tol = 1e-3 * max(1.0, np.abs(f).max())\n    assert np.all(f >= -tol)\n    assert np.all(f[~active] <= tol)\n    assert np.all(f[active & (jar < -1e-3)] > 0)\n    return int(active.sum())\n\n\ncounts = [check_world(w) for w in range(d.nworld)]\nprint("active rows per world:", counts)\nassert counts == [8, 6, 6, 2]\nprint("Exercise 19.2 passed")'

CELLS = [
    ["md", "Every code cell below is the same file as the matching block on the chapter page "
           "(`examples/19-constraints-as-optimization/`). Most examples use one world per case, so they are "
           "small on a GPU too; examples with an `ON_GPU` budget grow on a GPU. MJWarp computes in float32, so "
           "expect differences of about 1e-4 to 1e-6 against MuJoCo C (float64). The figure-data flags "
           "(`--dump-json`) are not needed here.\n\n"
           "Order: the cells follow the chapter page: Example 19.1, the NumPy math toolkit (Example 19.12), "
           "then Examples 19.2, 19.3, 19.9, 19.11, 19.10 and 19.4-19.8. The "
           "centerpiece is Example 19.3, which rebuilds the cost from MJWarp's arrays and proves that "
           "`qacc` is its minimizer."],
    ["md", "## 1. The 1-D toy: one ball, one row\nThe ball's acceleration minimizes "
           "`0.5 m (a - a0)^2 + 0.5 D (a - aref)^2` (second term only while `a < aref`). The closed form is "
           "`a* = (m a0 + D aref)/(m + D)`. `k, b, imp` come from solref/solimp as in "
           "`constraint.py::_contact_kbimp`, then `D = imp/((1-imp) invweight)` and `aref = -b v - k imp pos` "
           "(`_efc_row`). Each world is one (penetration, velocity) case."],
    ["example", "ex1_toy_1d.py", "19.1"],
    ["md", "## Math toolkit (chapter section 2)\nA 2-D SPD quadratic minimized by gradient descent (fixed "
           "step), Newton (1 step) and conjugate gradient (2 steps), then a 1-D piecewise quadratic with three "
           "kinks, minimized exactly by Newton steps that jump from piece to piece. This is the vocabulary of "
           "the solvers in Ch 20: `SolverType.CG`, `SolverType.NEWTON` and the exact line search."],
    ["example", "ex12_math_toolkit.py", "19.12"],
    ["md", "## 4. The efc arrays\nRows come out per world in the order equality | friction | limit | "
           "contact. One row of every category, compared with MuJoCo C. Note the limit row: violated "
           "(`pos < 0`) but SATISFIED, because activity is decided at the optimum."],
    ["example", "ex2_inspect_efc.py", "19.2"],
    ["md", "## 5. Verify the optimum yourself (centerpiece)\nRebuild "
           "`cost(a) = 0.5 (a - qacc_smooth)^T M (a - qacc_smooth) + sum_active 0.5 D (J a - aref)^2` in NumPy, "
           "recompute the forces, check `M (qacc - qacc_smooth) = J^T force`, and check that random "
           "perturbations of `qacc` never lower the cost."],
    ["example", "ex3_rebuild_cost.py", "19.3"],
    ["md", "## 6. Per-world eq_active seen through the efc strip\nRecall Ch 8 ex6 (same toggle). New here: "
           "the weld block always takes rows 0-5, and where it is switched off every contact's "
           "`contact.efc_address` shifts down by 6."],
    ["example", "ex9_eq_active_worlds.py", "19.9"],
    ["md", "## 6. make_constraint and solve by hand\nBoth are public. Rebuilding the rows and re-solving after "
           "`forward` gives a bitwise-identical `qacc`."],
    ["example", "ex11_by_hand.py", "19.11"],
    ["md", "## 7. Dense vs sparse J\n`jacobian=\"auto\"` is sparse for `nv > 32`. Sparse `efc.J` is a value "
           "ribbon `(nworld, 1, njmax_nnz)` indexed by `J_rowadr`, `J_rownnz`, `J_colind` (columns in "
           "descending order). Dense is `(nworld, njmax_pad, nv_pad)`."],
    ["example", "ex10_sparse_j.py", "19.10"],
    ["md", "## 8. Softness: impedance and D\n`imp(x)` with `x = |pos|/width` is a sigmoid from dmin to dmax "
           "built from two power curves joined at `mid`. `D = imp / ((1 - imp) invweight)`."],
    ["example", "ex4_impedance.py", "19.4"],
    ["md", "## 8. A per-world solref sweep\n`geom_solref` is batched over worlds "
           "(`put_model(..., batch_sizes=...)`): eight time constants in one launch. Larger timeconst, "
           "softer contact, deeper penetration. The static model `p = g (1 - imp) / (k imp^2)` predicts the "
           "rest penetration."],
    ["example", "ex5_solref_sweep.py", "19.5"],
    ["md", "## 9. Cones and condim\nPyramidal: `2*(condim-1)` independent rows `n +- mu t` (1 for condim 1). "
           "Elliptic: `condim` coupled rows with SATISFIED / CONE / QUADRATIC zones. Each (cone, condim) "
           "combination compiles a few kernels the first time."],
    ["example", "ex6_cones_condim.py", "19.6"],
    ["md", "## 9. Friction loss: a Huber row\nQuadratic for `|x| < frictionloss/D` (the joint sticks with a "
           "small soft creep), linear beyond (LINEARPOS/LINEARNEG, force exactly -+frictionloss)."],
    ["example", "ex7_frictionloss.py", "19.7"],
    ["md", "## 10. Equalities\nCONNECT (3 rows), WELD (6), JOINT (1), TENDON (1). Rows come out per kernel "
           "type (connect, weld, joint, tendon), not in eq-id order; map rows with `efc.id`. FLEX and "
           "FLEXSTRAIN need a flex and are shown in Ch 23."],
    ["example", "ex8_equalities.py", "19.8"],
    ["md", "## Exercise 19.1: predict nefc\nWrite `expected_rows(ncon, condim, cone)` and assert it against "
           "`d.nefc` for both cones and condim 1, 3, 4, 6. The scene has 1 CONNECT equality (3 rows), 1 "
           "friction-loss dof, 1 violated hinge limit and 4 box-floor contacts. A contact takes the larger "
           "condim of its two geoms, so the floor gets the same condim."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 19.1"],
    ["md", "## Exercise 19.2: force only on active pyramid rows\nOn the ex3 scene, assert from MJWarp's "
           "arrays that every pyramidal row force is >= 0, zero where `J qacc - aref >= 0`, and positive "
           "where it is clearly negative. Return the active-row count per world."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 19.2"],
    ["md", "## Stretch: the elliptic cone in NumPy\nSwitch the ex3 scene to `cone=\"elliptic\"` (3 rows per "
           "contact). Group rows by `efc.id`; per contact compute `N = mu x0` and `T = ||(mu_i x_i)||` from "
           "the residuals `x = J qacc - aref`; pick the zone as in `solver.py::_eval_constraint` (top: 0; "
           "bottom: sum 0.5 D_i x_i^2; middle: 0.5 dm (N - mu T)^2 with dm = D0 / (mu^2 (1 + mu^2))); check "
           "that random perturbations of qacc never lower your cost and that your forces match "
           "`efc.force`."],
]
