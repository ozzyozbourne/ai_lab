# Notebook spec for Chapter 3. Build with:
#   python3 tools/make_notebook.py notebooks/specs/03-rigid-body-physics-primer.py
SLUG = "03-rigid-body-physics-primer"
TITLE = "Ch 03 · Rigid-Body Physics from Scratch: Particles, Rigid Bodies, Joints and Contacts"

PHASE_CELL = (
    '# Interactive phase portraits: drag the slider (ipywidgets) or call show(dt) yourself.\n'
    'import numpy as np\n'
    'try:\n'
    '    import matplotlib\n'
    '    import matplotlib.pyplot as plt\n'
    'except ImportError:\n'
    '    plt = None\n'
    '    print("skipped: matplotlib not installed")\n'
    '\n'
    '\n'
    'def euler_paths(dt, T=3.0, omega=2 * np.pi):\n'
    '    paths = {}\n'
    '    for name, semi in [("explicit", False), ("semi-implicit", True)]:\n'
    '        x, v, pts = 1.0, 0.0, [(1.0, 0.0)]\n'
    '        for _ in range(round(T / dt)):\n'
    '            a = -omega**2 * x\n'
    '            if semi:\n'
    '                v += a * dt\n'
    '                x += v * dt\n'
    '            else:\n'
    '                x, v = x + v * dt, v + a * dt\n'
    '            pts.append((x, v / omega))\n'
    '        paths[name] = np.array(pts)\n'
    '    return paths\n'
    '\n'
    '\n'
    'def show(dt=0.05):\n'
    '    paths = euler_paths(dt)\n'
    '    for name, p in paths.items():\n'
    '        print(f"dt = {dt}: {name:<13} final E/E0 = {(p[-1] ** 2).sum():.4g}")\n'
    '    if plt is None:\n'
    '        return\n'
    '    fig, ax = plt.subplots(figsize=(4.5, 4.5))\n'
    '    th = np.linspace(0, 2 * np.pi, 200)\n'
    '    ax.plot(np.cos(th), np.sin(th), "k--", lw=1, label="exact")\n'
    '    ax.plot(*paths["explicit"].T, "r.-", label="explicit")\n'
    '    ax.plot(*paths["semi-implicit"].T, "g.-", label="semi-implicit")\n'
    '    ax.set(xlim=(-2.5, 2.5), ylim=(-2.5, 2.5), xlabel="x", ylabel="v / omega", aspect="equal",\n'
    '           title=f"dt = {dt} s, omega*dt = {2 * np.pi * dt:.2f}")\n'
    '    ax.legend(loc="upper right")\n'
    '    plt.show()\n'
    '\n'
    '\n'
    'try:\n'
    '    from ipywidgets import FloatLogSlider, interact\n'
    '    interact(show, dt=FloatLogSlider(value=0.05, base=10, min=-2.3, max=-0.4, step=0.05))\n'
    'except ImportError:\n'
    '    for dt in (0.01, 0.05, 0.2):\n'
    '        show(dt)'
)

ENGINE_CELL = (
    '# Your own physics engine in ~40 lines: many worlds, one ball each, a soft floor.\n'
    'import numpy as np\n'
    '\n'
    '\n'
    'class TinyEngine:\n'
    '    """Batched point-mass engine: state (z, v) per world, semi-implicit Euler, penalty floor."""\n'
    '\n'
    '    def __init__(self, nworld, radius=0.1, dt=0.002, timeconst=0.02, dampratio=1.0, g=9.81):\n'
    '        self.nworld, self.radius, self.dt, self.g = nworld, radius, dt, g\n'
    '        self.k = 1.0 / (timeconst * dampratio) ** 2     # floor stiffness per unit mass\n'
    '        self.b = 2.0 / timeconst                         # floor damping per unit mass\n'
    '        self.z = np.ones(nworld)                         # qpos: one number per world\n'
    '        self.v = np.zeros(nworld)                        # qvel\n'
    '        self.t = 0.0\n'
    '\n'
    '    def forces(self):\n'
    '        """Acceleration of every world at the current state (the \'forward\' pass)."""\n'
    '        a = np.full(self.nworld, -self.g)                # gravity\n'
    '        pen = self.radius - self.z                       # > 0 inside the floor\n'
    "        contact = pen > 0                                # 'collision detection'\n"
    '        push = np.maximum(0.0, self.k * pen - self.b * self.v)\n'
    "        a[contact] += push[contact]                      # one-sided 'constraint' force\n"
    '        return a\n'
    '\n'
    '    def step(self):\n'
    '        """One time step: forward, then integrate (velocity first, like MuJoCo\'s Euler)."""\n'
    '        a = self.forces()\n'
    '        self.v += a * self.dt\n'
    '        self.z += self.v * self.dt\n'
    '        self.t += self.dt\n'
    '\n'
    '\n'
    'eng = TinyEngine(nworld=4)\n'
    'eng.z[:] = np.linspace(0.3, 0.8, 4)\n'
    'for _ in range(500):\n'
    '    eng.step()\n'
    'print(f"t = {eng.t:.2f} s, z per world:", np.round(eng.z, 4))\n'
    'print("rest penetration [mm]:", np.round(1000 * (eng.radius - eng.z), 3))'
)

