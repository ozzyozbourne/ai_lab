"""Example 25.1 - profile one captured mjw.step with EventTracer; read ns per world-step.

GPU: `with EventTracer(enabled=ON_GPU) as t:` around a captured step, replay it NSTEP times,
then t.trace() gives {name: (times_ms, sub_trace)} for every @event_scope function. We print
the tree in microseconds per replay and in nanoseconds per world-step (testspeed's unit).
CPU: EventTracer is enabled=False (Rule G: the first event_scope would raise "Device cpu is not
a CUDA device"), so the trace is empty. As a CPU stand-in we record the SAME tree by watching
the event_scope wrapper with sys.setprofile (skipping capture_while/capture_if bodies, as
event_scope does) and timing it with the wall clock. Those numbers are CPU numbers with Python
overhead included, never GPU performance.
Run: python ex1_event_trace.py [--dump-json PATH]
  --dump-json PATH writes the nested trace (ns per world-step) for the page's icicle chart.
"""
import argparse
import json
import sys
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath
from mujoco_warp._src import warp_util          # private API: EventTracer, event_scope

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 20

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
mjm = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
mjd = mujoco.MjData(mjm)
mujoco.mj_resetDataKeyframe(mjm, mjd, 0)                # like testspeed's --keyframe 0
m = mjw.put_model(mjm)
if ON_GPU and not wp.is_conditional_graph_supported():
    m.opt.graph_conditional = False                     # Rule G fallback (CUDA < 12.4)
d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=24, njmax=64)
mjw.step(m, d)                                          # warm-up: JIT compile outside the trace
wp.synchronize()


def sum_trace(a, b):
    """Add two traces call by call (what testspeed._sum_trace does after every replay)."""
    out = dict(a)
    for name, (times, sub) in b.items():
        if name in a:
            times = tuple(t1 + t2 for t1, t2 in zip(a[name][0], times))
            sub = sum_trace(a[name][1], sub)
        out[name] = (times, sub)
    return out


def per_world_step(trace, nstep, nworld, reps=1):
    """{name: (ms, ...)} -> {name: {"us": per replay, "ns": per world-step, "calls", "sub"}}.

    us per replay = 1e3 * ms / nstep (the latency of one call for all worlds);
    ns per world-step = 1e6 * ms / (nstep * nworld), the unit testspeed prints."""
    out = {}
    for name, (times, sub) in trace.items():
        out[name] = {"us": round(1e3 * sum(times) / nstep, 3),
                     "ns": round(1e6 * sum(times) / (nstep * nworld), 3),
                     "calls": len(times) // reps,
                     "sub": per_world_step(sub, nstep, nworld, reps)}
    return out


def show(tree, indent=0, depth=4):
    if indent == 0:
        print(f"{'':<28} {'us/replay':>12} {'ns/world-step':>14}")
    for name, node in tree.items():
        print("  " * indent + f"{name:<{28 - 2 * indent}} {node['us']:>12.1f} {node['ns']:>14.1f}")
        if indent + 1 < depth:
            show(node["sub"], indent + 1, depth)


# ---- 1. the real tool: EventTracer (records CUDA events, so GPU only) ----
with warp_util.EventTracer(enabled=ON_GPU) as tracer:
    with wp.ScopedCapture() as cap:                     # events become graph nodes
        mjw.step(m, d)
    gpu_trace = {}
    for _ in range(NSTEP):
        wp.capture_launch(cap.graph)
        wp.synchronize()
        # trace() reads the events of the replay that just ran; add them up
        gpu_trace = sum_trace(gpu_trace, tracer.trace())

if ON_GPU:
    tree = per_world_step(gpu_trace, NSTEP, NWORLD)
    print(f"EventTracer on {wp.get_device()}, nworld={NWORLD}, {NSTEP} replays:")
    show(tree)
    source = "EventTracer, GPU"
else:
    print("skipped on CPU: EventTracer needs CUDA events; trace() returned", gpu_trace)

    # ---- 2. CPU stand-in: the same tree, timed with the wall clock ----
    WRAPPER = warp_util.event_scope(lambda: None).__code__   # every event_scope shares it
    root = {}
    stack, open_ = [root], []

    inside_conditional = [0]                            # event_scope skips these bodies

    def watch(frame, event, arg):
        code = frame.f_code
        if code.co_name in ("capture_while", "capture_if") and event in ("call", "return"):
            inside_conditional[0] += 1 if event == "call" else -1
            return
        if code is not WRAPPER or inside_conditional[0]:
            return
        if event == "call":                             # the wrapper's closure holds `name`
            node = stack[-1].setdefault(frame.f_locals["name"], ([], {}))
            stack.append(node[1])
            open_.append((node, time.perf_counter()))
        elif event == "return":
            node, t0 = open_.pop()
            stack.pop()
            node[0].append(1e3 * (time.perf_counter() - t0))   # ms, like get_event_elapsed_time

    sys.setprofile(watch)
    for _ in range(NSTEP):
        mjw.step(m, d)                                  # eager: CPU launches run immediately
    sys.setprofile(None)
    tree = per_world_step(root, NSTEP, NWORLD, reps=NSTEP)
    print(f"CPU stand-in (wall clock, eager, nworld={NWORLD}, {NSTEP} steps, CPU numbers):")
    show(tree)
    source = "sys.setprofile wall clock, CPU"

step_ns = tree["step"]["ns"]
fwd = tree["step"]["sub"]["forward"]["sub"]
top = max(fwd, key=lambda k: fwd[k]["ns"])
print(f"step = {step_ns:.0f} ns per world-step -> {1e9 / step_ns:,.0f} world-steps/s")
print(f"largest stage under forward: {top} ({100 * fwd[top]['ns'] / step_ns:.0f}% of step)")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"source": source, "nworld": NWORLD, "nstep": NSTEP, "unit": "ns/world-step",
                   "tree": tree}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
