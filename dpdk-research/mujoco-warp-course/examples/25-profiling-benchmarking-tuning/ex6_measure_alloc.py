"""Example 25.6 - size nconmax/njmax from measured contact and constraint counts.

GPU: `mjwarp-testspeed ... --measure_alloc` prints per-bucket mean/std/min/max of nacon (all
worlds) and nefc (worst world). We run it on the humanoid, parse the two tables, apply
pick_budget to the bucket max column (testspeed prints no per-step values, so this is an upper
bound on the p95 rule), then rerun testspeed --format json with the default sizes and with the
picked --nconmax/--njmax and compare steps/s and data_memory.
CPU: the same measurement by hand on box_stack(5): a generous first run records, every step,
max(nacon, ncollision) over all worlds and the worst world's nefc (what --measure_alloc
records), prints the bucket tables, chooses budgets with pick_budget (p95 + headroom, rounded
up), and reruns with the default njmax, the measured budget and the generous one.
Run: python ex6_measure_alloc.py [--dump-json PATH]
"""
import argparse
import json
import subprocess
import sys
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 100
BUCKETS = 10 if ON_GPU else 5


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


def pick_budget(maxima, headroom=1.25, multiple=8):
    """Per-world budget: p95 of the measured per-step maxima, times headroom, rounded up."""
    p95 = float(np.percentile(maxima, 95))
    return int(np.ceil(p95 * headroom / multiple) * multiple)


def table(rows, title):
    """testspeed._print_table: one row per bucket of steps."""
    print(f"\n{title}:\n{'mean':>8}{'std':>8}{'min':>6}{'max':>6}")
    for r in rows:
        print(f"{r[0]:>8.1f}{r[1]:>8.2f}{r[2]:>6.0f}{r[3]:>6.0f}")


def buckets(values, n):
    return [[np.mean(c), np.std(c), np.min(c), np.max(c)] for c in np.array_split(values, n)]


if ON_GPU:
    MODEL = "test_data/humanoid/humanoid.xml"
    MASK = ["-o", "opt.warn_overflow=~ITERATIONS|~LS_ITERATIONS"]   # abort on buffers only

    def testspeed(*flags):
        cmd = [sys.executable, "-m", "mujoco_warp.testspeed", MODEL, "--nworld", str(NWORLD),
               "--nstep", str(NSTEP), *MASK, *flags]
        r = subprocess.run(cmd, capture_output=True, text=True)
        return r.returncode, r.stdout

    def bucket_rows(out, title):
        """[mean, std, min, max] rows of one testspeed._print_table block."""
        lines = out.splitlines()
        i = lines.index(f"{title}:") + 4      # skip title, blank line, header, separator
        return np.array([[float(x) for x in ln.split()] for ln in lines[i:i + BUCKETS]])

    code, out = testspeed("--measure_alloc", "--num_buckets", str(BUCKETS))
    if code != 0:
        raise RuntimeError("testspeed --measure_alloc failed:\n" + out[-2000:])
    print(out[out.index("nacon alloc:"):])
    nacon, nefc = bucket_rows(out, "nacon alloc"), bucket_rows(out, "nefc alloc")
    nconmax = pick_budget(nacon[:, 3] / NWORLD)           # bucket max: an upper bound
    njmax = pick_budget(nefc[:, 3])
    print(f"bucket max per world: ncon {nacon[:, 3].max() / NWORLD:.1f}, nefc {nefc[:, 3].max():.0f}"
          f" -> pick_budget: nconmax={nconmax}, njmax={njmax}")

    print(f"\n{'budget':<16}{'steps/s':>14}{'data MiB':>10}  result")
    for label, flags in [("default sizes", []),
                         ("measured", ["--nconmax", str(nconmax), "--njmax", str(njmax)])]:
        code, out = testspeed("--format", "json", *flags)
        if code != 0:                                     # "Simulation aborted: overflow ..."
            print(f"{label:<16}  exited {code}: " + " / ".join(out.strip().splitlines()[-3:]))
            continue
        m = json.loads(out.strip().splitlines()[-1])
        print(f"{label:<16}{m['steps_per_second']:>14,.0f}{m['data_memory'] / 2**20:>10.1f}  "
              f"{m['converged_worlds']}/{NWORLD} converged, no buffer overflow")