COMPARE_CELL = (
    '# Compare TinyEngine with MJWarp on the same four drops (run the TinyEngine cell first).\n'
    'import mujoco\n'
    'import numpy as np\n'
    'import warp as wp\n'
    'wp.config.log_level = wp.LOG_WARNING\n'
    'import mujoco_warp as mjw\n'
    '\n'
    'BALL = """<mujoco><option timestep="0.002"/><worldbody><geom type="plane" size="5 5 .1"/>\n'
    '<body pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1"/></body></worldbody></mujoco>"""\n'
    'mjm = mujoco.MjModel.from_xml_string(BALL)\n'
    'm = mjw.put_model(mjm)\n'
    'd = mjw.make_data(mjm, nworld=4, nconmax=4, njmax=16)\n'
    'qpos = np.tile(mjm.qpos0, (4, 1)).astype(np.float32)\n'
    'qpos[:, 2] = np.linspace(0.3, 0.8, 4)\n'
    'd.qpos.assign(qpos)\n'
    '\n'
    'mine = TinyEngine(nworld=4)\n'
    'mine.z[:] = qpos[:, 2]\n'
    'print(" t [s]   world 3 z: TinyEngine   MJWarp")\n'
    'for i in range(500):\n'
    '    mjw.step(m, d)\n'
    '    mine.step()\n'
    '    if i % 50 == 49:\n'
    '        print(f" {(i + 1) * 0.002:.1f}               {mine.z[3]:.4f}     {d.qpos.numpy()[3, 2]:.4f}")\n'
    'print("rest penetration [mm]: TinyEngine", round(1000 * (0.1 - mine.z[0]), 3),\n'
    '      " MJWarp", round(1000 * (0.1 - float(d.qpos.numpy()[0, 2])), 3))\n'
    'print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())'
)

SOL1 = (
    'import numpy as np\n'
    '\n'
    'G = np.array([0.0, -9.81])\n'
    'C_OVER_M = 0.01            # quadratic drag coefficient per unit mass [1/m]\n'
    '\n'
    '\n'
    'def landing_distance(dt, v0=30.0, angle_deg=45.0):\n'
    '    """Semi-implicit Euler for a projectile with drag a = g - (c/m)|v| v. Returns x at z = 0."""\n'
    '    a0 = np.radians(angle_deg)\n'
    '    p = np.zeros(2)\n'
    '    v = v0 * np.array([np.cos(a0), np.sin(a0)])\n'
    '    while True:\n'
    '        a = G - C_OVER_M * np.linalg.norm(v) * v\n'
    '        v = v + a * dt\n'
    '        p_new = p + v * dt\n'
    '        if p_new[1] < 0:                        # crossed the ground in this step\n'
    '            s = p[1] / (p[1] - p_new[1])        # linear interpolation inside the step\n'
    '            return p[0] + s * (p_new[0] - p[0])\n'
    '        p = p_new\n'
    '\n'
    '\n'
    'ref = landing_distance(1e-5)\n'
    'mine = landing_distance(0.01)\n'
    'print(f"reference (dt=1e-5): {ref:.3f} m, dt=0.01: {mine:.3f} m, "\n'
    '      f"error {100 * abs(mine - ref) / ref:.3f} %")\n'
    'print(f"no drag would give v0^2/g = {30.0**2 / 9.81:.3f} m")\n'
    'assert abs(mine - ref) / ref < 0.02'
)

