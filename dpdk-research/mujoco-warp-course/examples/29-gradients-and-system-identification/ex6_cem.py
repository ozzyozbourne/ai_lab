"""Example 29.6 - the cross-entropy method (CEM): Ch 8's random shooting, made iterative.

CARTPOLE starts hanging (hinge = pi). The plan is an open-loop sequence of KNOTS force values,
each held for HOLD steps. CEM keeps a Gaussian over plans (mean mu, std sigma per knot). Every
iteration: restore the start snapshot (State.PHYSICS | TIME) in all worlds, sample NWORLD plans
on the device, roll them all out at once while a kernel sums the reward per world, keep the
NELITE best plans, refit mu and sigma to them, repeat. World 0 always replays the current mean
and world 1 the best plan found so far (elitism), so the best return never goes down.
Run: python ex6_cem.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

CARTPOLE = """
<mujoco model="cartpole">
  <option timestep="0.01" integrator="implicitfast"/>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="front" pos="0 -4 1" xyaxes="1 0 0 0 0 1"/>
    <geom name="rail" type="capsule" fromto="-2 0 1 2 0 1" size=".02" contype="0" conaffinity="0"/>
    <body name="cart" pos="0 0 1">
      <joint name="slider" type="slide" axis="1 0 0" range="-1.8 1.8" limited="true" damping="0.1"/>
      <geom name="cart" type="box" size=".2 .1 .05" mass="1" contype="0" conaffinity="0"/>
      <body name="pole">
        <joint name="hinge" type="hinge" axis="0 1 0" damping="0.01"/>
        <geom name="pole" type="capsule" fromto="0 0 0 0 0 .6" size=".03" mass="0.1"
              contype="0" conaffinity="0"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="slider" gear="10" ctrlrange="-1 1" ctrllimited="true"/></actuator>
  <sensor>
    <jointpos joint="slider"/><jointpos joint="hinge"/>
    <jointvel joint="slider"/><jointvel joint="hinge"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 64     # samples per CEM iteration
NELITE = NWORLD // 8                # elites kept to refit the Gaussian
NITER = 12 if ON_GPU else 10
KNOTS, HOLD = 10, 20                # 10 knots x 20 steps = 2 s plan
SIGMA0, SIGMA_MIN = 0.8, 0.05


@wp.kernel
def sample_plans(seed: int, it: int, mu: wp.array[float], sigma: wp.array[float],
                 best: wp.array[float], plans_out: wp.array2d[float]):
    w, k = wp.tid()
    rng = wp.rand_init(seed, (it * 65536 + w) * 64 + k)
    u = mu[k]                                  # world 0 replays the mean plan
    if w == 1:
        u = best[k]                            # world 1 replays the best plan so far
    elif w > 1:
        u = mu[k] + sigma[k] * wp.randn(rng)
    plans_out[w, k] = wp.clamp(u, -1.0, 1.0)   # sample, then clip to ctrlrange


@wp.kernel
def set_ctrl(plans_in: wp.array2d[float], k: int, ctrl_out: wp.array2d[float]):
    w = wp.tid()
    ctrl_out[w, 0] = plans_in[w, k]


@wp.kernel
def add_reward(qpos_in: wp.array2d[float], qvel_in: wp.array2d[float],
               ctrl_in: wp.array2d[float], ret_out: wp.array[float]):
    w = wp.tid()
    x, theta = qpos_in[w, 0], qpos_in[w, 1]    # theta = 0 is upright
    u, om = ctrl_in[w, 0], qvel_in[w, 1]
    ret_out[w] += wp.cos(theta) - 0.1 * x * x - 0.01 * u * u - 0.001 * om * om


mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
q0 = mjm.qpos0.copy()
q0[1] = np.pi                                  # hanging start
d.qpos.assign(np.tile(q0, (NWORLD, 1)))

