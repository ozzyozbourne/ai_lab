"""Example 25.4 - compare solver settings with testspeed's -o/--override.

GPU: four testspeed runs on the humanoid: the defaults, -o "opt.solver=cg",
-o "opt.iterations=5" and -o "opt.cone=elliptic"; prints a comparison table. testspeed's default
--overflow_behavior=error exits 1 on ANY set bit of warn_overflow, and the solver sets the
ITERATIONS bit whenever a world hits the cap, so an unconverged setting would abort the run.
Every row therefore adds -o "opt.warn_overflow=~ITERATIONS|~LS_ITERATIONS" (the mask is read
after the overrides): buffer overflows (NEFC, NARROWPHASE, ...) still abort, and the overflow
column says whether the p95 iteration count sits at the cap. A row that aborts prints
testspeed's "Simulation aborted" lines instead of numbers.
CPU: the same comparison by hand. For each setting we do what cli.load_model/init_structs do:
apply io.override_model to the MjModel, put_model, apply it again to the mjw.Model (it mutates
in place and returns None), then time NSTEP eager steps. CPU numbers are CPU numbers.
Run: python ex4_overrides.py
"""
import subprocess
import sys
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath
from mujoco_warp._src.io import override_model     # private API

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 500 if ON_GPU else 50
MODEL = "test_data/humanoid/humanoid.xml"
SETTINGS = {"defaults": [], "cg": ["opt.solver=cg"], "iterations=5": ["opt.iterations=5"],
            "elliptic": ["opt.cone=elliptic"]}

if ON_GPU:
    import json
    MASK = ["-o", "opt.warn_overflow=~ITERATIONS|~LS_ITERATIONS"]   # iteration caps: report only
    path = str(epath.resource_path("mujoco_warp") / MODEL)
    print(f"{'setting':<16}{'iters':>6}{'steps/s':>14}{'niter mean':>12}{'nefc p95':>10}  overflow")
    for name, ov in SETTINGS.items():
        mjm = mujoco.MjModel.from_xml_path(path)
        override_model(mjm, ov)                         # only to read the iteration cap
        flags = [f for o in ov for f in ("-o", o)] + MASK
        cmd = [sys.executable, "-m", "mujoco_warp.testspeed", MODEL, "--nworld", str(NWORLD),
               "--nstep", str(NSTEP), "--format", "json", *flags]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:                           # e.g. "Simulation aborted: overflow ..."
            lines = [ln for ln in r.stdout.splitlines() if ln.strip()] or r.stderr.splitlines()[-1:]
            print(f"{name:<16}{mjm.opt.iterations:>6}  exited {r.returncode}: " + " / ".join(lines[:3]))
            continue
        m = json.loads(r.stdout.strip().splitlines()[-1])
        cap = "ITERATIONS (p95 at cap)" if m["solver_niter_p95"] >= mjm.opt.iterations else "none"
        print(f"{name:<16}{mjm.opt.iterations:>6}{m['steps_per_second']:>14,.0f}"
              f"{m['solver_niter_mean']:>12.2f}{m['nefc_p95']:>10.0f}  {cap}")
else:
    print("skipped on CPU: mjwarp-testspeed is GPU only; applying the same overrides by hand")
    path = str(epath.resource_path("mujoco_warp") / MODEL)
    print(f"{'setting':<16}{'solver':>8}{'cone':>11}{'iters':>6}{'steps/s':>9}{'niter':>7}"
          f"{'nefc':>6}  overflow")
    for name, ov in SETTINGS.items():
        mjm = mujoco.MjModel.from_xml_path(path)
        if ov:
            override_model(mjm, ov)                     # MjModel side: what C MuJoCo compiles
        mjd = mujoco.MjData(mjm)
        mujoco.mj_resetDataKeyframe(mjm, mjd, 0)
        m = mjw.put_model(mjm)
        if ov:
            assert override_model(m, ov) is None        # mjw.Model side, in place
        m.opt.warn_overflow = 0                         # read the bits instead of printing
        d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=24, njmax=64)
        mjw.step(m, d)                                  # warm-up (JIT) outside the timing
        wp.synchronize()
        niter = []
        t0 = time.perf_counter()
        for _ in range(NSTEP):
            mjw.step(m, d)
            niter.append(d.solver_niter.numpy().mean())  # a host read per step, like testspeed
        wp.synchronize()
        sps = NWORLD * NSTEP / (time.perf_counter() - t0)
        bits = int(np.bitwise_or.reduce(d.overflow.numpy()))
        flags = [o.name for o in mjw.OverflowType
                 if o.value & bits and o.value & (o.value - 1) == 0]
        print(f"{name:<16}{mjw.SolverType(m.opt.solver).name:>8}{mjw.ConeType(m.opt.cone).name:>11}"
              f"{m.opt.iterations:>6}{sps:>9,.0f}{np.mean(niter):>7.2f}{d.nefc.numpy().max():>6}  "
              f"{'none' if not flags else '|'.join(flags)}")
