# Notebook spec for Chapter 12. Build with:
#   python3 tools/make_notebook.py notebooks/specs/12-forces-actuators-tendons.py
SLUG = "12-forces-actuators-tendons"
TITLE = "Ch 12 · Forces: Passive, Springs, Bias, Actuators and Tendons"

PLOT_PASSIVE = r'''
# Stacked bars: qfrc_passive of the 3-link arm by name (uses `parts` from Example 12.2).
try:
    import matplotlib.pyplot as plt
    names = ["qfrc_spring", "qfrc_damper", "qfrc_gravcomp", "qfrc_fluid"]
    pos, neg = np.zeros(3), np.zeros(3)
    fig, ax = plt.subplots(figsize=(5, 3.2))
    for k, n in enumerate(names):
        v = np.array(parts[n])
        c = f"C{k}"
        ax.bar(range(3), np.where(v > 0, v, 0), bottom=pos, color=c, label=n)
        ax.bar(range(3), np.where(v < 0, v, 0), bottom=neg, color=c)
        pos += np.where(v > 0, v, 0)
        neg += np.where(v < 0, v, 0)
    ax.scatter(range(3), parts["qfrc_passive"], color="k", zorder=3, label="qfrc_passive")
    ax.set_xticks(range(3), ["j1", "j2", "j3"])
    ax.axhline(0, color="k", lw=0.8)
    ax.legend(fontsize=7)
    plt.show()
except ImportError:
    print("skipped: matplotlib not installed")
'''

PLOT_MUSCLE = r'''
# Force-length curve of the muscle (uses L, F, Fp from Example 12.8).
try:
    import matplotlib.pyplot as plt
    plt.figure(figsize=(5, 3.2))
    plt.plot(L, -F, label="act = 1 (active + passive)")
    plt.plot(L, -Fp, "--", label="act = 0 (passive only)")
    plt.xlabel("tendon length [m]"); plt.ylabel("pull = -actuator_force [N]"); plt.legend()
    plt.show()
except ImportError:
    print("skipped: matplotlib not installed")
'''

PLOT_FLUID = r'''
# Vertical velocity over time, one curve per density world (uses traj, DENS from Example 12.12).
try:
    import matplotlib.pyplot as plt
    tr = np.array(traj)
    plt.figure(figsize=(5, 3.2))
    for k, rho in enumerate(DENS):
        plt.plot(np.arange(1, len(tr) + 1) * 0.1, tr[:, k], label=f"density {rho}")
    plt.xlabel("t [s]"); plt.ylabel("vz [m/s]"); plt.legend()
    plt.show()
except ImportError:
    print("skipped: matplotlib not installed")
'''

