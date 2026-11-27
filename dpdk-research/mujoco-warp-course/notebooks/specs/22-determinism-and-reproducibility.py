# Notebook spec for Ch 22. Build with:
#   python3 tools/make_notebook.py notebooks/specs/22-determinism-and-reproducibility.py
SLUG = "22-determinism-and-reproducibility"
TITLE = "Ch 22 · Determinism and Reproducibility"

EX1_STUB = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nPENDULUM = """\n<mujoco><option timestep="0.01"/><worldbody>\n  <body pos="0 0 1.5"><joint name="h1" type="hinge" axis="0 1 0"/>\n    <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>\n    <body pos="0 0 -.5"><joint name="h2" type="hinge" axis="0 1 0"/>\n      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/></body></body>\n</worldbody></mujoco>"""\nmjm = mujoco.MjModel.from_xml_string(PENDULUM)\nm = mjw.put_model(mjm)\n\n\ndef run(nudge=0.0, nworld=4, nstep=50):\n    d = mjw.make_data(mjm, nworld=nworld)\n    qpos = np.tile([1.2, 0.0], (nworld, 1)).astype(np.float32)\n    qpos[2, 0] += nudge                       # only world 2 is nudged\n    d.qpos.assign(qpos)\n    for _ in range(nstep):\n        mjw.step(m, d)\n    return d\n\n\ndef first_difference(d1, d2, fields=("qpos", "qvel", "qacc")):\n    ...  # your code\n\n\nassert first_difference(run(), run()) is None\nassert first_difference(run(), run(nudge=1e-5)) == ("qpos", 2)\nprint("Exercise 22.1 passed")'
EX1_SOL = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nPENDULUM = """\n<mujoco><option timestep="0.01"/><worldbody>\n  <body pos="0 0 1.5"><joint name="h1" type="hinge" axis="0 1 0"/>\n    <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>\n    <body pos="0 0 -.5"><joint name="h2" type="hinge" axis="0 1 0"/>\n      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/></body></body>\n</worldbody></mujoco>"""\nmjm = mujoco.MjModel.from_xml_string(PENDULUM)\nm = mjw.put_model(mjm)\n\n\ndef run(nudge=0.0, nworld=4, nstep=50):\n    d = mjw.make_data(mjm, nworld=nworld)\n    qpos = np.tile([1.2, 0.0], (nworld, 1)).astype(np.float32)\n    qpos[2, 0] += nudge                       # only world 2 is nudged\n    d.qpos.assign(qpos)\n    for _ in range(nstep):\n        mjw.step(m, d)\n    return d\n\n\ndef first_difference(d1, d2, fields=("qpos", "qvel", "qacc")):\n    """(field, world) of the first bitwise difference, or None."""\n    for name in fields:\n        a, b = getattr(d1, name).numpy(), getattr(d2, name).numpy()\n        ua = a.reshape(a.shape[0], -1).view(f"u{a.itemsize}")\n        ub = b.reshape(b.shape[0], -1).view(f"u{b.itemsize}")\n        bad = np.flatnonzero((ua != ub).any(axis=1))\n        if bad.size:\n            return name, int(bad[0])\n    return None\n\n\nassert first_difference(run(), run()) is None\nassert first_difference(run(), run(nudge=1e-5)) == ("qpos", 2)\nprint("Exercise 22.1 passed")'
EX2_STUB = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nTWO_BOXES = """\n<mujoco><option timestep="0.005"/><worldbody>\n  <geom type="plane" size="5 5 .1"/>\n  <body pos="0 0 0.3" euler="10 20 0"><freejoint/><geom type="box" size=".1 .1 .1"/></body>\n  <body pos="0.05 0 0.6" euler="0 15 30"><freejoint/><geom type="box" size=".1 .1 .1"/></body>\n</worldbody></mujoco>"""\nwith wp.ScopedDevice("cpu"):  # the exact-replay claim is a CPU claim\n    mjm = mujoco.MjModel.from_xml_string(TWO_BOXES)\n    m = mjw.put_model(mjm)\n    d = mjw.make_data(mjm, nworld=4, nconmax=16, njmax=64)\n    for _ in range(150):\n        mjw.step(m, d)\n    S = mjw.State\n\n    def replay_is_exact(sig, nstep=30):\n        ...  # your code: get_state, step, set_state, step, compare\n\n    assert replay_is_exact(S.PHYSICS | S.WARMSTART)\n    assert not replay_is_exact(S.QPOS | S.QVEL)\n    print("Exercise 22.2 passed")'
EX2_SOL = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nTWO_BOXES = """\n<mujoco><option timestep="0.005"/><worldbody>\n  <geom type="plane" size="5 5 .1"/>\n  <body pos="0 0 0.3" euler="10 20 0"><freejoint/><geom type="box" size=".1 .1 .1"/></body>\n  <body pos="0.05 0 0.6" euler="0 15 30"><freejoint/><geom type="box" size=".1 .1 .1"/></body>\n</worldbody></mujoco>"""\nwith wp.ScopedDevice("cpu"):  # the exact-replay claim is a CPU claim\n    mjm = mujoco.MjModel.from_xml_string(TWO_BOXES)\n    m = mjw.put_model(mjm)\n    d = mjw.make_data(mjm, nworld=4, nconmax=16, njmax=64)\n    for _ in range(150):\n        mjw.step(m, d)\n    S = mjw.State\n\n    def replay_is_exact(sig, nstep=30):\n        """Snapshot with `sig`, run nstep (reference), restore, rerun; True if qpos is bitwise equal."""\n        size = mujoco.mj_stateSize(mjm, int(sig))\n        buf = wp.zeros((d.nworld, size), dtype=float)\n        mjw.get_state(m, d, buf, int(sig))\n        for _ in range(nstep):\n            mjw.step(m, d)\n        ref = d.qpos.numpy().copy()\n        mjw.set_state(m, d, buf, int(sig))\n        for _ in range(nstep):\n            mjw.step(m, d)\n        return d.qpos.numpy().tobytes() == ref.tobytes()\n\n    assert replay_is_exact(S.PHYSICS | S.WARMSTART)\n    assert not replay_is_exact(S.QPOS | S.QVEL)\n    print("Exercise 22.2 passed")'
EX3_STUB = 'import numpy as np\n\nrng = np.random.default_rng(0)\nn = 40\nworldid = rng.integers(0, 4, n)\ngeom = np.sort(rng.integers(0, 6, (n, 2)), axis=1)\npos = rng.random((n, 3)).astype(np.float32)\nperm = rng.permutation(n)                          # "run B": same contacts, other slots\nb = {"worldid": worldid[perm], "geom": geom[perm], "pos": pos[perm]}\na = {"worldid": worldid, "geom": geom, "pos": pos}\n\n\ndef canonical(c):\n    ...  # your code: return an index array\n\n\nassert not np.array_equal(a["geom"], b["geom"])\npa, pb = canonical(a), canonical(b)\nfor k in a:\n    assert np.array_equal(a[k][pa], b[k][pb]), k\nassert np.all(np.diff(a["worldid"][pa]) >= 0)\nprint("Exercise 22.3 passed")'
EX3_SOL = 'import numpy as np\n\nrng = np.random.default_rng(0)\nn = 40\nworldid = rng.integers(0, 4, n)\ngeom = np.sort(rng.integers(0, 6, (n, 2)), axis=1)\npos = rng.random((n, 3)).astype(np.float32)\nperm = rng.permutation(n)                          # "run B": same contacts, other slots\nb = {"worldid": worldid[perm], "geom": geom[perm], "pos": pos[perm]}\na = {"worldid": worldid, "geom": geom, "pos": pos}\n\n\ndef canonical(c):\n    p = c["pos"]\n    return np.lexsort((p[:, 2], p[:, 1], p[:, 0], c["geom"][:, 1], c["geom"][:, 0], c["worldid"]))\n\n\nassert not np.array_equal(a["geom"], b["geom"])\npa, pb = canonical(a), canonical(b)\nfor k in a:\n    assert np.array_equal(a[k][pa], b[k][pb]), k\nassert np.all(np.diff(a["worldid"][pa]) >= 0)\nprint("Exercise 22.3 passed")'

