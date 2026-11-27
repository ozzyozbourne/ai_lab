# Notebook spec for Ch 6. Build with:
#   python3 tools/make_notebook.py notebooks/specs/06-batched-data-layout.py
SLUG = "06-batched-data-layout"
TITLE = "Ch 06 · Many Worlds: The Batched Data Layout"

PENDULUM = '''PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""
'''

BALL_WIND = '''BALL_WIND = """
<mujoco model="ball_wind">
  <option timestep="0.002" density="1.2"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1"/></body>
  </worldbody>
</mujoco>
"""
'''

CELLS = [
    ["md", "Every code cell below is the same file as the matching block on the chapter page "
           "(`examples/06-batched-data-layout/`). On a GPU the budgets grow automatically "
           "(`ON_GPU`); on a CPU they stay small. Timings printed here are **your** numbers."],
    ["md", "Sections below follow the chapter page: each heading names the page section (§N), and the "
           "examples appear in the same order and with the same numbers as on the page (file names keep their exNN prefix)."],
    ["md", "## §1. The nworld-first rule\nEvery `mjw.Data` array starts with `nworld`. Vector dtypes "
           "(`vec3`, `quat`, `mat33`, `spatial_vector`) add trailing dimensions only in the NumPy view (page §2)."],
    ["example", "ex01_shape_table.py", "6.1"],
    ["md", "## §3. From shape to bytes\nRow-major layout: `offset = ((w * nbody + b) * 3 + k) * 4`. "
           "A `dim=(nworld, nbody)` launch numbers threads in the same order, so a warp reads "
           "contiguous bytes."],
    ["example", "ex08_addresses.py", "6.2"],
    ["md", "## §4. Writing per-world inputs in place\nBuild a full `(nworld, ...)` array and copy it "
           "*into* the device array with `.assign`. Then `forward` updates kinematics for all worlds."],
    ["example", "ex03_per_world_qpos.py", "6.3"],
    ["md", "`d.ctrl` is `(nworld, nu)`: one control per world, set once, applied every step."],
    ["example", "ex04_per_world_ctrl.py", "6.4"],
    ["md", "`fill_`, `zero_`, `wp.copy`, row views, and the trap: `assign`/`wp.copy` only refuse a "
           "source that is *larger* than the destination."],
    ["example", "ex05_fill_copy_zero.py", "6.5"],
    ["md", "## §5. Replace vs assign\n`d.qpos.assign(x)` keeps the array (and its device pointer); "
           "`d.qpos = wp.array(x)` creates a new one. Anything holding the old array (your variables, "
           "a captured CUDA graph in Ch 24) keeps using the old memory."],
    ["example", "ex06_replace_vs_assign.py", "6.6"],
    ["md", "## §6. Which Model fields can vary per world?\nA field can vary per world if and only if its "
           "spec in `types.py` starts with `\"*\"`: it then has a batch dimension B (default 1). "
           "Topology (types, tree, addresses) has no `\"*\"`; a few integer selectors such as "
           "`geom_dataid` do."],
    ["example", "ex02_model_batched.py", "6.7"],
    ["md", "## §7. Round robin, not blocks\nWorld `w` reads row `w % B` of a batched Model field."],
    ["example", "ex07_gravity_round_robin.py", "6.8"],
    ["md", "## §9. The spec strings, and the running project\nThe next cell writes `my_env.py` "
           "(the course's helper module, Ch 6 snapshot: `make_worlds`). Example 6.9 imports it and "
           "prints each field's docstring shape, declared spec and real shapes."],
    ["writefile", "my_env.py", "examples/06-batched-data-layout/my_env_step06.py"],
    ["example", "ex11_docstring_specs.py", "6.9"],
    ["md", "## §10. What `.numpy()` costs\nOn a GPU every `.numpy()` is an allocation, a copy **and a "
           "sync**, on top of the sync an eager `mjw.step` already does inside the solver "
           "(`wp.capture_while`). On Warp's CPU device it is a view of the live buffer, so the example "
           "adds `.copy()`. Compare reading every step with reading once (each variant runs once "
           "untimed, then the best of 3 alternating runs is kept). On the CPU the gap is within noise; "
           "on Colab the copy + sync makes it real."],
    ["example", "ex09_numpy_cost.py", "6.10"],
    ["md", "### §10 (cont.) Record on the device, read once, plot many worlds\nA small kernel writes "
           "one row of a `(nstep, nworld)` buffer per step; one `.numpy()` at the end. The first cell "
           "passes `--dump-png .` so the example saves its two PNGs in the notebook's folder; the cell after "
           "it shows them."],
    ["code", "import sys\n_argv = sys.argv\nsys.argv = [\"ex10_batched_plots.py\", \"--dump-png\", \".\"]   # read by argparse in the next cell"],
    ["example", "ex10_batched_plots.py", "6.11"],
    ["code", "from IPython.display import Image, display\nimport os\n"
             "sys.argv = _argv   # restore the kernel's own arguments\n"
             "for name in (\"ex10_small_multiples.png\", \"ex10_phase_portrait.png\"):\n"
             "    if os.path.exists(name):\n        display(Image(name))\n"
             "    else:\n        print(\"not found (matplotlib missing?):\", name)"],
    ["md", "## §11. When is the GPU faster? Throughput vs nworld\nOn Colab this runs nworld = 1, 16, "
           "256, 4096. Copy the JSON line printed by the cell after it into the "
           "chapter page's throughput widget to plot your own curve. Expect one world to be slower "
           "than C MuJoCo (about 95 kernel launches of several µs each against about 3 µs for a whole C "
           "step, plus a host sync at each solver loop check when stepping eagerly); the first row "
           "(nworld = 1) of the table is your check. Many worlds win."],
    ["example", "ex12_throughput_vs_nworld.py", "6.12"],
    ["code", "import json\n"
             "# the variables come from the Example 6.12 cell above (same format as --dump-json)\n"
             "rows_json = {\"device\": str(wp.get_device()), \"on_gpu\": ON_GPU, \"nstep\": NSTEP,\n"
             "             \"launches_per_step\": counts[\"n\"], \"c_rate\": round(c_rate, 1),\n"
             "             \"rows\": [{k: round(v, 4) for k, v in r.items()} for r in rows]}\n"
             "print(json.dumps(rows_json))   # paste this line into the page's throughput widget"],
    ["md", "## Exercise 6.1: predict six shapes\nFill in `pred` **before** running. The cell checks "
           "your answers against the real arrays."],
    ["code", PENDULUM + "\n"
             "pred = {\n"
             "    \"d.qpos\": (),            # Warp shape\n"
             "    \"d.xpos.numpy()\": (),    # NumPy view\n"
             "    \"d.sensordata\": (),\n"
             "    \"m.body_mass\": (),\n"
             "    \"m.geom_type\": (),\n"
             "    \"d.contact.pos\": (),     # default nconmax = 48 per world\n"
             "}\n"
             "mjm = mujoco.MjModel.from_xml_string(PENDULUM)\n"
             "m = mjw.put_model(mjm)\n"
             "d = mjw.make_data(mjm, nworld=32)\n"
             "actual = {\"d.qpos\": d.qpos.shape, \"d.xpos.numpy()\": d.xpos.numpy().shape,\n"
             "          \"d.sensordata\": d.sensordata.shape, \"m.body_mass\": m.body_mass.shape,\n"
             "          \"m.geom_type\": m.geom_type.shape, \"d.contact.pos\": d.contact.pos.shape}\n"
             "wrong = [k for k in pred if pred[k] != actual[k]]\n"
             "for k in wrong:\n"
             "    print(f\"{k}: you said {pred[k]}, it is {actual[k]}\")\n"
             "assert not wrong, f\"{len(wrong)} of 6 shapes wrong\"\n"
             "print(\"all six shapes correct\")"],
    ["solution", "pred = {\"d.qpos\": (32, 2), \"d.xpos.numpy()\": (32, 3, 3), \"d.sensordata\": (32, 5),\n"
                 "        \"m.body_mass\": (1, 3), \"m.geom_type\": (2,), \"d.contact.pos\": (1536,)}\n"
                 "# sensordata: jointpos 1 + jointvel 1 + framepos 3 = 5; contact pool: 48 * 32 = 1536\n"
                 "assert all(pred[k] == actual[k] for k in pred), actual\n"
                 "print(\"all six shapes correct\")",
     "Exercise 6.1"],
    ["md", "## Exercise 6.2: per-world wind\nGive 4 ball worlds the winds (+5,0,0), (-5,0,0), (0,+5,0), "
           "(0,0,0) m/s via `m.opt.wind`, step 100 times and assert each ball drifts with its wind. "
           "Note the `density` in the model: without it `put_model` sets `m.has_fluid = False` and "
           "the wind is never read."],
    ["code", BALL_WIND + "\n"
             "# your code: put_model, make_data(nworld=4, nconmax=4, njmax=16), set m.opt.wind,\n"
             "# step 100 times, then:\n"
             "# x = d.qpos.numpy()[:, :2]\n"
             "# assert x[0, 0] > 1e-3 and x[1, 0] < -1e-3 and x[2, 1] > 1e-3 and abs(x[3]).max() < 1e-6"],
    ["solution", "mjm = mujoco.MjModel.from_xml_string(BALL_WIND)\n"
                 "m = mjw.put_model(mjm)\n"
                 "d = mjw.make_data(mjm, nworld=4, nconmax=4, njmax=16)\n"
                 "wind = np.array([[5, 0, 0], [-5, 0, 0], [0, 5, 0], [0, 0, 0]], dtype=np.float32)\n"
                 "m.opt.wind = wp.array(wind, dtype=wp.vec3)   # B = 4 = nworld\n"
                 "for _ in range(100):\n"
                 "    mjw.step(m, d)\n"
                 "x = d.qpos.numpy()[:, :2]\n"
                 "assert x[0, 0] > 1e-3 and x[1, 0] < -1e-3 and x[2, 1] > 1e-3 and abs(x[3]).max() < 1e-6\n"
                 "print(\"drift per world:\", x)", "Exercise 6.2"],
    ["md", "## Stretch: seed per-world qpos in a kernel\nWrite a kernel launched with "
           "`dim=(d.nworld, m.nq)` that copies `qpos0` (with `worldid % qpos0.shape[0]`) and sets one "
           "address from `wp.rand_init(seed, worldid)` / `wp.randf`. Same seed, same result; time it "
           "against NumPy + `assign` for nworld = 4096."],
    ["code", "# your kernel here"],
    ["solution", "@wp.kernel\n"
                 "def seed_qpos(seed: int, qpos0: wp.array2d(dtype=float), adr: int, lo: float, hi: float,\n"
                 "              qpos: wp.array2d(dtype=float)):\n"
                 "    worldid, i = wp.tid()\n"
                 "    qpos[worldid, i] = qpos0[worldid % qpos0.shape[0], i]\n"
                 "    if i == adr:\n"
                 "        state = wp.rand_init(seed, worldid)\n"
                 "        qpos[worldid, i] = lo + (hi - lo) * wp.randf(state)\n\n"
                 "mjm = mujoco.MjModel.from_xml_string(PENDULUM)\n"
                 "m = mjw.put_model(mjm)\n"
                 "d = mjw.make_data(mjm, nworld=8)\n"
                 "wp.launch(seed_qpos, dim=(d.nworld, mjm.nq), inputs=[42, m.qpos0, 0, -1.0, 1.0], outputs=[d.qpos])\n"
                 "a = d.qpos.numpy().copy()\n"
                 "wp.launch(seed_qpos, dim=(d.nworld, mjm.nq), inputs=[42, m.qpos0, 0, -1.0, 1.0], outputs=[d.qpos])\n"
                 "assert np.array_equal(a, d.qpos.numpy())\n"
                 "print(a[:, 0])", "Stretch"],
]