SOL2 = (
    'import mujoco\n'
    'import numpy as np\n'
    '\n'
    'r, h, m = 0.1, 0.3, 2.0          # radius, HALF length, mass\n'
    'xml = f"""<mujoco><worldbody><body><freejoint/>\n'
    '  <geom type="cylinder" size="{r} {h}" mass="{m}"/></body></worldbody></mujoco>"""\n'
    'mjm = mujoco.MjModel.from_xml_string(xml)\n'
    '\n'
    'I_axial = m * r**2 / 2                          # about the cylinder axis (z)\n'
    'I_side = m * (3 * r**2 + (2 * h) ** 2) / 12     # about x and y through the centre\n'
    'I_mine = np.array([I_side, I_side, I_axial])\n'
    'print("formula:", I_mine, " MuJoCo:", mjm.body_inertia[1])\n'
    'assert np.allclose(I_mine, mjm.body_inertia[1], rtol=1e-6)'
)

CELLS = [
    ["md", "## How to use this notebook\n"
           "This chapter builds rigid-body physics from scratch. Examples 3.1, 3.2, 3.5 and 3.8 are plain NumPy "
           "or C MuJoCo and run on any machine; 3.3, 3.4, 3.6, 3.7, 3.9 and 3.10 also run MJWarp. Every example "
           "cell is the same file as on the chapter page. Run the cells top to bottom; each one is standalone."],

    ["md", "## §1 A point mass: F = m a and time stepping\n"
           "A point mass has state (x, v). Each time step computes the force, a = F / m, and writes the next "
           "state. The two loops below differ only in the ORDER of the two update lines."],
    ["example", "ex1_point_mass.py", "3.1"],

    ["md", "## §2 Explicit vs semi-implicit Euler\n"
           "On a spring (a = -omega^2 x), explicit Euler multiplies the energy by (1 + omega^2 dt^2) every step. "
           "Semi-implicit Euler (velocity first, MuJoCo's `euler`: `_next_velocity` then `_next_position`) keeps "
           "it bounded while omega*dt < 2."],
    ["example", "ex2_spring_oscillator.py", "3.2"],
    ["md", "### Interactive phase portraits\n"
           "Move the slider (Colab has ipywidgets) to change dt and watch explicit Euler spiral out while "
           "semi-implicit Euler stays on a closed loop. Past omega*dt = 2 (dt > 0.32; the slider goes to 0.4) semi-implicit Euler "
           "explodes too."],
    ["code", PHASE_CELL],

    ["md", "## §3 A bouncing ball on a spring-damper floor\n"
           "solref (timeconst, dampratio) maps to k/m = 1/(timeconst*dampratio)^2 and b/m = 2/timeconst "
           "(`constraint.py::_contact_kbimp`). dampratio is the damping ratio: 1 means no bounce. The same drop "
           "then runs in C MuJoCo and MJWarp."],
    ["example", "ex3_bouncing_ball_numpy.py", "3.3"],

    ["md", "## §4 A rigid body: 6 DOF, qpos 7 and qvel 6\n"
           "Position (3) + unit quaternion (w, x, y, z) (4) + linear velocity (3, world frame) + angular velocity "
           "(3, BODY frame)."],
    ["example", "ex4_rigid_body_state.py", "3.4"],

    ["md", "## §5 Mass properties: com, inertia tensor, principal axes\n"
           "MuJoCo stores the principal moments (`body_inertia`) and the rotation to the principal axes "
           "(`body_iquat`), never the full 3x3 tensor. Rebuild it with R diag(I) R^T."],
    ["example", "ex5_inertia_tensor.py", "3.5"],

    ["md", "## §6 Integrating an orientation\n"
           "The exact update is q <- q * exp(omega dt / 2) (`math.quat_integrate`, called by `_next_position` for "
           "free and ball joints). Add-and-renormalize falls behind by about (|omega| dt)^3 / 12 per step. "
           "This example imports `mujoco_warp._src.math`: private API, the name may change."],
    ["example", "ex6_quat_integrate.py", "3.6"],
    ["md", "### The tennis racket in many worlds\n"
           "Euler's rotation equation I dw/dt + w x (I w) = tau makes spin about the intermediate axis unstable. "
           "Each world starts with a different tiny wobble; smaller wobbles flip later. On a GPU this runs 4096 "
           "worlds in the same `mjw.step` call and prints 8 of them."],
    ["example", "ex7_tennis_racket.py", "3.7"],

    ["md", "## §7 Joints and reduced coordinates\n"
           "A pendulum in maximal coordinates (x, z + a stiff spring rod) vs one hinge angle. Stiffer rods drift "
           "less but need smaller steps; the hinge is exact by construction."],
    ["example", "ex8_pendulum_two_ways.py", "3.8"],

    ["md", "## §8 Constraints: a resting contact cancels gravity\n"
           "Contacts and joint limits are one-sided, equalities two-sided. All are soft: the resting ball sits "
           "0.367 mm inside the floor, which MuJoCo's reference acceleration aref = -k*imp*pos - b*vel predicts."],
    ["example", "ex9_contact_as_constraint.py", "3.9"],

    ["md", "## §9 Bridge to MuJoCo: M(q) qacc + c(q, qvel) = tau + J^T f\n"
           "You derive M and c in Ch 11. Here, just check that the equation balances on the double pendulum."],
    ["example", "ex10_preview_eom.py", "3.10"],

    ["md", "## Your own physics engine in 40 lines\n"
           "Everything above in one class: a batched state (one ball per world), a forward pass (gravity, "
           "collision detection, a one-sided soft floor) and a semi-implicit integrator."],
    ["code", ENGINE_CELL],

    ["md", "## Exercise 3.1: a projectile with air drag (auto-checked)\n"
           "A ball leaves the ground at 30 m/s and 45 degrees. Drag adds -(c/m)|v| v with c/m = 0.01 1/m. "
           "Write `landing_distance(dt)` with semi-implicit Euler, interpolate the landing point inside the "
           "last step, and check that dt = 0.01 lands within 2 percent of a dt = 1e-5 reference."],
    ["code", "import numpy as np\n\nG = np.array([0.0, -9.81])\nC_OVER_M = 0.01\n\n\n"
             "def landing_distance(dt, v0=30.0, angle_deg=45.0):\n"
             "    ...  # your semi-implicit Euler loop; return x at z = 0\n\n\n"
             "ref = landing_distance(1e-5)\nmine = landing_distance(0.01)\n"
             "if mine is None:\n"
             "    print(\"fill in landing_distance\")\n"
             "else:\n"
             "    assert abs(mine - ref) / ref < 0.02"],
    ["solution", SOL1, "Exercise 3.1"],

    ["md", "## Exercise 3.2: the inertia of a cylinder (auto-checked)\n"
           "A cylinder geom of radius 0.1 m, half-length 0.3 m, mass 2 kg (MJCF `size=\"radius half_length\"`). "
           "Compute its principal moments by hand and assert them against `mjm.body_inertia[1]`."],
    ["code", "import mujoco\nimport numpy as np\n\nr, h, m = 0.1, 0.3, 2.0\n"
             "xml = ...          # a body with a freejoint and the cylinder geom\n"
             "I_mine = ...       # [I_xx, I_yy, I_zz] about the centre; the cylinder axis is z\n"
             "if xml is ... or I_mine is ...:\n"
             "    print(\"fill in xml and I_mine\")\n"
             "else:\n"
             "    mjm = mujoco.MjModel.from_xml_string(xml)\n"
             "    assert np.allclose(I_mine, mjm.body_inertia[1], rtol=1e-6)"],
    ["solution", SOL2, "Exercise 3.2"],

    ["md", "## Stretch: two balls that collide\n"
           "Extend `TinyEngine` to 2-D positions and two balls per world, with a ball-ball penalty contact along "
           "the line between the centres (equal and opposite forces, damper on the relative normal velocity). "
           "Check that momentum is conserved with gravity and the floor switched off, then compare with the same "
           "scene in MJCF + MJWarp."],
    ["code", "# your stretch solution here"],

    ["md", "## Last cell: TinyEngine vs MJWarp\n"
           "Same four drops in both engines. In free flight they agree to every digit (same gravity, same "
           "semi-implicit Euler, same 0.002 s step); at the floor a penalty spring and MuJoCo's soft constraint "
           "part ways (3.92 mm vs 0.367 mm rest depth). Run the TinyEngine cell above first."],
    ["code", COMPARE_CELL],
]