RESULTS_TABLE = """# Results table: what this runtime measured (filled by the record cells after each example),
# next to what to expect on a GPU. On a CPU every run is bitwise identical, so the measured
# column says "same" almost everywhere; run on a GPU to see the real effects.
rows = [
    ("ex1", "Float atomics change low bits between runs (NONE)?", "GPU: often; CPU: never"),
    ("ex2", "Raw contact slot order repeats?", "GPU: usually not; CPU: yes"),
    ("ex4", "Contact-free models bitwise under ATOMICS?", "PENDULUM: yes; HUMANOID: usually (limit rows racy)"),
    ("ex5", "box_stack(5) bitwise under ALL?", "not promised in 4.0.1 (sorts are stubs)"),
    ("ex6", "Replayed run bitwise equal to run A?", "yes, under ATOMICS"),
    ("ex7", "compare_runs finds the nudged world?", "yes: qpos, world 3"),
    ("ex8", "PHYSICS|WARMSTART restore exact (ATOMICS)?", "CPU: yes; GPU: up to contact-order noise"),
    ("ex9", "ALL costs more than ATOMICS?", "no: ALL = ATOMICS in 4.0.1"),
]
print("device:", wp.get_device())
print(f"{'question':<52} {'measured here':<60} expected")
for key, q, expected in rows:
    print(f"{q:<52} {RESULTS.get(key, '(cell not run)'):<60} {expected}")
"""

