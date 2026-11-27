"""Example 8.10 - device-side auto-reset: a done kernel, a masked reset, and a non-finite guard.

BALL_DROP with a random initial velocity per episode. An episode ends when the ball lands
(z < 0.15), when it lasts longer than 0.8 s, or when qpos/qvel is not finite (MJWarp has no
mj_checkPos/mj_checkVel). Done worlds are reset, re-randomized and recomputed on the device every step;
no host read is needed inside the loop. World 1 gets a NaN injected once to test the guard.
Run: python ex10_auto_reset.py [--dump-json PATH]
  --dump-json PATH writes decimated ball heights and done flags of 8 worlds (Rule D, timeline).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 5000 if ON_GPU else 1000   # 10 s / 2 s of simulated time


# --- the helpers this chapter adds to my_env.py (same code as my_env_step08.py) ---
@wp.kernel
def _nonfinite_kernel(qpos_in: wp.array2d[float], qvel_in: wp.array2d[float],
                      done_out: wp.array[bool]):
    worldid = wp.tid()
    bad = bool(False)
    for i in range(qpos_in.shape[1]):
        if not wp.isfinite(qpos_in[worldid, i]):
            bad = True
    for i in range(qvel_in.shape[1]):
        if not wp.isfinite(qvel_in[worldid, i]):
            bad = True
    if bad:
        done_out[worldid] = True          # only ever sets flags; never clears another reason


def reset_done(m, d, done, randomize=None):
    """Reset the worlds whose done flag is True, randomize them, then recompute derived quantities."""
    mjw.reset_data(m, d, reset=done)      # bool mask of shape (nworld,): no host sync
    if randomize is not None:
        randomize(m, d, done)             # before forward, so forward sees the final state
    mjw.forward(m, d)                     # reset does not recompute xpos, sensors, ...
    # forward runs on ALL worlds, every call, even when no world is done: about one extra pipeline
    # pass per step. Unconditional on purpose: no host branch, so the loop stays graph-capturable.


def nonfinite_reset(m, d, done):
    """Mark worlds with NaN/Inf in qpos or qvel as done (in place, OR-ed into `done`)."""
    wp.launch(_nonfinite_kernel, dim=d.nworld, inputs=[d.qpos, d.qvel], outputs=[done])


# --- task-specific kernels ---
@wp.kernel
def done_kernel(qpos_in: wp.array2d[float], time_in: wp.array[float], z_min: float, t_max: float,
                done_out: wp.array[bool], reason_out: wp.array2d[int]):
    worldid = wp.tid()
    landed = qpos_in[worldid, 2] < z_min
    timeout = time_in[worldid] > t_max
    done_out[worldid] = landed or timeout
    if landed:
        reason_out[worldid, 0] += 1
    elif timeout:
        reason_out[worldid, 1] += 1


@wp.kernel
def count_nonfinite(qpos_in: wp.array2d[float], qvel_in: wp.array2d[float],
                    reason_out: wp.array2d[int]):
    worldid = wp.tid()
    if not (wp.isfinite(qpos_in[worldid, 2]) and wp.isfinite(qvel_in[worldid, 2])):
        reason_out[worldid, 2] += 1


@wp.kernel
def randomize_velocity(done_in: wp.array[bool], seed: int, episode_in: wp.array[int],
                       qvel_out: wp.array2d[float]):
    worldid = wp.tid()
    if not done_in[worldid]:
        return
    episode_in[worldid] += 1
    rng = wp.rand_init(seed, worldid * 100003 + episode_in[worldid])
    qvel_out[worldid, 0] = wp.randf(rng, -1.0, 1.0)  # vx
    qvel_out[worldid, 1] = wp.randf(rng, -1.0, 1.0)  # vy
    qvel_out[worldid, 2] = wp.randf(rng, 0.0, 4.0)   # vz (up)


mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)

done = wp.ones(NWORLD, dtype=bool)          # allocate everything before the loop
episode = wp.zeros(NWORLD, dtype=int)       # episode counter, also the RNG stream id
reason = wp.zeros((NWORLD, 3), dtype=int)   # landed, timeout, non-finite


def randomize(m, d, done):
    """Per-episode randomization of the done worlds (passed to reset_done)."""
    wp.launch(randomize_velocity, dim=NWORLD, inputs=[done, 42, episode], outputs=[d.qvel])


randomize(m, d, done)                       # first episode of every world

frames = []
done_since = np.zeros(8, dtype=bool)
for i in range(NSTEP):
    mjw.step(m, d)
    if i == 300:                                  # inject a blow-up in world 1 (test only)
        q = d.qvel.numpy()
        q[1, 2] = np.nan
        d.qvel.assign(q)
    wp.launch(done_kernel, dim=NWORLD, inputs=[d.qpos, d.time, 0.15, 0.8],
              outputs=[done, reason])
    wp.launch(count_nonfinite, dim=NWORLD, inputs=[d.qpos, d.qvel], outputs=[reason])
    nonfinite_reset(m, d, done)                   # NaN worlds join the done mask
    reset_done(m, d, done, randomize)             # masked reset, re-randomize, forward
    if args.dump_json:                            # host reads for the figure only
        done_since |= done.numpy()[:8]            # remember resets between sampled frames
        if i % 10 == 9:
            z = d.qpos.numpy()[:8, 2]
            frames.append([[round(float(z[w]), 3), int(done_since[w])] for w in range(8)])
            done_since[:] = False
wp.synchronize()

r = reason.numpy()
print(f"{NSTEP} steps = {NSTEP * mjm.opt.timestep:.1f} s per world")
print("episodes finished per world:", r[:8].sum(axis=1))
print("  landed  (z < 0.15):        ", r[:8, 0])
print("  timeout (t > 0.8 s):       ", r[:8, 1])
print("  non-finite (NaN guard):    ", r[:8, 2])
print("all worlds finite now:", bool(np.isfinite(d.qpos.numpy()).all()))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": 8, "dt": 10 * float(mjm.opt.timestep), "kind": "episodes",
                   "labels": ["ball z", "done in the last 10 steps"], "nan_world": 1, "nan_step": 300,
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