SWEEP = r'''
# Parameter sweep: one position servo per world, each with its own kp
# (batched actuator_gainprm / actuator_biasprm, Ch 10). 1024 worlds on a GPU, 8 on CPU.
# Each servo also gets critical velocity damping kv = 2 sqrt(kp * I), so it settles
# without ringing and a stiffer servo settles faster (time constant ~ sqrt(I / kp)).
NW = 1024 if ON_GPU else 8
SERVO = """
<mujoco><option timestep="0.002" gravity="0 0 0"/>
  <worldbody><body><joint name="j" type="hinge" axis="0 1 0" damping="0.05"/>
    <geom type="capsule" fromto="0 0 0 .3 0 0" size=".03" mass="1"/></body></worldbody>
  <actuator><position joint="j" kp="10"/></actuator></mujoco>"""
mjm_s = mujoco.MjModel.from_xml_string(SERVO)
m_s = mjw.put_model(mjm_s, batch_sizes={"actuator_gainprm": NW, "actuator_biasprm": NW})
d_s = mjw.make_data(mjm_s, nworld=NW)
I = float(mjm_s.dof_M0[0])                  # joint-space inertia of the hinge at qpos0
kp = np.geomspace(1, 100, NW)
kv = 2 * np.sqrt(kp * I)                     # critical damping
g, b = m_s.actuator_gainprm.numpy(), m_s.actuator_biasprm.numpy()
g[:, 0, 0] = kp           # gain = kp
b[:, 0, 1] = -kp          # bias = -kp * length ...
b[:, 0, 2] = -kv          #      - kv * velocity
m_s.actuator_gainprm.assign(g)
m_s.actuator_biasprm.assign(b)
d_s.ctrl.fill_(0.5)       # every servo aims at 0.5 rad
traj_s = []
for i in range(500):
    mjw.step(m_s, d_s)
    if (i + 1) % 10 == 0:                    # samples at t = 0.02, 0.04, ..., 1.00 s
        traj_s.append(d_s.qpos.numpy()[:, 0].copy())   # .copy(): on CPU .numpy() is a view
traj_s = np.array(traj_s)
t = (np.arange(len(traj_s)) + 1) * 10 * mjm_s.opt.timestep
err = np.abs(traj_s - 0.5)
band = 0.02 * 0.5                            # 2% of the 0.5 rad step
def settling_time(e):
    if e[-1] > band:
        return float("nan")                  # not settled by the last sample
    out = np.nonzero(e > band)[0]
    return float(t[out.max() + 1]) if len(out) else float(t[0])
settle = [settling_time(e) for e in err.T]
print(f"I = {I:.4f} kg m^2, sample times {t[0]:.2f} ... {t[-1]:.2f} s")
print("kp:              ", [round(float(x), 1) for x in kp[:8]])
print(f"q at t={t[-1]:.2f} s:   ", [round(float(x), 3) for x in traj_s[-1, :8]], "(target 0.5)")
print("2% settling [s]: ", [round(x, 2) for x in settle[:8]], "(nan: not settled by 1 s)")
try:
    import matplotlib.pyplot as plt
    for k in np.linspace(0, NW - 1, 6).astype(int):
        plt.plot(t, traj_s[:, k], label=f"kp={kp[k]:.1f}")
    plt.axhline(0.5, color="k", ls="--", lw=1)
    plt.xlabel("t [s]"); plt.ylabel("q [rad]"); plt.legend(); plt.show()
except ImportError:
    print("skipped: matplotlib not installed")
'''

STUB1 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

KP, KD = 30.0, 2.0
SERVO = """
<mujoco>
  <option gravity="0 0 0"/>
  <worldbody>
    <body>
      <joint name="j" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".03" mass="1"/>
    </body>
  </worldbody>
  <actuator>
    <general joint="j" gaintype="fixed" gainprm="..." biastype="affine" biasprm="..."/>
  </actuator>
</mujoco>
"""
# TODO: fill in gainprm and biasprm so that force = KP * (ctrl - q) - KD * qdot
mjm = mujoco.MjModel.from_xml_string(SERVO)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4)
rng = np.random.default_rng(0)
q, v, u = (rng.uniform(-1, 1, (4, 1)).astype(np.float32) for _ in range(3))
d.qpos.assign(q); d.qvel.assign(v); d.ctrl.assign(u)
mjw.forward(m, d)
force = d.actuator_force.numpy()
assert np.allclose(force, KP * (u - q) - KD * v, atol=1e-5), force
print("PD servo OK:", force[:, 0])
'''

SOL1 = STUB1.replace('gainprm="..." biastype="affine" biasprm="..."',
                     'gainprm="{KP}" biastype="affine" biasprm="0 {-KP} {-KD}"').replace(
    'SERVO = """', 'SERVO = f"""').replace(
    "# TODO: fill in gainprm and biasprm so that force = KP * (ctrl - q) - KD * qdot\n", "")

STUB2 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

PATH = epath.resource_path("mujoco_warp") / "test_data/actuation/slidercrank.xml"
mjm = mujoco.MjModel.from_xml_path(str(PATH))
m = mjw.put_model(mjm)
q0, eps = 0.7, 1e-3
# TODO: 3 worlds at crank angles q0, q0 + eps, q0 - eps; one forward; central difference of
# actuator_length; read the slider-crank moment on dof 0 from the sparse moment arrays.
fd = ...
moment = ...
assert abs(moment - fd) < 1e-3, (moment, fd)
'''

SOL2 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

