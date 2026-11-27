"""Example 22.9 - what determinism costs: steps/s for NONE, ATOMICS and ALL.

For two scenes (box_stack(5) with contacts, HUMANOID with contacts off) we time NSTEP steps of
NWORLD worlds per mode, after a warm-up step that JIT-compiles the mode's kernels. We also count,
for one sampled step, how many kernel launches run in Warp's RUN_TO_RUN mode (the same launch spy that
determinism_test.py::_record_launches uses). The counts belong to that one step: the solver loop
runs until every world converges, so its launches grow with solver_niter (printed next to the
counts), and a few launch paths branch on wp.get_device().is_cuda, so a GPU can count differently.
In 4.0.1 ALL costs the same as ATOMICS, because the
CONTACTS and CONSTRAINT sorts are stubs. On a GPU, RUN_TO_RUN kernels record their atomic
contributions and sort them before reducing, so expect them to be slower; on Warp's CPU device the
deterministic code path is compiled out (threads already run in order), so CPU timings differ by
noise only. CPU numbers are from a shared CPU dev box and say nothing about GPU speed.
Run: python ex9_determinism_cost.py [--dump-json PATH]   (on Colab you can also use:
  mjwarp-testspeed <xml> -o "opt.deterministic=ATOMICS")
  --dump-json PATH writes launches per step and RUN_TO_RUN launches per scene and mode.
"""
import argparse
import contextlib
import json
import time
from unittest import mock

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath


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

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 500 if ON_GPU else 20
DT = mjw.DeterminismType


@contextlib.contextmanager
def count_launches():
    """Count kernel launches, and those compiled with the RUN_TO_RUN module option."""
    counts = {"all": 0, "run_to_run": 0}

    def wrap(launch):
        def wrapper(*a, **kw):
            kernel = kw["kernel"] if "kernel" in kw else a[0]
            counts["all"] += 1
            mode = kernel.module.options.get("deterministic", wp.DeterministicMode.NOT_GUARANTEED)
            counts["run_to_run"] += mode == wp.DeterministicMode.RUN_TO_RUN
            return launch(*a, **kw)
        return wrapper

    with mock.patch.object(wp, "launch", wrap(wp.launch)), \
         mock.patch.object(wp, "launch_tiled", wrap(wp.launch_tiled)):
        yield counts


humanoid = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
humanoid.opt.disableflags |= mujoco.mjtDisableBit.mjDSBL_CONTACT
humanoid.opt.ls_iterations = 50
scenes = [("box_stack(5)", mujoco.MjModel.from_xml_string(box_stack(5)),
           dict(nconmax=32, njmax=128)),
          ("HUMANOID, no contacts", humanoid, {})]
print(f"device: {wp.get_device()} | nworld {NWORLD} | {NSTEP} timed steps"
      + ("" if ON_GPU else " | CPU dev box: timings are noise-level, not GPU numbers"))
print(f"{'scene':22s} {'mode':8s} {'world-steps/s':>14s} {'vs NONE':>8s} {'launches/step':>14s}"
      f" {'RUN_TO_RUN':>11s} {'niter':>6s}")
rows, rates = [], {}
for name, mjm, sizes in scenes:
    base = None
    for mode in (DT.NONE, DT.ATOMICS, DT.ALL):
        m = mjw.put_model(mjm)
        m.opt.deterministic = mode
        d = mjw.make_data(mjm, nworld=NWORLD, **sizes)
        mjw.step(m, d)                         # warm-up: compiles this mode's kernels
        with count_launches() as counts:
            mjw.step(m, d)
        niter = int(d.solver_niter.numpy().max())  # solver iterations in the counted step
        wp.synchronize()
        t0 = time.perf_counter()
        for _ in range(NSTEP):
            mjw.step(m, d)
        wp.synchronize()
        rate = NWORLD * NSTEP / (time.perf_counter() - t0)
        base = base or rate
        rates[name, mode.name] = rate
        print(f"{name:22s} {mode.name:8s} {rate:14,.0f} {rate / base:8.2f} {counts['all']:14d}"
              f" {counts['run_to_run']:11d} {niter:6d}")
        assert not d.overflow.numpy().any(), "overflow"
        rows.append({"scene": name, "mode": mode.name, "launches": counts["all"],
                     "run_to_run": counts["run_to_run"], "solver_niter": niter})

if args.dump_json:   # launch counts only: timings are machine-specific
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "rows": rows}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
