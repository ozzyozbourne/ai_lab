"""Example 3.6 - integrating an orientation: the quaternion exponential vs "add and renormalize".

A body spins with a constant angular velocity w (body frame, 10 rad/s) for 1000 steps of 0.01 s.
  exact update : q <- q * exp(w dt / 2)              (what MuJoCo and MJWarp do)
  naive update : q <- q + dt * 0.5 * q * (0, w), then divide by |q|
We print the angle error of each against the closed-form answer, and the norm of the naive
quaternion before renormalization. Then we run MJWarp's own math.quat_integrate (private API)
inside a small Warp kernel, and C MuJoCo's mju_quatIntegrate, and check they agree.
Run: python ex6_quat_integrate.py [--dump-json PATH]
  --dump-json PATH writes the angle error per step for the page's chart (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
from mujoco_warp._src import math as mjw_math      # private API: the name may change

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

DT, NSTEP = 0.01, 1000
W = np.array([2.0, -3.0, 9.0])
W = 10.0 * W / np.linalg.norm(W)                     # |w| = 10 rad/s about a tilted axis
Q0 = np.array([np.cos(0.4), np.sin(0.4), 0.0, 0.0])  # start rotated 0.8 rad about x


def qmul(a, b):
    """Hamilton product of (w, x, y, z) quaternions (same formula as math.mul_quat)."""
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return np.array([w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
                     w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
                     w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
                     w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2])


def qexp(rotvec):
    """Unit quaternion of a rotation by |rotvec| about rotvec / |rotvec|."""
    angle = np.linalg.norm(rotvec)
    if angle < 1e-12:
        return np.array([1.0, 0.0, 0.0, 0.0])
    return np.concatenate([[np.cos(angle / 2)], np.sin(angle / 2) * rotvec / angle])


def angle_between(a, b):
    """Rotation angle that takes a to b (q and -q are the same rotation, hence abs)."""
    rel = qmul(a * np.array([1.0, -1.0, -1.0, -1.0]), b) / np.linalg.norm(a) / np.linalg.norm(b)
    return 2 * np.arctan2(np.linalg.norm(rel[1:]), abs(rel[0]))


q_exact, q_naive, q_raw = Q0.copy(), Q0.copy(), Q0.copy()
err_exact, err_naive, norms = [], [], []
for n in range(1, NSTEP + 1):
    q_exact = qmul(q_exact, qexp(W * DT))                       # exponential map
    q_naive = q_naive + DT * 0.5 * qmul(q_naive, np.r_[0.0, W])  # first-order derivative step
    norms.append(np.linalg.norm(q_naive))
    q_naive = q_naive / np.linalg.norm(q_naive)                 # renormalize
    q_raw = q_raw + DT * 0.5 * qmul(q_raw, np.r_[0.0, W])       # same, never renormalized
    q_true = qmul(Q0, qexp(W * DT * n))                         # closed form for constant w
    err_exact.append(angle_between(q_exact, q_true))
    err_naive.append(angle_between(q_naive, q_true))

print(f"|w| = {np.linalg.norm(W):.1f} rad/s, dt = {DT}, {NSTEP} steps (t = {NSTEP * DT:.0f} s, "
      f"{np.linalg.norm(W) * NSTEP * DT / (2 * np.pi):.1f} turns)")
print(f"exact exp update  : final angle error = {err_exact[-1]:.2e} rad")
print(f"naive + normalize : final angle error = {err_naive[-1]:.4f} rad "
      f"({np.degrees(err_naive[-1]):.2f} deg)")
print(f"naive |q| before each renormalization = {norms[0]:.6f} (sqrt(1 + (|w| dt / 2)^2) = "
      f"{np.sqrt(1 + (np.linalg.norm(W) * DT / 2) ** 2):.6f})")
print(f"naive without renormalizing: |q| = {np.linalg.norm(q_raw):.3f} after {NSTEP} steps")


@wp.kernel
def spin_kernel(q0: wp.array(dtype=wp.quat), w: wp.vec3, dt: float, nstep: int,
                q_out: wp.array(dtype=wp.quat)):
    q = q0[0]                              # MJWarp keeps (w, x, y, z) in a wp.quat (Ch 4)
    for _ in range(nstep):
        q = mjw_math.quat_integrate(q, w, dt)
    q_out[0] = q


q_in = wp.array([wp.quat(*Q0.astype(np.float32))], dtype=wp.quat)
q_out = wp.zeros(1, dtype=wp.quat)
wp.launch(spin_kernel, dim=1, inputs=[q_in, wp.vec3(*W.astype(np.float32)), DT, NSTEP],
          outputs=[q_out])
q_mjw = q_out.numpy()[0].astype(np.float64)

q_c = Q0.copy()
for _ in range(NSTEP):
    mujoco.mju_quatIntegrate(q_c, W, DT)   # C MuJoCo: q <- q * exp(W * DT / 2)

print("closed form       :", qmul(Q0, qexp(W * DT * NSTEP)))
print("MJWarp float32    :", q_mjw, f" error {angle_between(q_mjw, q_true):.1e} rad")
print("C MuJoCo float64  :", q_c, f" error {angle_between(q_c, q_true):.1e} rad")

if args.dump_json:
    idx = list(range(9, NSTEP, 10))
    with open(args.dump_json, "w") as f:
        json.dump({"dt": DT, "step": [i + 1 for i in idx],
                   "exact": [float(f"{err_exact[i]:.3e}") for i in idx],
                   "naive": [round(err_naive[i], 5) for i in idx],
                   "mjwarp_final": float(f"{angle_between(q_mjw, q_true):.2e}"),
                   "mujoco_final": float(f"{angle_between(q_c, q_true):.2e}")},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