PATH = epath.resource_path("mujoco_warp") / "test_data/actuation/slidercrank.xml"
mjm = mujoco.MjModel.from_xml_path(str(PATH))
m = mjw.put_model(mjm)
q0, eps = 0.7, 1e-3
d = mjw.make_data(mjm, nworld=3)
qpos = np.zeros((3, mjm.nq), dtype=np.float32)
qpos[:, 0] = [q0, q0 + eps, q0 - eps]
d.qpos.assign(qpos)
mjw.forward(m, d)
L = d.actuator_length.numpy()[:, 0]
fd = (L[1] - L[2]) / (2 * eps)
adr = d.moment_rowadr.numpy()[0, 0]
nnz = d.moment_rownnz.numpy()[0, 0]
cols = d.moment_colind.numpy()[0, adr:adr + nnz]
vals = d.actuator_moment.numpy()[0, adr:adr + nnz]
moment = dict(zip(cols.tolist(), vals.tolist())).get(0, 0.0)
print(f"moment {moment:.5f}  finite difference {fd:.5f}")
assert abs(moment - fd) < 1e-3, (moment, fd)
'''

STUB3 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

TENDON = """
<mujoco>
  <option gravity="0 0 0"/>
  <worldbody>
    <body><joint name="a" type="slide" axis="1 0 0"/><geom type="sphere" size=".05" mass="1"/>
      <body><joint name="b" type="slide" axis="1 0 0"/><geom type="sphere" size=".05" mass="1"/></body>
    </body>
  </worldbody>
  <tendon>
    <fixed name="t" stiffness="50" springlength="0.1">
      <joint joint="a" coef="1"/><joint joint="b" coef="-2"/>
    </fixed>
  </tendon>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(TENDON)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
d.qpos.assign(np.array([[0.4, 0.05]], dtype=np.float32))
mjw.forward(m, d)
expected = ...   # TODO: qfrc_spring predicted from L, the tendon Jacobian and the spring law
assert np.allclose(d.qfrc_spring.numpy()[0], expected, atol=1e-5), d.qfrc_spring.numpy()
'''

SOL3 = STUB3.replace(
    "expected = ...   # TODO: qfrc_spring predicted from L, the tendon Jacobian and the spring law",
    "L = 0.4 - 2 * 0.05                     # fixed tendon: sum coef * q\n"
    "J = np.array([1.0, -2.0])              # dL/dq = the coefficients\n"
    "expected = J * (-50 * (L - 0.1))       # tendon force -k (L - springlength), mapped by J^T\n"
    "print(d.ten_length.numpy(), d.qfrc_spring.numpy(), expected)")

STRETCH = r'''
# Stretch sketch: a custom linear drag through m.callback.passive (runs at the end of passive.py::passive).
C = 0.8

@wp.kernel
def drag(qvel: wp.array2d(dtype=float), c: float, qfrc_passive: wp.array2d(dtype=float)):
    worldid, dofid = wp.tid()
    qfrc_passive[worldid, dofid] -= c * qvel[worldid, dofid]

def my_passive(m, d):
    wp.launch(drag, dim=(d.nworld, m.nv), inputs=[d.qvel, C], outputs=[d.qfrc_passive])

XML = """<mujoco><option timestep="0.01"/><worldbody><body pos="0 0 1"><freejoint/>
<geom type="sphere" size=".1" mass="1"/></body></worldbody></mujoco>"""
mjm_c = mujoco.MjModel.from_xml_string(XML)
m_c = mjw.put_model(mjm_c)
m_c.callback.passive = my_passive
d_c = mjw.make_data(mjm_c, nworld=2)
for _ in range(800):
    mjw.step(m_c, d_c)
print("vz after 8 s:", d_c.qvel.numpy()[:, 2], "| terminal -m g / c =", -9.81 / C)
'''

