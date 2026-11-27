"""Example 25.2 - run mjwarp-testspeed on the shipped humanoid and parse its JSON.

GPU: runs `mjwarp-testspeed test_data/humanoid/humanoid.xml --nworld 4096 --nstep 500
--format json --event_trace` in a subprocess (the path falls back to the installed package, so
no clone is needed) and prints steps/s, ncon/nefc mean and p95, solver iterations, and the
step.forward.* stages (the trace keys exist only with --event_trace).
CPU: testspeed refuses to run (Rule G). We show its real error, then run `mini_testspeed`, a
small re-implementation of what testspeed measures (testspeed.py::_main + cli.unroll), and
print the same JSON keys except total_memory (a device free-memory difference). CPU numbers
are CPU numbers, never GPU performance.
Run: python ex2_testspeed.py [--dump-json PATH]
  --dump-json PATH writes the CPU metrics in testspeed's JSON schema (bundled sample).
"""
import argparse
import dataclasses
import json
import subprocess
import sys
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 500 if ON_GPU else 50
MODEL = "test_data/humanoid/humanoid.xml"


def run_testspeed(*flags):
    """Run mjwarp-testspeed in a subprocess; return (returncode, stdout, last stderr line)."""
    cmd = [sys.executable, "-m", "mujoco_warp.testspeed", MODEL, *flags]
    r = subprocess.run(cmd, capture_output=True, text=True)
    err = [ln for ln in r.stderr.splitlines() if ln.strip()]
    return r.returncode, r.stdout, err[-1] if err else ""


# --- a copy of cli._ctrl_noise (Ornstein-Uhlenbeck noise on ctrl, Halton samples) ---
@wp.func
def halton(index: int, base: int) -> float:
    n0 = index
    b = float(base)
    f = float(1.0) / b
    hn = float(0.0)
    while n0 > 0:
        n1 = n0 // base
        r = n0 - n1 * base
        hn += f * float(r)
        f /= b
        n0 = n1
    return hn


@wp.kernel
def ctrl_noise(timestep: wp.array(dtype=float), ctrllimited: wp.array(dtype=bool),
               ctrlrange: wp.array2d(dtype=wp.vec2), ctrl_in: wp.array2d(dtype=float),
               center: wp.array(dtype=float), step: int, std: float, rate_s: float,
               ctrl_out: wp.array2d(dtype=float)):
    worldid, actid = wp.tid()
    rate = wp.exp(-timestep[worldid % timestep.shape[0]] / rate_s)
    scale = std * wp.sqrt(1.0 - rate * rate)
    midpoint = 0.0
    halfrange = 1.0
    cr = ctrlrange[worldid % ctrlrange.shape[0], actid]
    if ctrllimited[actid]:
        midpoint = 0.5 * (cr[1] + cr[0])
        halfrange = 0.5 * (cr[1] - cr[0])
    if center.shape[0] > 0:
        midpoint = center[actid]
    ctrl = rate * ctrl_in[worldid, actid] + (1.0 - rate) * midpoint      # pull toward center
    ctrl += scale * halfrange * (2.0 * halton((step + 1) * (worldid + 1), actid + 2) - 1.0)
    if ctrllimited[actid]:
        ctrl = wp.clamp(ctrl, cr[0], cr[1])
    ctrl_out[worldid, actid] = ctrl


def nbytes(obj):
    """Sum of wp.array capacities in a dataclass (testspeed._dataclass_memory)."""
    total = 0
    for f in dataclasses.fields(obj):
        v = getattr(obj, f.name)
        if dataclasses.is_dataclass(v):
            total += nbytes(v)
        elif isinstance(v, wp.array):
            total += v.capacity
    return total


