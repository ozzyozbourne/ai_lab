# Notebook spec for Chapter 2. Build with:
#   python3 tools/make_notebook.py notebooks/specs/02-mujoco-essentials.py
SLUG = "02-mujoco-essentials"
TITLE = "Ch 02 · MuJoCo Essentials for MJWarp Users"
# AUTO_HEADER is off so the EGL ICD cell can run before the standard setup cell (plan 0.4: rendering
# notebooks write the ICD file right after choosing MUJOCO_GL). Example 2.12 uses mujoco.Renderer.
AUTO_HEADER = False

COLAB = ("https://colab.research.google.com/github/ozzyozbourne/ai_lab/blob/main/"
         "dpdk-research/mujoco-warp-course/notebooks/02-mujoco-essentials.ipynb")

EGL_CELL = '''# Rendering notebooks only: let glvnd find the NVIDIA EGL driver (from the official
# mujoco_warp tutorial). Must run before mujoco is imported by the setup cell below.
import os
os.environ.setdefault("MUJOCO_GL", "egl")
NVIDIA_ICD_CONFIG_PATH = "/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
try:
    if not os.path.exists(NVIDIA_ICD_CONFIG_PATH):
        os.makedirs(os.path.dirname(NVIDIA_ICD_CONFIG_PATH), exist_ok=True)
        with open(NVIDIA_ICD_CONFIG_PATH, "w") as f:
            f.write('{"file_format_version": "1.0.0", '
                    '"ICD": {"library_path": "libEGL_nvidia.so.0"}}\\n')
    print("EGL ICD file:", NVIDIA_ICD_CONFIG_PATH, "| MUJOCO_GL =", os.environ["MUJOCO_GL"])
except OSError as e:
    print("could not write the EGL ICD file (fine outside Colab):", e)'''