CELLS = [
    ["md", "**How this notebook works.** Every example cell is the same file as on the chapter page "
           "(`examples/12-forces-actuators-tendons/`). Cells run top to bottom in a fresh runtime. Most "
           "examples here use a handful of worlds on purpose: they check formulas against C MuJoCo. "
           "Only the parameter sweep scales with `ON_GPU`. Examples appear here in numeric order, "
           "which differs from the order on the chapter page, and the section numbers below are this "
           "notebook's own: to follow a run-note on the page, search for the example number "
           "(for example \"Example 12.7b\")."],
    ["md", "## 1. Bias forces and the gravity trick\n"
           "`qfrc_bias` is what RNE computes: gravity plus Coriolis and centrifugal terms. The world body "
           "is given the acceleration `-gravity`, and that acceleration flows down the tree."],
    ["example", "ex1_qfrc_bias_gravity.py", "12.1"],
    ["md", "## 2. Passive forces by name\nSprings, dampers (including MuJoCo 4 polynomial terms), "
           "gravcomp and fluid forces are written to separate arrays and summed into `qfrc_passive`. "
           "Note `<compiler angle=\"radian\"/>`: without it `springref` is read in degrees."],
    ["example", "ex2_spring_damper.py", "12.2"],
    ["code", PLOT_PASSIVE],
    ["md", "### Plastic springs\nWith `springyield` the spring reference lives in `d.plastic` and moves "
           "after every step (`forward.py::_advance` → `_next_plastic_joint`)."],
    ["example", "ex2b_plastic_spring.py", "12.2b"],
    ["md", "## 3. Actuators: one formula\n`force = gain * ctrl + bias`, clamped to `forcerange`."],
    ["example", "ex3_actuator_types.py", "12.3"],
    ["md", "## 4. Activation dynamics\nA filter actuator has an internal state `act`."],
    ["example", "ex4_filter_dynamics.py", "12.4"],
    ["md", "## 5. Transmissions and the sparse moment\n`d.actuator_moment` is stored as sparse rows per "
           "world (`moment_rownnz`, `moment_rowadr`, `moment_colind`)."],
    ["example", "ex5_transmissions.py", "12.5"],
    ["md", "## 6. MuJoCo 4 actuators\n`nu` (control slots) can be larger than `nactuator`. The DC motor "
           "runs in 4.0.1; SO3 and PID actuators are rejected by `put_model`."],
    ["example", "ex6_mujoco4_actuators.py", "12.6"],
    ["example", "ex7_pid_rejected.py", "12.7"],
    ["md", "### Actuator damping\nAn actuator's `damping` attribute is passive: it ends up in `qfrc_damper`."],
    ["example", "ex7b_actuator_damping.py", "12.7b"],
    ["md", "## 7. Muscles"],
    ["example", "ex8_muscle.py", "12.8"],
    ["code", PLOT_MUSCLE],
    ["md", "## 8. Tendons and wrapping"],
    ["example", "ex9_tendons.py", "12.9"],
    ["md", "## 9. After the solver: rne_postconstraint\n`cacc` and `cfrc_ext` are only complete when "
           "`rne_postconstraint` runs."],
    ["example", "ex10_postconstraint.py", "12.10"],
    ["md", "## 10. Gravity compensation and subtree velocities"],
    ["example", "ex11_gravcomp_subtree_vel.py", "12.11"],
    ["md", "## 11. Fluid forces"],
    ["example", "ex12_fluid_models.py", "12.12"],
    ["code", PLOT_FLUID],
    ["md", "## Parameter sweep: 1024 servos, one kp each\nA batched sweep is the MJWarp way to explore a "
           "parameter: every world gets its own `gainprm`/`biasprm`. Each servo is critically damped "
           "(`kv = 2 sqrt(kp I)`), so the printed 2% settling time falls as `kp` grows, roughly as "
           "`1/sqrt(kp)`. On CPU only 8 worlds run; the numbers are CPU numbers."],
    ["code", SWEEP],
    ["md", "## Exercise 12.1: a PD servo from a general actuator\nFill in `gainprm` and `biasprm` so "
           "that `actuator_force = KP (ctrl - q) - KD qdot`."],
    ["code", STUB1],
    ["solution", SOL1, "Exercise 12.1"],
    ["md", "## Exercise 12.2: the slider-crank moment arm by finite differences\nThe moment row is "
           "d(actuator_length)/d(qpos). Check it with a central difference, using one world per sample."],
    ["code", STUB2],
    ["solution", SOL2, "Exercise 12.2"],
    ["md", "## Exercise 12.3: a fixed-tendon spring\nPredict `qfrc_spring` of a stretched fixed tendon "
           "from its length, its Jacobian and the spring law."],
    ["code", STUB3],
    ["solution", SOL3, "Exercise 12.3"],
    ["md", "## Stretch: your own passive force through `m.callback.passive`\nWrite a kernel that adds a "
           "drag `-c * qvel` to `d.qfrc_passive` and register it as `m.callback.passive` (recall Ch 8; the "
           "callback catalogue is Ch 26). The sketch below shows one way."],
    ["code", STRETCH],
]
