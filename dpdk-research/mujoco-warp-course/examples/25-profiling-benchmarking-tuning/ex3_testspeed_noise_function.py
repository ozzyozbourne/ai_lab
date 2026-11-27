"""Example 25.3 - what --noise_std and --function change in a testspeed measurement.

GPU: four testspeed runs on the humanoid: the default noise (0.01) vs --noise_std 0,
--function forward vs --function step, and --function render at 64x64 with depth; prints a
comparison table (steps/s, ncon).
CPU: testspeed does not run (Rule G). We print the list of names --function accepts (built with
testspeed's own rule), then measure the two effects that matter for comparisons with a small
copy of testspeed's loop: (1) without noise every world stays identical, (2) `forward` never
advances time, so it times the same state again and again. CPU numbers are CPU numbers.
Run: python ex3_testspeed_noise_function.py
"""
import inspect
import subprocess
import sys
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 500 if ON_GPU else 50
MODEL = "test_data/humanoid/humanoid.xml"

# testspeed.py::_FUNCS: public functions whose parameters are exactly {m, d} or {m, d, rc}
FUNCS = sorted(n for n, f in inspect.getmembers(mjw, inspect.isfunction)
               if set(inspect.signature(f).parameters) in ({"m", "d"}, {"m", "d", "rc"}))
print(f"--function accepts {len(FUNCS)} names:", ", ".join(FUNCS))
for name in ("fwd_position", "collision", "fwd_acceleration"):
    params = list(inspect.signature(getattr(mjw, name)).parameters)
    print(f"  not accepted: {name}{tuple(params)} (extra parameter)")

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


mjm = mujoco.MjModel.from_xml_path(str(epath.resource_path("mujoco_warp") / MODEL))
mjd = mujoco.MjData(mjm)
mujoco.mj_resetDataKeyframe(mjm, mjd, 0)
center = wp.array(mjd.ctrl.astype(np.float32), dtype=float)


def run(fn, noise_std):
    m = mjw.put_model(mjm)
    d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=24, njmax=64)
    with wp.ScopedCapture() as cap:
        fn(m, d)
    ncon, runtime = [], 0.0
    for i in range(NSTEP):
        wp.launch(ctrl_noise, dim=(NWORLD, m.nu),
                  inputs=[m.opt.timestep, m.actuator_ctrllimited, m.actuator_ctrlrange, d.ctrl,
                          center, i, noise_std, 0.1], outputs=[d.ctrl])
        t = time.perf_counter()
        wp.capture_launch(cap.graph)
        wp.synchronize()
        runtime += time.perf_counter() - t
        # testspeed's ncon_mean: max(nacon, ncollision) / nworld (testspeed.py:263)
        ncon.append(max(d.nacon.numpy()[0], d.ncollision.numpy()[0]) / NWORLD)
    q = d.qpos.numpy()
    return {"sps": NWORLD * NSTEP / runtime, "ncon": np.mean(ncon),
            "spread": float(np.abs(q - q[0]).max()), "time": float(d.time.numpy()[0])}



if ON_GPU:
    import json

    def testspeed(*flags):
        cmd = [sys.executable, "-m", "mujoco_warp.testspeed", MODEL, "--nworld", str(NWORLD),
               "--nstep", str(NSTEP), "--format", "json", *flags]
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
        return json.loads(out.strip().splitlines()[-1])

    runs = {
        "step, noise 0.01 (default)": testspeed(),
        "step, --noise_std 0": testspeed("--noise_std", "0"),
        "--function forward": testspeed("--function", "forward"),
        "--function render 64x64 rgb+depth": testspeed(
            "--function", "render", "--render_width", "64", "--render_height", "64",
            "--render_depth", "true"),
    }
    print(f"\n{'run':<36}{'steps/s':>14}{'ncon mean':>11}")
    for name, r in runs.items():
        print(f"{name:<36}{r['steps_per_second']:>14,.0f}{r['ncon_mean']:>11.2f}")
else:
    print("\nskipped on CPU: mjwarp-testspeed is GPU only. What the four GPU runs measure:")
    print("  default            : step; ctrl pulled to the keyframe ctrl + OU noise (0.01, 0.1 s)")
    print("  --noise_std 0      : step, no noise -> every world repeats world 0")
    print("  --function forward : forward only, no integration, d.time never moves")
    print("  --function render  : refit_bvh + render timed; step replayed untimed in between")
    print("Measuring the first three by hand on CPU:")
    rows = {"step, noise 0.01 (default)": run(mjw.step, 0.01),
            "step, noise_std 0": run(mjw.step, 0.0),
            "forward, noise 0.01": run(mjw.forward, 0.01)}
    head = f"run (CPU, nworld={NWORLD}, {NSTEP} steps)"
    print(f"\n{head:<36}{'steps/s':>9}{'ncon/world':>11}{'max|q_w - q_0|':>16}{'d.time':>8}")
    for name, r in rows.items():
        print(f"{name:<36}{r['sps']:>9,.0f}{r['ncon']:>11.2f}{r['spread']:>16.4f}"
              f"{r['time']:>8.3f}")
    print("noise 0: all worlds identical ->", rows["step, noise_std 0"]["spread"] == 0.0)
    print("forward: d.time stays", rows["forward, noise 0.01"]["time"], "(no integration)")