CELLS = [
    ["md", f"# {TITLE}\n\n[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)]({COLAB})\n\n"
           "Companion notebook for the chapter page `chapters/02-mujoco-essentials.html` "
           "([page](../chapters/02-mujoco-essentials.html)). Pinned versions: "
           "mujoco-warp 4.0.1, warp-lang 1.19.0, mujoco-core 4.0.1.\n\n"
           "**Before you start:** Runtime > Change runtime type > select a GPU. Then run the cells top to bottom."],
    ["code", "# Check the GPU Colab gave you (this fails harmlessly on a CPU runtime).\n!nvidia-smi"],
    ["code", EGL_CELL],
    ["setup", {"render": True}],
    ["md", "## How to use this notebook\n"
           "Most of this chapter runs **C MuJoCo** (`mujoco.mj_step`, `mujoco.MjData`) on the CPU: it teaches the "
           "vocabulary that MJWarp keeps. Examples 2.1, 2.2, 2.9 and 2.12 also touch MJWarp (`mjw.put_model`, "
           "`mjw.make_data`, `mjw.step`, the batch renderer). Every cell is the same file as on the chapter page; "
           "run them top to bottom. Examples are numbered by file (`exN_*.py`) and appear in the order of the "
           "chapter's sections, where their topic is taught."],

    ["md", "## §2 MJCF anatomy and model sizes\n"
           "`PLAYGROUND` has a ball and a box on free joints and a hinged arm. Body 0 is the world, so `nbody` is 4. "
           "The MJWarp `Model` keeps the same size fields as plain Python ints."],
    ["example", "ex1_sizes.py", "2.1"],

    ["md", "## §3 Joints, coordinates and quaternions\n"
           "Free joints own 7 qpos / 6 qvel, ball 4 / 3, slide and hinge 1 / 1. `jnt_qposadr` and `jnt_dofadr` "
           "say where each joint's slice starts."],
    ["example", "ex2_joint_table.py", "2.2"],
    ["md", "MuJoCo quaternions are **(w, x, y, z)**; the identity is (1, 0, 0, 0). SciPy's `as_quat()` returns "
           "(x, y, z, w) by default: feeding it unchanged gives a different rotation and no error."],
    ["example", "ex6_quaternions.py", "2.6"],
    ["md", "Default classes set attributes once; joint limits are soft and add one constraint row when violated."],
    ["example", "ex8_limits_defaults.py", "2.8"],

    ["md", "## §4 Contacts are soft\n"
           "A resting ball sinks a fraction of a millimetre (`dist < 0`). `solref = (timeconst, dampratio)` is a "
           "spring-damper: smaller timeconst = stiffer, smaller dampratio = bouncier. Add `--dump-json PATH` to "
           "record the sweep used by the chapter's widget."],
    ["example", "ex7_contacts_soft.py", "2.7"],

    ["md", "## §5-§6 Equality constraints and mocap bodies\n"
           "A mocap target circles; a weld equality drags a free box after it; `eq_active[0] = 0` releases the box. "
           "The same schedule then runs in MJWarp with `d.mocap_pos` and `d.eq_active`."],
    ["example", "ex9_equality_mocap.py", "2.9"],

    ["md", "## §7 Actuators, controls and sensors\n"
           "`ctrl` drives the motor (clamped by `ctrlrange`); sensor `i` lives at "
           "`sensordata[sensor_adr[i] : sensor_adr[i] + sensor_dim[i]]`."],
    ["example", "ex5_ctrl_sensor.py", "2.5"],

    ["md", "## §9 The simulation loop\n"
           "`mj_step` = `mj_forward` + integrate. Record a trajectory, then reset with keyframes. On Colab, "
           "matplotlib is installed, so Example 2.3 also saves `ex3_trajectory.png`."],
    ["example", "ex3_trajectory.py", "2.3"],
    ["code", "# Show the saved plot (Colab has mediapy installed by the setup cell)\n"
             "import os\n"
             "if os.path.exists(\"ex3_trajectory.png\"):\n"
             "    import mediapy as media\n"
             "    media.show_image(media.read_image(\"ex3_trajectory.png\"))"],
    ["example", "ex4_keyframe.py", "2.4"],

    ["md", "## §10 Derived quantities and the mass matrix\n"
           "MuJoCo 4 stores the mass matrix in `mjd.M` (not `qM`); `mujoco.mj_fullM(m, d, dst)` expands it."],
    ["example", "ex11_mass_matrix.py", "2.11"],

    ["md", "## §11 Building models with MjSpec"],
    ["example", "ex10_mjspec.py", "2.10"],

    ["md", "## §12 Seeing a frame\n"
           "The EGL cell at the top sets `MUJOCO_GL=egl` and writes the NVIDIA EGL ICD file, which `mujoco.Renderer` "
           "needs on a Colab GPU runtime. If the renderer still cannot start, the example falls back to the MJWarp "
           "batch renderer and says so in its output."],
    ["example", "ex12_render.py", "2.12"],
    ["code", "import os\n"
             "if os.path.exists(\"ex12_frame.png\"):\n"
             "    import mediapy as media\n"
             "    media.show_image(media.read_image(\"ex12_frame.png\"))"],

    ["md", "## Exercise 2.1: count the coordinates\n"
           "Two free bodies and a chain of three hinges. Predict `nq` and `nv`. Fill in your answer, then uncomment the last two lines to check it."],
    ["code", "import mujoco\n\n"
             "XML = \"\"\"\n"
             "<mujoco>\n"
             "  <worldbody>\n"
             "    <body name=\"a\" pos=\"0 0 1\"><freejoint/><geom type=\"sphere\" size=\".1\"/></body>\n"
             "    <body name=\"b\" pos=\"1 0 1\"><freejoint/><geom type=\"box\" size=\".1 .1 .1\"/></body>\n"
             "    <body name=\"l1\" pos=\"2 0 2\">\n"
             "      <joint type=\"hinge\" axis=\"0 1 0\"/><geom type=\"capsule\" fromto=\"0 0 0 0 0 -.3\" size=\".02\"/>\n"
             "      <body name=\"l2\" pos=\"0 0 -.3\">\n"
             "        <joint type=\"hinge\" axis=\"0 1 0\"/><geom type=\"capsule\" fromto=\"0 0 0 0 0 -.3\" size=\".02\"/>\n"
             "        <body name=\"l3\" pos=\"0 0 -.3\">\n"
             "          <joint type=\"hinge\" axis=\"0 1 0\"/><geom type=\"capsule\" fromto=\"0 0 0 0 0 -.3\" size=\".02\"/>\n"
             "        </body>\n"
             "      </body>\n"
             "    </body>\n"
             "  </worldbody>\n"
             "</mujoco>\n"
             "\"\"\"\n"
             "nq_pred = ...  # your prediction\n"
             "nv_pred = ...\n"
             "mjm = mujoco.MjModel.from_xml_string(XML)\n"
             "# assert (mjm.nq, mjm.nv) == (nq_pred, nv_pred), (mjm.nq, mjm.nv)\n"
             "# print(\"Exercise 2.1 passed:\", mjm.nq, mjm.nv)"],
    ["solution", "nq_pred = 2 * 7 + 3 * 1   # 17\n"
                 "nv_pred = 2 * 6 + 3 * 1   # 15\n"
                 "mjm = mujoco.MjModel.from_xml_string(XML)\n"
                 "assert (mjm.nq, mjm.nv) == (nq_pred, nv_pred), (mjm.nq, mjm.nv)\n"
                 "print(\"Exercise 2.1 passed:\", mjm.nq, mjm.nv)", "Exercise 2.1"],

    ["md", "## Exercise 2.2: build your own model with MjSpec\n"
           "Two hinged links (shoulder, elbow), one motor on the shoulder, sensors producing exactly 3 numbers. "
           "No XML allowed. Fill in your answer, then uncomment the last three lines to check it."],
    ["code", "import mujoco\n\n"
             "spec = mujoco.MjSpec()\n"
             "# TODO: upper body + hinge \"shoulder\", lower body + hinge \"elbow\", a motor on \"shoulder\",\n"
             "#       sensors with 3 numbers in total\n"
             "# mjm = spec.compile()\n"
             "# assert mjm.nq == 2 and mjm.nu == 1 and mjm.nsensordata == 3, (mjm.nq, mjm.nu, mjm.nsensordata)\n"
             "# print(\"Exercise 2.2 passed\")"],
    ["solution", "import mujoco\n\n"
                 "spec = mujoco.MjSpec()\n"
                 "upper = spec.worldbody.add_body(name=\"upper\", pos=[0, 0, 1])\n"
                 "upper.add_joint(name=\"shoulder\", type=mujoco.mjtJoint.mjJNT_HINGE, axis=[0, 1, 0])\n"
                 "upper.add_geom(type=mujoco.mjtGeom.mjGEOM_CAPSULE, fromto=[0, 0, 0, 0.4, 0, 0], size=[0.03, 0, 0])\n"
                 "lower = upper.add_body(name=\"lower\", pos=[0.4, 0, 0])\n"
                 "lower.add_joint(name=\"elbow\", type=mujoco.mjtJoint.mjJNT_HINGE, axis=[0, 1, 0])\n"
                 "lower.add_geom(type=mujoco.mjtGeom.mjGEOM_CAPSULE, fromto=[0, 0, 0, 0.3, 0, 0], size=[0.03, 0, 0])\n"
                 "lower.add_site(name=\"tip\", pos=[0.3, 0, 0])\n"
                 "spec.add_actuator(name=\"motor\", target=\"shoulder\", trntype=mujoco.mjtTrn.mjTRN_JOINT)\n"
                 "spec.add_sensor(name=\"tip_pos\", type=mujoco.mjtSensor.mjSENS_FRAMEPOS,\n"
                 "                objtype=mujoco.mjtObj.mjOBJ_SITE, objname=\"tip\")\n"
                 "mjm = spec.compile()\n"
                 "assert mjm.nq == 2 and mjm.nu == 1 and mjm.nsensordata == 3\n"
                 "d = mujoco.MjData(mjm)\n"
                 "mujoco.mj_forward(mjm, d)\n"
                 "print(\"Exercise 2.2 passed; tip at\", d.sensordata)", "Exercise 2.2"],

    ["md", "## Stretch: close a four-bar linkage\n"
           "Crank hinged at (0, 0, 1), coupler hinged to the crank's end, rocker hinged at (0.5, 0, 1); close the loop "
           "with a `<connect>` equality. Spin the crank and measure the gap between the two ends; tighten `solref` "
           "and measure again. Bonus: build it with MjSpec and step it in MJWarp."],
    ["code", "# your four-bar linkage here"],
    ["solution", "import mujoco\n"
                 "import numpy as np\n\n"
                 "FOURBAR = \"\"\"\n"
                 "<mujoco>\n"
                 "  <option timestep=\"0.002\"/>\n"
                 "  <default><geom contype=\"0\" conaffinity=\"0\"/></default>\n"
                 "  <worldbody>\n"
                 "    <body name=\"crank\" pos=\"0 0 1\">\n"
                 "      <joint name=\"j1\" type=\"hinge\" axis=\"0 1 0\" damping=\"0.05\"/>\n"
                 "      <geom type=\"capsule\" fromto=\"0 0 0 0 0 -.3\" size=\".02\"/>\n"
                 "      <body name=\"coupler\" pos=\"0 0 -.3\">\n"
                 "        <joint name=\"j2\" type=\"hinge\" axis=\"0 1 0\"/>\n"
                 "        <geom type=\"capsule\" fromto=\"0 0 0 .5 0 0\" size=\".02\"/>\n"
                 "      </body>\n"
                 "    </body>\n"
                 "    <body name=\"rocker\" pos=\".5 0 1\">\n"
                 "      <joint name=\"j3\" type=\"hinge\" axis=\"0 1 0\"/>\n"
                 "      <geom type=\"capsule\" fromto=\"0 0 0 0 0 -.3\" size=\".02\"/>\n"
                 "    </body>\n"
                 "  </worldbody>\n"
                 "  <equality><connect body1=\"coupler\" body2=\"rocker\" anchor=\".5 0 0\"/></equality>\n"
                 "</mujoco>\n"
                 "\"\"\"\n"
                 "m = mujoco.MjModel.from_xml_string(FOURBAR)\n"
                 "d = mujoco.MjData(m)\n"
                 "d.qvel[0] = 2.0\n"
                 "gaps = []\n"
                 "for _ in range(1000):\n"
                 "    mujoco.mj_step(m, d)\n"
                 "    a = d.xpos[2] + d.xmat[2].reshape(3, 3) @ np.array([0.5, 0, 0])\n"
                 "    b = d.xpos[3] + d.xmat[3].reshape(3, 3) @ np.array([0, 0, -0.3])\n"
                 "    gaps.append(np.linalg.norm(a - b))\n"
                 "print(\"nq\", m.nq, \"neq\", m.neq, \"nefc\", d.nefc, f\"max gap {max(gaps):.4f} m\")\n\n"
                 "# tighten the equality: timeconst 0.02 -> 0.005 (keep it >= 2 x timestep)\n"
                 "m2 = mujoco.MjModel.from_xml_string(FOURBAR.replace('anchor=\".5 0 0\"', 'anchor=\".5 0 0\" solref=\"0.005 1\"'))\n"
                 "d2 = mujoco.MjData(m2)\n"
                 "d2.qvel[0] = 2.0\n"
                 "gaps2 = []\n"
                 "for _ in range(1000):\n"
                 "    mujoco.mj_step(m2, d2)\n"
                 "    a = d2.xpos[2] + d2.xmat[2].reshape(3, 3) @ np.array([0.5, 0, 0])\n"
                 "    b = d2.xpos[3] + d2.xmat[3].reshape(3, 3) @ np.array([0, 0, -0.3])\n"
                 "    gaps2.append(np.linalg.norm(a - b))\n"
                 "print(f\"solref 0.005: max gap {max(gaps2):.5f} m (default about 0.0068 m)\")",
     "Stretch"],

    ["md", "## Where next\n"
           "Ch 3 explains the physics behind contacts, joints and integration from scratch; Ch 5 runs the first "
           "full MJWarp simulation in many worlds and shows both ways of rendering it."],
]