SIG = int(mjw.State.PHYSICS | mjw.State.TIME)  # Ch 8 sec. 4; no contacts, so no WARMSTART
snap = wp.zeros((NWORLD, mujoco.mj_stateSize(mjm, SIG)), dtype=float)
mjw.get_state(m, d, snap, SIG)                 # the start state, taken once

mu = np.zeros(KNOTS)
sigma = np.full(KNOTS, SIGMA0)
plans = wp.zeros((NWORLD, KNOTS), dtype=float)
ret = wp.zeros(NWORLD, dtype=float)
mu_wp, sigma_wp = wp.zeros(KNOTS, dtype=float), wp.zeros(KNOTS, dtype=float)
best_wp = wp.zeros(KNOTS, dtype=float)
hist, replay_ok, prev_best = [], [], None
print(f"nworld {NWORLD} samples/iter, {NELITE} elites, plan {KNOTS} knots x {HOLD} steps")
for it in range(NITER):
    mjw.set_state(m, d, snap, SIG)             # every world back to the start
    mu_wp.assign(mu)
    sigma_wp.assign(sigma)
    wp.launch(sample_plans, dim=(NWORLD, KNOTS), inputs=[11, it, mu_wp, sigma_wp, best_wp],
              outputs=[plans])
    ret.zero_()
    for k in range(KNOTS):                     # all NWORLD rollouts in one batch
        wp.launch(set_ctrl, dim=NWORLD, inputs=[plans, k], outputs=[d.ctrl])
        for _ in range(HOLD):
            mjw.step(m, d)
            wp.launch(add_reward, dim=NWORLD, inputs=[d.qpos, d.qvel, d.ctrl], outputs=[ret])
    r = ret.numpy()                            # one small host copy per iteration
    if prev_best is not None:
        replay_ok.append(bool(r[1] == prev_best))  # same plan + same snapshot = same return
    P = plans.numpy()
    elite = np.argsort(r)[-NELITE:]            # top-NELITE worlds
    mu = P[elite].mean(axis=0)
    sigma = np.maximum(P[elite].std(axis=0), SIGMA_MIN)
    best = int(elite[-1])
    best_wp.assign(P[best])                    # elitism: carried into the next iteration
    prev_best = r[best]
    hist.append({"best": round(float(r[best]), 2), "mean_plan": round(float(r[0]), 2),
                 "elite_min": round(float(r[elite[0]]), 2), "sigma": round(float(sigma.mean()), 3),
                 "mu": np.round(mu, 3).tolist(),
                 "samples": np.round(P[2:26, :], 3).tolist(),
                 "elite_idx": [int(e) - 2 for e in elite if 1 < e < 26]})
    print(f"iter {it}: best return {r[best]:7.2f} | mean-plan return {r[0]:7.2f} | "
          f"mean sigma {sigma.mean():.3f}")

# replay the best plan in world 1 and report how close to upright the pole gets
mjw.set_state(m, d, snap, SIG)
wp.launch(sample_plans, dim=(NWORLD, KNOTS), inputs=[11, 0, mu_wp, sigma_wp, best_wp],
          outputs=[plans])
theta, frames = [], []
for k in range(KNOTS):
    wp.launch(set_ctrl, dim=NWORLD, inputs=[plans, k], outputs=[d.ctrl])
    for s in range(HOLD):
        mjw.step(m, d)
        if args.dump_json and s % 4 == 3:      # replay frames for the page (dump only)
            frames.append(np.round(d.qpos.numpy()[1], 3).tolist())
    theta.append(float(d.qpos.numpy()[1, 1]))
th = np.array(theta)
print("world-1 replays of the carried best plan reproduced its return exactly:", all(replay_ok))
print("best plan:", best_wp.numpy())
print("pole angle every 0.2 s (0 = upright):", th)
print(f"min |angle - 0| during the plan: {np.abs(np.angle(np.exp(1j * th))).min():.3f} rad")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "nelite": NELITE, "knots": KNOTS, "hold": HOLD,
                   "dt": float(mjm.opt.timestep), "iters": hist,
                   "theta_final": np.round(th, 3).tolist(),
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