CELLS = [
    ["md", "Every code cell below is the same file as the matching block on the chapter page "
           "(`examples/22-determinism-and-reproducibility/`). Budgets grow on a GPU (`ON_GPU`) and stay "
           "small on a CPU. **This chapter is about GPU behaviour**: on Warp's CPU device threads run one "
           "after another in index order, so every CPU run is bitwise identical and several examples print "
           "trivially equal results there. Run this notebook on a GPU runtime to see the real effects. "
           "Timings printed here are your numbers; CPU numbers are never GPU numbers.\n\n"
           "The examples run in the same order as on the chapter page (Examples 22.1 to 22.9)."],
    ["code", "RESULTS = {}   # measured values, filled after each example and printed in the results table"],
    ["md", "## 1. Float atomics and slot counters\nFloat addition is not associative, so a sum whose terms "
           "arrive in a different order can differ in the last bits. A counter atomic "
           "(`slot = wp.atomic_add(counter, 0, 1)`) hands out slots in arrival order. Warp's "
           "`wp.DeterministicMode.RUN_TO_RUN` module option records the contributions and sorts them "
           "before reducing; MJWarp's kernel factories set it (plus `deterministic_max_records`) when "
           "ATOMICS is on. Part 2 emulates GPU arrival order in NumPy, so it shows the effect on CPU too."],
    ["example", "ex1_atomic_order.py", "22.1"],
    ["code", "# record the measured result for the results table\n" + 'k_plain, t = make_sum_kernel(False), []\nfor _ in range(2):\n    tot = wp.zeros(1, dtype=float)\n    wp.launch(k_plain, dim=N, inputs=[x], outputs=[tot])\n    t.append(hexf(tot.numpy()[0]))\nRESULTS["ex1"] = (("bits differ" if t[0] != t[1] else "same bits") + " in 2 NONE runs"\n                  f"; emulated: {len(racy)} distinct sums")'],
    ["md", "## 2. Contact slot order\nEvery contact takes the next free slot of the shared pool through "
           "`wp.atomic_add(nacon_out, 0, 1)` in `collision_core.write_contact`. Compare two runs in raw "
           "slot order and in a canonical order (sorted by world, geom pair and position). On a GPU the raw "
           "order usually differs while the sorted contacts match."],
    ["example", "ex2_contact_order.py", "22.2"],
    ["code", "# record the measured result for the results table\n" + 'RESULTS["ex2"] = f"raw order same: {same_raw}; sorted same: {same_sorted}"'],
    ["md", "## 3. The deterministic setter\n`m.opt.deterministic` is a `mjw.DeterminismType` bitmask: "
           "CONTACTS = 1, CONSTRAINT = 2, ATOMICS = 4, ALL = 7. `True`/`False`/`None` map to ALL/NONE, a "
           "complement such as `~DeterminismType.CONTACTS` is masked to the valid bits, and values outside "
           "ALL raise `ValueError`. `override_model` parses the same option from strings.\n\n"
           "In 4.0.1 **only ATOMICS has an effect**: `collision_driver._sort_contacts` and "
           "`constraint._sort_constraints` are `pass` stubs, so ALL behaves exactly like ATOMICS."],
    ["example", "ex3_deterministic_setter.py", "22.3"],
    ["md", "## 4. Bitwise reproducibility without contacts\nWith `DisableBit.CONTACT` there is no slot order "
           "and no contact rows. ATOMICS then makes the result bitwise only when each world has at most one "
           "active limit, friction-loss or equality row, as in the PENDULUM: those rows are still reserved "
           "in racy order. The HUMANOID hits its joint limits, so its ATOMICS line is usually, but not "
           "necessarily, True. `determinism_test.py` observes equality on 2 worlds x 3 steps; that is an "
           "observation, not a guarantee. Look at the NONE rows on a GPU: they may differ."],
    ["example", "ex4_bitwise_contact_free.py", "22.4"],
    ["code", "# record the measured result for the results table\n" + 'RESULTS["ex4"] = "; ".join(f"{n.split()[0]} {md}: {v}" for (n, md), v in equal.items() if md == "ATOMICS")'],
    ["md", "## 5. Contact scenes and the chaos amplifier\nA toppling `box_stack(5)` under NONE, ATOMICS and "
           "ALL. The example prints the differences and does not assert 0: in 4.0.1 contact scenes are not "
           "promised to be bitwise reproducible on a GPU. Part 2 starts run B one float32 ulp away and shows "
           "how quickly a contact-rich, chaotic scene amplifies that difference to tens of centimetres."],
    ["example", "ex5_contact_scene_differences.py", "22.5"],
    ["code", "# record the measured result for the results table\n" + 'RESULTS["ex5"] = (f"ALL max |dqpos| A vs B = {np.abs(qa - qb).max():.3g}; "\n                  f"1-ulp nudge -> {dq[-1].max():.2g} m")'],
    ["md", "## 6. The replay test\nThe test suite's `_Replay` records the outputs of `collision` and "
           "`make_constraint` in run A and, in run B, checks inputs bitwise and outputs up to order, then "
           "overwrites B's outputs with A's. Downstream stages can then be compared bitwise under ATOMICS. "
           "On CPU we inject the GPU's behaviour with a contact shuffler (private API, `unittest.mock`)."],
    ["example", "ex6_replay_test.py", "22.6"],
    ["code", "# record the measured result for the results table\n" + 'RESULTS["ex6"] = f"run C bitwise equal: {same} ({rep.checked} stage checks)"'],
    ["md", "## 7. A reusable bitwise comparator\n`compare_runs(d1, d2, fields)` compares bit patterns, not "
           "values, and reports the first differing field, world and element in hex. The exercises use the "
           "same idea."],
    ["example", "ex7_compare_runs.py", "22.7"],
    ["code", "# record the measured result for the results table\n" + 'RESULTS["ex7"] = f"first: {diff[\'field\']}, world {diff[\'world\']}" if diff else "no difference"'],
    ["md", "## 8. Bitwise restarts need the warmstart\nSnapshot at step 100 with `mjw.get_state`, run 100 "
           "steps, restore with `mjw.set_state`, rerun. `QPOS|QVEL` and `PHYSICS` leave "
           "`d.qacc_warmstart` at the end-of-reference value, so the solver starts elsewhere and the replay "
           "is off in the low bits. `PHYSICS | WARMSTART` is exact on CPU. Always allocate the buffer with "
           "`mujoco.mj_stateSize` (get_state does not check its size)."],
    ["example", "ex8_snapshot_replay.py", "22.8"],
    ["code", "# record the measured result for the results table\n" + 'r8 = next(r for r in rows if r["mode"] == "ATOMICS" and r["sig"] == "PHYSICS|WARMSTART")\nRESULTS["ex8"] = f"bitwise: {r8[\'exact\']}, max |dqpos| = {r8[\'dq\']:.3g}"'],
    ["md", "## 9. What determinism costs\nSteps/s for NONE, ATOMICS and ALL, plus the number of kernel "
           "launches per step that run in RUN_TO_RUN mode. On a GPU, RUN_TO_RUN kernels record and sort "
           "their atomic contributions, so expect them to be slower; on CPU the deterministic path is "
           "compiled out and timings differ by noise. On Colab you can also run "
           "`mjwarp-testspeed <xml> -o \"opt.deterministic=ATOMICS\"`."],
    ["example", "ex9_determinism_cost.py", "22.9"],
    ["code", "# record the measured result for the results table\n" + 'RESULTS["ex9"] = "; ".join(f"{n.split()[0].rstrip(\',\')} ALL/ATOMICS = {rates[n, \'ALL\'] / rates[n, \'ATOMICS\']:.2f}"\n                           for n in dict.fromkeys(k[0] for k in rates))'],
    ["md", "## Results table\nWhat this runtime measured in the examples above, next to what to expect on a GPU."],
    ["code", RESULTS_TABLE],
    ["md", "## Exercise 22.1: find the first bitwise difference\nWrite `first_difference(d1, d2, fields)` "
           "that returns `(field, world)` of the first bitwise difference, or `None`. View the arrays as "
           "unsigned integers of the same width."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 22.1"],
    ["md", "## Exercise 22.2: which snapshot replays exactly?\nTwo boxes have landed (contacts and "
           "warmstart active). Assert that `PHYSICS | WARMSTART` reproduces the run exactly on CPU while "
           "`QPOS | QVEL` does not. The cell runs on CPU (`wp.ScopedDevice(\"cpu\")`); on a GPU, try it "
           "without the scope as a stretch."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 22.2"],
    ["md", "## Exercise 22.3: canonical contact order\nRun B holds the same contacts as run A in a shuffled "
           "order. Write the permutation that sorts contacts by `(worldid, geom0, geom1, pos.x, pos.y, "
           "pos.z)`. Pure NumPy."],
    ["code", EX3_STUB],
    ["solution", EX3_SOL, "Exercise 22.3"],
    ["md", "## Stretch: extend the replay test to sensors\nAdd a `touch` sensor on the top box, a "
           "`framepos` of the top box and a `contact` sensor between box 3 and box 4 to the `box_stack` of "
           "Example 22.6. Extend `PHYSICS` with `sensordata` and check: (a) with replay, all sensors are "
           "bitwise equal to run A; (b) in the shuffled run without replay, which sensors differ first, and "
           "by how much? (c) Why does the test suite exclude contact sensors from its NONE-vs-ATOMICS "
           "tolerance check? On a GPU, run the test without the shuffler and compare."],
    ["code", "# your sensor replay test here\n"],
]
