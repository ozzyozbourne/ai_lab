"""Example 15.8 - how collision time scales with the number of geoms, for each broadphase.

Times mjw.collision (broadphase + narrowphase) on packed scatter(n) scenes. Warm up once per
configuration (JIT compile), synchronize before reading the clock, report the median of a few
calls. CPU numbers say nothing about GPU performance: run this on Colab for real numbers.
Run: python ex8_scaling.py [--dump-json PATH] [--plot PATH]
"""
import argparse
import json
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

ON_GPU = wp.get_device().is_cuda
NWORLD = 64 if ON_GPU else 2
# GPU sizes stop at 3000: from n = 4000 MuJoCo's default arena is too small and compiling scatter(n)
# fails with "Could not allocate memory" (add <size memory="1G"/> to the MJCF to go higher).
SIZES = [50, 200, 800, 2000, 3000] if ON_GPU else [50, 200, 800, 2000]
REPEAT = 20 if ON_GPU else 3

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
parser.add_argument("--plot", default=None)
args, _ = parser.parse_known_args()


def scatter(n, seed=0, spacing=0.4):
    """MJCF string: a plane plus n free bodies (alternating sphere / capsule), lattice + jitter."""
    rng = np.random.default_rng(seed)
    per_side = 10                                   # 10 x 10 bodies per layer, 4 m x 4 m
    bodies = []
    for i in range(n):
        layer, k = divmod(i, per_side * per_side)
        row, col = divmod(k, per_side)
        x = -0.5 * spacing * (per_side - 1) + spacing * col + rng.uniform(-0.02, 0.02)
        y = -0.5 * spacing * (per_side - 1) + spacing * row + rng.uniform(-0.02, 0.02)
        z = 0.3 + spacing * layer
        if i % 2 == 0:
            geom = f'<geom type="sphere" size="{rng.uniform(0.05, 0.1):.3f}"/>'
        else:
            e = rng.uniform(-180, 180, size=3)
            geom = (f'<geom type="capsule" size="{rng.uniform(0.05, 0.07):.3f} '
                    f'{rng.uniform(0.05, 0.1):.3f}" euler="{e[0]:.0f} {e[1]:.0f} {e[2]:.0f}"/>')
        bodies.append(f'<body name="b{i}" pos="{x:.3f} {y:.3f} {z:.3f}"><freejoint/>{geom}</body>')
    return ('<mujoco model="scatter"><option timestep="0.002"/><worldbody>'
            '<light pos="0 0 4" dir="0 0 -1"/><geom name="floor" type="plane" size="3 3 .1"/>'
            + "".join(bodies) + '</worldbody></mujoco>')



def time_collision(m, d, repeat):
    mjw.collision(m, d)                       # warm-up: compiles kernels for this configuration
    wp.synchronize()
    times = []
    for _ in range(repeat):
        t0 = time.perf_counter()
        mjw.collision(m, d)
        wp.synchronize()
        times.append(time.perf_counter() - t0)
    return float(np.median(times))


rows = []
print(f"device: {wp.get_device()} | nworld = {NWORLD} | median of {REPEAT} calls")
print("     n   pairs/world  auto           NXN [ms]  SAP_TILE [ms]  SAP_SEG [ms]  ncollision")
for n in SIZES:
    mjm = mujoco.MjModel.from_xml_string(scatter(n, spacing=0.22))
    m = mjw.put_model(mjm)
    auto = mjw.BroadphaseType(m.opt.broadphase).name
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8 * n, njmax=64)
    mjw.kinematics(m, d)
    ms, ncol = {}, set()
    for bp in mjw.BroadphaseType:
        m.opt.broadphase = bp
        ms[bp.name] = 1e3 * time_collision(m, d, REPEAT)
        ncol.add(int(d.ncollision.numpy()[0]))
    assert len(ncol) == 1                     # every broadphase finds the same candidates
    nfiltered = m.nxn_geom_pair_filtered.shape[0]
    rows.append({"n": n, "pairs": nfiltered, "auto": auto, **ms, "ncollision": ncol.pop()})
    r = rows[-1]
    print(f"{n:6d} {nfiltered:12d}  {auto:13s} {r['NXN']:9.2f} {r['SAP_TILE']:14.2f} "
          f"{r['SAP_SEGMENTED']:13.2f} {r['ncollision']:11d}")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "nworld": NWORLD, "repeat": REPEAT,
                   "rows": [{k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()}
                            for r in rows]}, f, separators=(",", ":"))
    print("wrote", args.dump_json)

if args.plot:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("skipped: matplotlib not installed")
    else:
        ns = [r["n"] for r in rows]
        for bp in mjw.BroadphaseType:
            plt.loglog(ns, [r[bp.name] for r in rows], "o-", label=bp.name)
        plt.xlabel("geoms per world (n)")
        plt.ylabel("mjw.collision time [ms]")
        plt.title(f"{wp.get_device()}, nworld={NWORLD}")
        plt.legend()
        plt.savefig(args.plot, dpi=100)
        print("saved", args.plot)
