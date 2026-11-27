"""Example 7.11 - Part I checkpoint: a dashboard of many bouncing balls.

NWORLD balls (10,240 on a GPU) start at random heights with random velocities and bounce for 2 s.
Everything from Part I comes together: one Model, a batched Data, per-world initial state with
.assign(), mjw.step in a loop, a custom Warp kernel that counts bounces on the device (no .numpy()
in the loop), contact sizing with an overflow check, and a summary plus a 4-panel figure.
The ball model is M1 BALL_DROP with a bouncier contact (solref="0.02 0.1": low damping ratio).
Run: python ex11_checkpoint_dashboard.py [--dump-json PATH] [--dump-png DIR]
  --dump-json PATH  traces, histograms and the height/bounce scatter for the page's dashboard
  --dump-png DIR    also save the 4-panel matplotlib figure as DIR/ex11_dashboard.png
"""
import argparse
import json
import os
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

BOUNCY_BALLS = """
<mujoco model="bouncy_balls">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1" solref="0.02 0.1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1" solref="0.02 0.1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 10240 if ON_GPU else 64
NSTEP = 1000                     # 2 s at timestep 0.002 (same on CPU and GPU)
EVERY = 10                       # keep a height sample every 10 steps (0.02 s)
RADIUS = 0.1


@wp.kernel
def count_bounces(qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
                  prev_vz: wp.array(dtype=float), bounces: wp.array(dtype=int),
                  min_z: wp.array(dtype=float)):
    w = wp.tid()                                      # one thread per world
    z, vz = qpos[w, 2], qvel[w, 2]
    if prev_vz[w] < -0.05 and vz >= 0.0 and z < RADIUS + 0.02:
        bounces[w] += 1                               # falling -> rising, at the floor
    prev_vz[w] = vz
    min_z[w] = wp.min(min_z[w], z)


@wp.kernel
def record_height(qpos: wp.array2d(dtype=float), frame: int, out: wp.array2d(dtype=float)):
    w = wp.tid()
    out[frame, w] = qpos[w, 2]


mjm = mujoco.MjModel.from_xml_string(BOUNCY_BALLS)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=2, njmax=8)    # 1 contact = 4 pyramidal rows

rng = np.random.default_rng(7)
h0 = rng.uniform(0.3, 2.0, NWORLD).astype(np.float32)        # start heights [m]
qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = h0
qvel = np.zeros((NWORLD, mjm.nv), np.float32)
qvel[:, 0:2] = rng.normal(0.0, 0.5, (NWORLD, 2))             # sideways drift
qvel[:, 2] = rng.uniform(-1.0, 1.0, NWORLD)                  # initial vertical speed
d.qpos.assign(qpos)
d.qvel.assign(qvel)

prev_vz = wp.zeros(NWORLD, dtype=float)
bounces = wp.zeros(NWORLD, dtype=int)
min_z = wp.full(NWORLD, 10.0, dtype=float)
heights = wp.zeros((NSTEP // EVERY, NWORLD), dtype=float)

mjw.step(m, d)                                               # warm-up (JIT) outside the clock
wp.launch(count_bounces, dim=NWORLD, inputs=[d.qpos, d.qvel, prev_vz, bounces, min_z])
wp.synchronize()
t0 = time.perf_counter()
for i in range(1, NSTEP):
    mjw.step(m, d)
    wp.launch(count_bounces, dim=NWORLD, inputs=[d.qpos, d.qvel, prev_vz, bounces, min_z])
    if i % EVERY == 0:
        wp.launch(record_height, dim=NWORLD, inputs=[d.qpos, i // EVERY, heights])
wp.synchronize()
wall = time.perf_counter() - t0

b = bounces.numpy()
zf = d.qpos.numpy()[:, 2]
zmin = min_z.numpy()
H = heights.numpy()
print(f"device: {wp.get_device()} | nworld: {NWORLD} | {NSTEP} steps = "
      f"{NSTEP * mjm.opt.timestep:.1f} s simulated")
print(f"bounces per world: mean {b.mean():.2f}, min {b.min()}, max {b.max()}")
print("bounce count histogram:", {int(k): int(v) for k, v in zip(*np.unique(b, return_counts=True))})
edges = np.array([0.0, 0.11, 0.25, 0.5, 1.0, 3.0])
counts, _ = np.histogram(zf, bins=edges)
print("final z histogram:", {f"{edges[k]:.2f}-{edges[k + 1]:.2f}": int(c) for k, c in enumerate(counts)})
print(f"deepest penetration: {RADIUS - zmin.min():.4f} m (ball radius {RADIUS} m)")
print(f"corr(start height, bounces): {np.corrcoef(h0, b)[0, 1]:.2f}")
print(f"wall time {wall:.2f} s -> {NWORLD * (NSTEP - 1) / wall:,.0f} world-steps/s "
      f"({'GPU' if ON_GPU else 'CPU: not a GPU number'})")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    show = min(NWORLD, 8)
    out = {"nworld": NWORLD, "dt": EVERY * float(mjm.opt.timestep), "device": str(wp.get_device()),
           "traces": [[round(float(v), 3) for v in H[1:, w]] for w in range(show)],
           "bounce_hist": {int(k): int(v) for k, v in zip(*np.unique(b, return_counts=True))},
           "z_edges": edges.tolist(), "z_counts": counts.tolist(),
           "scatter": [[round(float(h0[w]), 3), int(b[w])] for w in range(min(NWORLD, 256))],
           "steps_per_s": round(NWORLD * (NSTEP - 1) / wall)}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    plt = None
    print("skipped: matplotlib not installed")
if plt is not None:
    fig, ax = plt.subplots(2, 2, figsize=(9, 6.5))
    t = np.arange(1, H.shape[0]) * EVERY * mjm.opt.timestep
    for w in range(min(NWORLD, 8)):
        ax[0, 0].plot(t, H[1:, w], lw=1)
    ax[0, 0].set(title="height of 8 worlds", xlabel="t [s]", ylabel="z [m]")
    ks, vs = np.unique(b, return_counts=True)
    ax[0, 1].bar(ks, vs, color="#4e79a7")
    ax[0, 1].set(title="bounces per world", xlabel="bounces in 2 s", ylabel="worlds")
    ax[1, 0].bar(range(len(counts)), counts, color="#59a14f",
                 tick_label=[f"{edges[k]:.2f}-\n{edges[k + 1]:.2f}" for k in range(len(counts))])
    ax[1, 0].set(title="final height", xlabel="z [m]", ylabel="worlds")
    ax[1, 1].scatter(h0, b + rng.uniform(-0.15, 0.15, NWORLD), s=6, alpha=0.6, color="#f28e2b")
    ax[1, 1].set(title="start height vs bounces", xlabel="h0 [m]", ylabel="bounces (jittered)")
    fig.suptitle(f"{NWORLD} bouncing balls, mujoco-warp {mjw.__version__}, {wp.get_device()}")
    fig.tight_layout()
    path = os.path.join(args.dump_png or ".", "ex11_dashboard.png")
    if args.dump_png:
        os.makedirs(args.dump_png, exist_ok=True)
    fig.savefig(path, dpi=80)
    print("saved", path)
