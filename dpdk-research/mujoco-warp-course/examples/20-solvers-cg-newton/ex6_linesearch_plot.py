"""Example 20.6 - the exact linesearch along MJWarp's first CG search direction.

Cold-started CG on box_stack(5) two steps after a small random kick (12 contact rows while the
bottom box meets the floor). Its first search direction is
search = -M^-1 grad(qacc_smooth). We evaluate the ray cost phi(alpha) = f(qacc_smooth + alpha *
search) in NumPy: a convex piecewise quadratic with a kink wherever a row J_i a - aref_i changes
sign. We find its exact minimizer by walking the kinks, replay MJWarp's bracketing algorithm
(_linesearch_iterative_kernel: a Newton probe from 0, then rounds of three probes lo / hi / mid)
in NumPy, and compare both with the alpha that MJWarp took (one CG iteration, iterations=1).
Run: python ex6_linesearch_plot.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
d.qvel.assign(np.random.default_rng(1).normal(0.0, 0.1, size=(1, mjm.nv)).astype(np.float32))
for _ in range(2):
    mjw.step(m, d)

mjm.opt.solver = mujoco.mjtSolver.mjSOL_CG
m = mjw.put_model(mjm)
m.opt.disableflags |= mjw.DisableBit.WARMSTART
m.opt.warn_overflow = 0
m.opt.iterations = 1                          # exactly one linesearch
mjw.forward(m, d)

mjd = mujoco.MjData(mjm)
mjw.get_data_into(mjd, mjm, d)
M = np.zeros((mjm.nv, mjm.nv))
mujoco.mj_fullM(mjm, mjd, M)
n = int(d.nefc.numpy()[0])
J = d.efc.J.numpy()[0, :n, :mjm.nv].astype(np.float64)
D = d.efc.D.numpy()[0, :n].astype(np.float64)
aref = d.efc.aref.numpy()[0, :n].astype(np.float64)
a0 = d.qacc_smooth.numpy()[0].astype(np.float64)
a1 = d.qacc.numpy()[0].astype(np.float64)

jaref0 = J @ a0 - aref
grad0 = J.T @ (D * (jaref0 < 0) * jaref0)     # Gauss term is 0 at qacc_smooth
s = -np.linalg.solve(M, grad0)                # CG's first direction: -M^-1 grad
jv = J @ s
alpha_mjw = (a1 - a0) @ s / (s @ s)


def phi(t):
    """Ray cost relative to t=0, its slope and curvature (what the kernel's probes return)."""
    x = jaref0 + t * jv
    act, act0 = x < 0, jaref0 < 0
    c = 0.5 * t * t * (s @ M @ s) + 0.5 * np.sum(D[act] * x[act] ** 2) \
        - 0.5 * np.sum(D[act0] * jaref0[act0] ** 2)
    g = t * (s @ M @ s) + np.sum(D[act] * jv[act] * x[act])
    h = s @ M @ s + np.sum(D[act] * jv[act] ** 2)
    return np.array([c, g, h])


# exact minimizer: the slope is piecewise linear and increasing; find its zero
with np.errstate(divide="ignore", invalid="ignore"):
    kinks = np.where(jv != 0, -jaref0 / jv, np.inf)
kinks = np.sort(kinks[(kinks > 0) & np.isfinite(kinks)])
edges = np.concatenate([[0.0], kinks, [kinks[-1] * 2 + 1.0]])
t_exact = None
for lo, hi in zip(edges[:-1], edges[1:]):
    mid = phi(0.5 * (lo + hi))
    t = 0.5 * (lo + hi) - mid[1] / mid[2]
    if lo <= t <= hi:
        t_exact = t
        break

# NumPy replay of the kernel's bracketing (gtol as in the kernel; noise-floor terms omitted)
tol, ls_tol = 1e-6, 0.01
scale = 1.0 / np.trace(M)
gtol = tol * ls_tol * np.linalg.norm(s) / scale
p0 = phi(0.0)
p0_delta = np.array([0.0, p0[1], p0[2]])
frames = [{"what": "p0", "alpha": 0.0, "pt": p0.tolist()}]
lo_alpha_in = -p0[1] / p0[2]
lo_in = phi(lo_alpha_in)
frames.append({"what": "newton_from_0", "alpha": lo_alpha_in, "pt": lo_in.tolist()})


def in_bracket(x, y):
    return (x[1] < y[1] < 0) or (x[1] > y[1] > 0)


alpha, rounds = 0.0, 0
if abs(lo_in[1]) < gtol and lo_in[0] < 0:
    alpha = lo_alpha_in
else:
    lo_less = lo_in[1] < p0[1]
    lo, lo_a = (lo_in, lo_alpha_in) if lo_less else (p0_delta, 0.0)
    hi, hi_a = (p0_delta, 0.0) if lo_less else (lo_in, lo_alpha_in)
    for rounds in range(1, 51):               # m.opt.ls_iterations = 50
        a_lo, a_hi, a_mid = lo_a - lo[1] / lo[2], hi_a - hi[1] / hi[2], 0.5 * (lo_a + hi_a)
        p_lo, p_hi, p_mid = phi(a_lo), phi(a_hi), phi(a_mid)
        frames.append({"what": "round", "round": rounds, "lo": lo_a, "hi": hi_a,
                       "probes": [[a_lo] + p_lo.tolist(), [a_hi] + p_hi.tolist(),
                                  [a_mid] + p_mid.tolist()]})
        conv = [(p[0], a) for p, a in ((p_lo, a_lo), (p_hi, a_hi), (p_mid, a_mid))
                if abs(p[1]) < gtol and p[0] < 0]
        if conv:
            alpha = min(conv)[1]
            break
        sw_lo = sw_hi = False
        for p, a in ((p_lo, a_lo), (p_mid, a_mid), (p_hi, a_hi)):
            if in_bracket(lo, p):
                lo, lo_a, sw_lo = p, a, True
        for k, (p, a) in enumerate(((p_hi, a_hi), (p_mid, a_mid), (p_lo, a_lo))):
            if in_bracket(hi, p) or (k == 0 and hi[1] < 0 < p[1]):
                hi, hi_a, sw_hi = p, a, True
        alpha = lo_a if lo[0] < hi[0] else hi_a
        if not sw_lo and not sw_hi:
            break

print(f"nefc={n}, kinks on the ray at alpha > 0: {len(kinks)} (first {kinks[0]:.4f}, "
      f"last {kinks[-1]:.4f})")
print(f"slope at 0: {p0[1]:.4e}  (negative: search is a descent direction)")
print(f"Newton probe from 0 (one quadratic piece): alpha = {lo_alpha_in:.5f}, "
      f"slope there {lo_in[1]:+.3e}, |slope| < gtol={gtol:.3e}? {abs(lo_in[1]) < gtol}")
print(f"bracketing rounds used: {rounds}  -> alpha = {alpha:.5f}")
print(f"exact minimizer (kink walk):       alpha = {t_exact:.5f}")
print(f"MJWarp's step (qacc1 - qacc0)/search: alpha = {alpha_mjw:.5f}")
print(f"cost drop phi(alpha_mjw) = {phi(alpha_mjw)[0]:.2f}  vs exact {phi(t_exact)[0]:.2f}")

if args.dump_json:
    ts = np.linspace(0.0, 1.6 * t_exact, 161)
    curve = [[round(float(t), 5), round(float(phi(t)[0]), 3)] for t in ts]
    with open(args.dump_json, "w") as f:
        json.dump({"curve": curve, "kinks": [round(float(k), 5) for k in kinks if k < ts[-1]],
                   "frames": json.loads(json.dumps(frames, default=float)),
                   "alpha_exact": round(float(t_exact), 6), "alpha_mjw": round(float(alpha_mjw), 6),
                   "gtol": float(gtol)}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
