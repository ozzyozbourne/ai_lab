"""Example 8.11 - worlds as parallel rollouts: random-shooting MPC on CARTPOLE.

All NWORLD worlds hold the same state. Each MPC iteration: snapshot, give every world its own
random action sequence, roll out H steps while a kernel sums an "upright" reward per world,
pick the best world on the device, restore the snapshot, apply that world's first action for
one control interval in every world (so the worlds stay identical), repeat.
Run: python ex11_mpc_rollouts.py [--dump-json PATH]
  --dump-json PATH writes, per iteration, the pole angle along 15 sampled rollouts plus the
  chosen one (Rule D, MPC fan figure).
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
NWORLD = 1024 if ON_GPU else 64   # number of sampled action sequences
HOLD = 5                          # physics steps per control knot (zero-order hold)
KNOTS = 10                        # horizon H = KNOTS * HOLD = 50 steps = 0.5 s
NITER = 20                        # MPC iterations; each applies one knot (5 steps)
THETA0 = 0.4                      # start with the pole tilted 0.4 rad from upright


# --- the helpers this chapter adds to my_env.py (same code as my_env_step08.py) ---
def snapshot(m, d, mjm, sig, buf=None):
    size = mujoco.mj_stateSize(mjm, int(sig))
    if buf is None:
        buf = wp.zeros((d.nworld, size), dtype=float)
    assert buf.shape == (d.nworld, size), f"state buffer {buf.shape} != {(d.nworld, size)}"
    mjw.get_state(m, d, buf, int(sig))
    return buf


def restore(m, d, mjm, buf, sig, active=None):
    assert buf.shape == (d.nworld, mujoco.mj_stateSize(mjm, int(sig)))
    mjw.set_state(m, d, buf, int(sig), active)


# --- MPC kernels (all on the device) ---
@wp.kernel
def sample_actions(seed: int, it: int, actions_out: wp.array2d[float]):
    worldid, k = wp.tid()
    rng = wp.rand_init(seed, (it * 65536 + worldid) * 64 + k)
    a = wp.randf(rng, -1.0, 1.0)
    if worldid == 0:
        a = 0.0                     # world 0 always tries "do nothing" as a baseline
    actions_out[worldid, k] = a


@wp.kernel
def set_ctrl(actions_in: wp.array2d[float], k: int, ctrl_out: wp.array2d[float]):
    worldid = wp.tid()
    ctrl_out[worldid, 0] = actions_in[worldid, k]


@wp.kernel
def add_reward(qpos_in: wp.array2d[float], ctrl_in: wp.array2d[float],
               score_out: wp.array[float]):
    worldid = wp.tid()
    x = qpos_in[worldid, 0]
    theta = qpos_in[worldid, 1]    # 0 = upright
    u = ctrl_in[worldid, 0]
    score_out[worldid] += wp.cos(theta) - 0.05 * x * x - 0.01 * u * u   # weak cart term, see below


@wp.kernel
def argmax_world(score_in: wp.array[float], nworld: int, best_out: wp.array[int]):
    best = int(0)
    for w in range(1, nworld):      # one thread; fine for a few thousand worlds
        if score_in[w] > score_in[best]:
            best = w
    best_out[0] = best


@wp.kernel
def apply_best(actions_in: wp.array2d[float], best_in: wp.array[int],
               ctrl_out: wp.array2d[float]):
    worldid = wp.tid()
    ctrl_out[worldid, 0] = actions_in[best_in[0], 0]   # same first action in every world


mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 1] = THETA0
d.qpos.assign(qpos)

SIG = mjw.State.TIME | mjw.State.PHYSICS     # PHYSICS has no TIME bit; add it so d.time
buf = snapshot(m, d, mjm, SIG)               # is restored too. Allocated once, reused.
actions = wp.zeros((NWORLD, KNOTS), dtype=float)
score = wp.zeros(NWORLD, dtype=float)
best = wp.zeros(1, dtype=int)
print("state size per world:", buf.shape[1], f"(TIME 1 + nq {mjm.nq} + nv {mjm.nv})")

angles, chosen, fans, xs = [THETA0], [], [], [0.0]
for it in range(NITER):
    snapshot(m, d, mjm, SIG, buf)                                     # 1. snapshot
    wp.launch(sample_actions, dim=(NWORLD, KNOTS), inputs=[7, it], outputs=[actions])
    score.zero_()
    fan = [d.qpos.numpy()[:, 1].copy()] if args.dump_json else []
    for k in range(KNOTS):                                            # 2. roll out H steps
        wp.launch(set_ctrl, dim=NWORLD, inputs=[actions, k], outputs=[d.ctrl])
        for _ in range(HOLD):
            mjw.step(m, d)
            wp.launch(add_reward, dim=NWORLD, inputs=[d.qpos, d.ctrl], outputs=[score])
        if args.dump_json:
            fan.append(d.qpos.numpy()[:, 1].copy())
    wp.launch(argmax_world, dim=1, inputs=[score, NWORLD], outputs=[best])  # 3. choose
    restore(m, d, mjm, buf, SIG)                                      # 4. restore
    wp.launch(apply_best, dim=NWORLD, inputs=[actions, best], outputs=[d.ctrl])
    for _ in range(HOLD):                                             # 5. apply one knot
        mjw.step(m, d)
    # host reads below are for printing only (one small copy per iteration)
    angles.append(float(d.qpos.numpy()[0, 1]))
    xs.append(float(d.qpos.numpy()[0, 0]))
    chosen.append(float(actions.numpy()[best.numpy()[0], 0]))
    if args.dump_json:
        b = int(best.numpy()[0])
        rows = [w for w in range(15) if w != b] + [b]      # 15 sampled rollouts + the best
        fan_np = np.array(fan)                              # (KNOTS + 1, NWORLD)
        fans.append({"rollouts": np.round(fan_np[:, rows].T, 3).tolist(), "best_world": b,
                     "theta": round(angles[-1], 3)})

q = d.qpos.numpy()
t_now = round(float(d.time.numpy()[0]), 3)
print("worlds identical after MPC:", bool(np.all(q == q[0])), "| time:", t_now)
print("chosen first actions:", np.array(chosen[:10]), "...")
print("pole angle every 0.05 s [rad]:")
print(np.array(angles))
# the cost penalises x only weakly (0.05 x^2) over a 0.5 s horizon: the cart drifts toward the
# +-1.8 m slider limit, which it reaches after about 1.8 s if you raise NITER to 40
print(f"cart x after {t_now} s: {xs[-1]:+.3f} m (max |x| {max(abs(v) for v in xs):.3f} m, limit 1.8 m)")

# baseline: same start, zero force
mjw.reset_data(m, d)
d.qpos.assign(qpos)
for _ in range(NITER * HOLD):
    mjw.step(m, d)
print(f"without control after {NITER * HOLD * mjm.opt.timestep:.1f} s: pole angle =",
      round(float(d.qpos.numpy()[0, 1]), 3))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "hold": HOLD, "knots": KNOTS,
                   "dt": float(mjm.opt.timestep), "theta": [round(a, 3) for a in angles],
                   "iters": fans}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(fans), "iterations")
