# Notebook spec for Ch 23. Build with:
#   python3 tools/make_notebook.py notebooks/specs/23-soft-bodies-flex-discrete-integrator.py
SLUG = "23-soft-bodies-flex-discrete-integrator"
TITLE = "Ch 23 · Soft Bodies: Flex, Cloth, Rods and the Discrete Integrator"

CELLS = [
 [
  "md",
  "Every code cell below is the same file as the matching block on the chapter page (`examples/23-soft-bodies-flex-discrete-integrator/`). Budgets grow on a GPU (`ON_GPU`) and stay small on a CPU. All outputs on the page are CPU outputs; timings printed here are **your** numbers, and CPU numbers are never GPU numbers. The examples run in the page's order, which is not their number order: 23.1, 23.2, 23.2b, 23.3, 23.8 (section 5), 23.4, 23.7 (section 6), 23.6 (section 7), 23.5 (section 8), 23.9."
 ],
 [
  "writefile",
  "my_env.py",
  "examples/14-sensors-delays-inverse-dynamics/my_env_step14.py"
 ],
 [
  "md",
  "## 1. What a flex is\nA flex is vertices (one body with 3 slide joints each, unless pinned), edges and simplex elements (`dim` 1, 2, 3). `smooth.flex` fills `d.flexvert_xpos`, `d.flexedge_length` and `d.flexedge_J` per world. Example 23.1 loads the shipped `rope.xml`."
 ],
 [
  "example",
  "ex1_rope.py",
  "23.1"
 ],
 [
  "md",
  "Example 23.2 reads the flex fields and the strain per edge. **Pitfall:** for `dim=2` you must set `elastic2d=\"stretch\"`, `\"bend\"` or `\"both\"`; the default `\"none\"` gives no forces. The C compiler may print a WARNING about 'no equality constraints or passive forces' on stderr for this model; the membrane forces are applied anyway."
 ],
 [
  "example",
  "ex2_flex_fields.py",
  "23.2"
 ],
 [
  "md",
  "## 2-3. Elasticity and rods\nEdge-based stretch (`_flex_elasticity`), bending (`_flex_bending`), stable Neo-Hookean (DISCRETE only, MjSpec `elastic3d = 1`), plasticity (return mapping in `_advance`) and discrete elastic rods (`eval_rod_chains`, `rod_parallel_transport`). A `dim=1` flex with `<elasticity>` becomes a rod with bending and twist; it still needs an edge equality to keep its length, and a cantilever needs two pinned vertices."
 ],
 [
  "example",
  "ex2b_elastic_rod.py",
  "23.2b"
 ],
 [
  "md",
  "## 5. Flex collision\n`flex_collision` runs after the rigid narrowphase: flex AABBs, plane-vertex and element-geom candidates, de-duplication, then pool slots. Example 23.3 drops a cloth on a sphere and sizes the buffers."
 ],
 [
  "example",
  "ex3_cloth_drop.py",
  "23.3"
 ],
 [
  "code",
  "import my_env                      # the running-project helper (Ch 9 describe_overflow)\nprint(my_env.describe_overflow(d))"
 ],
 [
  "code",
  "# Plot the cloth of Example 23.3 (world 0) after 300 steps, over the sphere.\nxyz = d.flexvert_xpos.numpy()[0]\nprint(\"cloth vertices z range:\", xyz[:, 2].min().round(4), \"to\", xyz[:, 2].max().round(4))\ntry:\n    import matplotlib.pyplot as plt\n    fig = plt.figure(figsize=(5, 4))\n    ax = fig.add_subplot(projection=\"3d\")\n    elem = mjm.flex_elem[: 3 * mjm.nflexelem].reshape(-1, 3)\n    ax.plot_trisurf(xyz[:, 0], xyz[:, 1], xyz[:, 2], triangles=elem, alpha=0.8)\n    u, v = np.mgrid[0:2 * np.pi:20j, 0:np.pi:10j]\n    ax.plot_wireframe(0.1 * np.cos(u) * np.sin(v), 0.1 * np.sin(u) * np.sin(v),\n                      0.2 + 0.1 * np.cos(v), color=\"orange\", linewidth=0.5)\n    ax.set_box_aspect((1, 1, 0.7)); ax.set_title(\"Example 23.3: cloth on sphere\")\n    plt.show()\nexcept ImportError:\n    print(\"skipped: matplotlib not installed\")\n"
 ],
 [
  "md",
  "Flex contacts in the shared pool. Classify a contact side as flex by `contact.geom == -1`: in 4.0.1 rigid colliders do not reset `contact.flex/elem/vert`, so rigid contacts can carry stale flex ids."
 ],
 [
  "example",
  "ex8_flex_contacts.py",
  "23.8"
 ],
 [
  "md",
  "A volumetric flex: the shipped Floppy block (1242 tetrahedra, nv 1153) under Euler."
 ],
 [
  "example",
  "ex4_floppy_volumetric.py",
  "23.4"
 ],
 [
  "md",
  "## 6. Flex equalities\nFLEX: one row per edge. FLEXSTRAIN: one row per stored deformation eigenmode of each interpolated cell (18 for one trilinear cell)."
 ],
 [
  "example",
  "ex7_flexstrain.py",
  "23.7"
 ],
 [
  "md",
  "## 7. The DISCRETE integrator\n`(M + hD + h^2 K) a = f - hKv`: `eff_build` -> `eff_shift` -> `eff_actuation` + `regularize_constraint` -> `eff_solve` (PCG, `capture_while` on GPU) -> the constraint solve in the same metric. Example 23.6: a stiff cloth that Euler cannot step."
 ],
 [
  "example",
  "ex6_discrete_integrator.py",
  "23.6"
 ],
 [
  "md",
  "## 8. What 4.0.1 refuses\nEvery unsupported flex combination, with the exception and message."
 ],
 [
  "example",
  "ex5_unsupported_combos.py",
  "23.5"
 ],
 [
  "md",
  "## 9. Rendering a cloth frame\nThe Ch 27 batch renderer puts a 2-D flex into its own BVH and offsets the faces by +-radius (`refit_flex_bvh`, `flex_render_smooth`). This works on CPU at a tiny resolution and is fast on a GPU."
 ],
 [
  "code",
  "# Batch-render one cloth frame (Ch 27 renderer; runs on CPU at a small resolution, fast on GPU)\nimport mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nON_GPU = wp.get_device().is_cuda\nRES = 256 if ON_GPU else 48\nSCENE = \"\"\"<mujoco><option timestep=\"0.002\" solver=\"CG\" tolerance=\"1e-6\"/><worldbody>\n  <light pos=\"0 0 3\" dir=\"0 0 -1\" directional=\"true\"/>\n  <camera name=\"cam\" pos=\"0 -0.9 0.6\" xyaxes=\"1 0 0 0 0.55 0.83\"/>\n  <geom type=\"plane\" size=\"2 2 .1\" rgba=\".85 .85 .85 1\"/>\n  <geom name=\"ball\" type=\"sphere\" size=\".1\" pos=\"0 0 .2\" rgba=\"1 .5 .1 1\"/>\n  <flexcomp name=\"cloth\" type=\"grid\" count=\"6 6 1\" spacing=\".06 .06 .06\" pos=\"0 0 .35\"\n            radius=\".01\" dim=\"2\" mass=\".1\" rgba=\".2 .5 .9 1\">\n    <edge equality=\"true\"/><contact condim=\"3\" selfcollide=\"none\"/>\n  </flexcomp></worldbody></mujoco>\"\"\"\nmjm = mujoco.MjModel.from_xml_string(SCENE)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=1, nconmax=64, njmax=384)\nfor _ in range(150):\n    mjw.step(m, d)\nrc = mjw.create_render_context(mjm, nworld=1, cam_res=(RES, RES), render_rgb=True,\n                               render_depth=False, render_seg=True, flex_render_smooth=True)\nmjw.refit_bvh(m, d, rc)\nmjw.render(m, d, rc)\nseg = rc.seg_data.numpy()[0]\nprint(\"pixels showing the flex (objtype 9 = mjOBJ_FLEX):\", int((seg[:, 1] == 9).sum()), \"of\", RES * RES)\nrgb = wp.zeros((1, RES, RES), dtype=wp.vec3)\nmjw.get_rgb(rc, 0, rgb)\ntry:\n    import matplotlib\n    import matplotlib.pyplot as plt\n    plt.imshow(np.clip(rgb.numpy()[0], 0, 1)); plt.axis(\"off\"); plt.title(\"cloth after 0.3 s\")\n    plt.show()\nexcept ImportError:\n    print(\"skipped: matplotlib not installed\")\n"
 ],
 [
  "md",
  "## 10. Part V checkpoint: cloth on a box stack under a throughput budget\nSize the buffers (the flex candidate buffer needs room too), then sweep integrator x solver x cone and pick the fastest config with no overflow bit (ITERATIONS included)."
 ],
 [
  "example",
  "ex9_checkpoint_cloth_stack.py",
  "23.9"
 ],
 [
  "md",
  "## Part V review\nAnswer for yourself, then check against the chapter page (the quiz there gives instant feedback).\n1. In which order does `make_constraint` write row blocks? *(equality, friction, limit, contact; flex rows are in the equality block)*\n2. What minimizes the per-world Gauss cost in MJWarp? *(CG or Newton with an exact linesearch; no PGS)*\n3. Which solver does sleep require? *(Newton; flex equalities are refused with sleep)*\n4. Which `DeterminismType` bit changes kernels in 4.0.1? *(ATOMICS; the CONTACTS and CONSTRAINT sorts are stubs)*\n5. How does DISCRETE change a row's `D`? *(divided by (sum J^2/qH)/(sum J^2/M) in `regularize_constraint`)*\n6. A cloth model with an hfield floor fails at `put_model`. Fix? *(replace the hfield by a plane, boxes or meshes)*\n"
 ],
 [
  "md",
  "## Exercise 23.1: build a rope and check its sizes\nWrite the MJCF and the DOF count."
 ],
 [
  "code",
  "import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nN = 10\nROPE = ...  # your MJCF: <body name=\"anchor\" ...><flexcomp ... dim=\"1\">...</flexcomp></body>\nmjm = mujoco.MjModel.from_xml_string(ROPE)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=2)\nfor _ in range(50):\n    mjw.step(m, d)\nassert mjm.nflexvert == N and mjm.nflexedge == N - 1\nassert mjm.nv == ...            # how many DOFs?\nassert d.flexvert_xpos.shape == (2, N)\nassert np.abs(d.flexedge_length.numpy() - m.flexedge_length0.numpy()).max() < 1e-3\nprint(\"Exercise 23.1 passed\")\n"
 ],
 [
  "solution",
  "import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nN = 10\nROPE = f\"\"\"<mujoco><option timestep=\"0.001\" solver=\"CG\"/><worldbody>\n  <body name=\"anchor\" pos=\"0 0 1\">\n    <flexcomp name=\"rope\" type=\"grid\" count=\"{N} 1 1\" spacing=\".05 .05 .05\" radius=\".01\"\n              dim=\"1\" mass=\".1\">\n      <edge equality=\"true\"/><contact contype=\"0\" conaffinity=\"0\"/><pin id=\"0\"/>\n    </flexcomp>\n  </body></worldbody></mujoco>\"\"\"\nmjm = mujoco.MjModel.from_xml_string(ROPE)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=2)\nfor _ in range(50):\n    mjw.step(m, d)\nassert mjm.nflexvert == N and mjm.nflexedge == N - 1\nassert mjm.nv == 3 * (N - 1)    # the pinned vertex has no DOFs\nassert d.flexvert_xpos.shape == (2, N)\nassert np.abs(d.flexedge_length.numpy() - m.flexedge_length0.numpy()).max() < 1e-3\nprint(\"Exercise 23.1 passed\")\n",
  "Exercise 23.1"
 ],
 [
  "md",
  "## Exercise 23.2: the cloth must not sink into the sphere"
 ],
 [
  "code",
  "import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nCENTRE, R, RADIUS, TOL = np.array([0, 0, 0.2]), 0.1, 0.01, 0.005\nSCENE = \"\"\"<mujoco><option timestep=\"0.002\" solver=\"CG\" tolerance=\"1e-6\"/><worldbody>\n  <geom type=\"plane\" size=\"2 2 .1\"/>\n  <geom name=\"ball\" type=\"sphere\" size=\".1\" pos=\"0 0 .2\"/>\n  <flexcomp name=\"cloth\" type=\"grid\" count=\"6 6 1\" spacing=\".06 .06 .06\" pos=\"0 0 .35\"\n            radius=\".01\" dim=\"2\" mass=\".1\">\n    <edge equality=\"true\"/><contact condim=\"3\" selfcollide=\"none\"/>\n  </flexcomp></worldbody></mujoco>\"\"\"\nmjm = mujoco.MjModel.from_xml_string(SCENE)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=2, nconmax=64, njmax=384)\nfor _ in range(300):\n    mjw.step(m, d)\nxyz = d.flexvert_xpos.numpy()                         # (nworld, nflexvert, 3)\ndist = ...                                            # distance of every vertex to CENTRE\nassert dist.min() >= R + RADIUS - TOL\nassert ...                                            # top vertex per world >= 0.3 - TOL\nassert not d.overflow.numpy().any()\nprint(\"Exercise 23.2 passed\")\n"
 ],
 [
  "solution",
  "import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nCENTRE, R, RADIUS, TOL = np.array([0, 0, 0.2]), 0.1, 0.01, 0.005\nSCENE = \"\"\"<mujoco><option timestep=\"0.002\" solver=\"CG\" tolerance=\"1e-6\"/><worldbody>\n  <geom type=\"plane\" size=\"2 2 .1\"/>\n  <geom name=\"ball\" type=\"sphere\" size=\".1\" pos=\"0 0 .2\"/>\n  <flexcomp name=\"cloth\" type=\"grid\" count=\"6 6 1\" spacing=\".06 .06 .06\" pos=\"0 0 .35\"\n            radius=\".01\" dim=\"2\" mass=\".1\">\n    <edge equality=\"true\"/><contact condim=\"3\" selfcollide=\"none\"/>\n  </flexcomp></worldbody></mujoco>\"\"\"\nmjm = mujoco.MjModel.from_xml_string(SCENE)\nm = mjw.put_model(mjm)\nd = mjw.make_data(mjm, nworld=2, nconmax=64, njmax=384)\nfor _ in range(300):\n    mjw.step(m, d)\nxyz = d.flexvert_xpos.numpy()                         # (nworld, nflexvert, 3)\ndist = np.linalg.norm(xyz - CENTRE, axis=-1)\nassert dist.min() >= R + RADIUS - TOL, dist.min()     # no vertex sinks into the sphere\nassert xyz[:, :, 2].max(axis=1).min() >= 0.3 - TOL    # the cloth still rests on the sphere top\nassert not d.overflow.numpy().any()\nprint(\"Exercise 23.2 passed\", round(float(dist.min()), 4))\n",
  "Exercise 23.2"
 ],
 [
  "md",
  "## Stretch: cloth with and without self-collision\nDrop a 12x12 cloth (spacing 0.04) on the sphere with `selfcollide=\"none\"` and `\"auto\"`. Count self-contacts (both `geom` entries -1 and `flex[0] == flex[1]`), compare peak `nacon`, overflow bits (raise `nconmax`), and time per step. Record the extra kernels of one `mjw.collision` call as in Example 23.8. On a GPU, scale `nworld` from 1 to 4096."
 ],
 [
  "code",
  "# your self-collision experiment here\n"
 ]
]
