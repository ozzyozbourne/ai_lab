# Notebook spec for Ch 21. Build with:
#   python3 tools/make_notebook.py notebooks/specs/21-islands-and-sleep.py
SLUG = "21-islands-and-sleep"
TITLE = "Ch 21 · Islands and Sleeping"

CHECKLIST = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\n\ndef sleep_checklist(mjm, nvmax=None):\n    """Return (ok, notes): the 4.0.1 put_model / make_data / first-step sleep rules applied to an MjModel."""\n    notes = []\n    sleep = bool(mjm.opt.enableflags & mujoco.mjtEnableBit.mjENBL_SLEEP)\n    if not sleep:\n        return True, ["SLEEP flag off: nothing to check (nvmax is ignored)"]\n    sp = mujoco.mjtSleepPolicy             # 4.0.1 supports only the compiler\'s AUTO values\n    supported = {int(sp.mjSLEEP_AUTO), int(sp.mjSLEEP_AUTO_NEVER), int(sp.mjSLEEP_AUTO_ALLOWED)}\n    bad = [sp(p).name for p in np.unique(mjm.tree_sleep_policy) if int(p) not in supported]\n    if bad:\n        notes.append(f"put_model raises NotImplementedError: {bad} not supported")\n    if (mjm.eq_type == mujoco.mjtEq.mjEQ_FLEX).any():\n        notes.append("put_model raises NotImplementedError: flex equality with sleep")\n    if mjm.opt.solver != mujoco.mjtSolver.mjSOL_NEWTON:\n        notes.append("put_model raises ValueError: sleeping requires the Newton solver")\n    discrete = mjm.opt.integrator == mujoco.mjtIntegrator.mjINT_DISCRETE\n    no_island = bool(mjm.opt.disableflags & mujoco.mjtDisableBit.mjDSBL_ISLAND)\n    if no_island:\n        notes.append("island disabled: nothing will ever sleep"\n                     + ("" if nvmax is not None else "; pass nvmax or the step reads empty buffers"))\n        if discrete:\n            notes.append("first forward raises ValueError: "\n                         "Discrete integrator: sleep without islands not yet supported")\n        if nvmax is not None and nvmax < mjm.nv:\n            notes.append(f"nvmax ({nvmax}) < nv ({mjm.nv}) with islands off: NVMAX set every step, "\n                         "DOFs past nvmax get qacc = 0")\n    elif discrete and mjm.nflex > 0:\n        # approximate: the exact check_discrete conditions use mjw Model fields (see Ch 23)\n        notes.append("discrete + flex: some flex features raise at the first forward (approximate check, see Ch 23)")\n    if nvmax is not None and not 0 <= nvmax <= mjm.nv:\n        notes.append(f"make_data raises ValueError: nvmax ({nvmax}) must be in [0, nv ({mjm.nv})]")\n    errors = [n for n in notes if "raises" in n or "empty" in n or "NVMAX" in n]\n    return not errors, notes or ["all sleep requirements met"]'
CHECKLIST_DEMO = 'ok_xml = (\'<mujoco><option solver="Newton"><flag sleep="enable"/></option><worldbody>\'\n          \'<geom type="plane" size="1 1 .1"/><body pos="0 0 .1"><freejoint/>\'\n          \'<geom type="box" size=".1 .1 .1"/></body></worldbody></mujoco>\')\nno_island = ok_xml.replace(\'sleep="enable"\', \'sleep="enable" island="disable"\')\nfor label, xml, nvmax in [\n        ("ok", ok_xml, None), ("CG", ok_xml.replace("Newton", "CG"), None),\n        ("init", ok_xml.replace(\'<body pos\', \'<body sleep="init" pos\'), None),\n        ("no island", no_island, None),\n        ("discrete, no island", no_island.replace(\'solver="Newton"\', \'solver="Newton" integrator="discrete"\'), 6),\n        ("island off, nvmax=1", no_island, 1)]:\n    mjm = mujoco.MjModel.from_xml_string(xml)\n    print(label, sleep_checklist(mjm, nvmax))\n'
EX1_STUB = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nBODIES = "".join(\n    f\'<body name="box{i}" pos="{0.5 * i:.2f} 0 0.099"><freejoint/>\'\n    f\'<geom type="box" size=".1 .1 .1"/></body>\' for i in range(6))\nXML = (\'<mujoco><option timestep="0.01" solver="Newton"><flag sleep="enable"/></option>\'\n       f\'<worldbody><geom type="plane" size="5 5 .1"/>{BODIES}</worldbody></mujoco>\')\nmjm = mujoco.MjModel.from_xml_string(XML)\nNWORLD = 4\n\n\ndef run(nvmax, nstep=60):\n    m = mjw.put_model(mjm)\n    m.opt.warn_overflow = 0\n    mjd = mujoco.MjData(mjm)\n    mjd.tree_asleep[:] = np.arange(mjm.ntree, dtype=np.int32)      # start asleep\n    d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=32, njmax=128, nvmax=nvmax)\n    xfrc = np.zeros((NWORLD, mjm.nbody, 6), dtype=np.float32)\n    xfrc[:, mjm.body("box0").id, 2] = 150.0                          # lift box 0 ...\n    xfrc[:, mjm.body("box1").id, 0] = 30.0                           # ... and slide box 1\n    d.xfrc_applied.assign(xfrc)\n    peak = 0\n    for i in range(nstep):\n        if i == 5:\n            d.xfrc_applied.zero_()\n        mjw.step(m, d)\n        peak = max(peak, int(d.nv_awake.numpy().max()))\n    bits = int(np.bitwise_or.reduce(d.overflow.numpy()))\n    return bits, peak\n\n\nNVMAX = ...          # your choice: the smallest capacity that never overflows\nbits, peak = run(NVMAX)\nprint("nvmax", NVMAX, "peak awake dofs", peak, "overflow bits", bits)\nassert NVMAX < mjm.nv\nassert not bits & mjw.OverflowType.NVMAX\nbits6, _ = run(6)\nprint("nvmax 6 -> overflow", [o.name for o in mjw.OverflowType if bits6 & o])\nassert bits6 & mjw.OverflowType.NVMAX\nprint("OK")\n'
EX1_SOL = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nBODIES = "".join(\n    f\'<body name="box{i}" pos="{0.5 * i:.2f} 0 0.099"><freejoint/>\'\n    f\'<geom type="box" size=".1 .1 .1"/></body>\' for i in range(6))\nXML = (\'<mujoco><option timestep="0.01" solver="Newton"><flag sleep="enable"/></option>\'\n       f\'<worldbody><geom type="plane" size="5 5 .1"/>{BODIES}</worldbody></mujoco>\')\nmjm = mujoco.MjModel.from_xml_string(XML)\nNWORLD = 4\n\n\ndef run(nvmax, nstep=60):\n    m = mjw.put_model(mjm)\n    m.opt.warn_overflow = 0\n    mjd = mujoco.MjData(mjm)\n    mjd.tree_asleep[:] = np.arange(mjm.ntree, dtype=np.int32)      # start asleep\n    d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=32, njmax=128, nvmax=nvmax)\n    xfrc = np.zeros((NWORLD, mjm.nbody, 6), dtype=np.float32)\n    xfrc[:, mjm.body("box0").id, 2] = 150.0                          # lift box 0 ...\n    xfrc[:, mjm.body("box1").id, 0] = 30.0                           # ... and slide box 1\n    d.xfrc_applied.assign(xfrc)\n    peak = 0\n    for i in range(nstep):\n        if i == 5:\n            d.xfrc_applied.zero_()\n        mjw.step(m, d)\n        peak = max(peak, int(d.nv_awake.numpy().max()))\n    bits = int(np.bitwise_or.reduce(d.overflow.numpy()))\n    return bits, peak\n\n\nNVMAX = 12\nbits, peak = run(NVMAX)\nprint("nvmax", NVMAX, "peak awake dofs", peak, "overflow bits", bits)\nassert NVMAX < mjm.nv\nassert not bits & mjw.OverflowType.NVMAX\nbits6, _ = run(6)\nprint("nvmax 6 -> overflow", [o.name for o in mjw.OverflowType if bits6 & o])\nassert bits6 & mjw.OverflowType.NVMAX\nprint("OK")\n'
EX2_STUB = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nZ = [0.1, 0.3, 0.5]\nBODIES = "".join(\n    f\'<body pos="{0.4 * i:.2f} 0 {z}"><freejoint/><geom type="box" size=".1 .1 .1"/></body>\'\n    for i, z in enumerate(Z))\nXML = (\'<mujoco><option timestep="0.01" solver="Newton"><flag sleep="enable"/></option>\'\n       f\'<worldbody><geom type="plane" size="5 5 .1"/>{BODIES}</worldbody></mujoco>\')\nmjm = mujoco.MjModel.from_xml_string(XML)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=4, nconmax=16, njmax=64)\n\n\ndef all_asleep(d):\n    """True when every tree in every world is asleep."""\n    ...      # read d.tree_asleep (or d.ntree_awake) on the host\n\n\nassert not all_asleep(d)                 # make_data starts every tree awake\nN = 200\nfor i in range(N):\n    mjw.step(m, d)\n    if all_asleep(d):\n        break\nprint("all asleep after", i + 1, "steps")\nassert all_asleep(d)\nassert (d.ntree_awake.numpy() == 0).all()\nprint("OK")\n'
EX2_SOL = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nZ = [0.1, 0.3, 0.5]\nBODIES = "".join(\n    f\'<body pos="{0.4 * i:.2f} 0 {z}"><freejoint/><geom type="box" size=".1 .1 .1"/></body>\'\n    for i, z in enumerate(Z))\nXML = (\'<mujoco><option timestep="0.01" solver="Newton"><flag sleep="enable"/></option>\'\n       f\'<worldbody><geom type="plane" size="5 5 .1"/>{BODIES}</worldbody></mujoco>\')\nmjm = mujoco.MjModel.from_xml_string(XML)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=4, nconmax=16, njmax=64)\n\n\ndef all_asleep(d):\n    """True when every tree in every world is asleep."""\n    return bool((d.tree_asleep.numpy() >= 0).all())\n\n\nassert not all_asleep(d)                 # make_data starts every tree awake\nN = 200\nfor i in range(N):\n    mjw.step(m, d)\n    if all_asleep(d):\n        break\nprint("all asleep after", i + 1, "steps")\nassert all_asleep(d)\nassert (d.ntree_awake.numpy() == 0).all()\nprint("OK")\n'

CELLS = [
    ["md", "Every code cell below is the same file as the matching block on the chapter page "
           "(`examples/21-islands-and-sleep/`). Budgets grow on a GPU (`ON_GPU`) and stay small on a CPU. "
           "Cells follow the page order, and the numbered headings are the page's section numbers. "
           "Timings are **your** numbers; CPU numbers say nothing about GPU speed.\n\n"
           "Every scene in this notebook uses `<flag sleep=\"enable\"/>` and `solver=\"Newton\"` (sleep "
           "requires Newton in 4.0.1)."],
    ["md", "## 1. Islands\nA *tree* is a body subtree hanging off the world body. Constraint rows (contacts, "
           "equalities, limits, friction) couple trees; an *island* is a connected group of coupled trees. "
           "`forward` runs island discovery (`island.island`, a GPU disjoint-set union over the efc rows) only "
           "when sleep is enabled; the public `mjw.island(m, d)` runs it on demand. Trees with no constraint "
           "row get `tree_island = -1`."],
    ["example", "ex1_islands.py", "21.1"],
    ["md", "## 2. Contacts build islands\nA stack shares one island, loose boxes get their own, and MJWarp's "
           "partition matches C MuJoCo. Then `mjw.island` timing against nworld (your GPU table on Colab)."],
    ["example", "ex8_islands_vs_contacts.py", "21.8"],
    ["md", "## 4. The sleep requirements\nAn error gallery of every check `put_model` and `make_data` make "
           "in 4.0.1, then the same rules as a small Python function you can run on your own models."],
    ["example", "ex6_sleep_errors.py", "21.6"],
    ["code", CHECKLIST],
    ["code", CHECKLIST_DEMO],
    ["md", "## 5. Falling asleep\n`tree_asleep` starts at `-(1 + mjMINAWAKE) = -11`. At the end of each "
           "step `sleep.sleep` adds 1 for every tree that is slow enough (`|dof_length * qvel| < "
           "sleep_tolerance` on every DOF, no applied force) and resets it to -11 otherwise. When every tree "
           "of an island has reached -1, `_build_cycles` links them into a circular list (values >= 0) and "
           "zeroes their qvel and qacc."],
    ["example", "ex2_fall_asleep.py", "21.2"],
    ["md", "## 6. Waking up\n`sleep.wake` (start of `forward`) wakes a sleeping tree that has a non-zero "
           "velocity, `qfrc_applied` or `xfrc_applied`; `sleep.wake_collision` wakes a sleeping tree that "
           "touches an awake one; `sleep.wake_equality` and `sleep.wake_tendon` do the same for active "
           "equalities and constrained tendons. Waking one tree wakes its whole sleep cycle."],
    ["example", "ex3_wake.py", "21.3"],
    ["md", "## 7. Starting asleep without sleep=\"init\"\nThe `--init_asleep` pattern from `_src/cli.py`: "
           "write `mjd.tree_asleep[:] = np.arange(ntree)` on the host, then call `put_data`."],
    ["example", "ex7_init_asleep.py", "21.7"],
    ["md", "## 8. nvmax: the capacity of the compacted solve\nWith sleep on, the awake DOFs are packed into "
           "dense buffers of `nvmax_pad` columns (`island.update_active_dofs`). More awake DOFs than `nvmax` "
           "sets the NVMAX overflow bit, and the DOFs that did not fit get zero acceleration. With sleep off, "
           "nvmax is ignored."],
    ["example", "ex4_nvmax.py", "21.4"],
    ["md", "## 10. What sleep costs and buys\nOn a GPU this cell prints your own numbers. On a CPU the "
           "compacted Newton loop runs all `opt.iterations` (no graph conditional off CUDA), so sleep looks "
           "slow there; what carries over is the work count: asleep worlds have `nacon = 0` and `nefc = 0`."],
    ["example", "ex5_sleep_cost.py", "21.5"],
    ["md", "## Exercise 21.1: size nvmax\nAll six boxes start asleep. Boxes 0 and 1 are pushed in every world "
           "and nothing else ever moves. Pick the smallest `NVMAX` that never sets the NVMAX bit, and check "
           "that 6 is too small."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 21.1"],
    ["md", "## Exercise 21.2: all_asleep(d)\nWrite `all_asleep(d)` and assert that a settling three-box scene "
           "reaches it within 200 steps."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 21.2"],
    ["md", "## Stretch: throughput against the fraction of moving objects\nOn a GPU, build a 64-box clutter "
           "scene, start every world asleep, and keep a fraction f of the boxes moving with `xfrc_applied`. "
           "Measure world-steps/s for f in 0, 0.1, 0.25, 0.5 and 1 with sleep on (nvmax sized for f) and "
           "off, and plot the ratio."],
]