else:
    print("skipped on CPU: --measure_alloc is a testspeed flag; measuring box_stack(5) by hand")
    mjm = mujoco.MjModel.from_xml_string(box_stack(5))
    rng = np.random.default_rng(0)
    q0 = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
    for b in range(5):                                    # small xy jitter per world and box
        q0[:, 7 * b:7 * b + 2] += rng.uniform(-0.03, 0.03, (NWORLD, 2)).astype(np.float32)


    def run(nconmax, njmax, record=False):
        m = mjw.put_model(mjm)
        m.opt.warn_overflow = 0
        d = mjw.make_data(mjm, nworld=NWORLD, nconmax=nconmax, njmax=njmax)
        d.qpos.assign(q0)
        mjw.step(m, d)                                    # warm-up
        d.qpos.assign(q0)
        d.qvel.zero_()
        wp.synchronize()
        nacon, nefc, t = [], [], 0.0
        for _ in range(NSTEP):
            t0 = time.perf_counter()
            mjw.step(m, d)
            wp.synchronize()
            t += time.perf_counter() - t0
            if record:
                nacon.append(max(d.nacon.numpy()[0], d.ncollision.numpy()[0]))
                nefc.append(d.nefc.numpy().max())
        bits = int(np.bitwise_or.reduce(d.overflow.numpy()))
        top_z = float(d.qpos.numpy()[:, 7 * 4 + 2].mean())
        return np.array(nacon), np.array(nefc), NWORLD * NSTEP / t, bits, top_z, d


    nacon, nefc, *_ , d0 = run(nconmax=64, njmax=256, record=True)
    print(f"generous run: nworld={NWORLD}, naconmax={d0.naconmax}, njmax={d0.njmax}, {NSTEP} steps")
    table(buckets(nacon, BUCKETS), "nacon alloc (all worlds)")
    table(buckets(nefc, BUCKETS), "nefc alloc (worst world)")

    ncon_world = nacon / NWORLD
    nconmax = pick_budget(ncon_world)
    njmax = pick_budget(nefc)
    print(f"\np95 per world: ncon {np.percentile(ncon_world, 95):.1f}, "
          f"nefc {np.percentile(nefc, 95):.1f}"
          f" -> pick_budget: nconmax={nconmax}, njmax={njmax}")

    names = {int(o): o.name for o in mjw.OverflowType if int(o) & (int(o) - 1) == 0 and int(o)}
    print(f"\n{'budget':<22}{'nconmax':>8}{'njmax':>6}{'steps/s':>9}{'top box z':>10}  overflow")
    results = []
    for label, nc, nj in [("default njmax", None, None), ("measured (p95+25%)", nconmax, njmax),
                          ("generous", 64, 256)]:
        _, _, sps, bits, z, d = run(nc, nj)
        flags = "|".join(n for v, n in names.items() if bits & v) or "none"
        print(f"{label:<22}{d.naconmax // NWORLD:>8}{d.njmax:>6}{sps:>9,.0f}{z:>10.3f}  {flags}")
        results.append({"label": label, "nconmax": d.naconmax // NWORLD, "njmax": d.njmax,
                        "sps": round(sps), "z": round(z, 3), "overflow": flags})
    print("stable stack: top box near z = 0.9 (0.1 + 4 * 0.2, minus soft-contact penetration)")

    if args.dump_json:
        with open(args.dump_json, "w") as f:
            json.dump({"nworld": NWORLD, "nstep": NSTEP,
                       "nacon": (nacon / NWORLD).round(2).tolist(), "nefc": nefc.tolist(),
                       "nconmax": nconmax, "njmax": njmax, "runs": results},
                      f, separators=(",", ":"))
        print("wrote", args.dump_json)