def mini_testspeed(mjm, fn=mjw.step, nworld=8, nstep=50, noise_std=0.01, noise_rate=0.1,
                   keyframe=0, nconmax=None, njmax=None):
    """What testspeed measures: capture fn once, then per step noise -> replay -> read counts."""
    mjd = mujoco.MjData(mjm)
    ctrls = None
    if mjm.nkey > 0 and keyframe > -1:              # cli.init_structs: keyframe -> ctrl center
        mujoco.mj_resetDataKeyframe(mjm, mjd, keyframe)
        ctrls = [mjd.ctrl.copy() for _ in range(nstep)]
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0                         # testspeed's default overflow_behavior=error
    d = mjw.put_data(mjm, mjd, nworld=nworld, nconmax=nconmax, njmax=njmax)
    t0 = time.perf_counter()
    with wp.ScopedCapture() as cap:                 # JIT + capture: testspeed's "jit_duration"
        fn(m, d)
    jit = time.perf_counter() - t0
    nacon, nefc, niter, runtime = [], [], [], 0.0
    for i in range(nstep):
        if ctrls is not None:                       # no keyframe and no --replay: no noise!
            center = wp.array(ctrls[i], dtype=float)
            wp.launch(ctrl_noise, dim=(d.nworld, m.nu),
                      inputs=[m.opt.timestep, m.actuator_ctrllimited, m.actuator_ctrlrange,
                              d.ctrl, center, i, noise_std, noise_rate], outputs=[d.ctrl])
            wp.synchronize()
        t = time.perf_counter()
        wp.capture_launch(cap.graph)                # only the replay is timed
        wp.synchronize()
        runtime += time.perf_counter() - t
        nacon.append(max(d.nacon.numpy()[0], d.ncollision.numpy()[0]))   # total, all worlds
        nefc.append(d.nefc.numpy().max())                                # worst world
        niter.append(d.solver_niter.numpy())
        if d.overflow.numpy().any():
            raise RuntimeError(f"overflow {d.overflow.numpy()} - raise nconmax/njmax")
    steps = nworld * nstep
    qpos = d.qpos.numpy()
    return {
        "jit_duration": jit, "run_time": runtime, "steps_per_second": steps / runtime,
        "converged_worlds": int(np.sum(~np.any(np.isnan(qpos), axis=1))),
        "model_memory": nbytes(m), "data_memory": nbytes(d),
        "ncon_mean": float(np.mean(nacon) / nworld),
        "ncon_p95": float(np.percentile(nacon, 95) / nworld),
        "nefc_mean": float(np.mean(nefc)), "nefc_p95": float(np.percentile(nefc, 95)),
        "solver_niter_mean": float(np.mean(niter)),
        "solver_niter_p95": float(np.percentile(niter, 95)),
    }, d


def summary(metrics):
    print(f"  steps/s           {metrics['steps_per_second']:,.0f}")
    print(f"  ncon  mean / p95  {metrics['ncon_mean']:.2f} / {metrics['ncon_p95']:.2f} per world")
    print(f"  nefc  mean / p95  {metrics['nefc_mean']:.1f} / {metrics['nefc_p95']:.1f}"
          " (worst world)")
    print(f"  solver_niter mean {metrics['solver_niter_mean']:.2f},"
          f" p95 {metrics['solver_niter_p95']:.0f}")
    print(f"  converged worlds  {metrics['converged_worlds']}")


if __name__ == "__main__":
    if ON_GPU:
        code, out, err = run_testspeed("--nworld", str(NWORLD), "--nstep", str(NSTEP),
                                       "--format", "json", "--event_trace")   # trace keys too
        if code != 0:
            raise RuntimeError(f"testspeed failed: {err}")
        metrics = json.loads(out.strip().splitlines()[-1])
        print(f"mjwarp-testspeed {MODEL} nworld={NWORLD} nstep={NSTEP} (your GPU):")
        summary(metrics)
        stages = {k: v for k, v in metrics.items()     # direct children of step.forward only
                  if k.startswith("step.forward.") and k.count(".") == 2}
        print("  stages [ns/world-step]:", {k[13:]: round(v, 1) for k, v in stages.items()})
    else:
        code, _, err = run_testspeed("--nworld", "8", "--nstep", "5", "--format", "json")
        print(f"skipped on CPU: mjwarp-testspeed exited with code {code}: {err}")
        mjm = mujoco.MjModel.from_xml_path(str(epath.resource_path("mujoco_warp") / MODEL))
        metrics, d = mini_testspeed(mjm, nworld=NWORLD, nstep=NSTEP, nconmax=24, njmax=64)
        print(f"mini_testspeed (CPU stand-in) {MODEL} nworld={NWORLD} nstep={NSTEP}:")
        summary(metrics)
        print("  JSON keys:", ", ".join(metrics))
    if args.dump_json:
        with open(args.dump_json, "w") as f:
            json.dump({k: (round(v, 4) if isinstance(v, float) else v)
                       for k, v in metrics.items()}, f)
        print("wrote", args.dump_json)
