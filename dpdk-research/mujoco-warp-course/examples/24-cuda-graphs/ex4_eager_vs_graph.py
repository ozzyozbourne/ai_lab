"""Example 24.4 - world-steps per second vs nworld: eager mjw.step vs a replayed graph.

Uses my_env.capture_step(m, d, nsub) (new in this chapter: it applies the graph-conditional
fallback and records nsub steps into one graph). Warm up first, call wp.synchronize() before
reading the clock, and report world-steps/s = nworld * steps / seconds. The ball starts resting
on the floor, so every timed step has an active contact (collision + constraint solve).
On CPU the numbers are from Warp's CPU device ("on a CPU dev box"), NOT GPU performance;
on a GPU the notebook prints your own numbers.
The log-log plot goes to --plot PNG (default ex4_throughput.png in the current folder; shown
inline in a notebook). On a GPU it also draws the course's CPU numbers (data/ex4_throughput.json)
as dashed reference lines when that file is present.
Run: python ex4_eager_vs_graph.py [--dump-json PATH] [--plot PNG]
"""
import argparse
import json
import pathlib
import sys
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
try:
    import my_env                           # notebook: written by the %%writefile cell
except ImportError:
    import my_env_step24 as my_env          # examples/24-cuda-graphs/

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 .1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
parser.add_argument("--plot", default=None, help="save the log-log plot to this PNG")
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLDS = [1, 16, 256, 4096, 16384, 65536] if ON_GPU else [1, 4, 16, 64, 256]
NSTEP = 200 if ON_GPU else 30

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)


def timed(fn, n, repeats=3):
    """Seconds per call: best of `repeats` runs of n calls (less noise from other processes)."""
    best = float("inf")
    for _ in range(repeats):
        wp.synchronize()
        t = time.perf_counter()
        for _ in range(n):
            fn()
        wp.synchronize()                    # launches are asynchronous on a GPU
        best = min(best, (time.perf_counter() - t) / n)
    return best


rows = []
print(f"device: {wp.get_device()}  ({'GPU' if ON_GPU else 'CPU dev box, not GPU performance'})")
print(f"{'nworld':>7} {'eager ms':>9} {'graph ms':>9} {'eager w-steps/s':>16} "
      f"{'graph w-steps/s':>16} {'speedup':>8}")
for nw in NWORLDS:
    d = mjw.make_data(mjm, nworld=nw, nconmax=4, njmax=16)
    for _ in range(3):
        mjw.step(m, d)                      # warm-up: compile / load kernels for this size
    eager = timed(lambda: mjw.step(m, d), NSTEP)
    graph = my_env.capture_step(m, d, nsub=1)
    replay = timed(lambda: wp.capture_launch(graph), NSTEP)
    assert not d.overflow.numpy().any(), my_env.describe_overflow(d)
    rows.append({"nworld": nw, "eager_ms": eager * 1e3, "graph_ms": replay * 1e3,
                 "eager_wsps": nw / eager, "graph_wsps": nw / replay})
    print(f"{nw:>7} {eager * 1e3:>9.3f} {replay * 1e3:>9.3f} {nw / eager:>16,.0f} "
          f"{nw / replay:>16,.0f} {eager / replay:>7.1f}x")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "nstep": NSTEP, "model": "BALL_DROP",
                   "rows": [{k: round(v, 4) if isinstance(v, float) else v for k, v in r.items()}
                            for r in rows]}, f, separators=(",", ":"))
    print("wrote", args.dump_json)

try:
    import matplotlib
    if args.plot or "ipykernel" not in sys.modules:
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    nws = [r["nworld"] for r in rows]
    fig, ax = plt.subplots(figsize=(6, 3.5))
    ax.loglog(nws, [r["eager_wsps"] for r in rows], "o-", label="eager mjw.step")
    ax.loglog(nws, [r["graph_wsps"] for r in rows], "s-", label="graph replay")
    ref = HERE / "data" / "ex4_throughput.json"
    if ON_GPU and ref.exists():             # overlay the course's CPU run for comparison
        cpu = json.loads(ref.read_text())["rows"]
        cnw = [r["nworld"] for r in cpu]
        ax.loglog(cnw, [r["eager_wsps"] for r in cpu], "o--", color="C0", alpha=.5, label="eager, course CPU")
        ax.loglog(cnw, [r["graph_wsps"] for r in cpu], "s--", color="C1", alpha=.5, label="graph, course CPU")
    ax.set_xlabel("nworld")
    ax.set_ylabel("world-steps / s")
    ax.set_title(f"BALL_DROP on {wp.get_device()}")
    ax.legend()
    fig.tight_layout()
    if "ipykernel" in sys.modules and not args.plot:
        plt.show()
    else:
        out = args.plot or "ex4_throughput.png"
        fig.savefig(out, dpi=100)
        print("saved", out)
except ImportError:
    print("skipped: matplotlib not installed")
