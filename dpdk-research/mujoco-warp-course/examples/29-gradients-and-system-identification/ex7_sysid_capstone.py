"""Example 29.7 - capstone: parallel system identification of a double pendulum.

A "real" PENDULUM (C MuJoCo, float64, plus sensor noise) has a hidden joint damping and a hidden
mass of the lower link. We record its joint angles while a known torque drives the shoulder.
Then every MJWarp world gets one candidate (damping, mass): batched Model fields (Ch 10), with
mjw.set_const called eagerly after each mass write (outside any graph) so the derived constants
match. All candidates replay the same torque in one batched rollout, a kernel sums the squared
angle error per world on the device, and 5 CEM rounds shrink the search onto the truth. The
damping is sharply determined by the recording, the mass only weakly, with a mild positive coupling
between them. This CEM refits a full 2x2 covariance to the elites: cheap insurance against a tilted
valley, not needed here (one sigma per parameter recovers the same values on this problem).
Run: python ex7_sysid_capstone.py [--dump-json PATH]
  --dump-json PATH also evaluates the loss on a grid of candidates (the landscape figure).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PENDULUM = """
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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 64        # candidates per CEM round
NELITE = max(4, NWORLD // 8)
NROUND = 5
T = 150                                # 1.5 s of data at dt = 0.01
TRUE_DAMPING, TRUE_MASS = 0.15, 1.6    # hidden from the identification code
LO, HI = np.array([0.0, 0.5]), np.array([0.5, 3.0])   # prior box: damping [N m s], mass [kg]
TRUTH_NOISE = 0.002                    # rad, sensor noise on the recording

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
LINK2 = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "link2")
torque = 2.0 * np.sin(2 * np.pi * 1.0 * np.arange(T) * mjm.opt.timestep)   # known excitation

# ---- 1. the "real" system: float64 C MuJoCo with the hidden parameters, noisy sensors ----
real = mujoco.MjModel.from_xml_string(PENDULUM)
real.dof_damping[:] = TRUE_DAMPING
real.body_inertia[LINK2] *= TRUE_MASS / real.body_mass[LINK2]
real.body_mass[LINK2] = TRUE_MASS
mujoco.mj_setConst(real, mujoco.MjData(real))
rd = mujoco.MjData(real)
mujoco.mj_resetDataKeyframe(real, rd, 0)
obs = np.zeros((T, mjm.nq))
for t in range(T):
    rd.ctrl[0] = torque[t]
    mujoco.mj_step(real, rd)
    obs[t] = rd.qpos
obs += np.random.default_rng(0).normal(0.0, TRUTH_NOISE, obs.shape)


# ---- 2. the batched candidate simulator ----
@wp.kernel
def set_torque(tau: wp.array[float], t: int, ctrl_out: wp.array2d[float]):
    w = wp.tid()
    ctrl_out[w, 0] = tau[t]


@wp.kernel
def add_loss(qpos_in: wp.array2d[float], obs_in: wp.array2d[float], t: int, nq: int,
             loss_out: wp.array[float]):
    w = wp.tid()
    acc = float(0.0)
    for i in range(nq):
        e = qpos_in[w, i] - obs_in[t, i]
        acc += e * e
    loss_out[w] += acc


FIELDS = ["dof_damping", "body_mass", "body_inertia",                       # what we vary
          "body_subtreemass", "body_invweight0", "dof_invweight0", "actuator_acc0"]  # derived


def make_candidates(n):
    m = mjw.put_model(mjm, batch_sizes={k: n for k in FIELDS})
    d = mjw.make_data(mjm, nworld=n)
    return m, d


