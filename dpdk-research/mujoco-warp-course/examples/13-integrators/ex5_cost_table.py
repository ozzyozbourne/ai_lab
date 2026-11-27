"""Example 13.5 - what one step costs with each integrator (humanoid).

Times NSTEP steps of the shipped humanoid (nv 27) per integrator after a warm-up step (JIT), with
wp.synchronize() before reading the clock. On a CPU dev box only the ratios mean something; on a
Colab GPU the notebook prints your own numbers (without CUDA graph capture, so per-step allocations
inside the integrators are included; Ch 24 shows the captured version). The last lines compute the
scratch memory that IMPLICIT's RNE derivative allocates on every step.
Run: python ex5_cost_table.py [--dump-json PATH]
"""
import argparse
import json
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
NSTEP = 200 if ON_GPU else 10

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
mjm = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
print(f"humanoid: nq {mjm.nq}, nv {mjm.nv}, nbody {mjm.nbody}, nu {mjm.nu} | nworld {NWORLD}, "
      f"device {wp.get_device()}")

INTEGRATORS = {"Euler": mjw.IntegratorType.EULER, "RK4": mjw.IntegratorType.RK4,
               "implicit": mjw.IntegratorType.IMPLICIT,
               "implicitfast": mjw.IntegratorType.IMPLICITFAST}
rng = np.random.default_rng(0)
times = {}
for name, integ in INTEGRATORS.items():
    m = mjw.put_model(mjm)
    m.opt.integrator = integ
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
    d.ctrl.assign(rng.uniform(-0.2, 0.2, (NWORLD, mjm.nu)))
    mjw.step(m, d)                 # warm-up: compiles (or loads) this integrator's kernels
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(NSTEP):
        mjw.step(m, d)
    wp.synchronize()
    times[name] = (time.perf_counter() - t0) / NSTEP
    assert not d.overflow.numpy().any(), "overflow: raise nconmax/njmax"

label = "GPU" if ON_GPU else "CPU dev box"
print(f"{'integrator':<13}{'ms/step':>9}{'x Euler':>9}{'world-steps/s':>15}   ({label})")
for name, t in times.items():
    print(f"{name:<13}{1e3 * t:>9.2f}{t / times['Euler']:>9.2f}{NWORLD / t:>15,.0f}")
print("overflow: none")

# deriv_rne_vel allocates Dcvel, Dcacc, Dcfrcbody (nworld, nbody, nv) and Dcdof_dot (nworld, nv, nv)
# of wp.spatial_vector (6 float32 = 24 bytes) on every IMPLICIT step
for nw in (NWORLD, 4096, 65536):
    nbytes = nw * (3 * mjm.nbody * mjm.nv + mjm.nv * mjm.nv) * 24
    print(f"IMPLICIT RNE-derivative scratch at nworld={nw:>6}: {nbytes / 2**20:9.1f} MiB per step")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": label, "nworld": NWORLD, "nstep": NSTEP,
                   "ms": {k: round(1e3 * v, 3) for k, v in times.items()}}, f)
    print("wrote", args.dump_json)
