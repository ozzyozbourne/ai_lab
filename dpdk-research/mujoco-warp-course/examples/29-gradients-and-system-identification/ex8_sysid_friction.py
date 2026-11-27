"""Example 29.8 - identify sliding friction from a box sliding down a slope (contacts).

The "real" box (float64 C MuJoCo) slides down a 30 degree slope with a hidden friction
coefficient; we record its distance along the slope (1 mm sensor noise). Every MJWarp world
gets one candidate mu in a batched geom_friction (Ch 10 sec. 3): a friction change needs no
set_const. One batched rollout scores all candidates; each round keeps the best and shrinks the
search interval around it (grid refinement). World 0 re-scores the best value so far.
Run: python ex8_sysid_friction.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

SLOPE_DEG = 30.0
n = np.array([np.sin(np.radians(SLOPE_DEG)), 0.0, np.cos(np.radians(SLOPE_DEG))])  # plane normal
p0 = 0.101 * n                                    # box centre: half-size + 1 mm above the plane
SLOPE = f"""
<mujoco model="slope">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="slope" type="plane" size="5 5 .1" euler="0 {SLOPE_DEG} 0"/>
    <body name="box" pos="{p0[0]:.5f} 0 {p0[2]:.5f}" euler="0 {SLOPE_DEG} 0">
      <freejoint/>
      <geom name="box" type="box" size=".1 .1 .1" mass="1" rgba=".3 .3 1 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 16                   # candidates per round
NROUND = 4
T = 200                                           # 1 s at dt = 0.005
TRUE_MU = 0.35                                    # hidden
DOWN = np.array([np.cos(np.radians(SLOPE_DEG)), 0.0, -np.sin(np.radians(SLOPE_DEG))])  # downhill

mjm = mujoco.MjModel.from_xml_string(SLOPE)

# ---- 1. the "real" recording: C MuJoCo, float64, sensor noise ----
real = mujoco.MjModel.from_xml_string(SLOPE)
real.geom_friction[:, 0] = TRUE_MU
rd = mujoco.MjData(real)
obs = np.zeros(T)
for t in range(T):
    mujoco.mj_step(real, rd)
    obs[t] = (rd.qpos[:3] - mjm.qpos0[:3]) @ DOWN  # distance travelled downhill
obs += np.random.default_rng(0).normal(0.0, 0.001, T)
print(f"real box: {obs[-1]:.3f} m downhill after {T * mjm.opt.timestep:.1f} s")


@wp.kernel
def add_loss(qpos_in: wp.array2d[float], p0: wp.vec3, down: wp.vec3, obs_in: wp.array[float],
             t: int, loss_out: wp.array[float]):
    w = wp.tid()
    p = wp.vec3(qpos_in[w, 0], qpos_in[w, 1], qpos_in[w, 2])
    e = wp.dot(p - p0, down) - obs_in[t]
    loss_out[w] += e * e


m = mjw.put_model(mjm, batch_sizes={"geom_friction": NWORLD})
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
obs_wp = wp.array(obs, dtype=float)
loss = wp.zeros(NWORLD, dtype=float)
P0, DN = wp.vec3(*mjm.qpos0[:3]), wp.vec3(*DOWN)


def evaluate(mu):
    fr = m.geom_friction.numpy()
    fr[:, :, 0] = mu[:, None]                     # slope AND box (contacts take the max)
    m.geom_friction.assign(fr)
    mjw.reset_data(m, d)                          # qpos0, zero qvel, zero warmstart
    loss.zero_()
    for t in range(T):
        mjw.step(m, d)
        wp.launch(add_loss, dim=NWORLD, inputs=[d.qpos, P0, DN, obs_wp, t], outputs=[loss])
    return np.sqrt(loss.numpy() / T)              # rms distance error [m]


lo, hi, best = 0.05, 0.55, 0.3                   # prior interval, any starting guess
curves = []
for r in range(NROUND):
    mu = np.concatenate([[best], np.linspace(lo, hi, NWORLD - 1)])
    err = evaluate(mu)
    b = int(err.argmin())
    best, step = mu[b], (hi - lo) / (NWORLD - 2)
    curves.append({"mu": np.round(mu[1:], 5).tolist(), "err": np.round(err[1:], 5).tolist()})
    print(f"round {r}: mu in [{lo:.4f}, {hi:.4f}] step {step:.4f} -> best mu "
          f"{best:.4f}, rms error {err[b] * 1000:.2f} mm")
    lo, hi = max(best - 2 * step, 0.0), best + 2 * step   # zoom to +- two grid steps
print(f"recovered mu = {best:.4f} (true {TRUE_MU})")
print(f"Coulomb check: tan(slope) = {np.tan(np.radians(SLOPE_DEG)):.3f} > mu, so the box slides")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "T": T, "truth": TRUE_MU, "rounds": curves,
                   "fit": round(float(best), 5)}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