def evaluate(m, d, params, tau_wp, obs_wp, loss):
    """Mean squared angle error for every row of params = [[damping, mass], ...]."""
    n = params.shape[0]
    m.dof_damping.assign(np.repeat(params[:, :1], mjm.nv, axis=1))
    bm, bi = np.tile(mjm.body_mass, (n, 1)), np.tile(mjm.body_inertia, (n, 1, 1))
    bm[:, LINK2] = params[:, 1]
    bi[:, LINK2] *= (params[:, 1] / mjm.body_mass[LINK2])[:, None]
    m.body_mass.assign(bm)
    m.body_inertia.assign(bi)
    mjw.set_const(m, d)                # derived constants, per world; eager, outside any graph
    mjw.reset_data_keyframe(m, d, 0)   # every world starts at the "horizontal" keyframe
    loss.zero_()
    for t in range(T):
        wp.launch(set_torque, dim=n, inputs=[tau_wp, t], outputs=[d.ctrl])
        mjw.step(m, d)
        wp.launch(add_loss, dim=n, inputs=[d.qpos, obs_wp, t, mjm.nq], outputs=[loss])
    return loss.numpy() / (T * mjm.nq)


tau_wp = wp.array(torque, dtype=float)
obs_wp = wp.array(obs, dtype=float)
m, d = make_candidates(NWORLD)
loss = wp.zeros(NWORLD, dtype=float)
print("batched shapes: dof_damping", m.dof_damping.shape, "| body_mass", m.body_mass.shape,
      "| body_subtreemass", m.body_subtreemass.shape)

# ---- 3. CEM over (damping, mass) ----
rng = np.random.default_rng(1)
mu, cov = (LO + HI) / 2, np.diag(((HI - LO) / 2) ** 2)
rounds = []
for r in range(NROUND):
    P = np.clip(rng.multivariate_normal(mu, cov, size=NWORLD), LO, HI)
    P[0] = mu                                         # world 0 evaluates the current mean
    L = evaluate(m, d, P, tau_wp, obs_wp, loss)
    elite = np.argsort(L)[:NELITE]
    mu = P[elite].mean(axis=0)
    cov = np.cov(P[elite].T) + 1e-8 * np.eye(2)       # full covariance: allows a tilted Gaussian
    sd, corr = np.sqrt(np.diag(cov)), cov[0, 1] / np.sqrt(cov[0, 0] * cov[1, 1])
    rounds.append({"samples": np.round(P[:64], 4).tolist(), "elite": [int(e) for e in elite
                   if e < 64], "mu": np.round(mu, 4).tolist(), "cov": np.round(cov, 7).tolist()})
    print(f"round {r}: best loss {L[elite[0]]:.2e} | damping {mu[0]:.4f} +- {sd[0]:.4f}"
          f" | mass {mu[1]:.4f} +- {sd[1]:.4f} | corr {corr:+.2f}")

print(f"recovered: damping {mu[0]:.4f} (true {TRUE_DAMPING}), mass {mu[1]:.4f} (true {TRUE_MASS})")
L2 = evaluate(m, d, np.tile([mu, [TRUE_DAMPING, TRUE_MASS]], (NWORLD // 2, 1)), tau_wp, obs_wp,
              loss)
print(f"rms angle error: fit {np.sqrt(L2[0]):.4f} rad, truth {np.sqrt(L2[1]):.4f} rad "
      f"(sensor noise {TRUTH_NOISE} rad)")

if args.dump_json:
    G = 32 if ON_GPU else 16                          # landscape: G x G candidates, one batch
    gd, gm = np.linspace(LO[0], HI[0], G), np.linspace(LO[1], HI[1], G)
    grid = np.array([[a, b] for b in gm for a in gd])
    mg, dg = make_candidates(G * G)
    Lg = evaluate(mg, dg, grid, tau_wp, obs_wp, wp.zeros(G * G, dtype=float))
    print(f"landscape: {G}x{G} grid, min loss at damping {grid[Lg.argmin(), 0]:.3f},"
          f" mass {grid[Lg.argmin(), 1]:.3f}")
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "T": T, "lo": LO.tolist(), "hi": HI.tolist(),
                   "truth": [TRUE_DAMPING, TRUE_MASS], "grid_n": G,
                   "loss_grid": np.round(np.log10(Lg), 3).reshape(G, G).tolist(),
                   "rounds": rounds, "fit": np.round(mu, 4).tolist()}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
