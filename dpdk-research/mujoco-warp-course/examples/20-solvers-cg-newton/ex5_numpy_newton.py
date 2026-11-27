"""Example 20.5 - a reference primal Newton solver in NumPy, checked against MJWarp's qacc.

We take the problem MJWarp builds for one world (M from mj_fullM, efc.J, efc.D, efc.aref and
qacc_smooth: the same arrays Ch 19 Example 19.3 used to rebuild the cost) and minimize
  f(a) = 0.5 (a - a0)' M (a - a0) + sum_i 0.5 D_i min(0, J_i a - aref_i)^2     (pyramidal rows)
with Newton's method: H = M + J' diag(D * active) J, search = -H^-1 grad, then an EXACT 1-D
linesearch that walks the kinks of the piecewise quadratic f(a + alpha * search) in order.
Both solvers start from qacc_smooth (warmstart off), so their iterates can be compared one by one.
Run: python ex5_numpy_newton.py
"""
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


def cost_grad(a, P):
    jaref = P["J"] @ a - P["aref"]
    act = jaref < 0.0
    da = a - P["a0"]
    cost = 0.5 * da @ P["M"] @ da + 0.5 * np.sum(P["D"][act] * jaref[act] ** 2)
    grad = P["M"] @ da + P["J"].T @ (P["D"] * act * jaref)
    return cost, grad, act


def exact_linesearch(a, s, P):
    """Minimize the convex piecewise quadratic phi(t) = f(a + t s) exactly, kink by kink."""
    jaref, jv = P["J"] @ a - P["aref"], P["J"] @ s
    g0 = s @ P["M"] @ (a - P["a0"])          # Gauss part of phi'(t) = g0 + t * h0
    h0 = s @ P["M"] @ s
    with np.errstate(divide="ignore", invalid="ignore"):
        kinks = np.where(jv != 0.0, -jaref / jv, np.inf)
    pts = np.sort(kinks[kinks > 0.0])
    lo = 0.0
    for hi in np.append(pts, np.inf):        # on (lo, hi) the active set is fixed
        t_mid = lo + 1.0 if np.isinf(hi) else 0.5 * (lo + hi)
        act = (jaref + t_mid * jv) < 0.0
        g = g0 + np.sum(P["D"][act] * jv[act] * jaref[act])   # phi'(t) = g + t * h
        h = h0 + np.sum(P["D"][act] * jv[act] ** 2)
        t = -g / h
        if lo <= t <= hi:
            return t, len(pts)
        lo = hi
    return lo, len(pts)


def numpy_newton(P, tol=1e-6, maxiter=50):
    a = P["a0"].copy()
    scale = 1.0 / np.trace(P["M"])
    history = [cost_grad(a, P)[0]]
    for it in range(1, maxiter + 1):
        c, g, act = cost_grad(a, P)
        H = P["M"] + P["J"].T @ (P["D"][:, None] * act[:, None] * P["J"])
        s = -np.linalg.solve(H, g)
        t, nk = exact_linesearch(a, s, P)
        a = a + t * s
        c_new, g_new, _ = cost_grad(a, P)
        history.append(c_new)
        print(f"  iter {it}: alpha {t:.4f}  kinks on ray {nk:2d}  cost {c_new:12.4f}  "
              f"|grad|*scale {scale * np.linalg.norm(g_new):.2e}  active {int(act.sum())}")
        if scale * (c - c_new) < tol or scale * np.linalg.norm(g_new) < tol:
            break
    return a, history


mjm = mujoco.MjModel.from_xml_string(box_stack(5))
m = mjw.put_model(mjm)
m.opt.disableflags |= mjw.DisableBit.WARMSTART      # start from qacc_smooth like the reference
d = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
d.qvel.assign(np.random.default_rng(1).normal(0.0, 0.1, size=(1, mjm.nv)).astype(np.float32))
for _ in range(20):
    mjw.step(m, d)
mjw.forward(m, d)

mjd = mujoco.MjData(mjm)
mjw.get_data_into(mjd, mjm, d)
M = np.zeros((mjm.nv, mjm.nv))
mujoco.mj_fullM(mjm, mjd, M)
n = int(d.nefc.numpy()[0])
P = {"M": M,
     "J": d.efc.J.numpy()[0, :n, :mjm.nv].astype(np.float64),
     "D": d.efc.D.numpy()[0, :n].astype(np.float64),
     "aref": d.efc.aref.numpy()[0, :n].astype(np.float64),
     "a0": d.qacc_smooth.numpy()[0].astype(np.float64)}
print(f"problem: nv={mjm.nv}, nefc={n} pyramidal rows, MJWarp Newton niter "
      f"{int(d.solver_niter.numpy()[0])}")
print("NumPy Newton (float64):")
a_np, hist = numpy_newton(P)

qacc = d.qacc.numpy()[0].astype(np.float64)
c_mj = cost_grad(qacc, P)[0]
print(f"cost: NumPy {hist[-1]:.4f}  MJWarp {c_mj:.4f}  (relative gap {(c_mj - hist[-1]) / hist[-1]:.1e})")
err = np.abs(a_np - qacc).max()
print(f"max |qacc_numpy - d.qacc| = {err:.2e}   (relative {err / np.abs(qacc).max():.1e})")
force = np.where(P["J"] @ a_np - P["aref"] < 0, -P["D"] * (P["J"] @ a_np - P["aref"]), 0.0)
print(f"max |force_numpy - d.efc.force| = {np.abs(force - d.efc.force.numpy()[0, :n]).max():.2e}"
      f"  (max force {force.max():.1f} N)")
