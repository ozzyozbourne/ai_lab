# Notebook spec for Chapter 25. Build with:
#   python3 tools/make_notebook.py notebooks/specs/25-profiling-benchmarking-tuning.py
SLUG = "25-profiling-benchmarking-tuning"
TITLE = "Ch 25 · Profiling, Benchmarking and Tuning for Throughput"

EX1_HEAD = r'''
import numpy as np

# Per-step maxima measured by Example 25.6 on box_stack(5), nworld=8, 100 steps (CPU run):
# contacts per world (max(nacon, ncollision) / nworld) and constraint rows of the worst world.
NCON = [1, 4, 4, 8, 8, 12, 12, 16] + [20] * 92
NEFC = [0, 16, 16, 32, 32, 48, 48, 64] + [80] * 92
'''

EX1_STUB = EX1_HEAD + r'''

def pick_budget(maxima, headroom=1.25, multiple=8):
    """Return the smallest multiple of `multiple` that is >= p95(maxima) * headroom."""
    ...


assert pick_budget(NCON) == 32
assert pick_budget(NEFC) == 104
assert pick_budget(NEFC, headroom=1.0) == 80
assert pick_budget([10] * 20, headroom=1.0) == 16
print("pick_budget OK:", pick_budget(NCON), pick_budget(NEFC))
'''

EX1_SOL = EX1_HEAD + r'''

def pick_budget(maxima, headroom=1.25, multiple=8):
    """Return the smallest multiple of `multiple` that is >= p95(maxima) * headroom."""
    p95 = float(np.percentile(maxima, 95))
    return int(np.ceil(p95 * headroom / multiple) * multiple)


assert pick_budget(NCON) == 32
assert pick_budget(NEFC) == 104
assert pick_budget(NEFC, headroom=1.0) == 80
assert pick_budget([10] * 20, headroom=1.0) == 16
print("pick_budget OK:", pick_budget(NCON), pick_budget(NEFC))
'''

EX2_HEAD = r'''
import json

# A subset of one testspeed --format json line, built from a single run: the CPU stand-in trace of
# Example 25.1 (nworld=8, 20 steps, data/ex1_trace.json), trace keys in ns per world-step with the
# 4.0.1 tree, and steps_per_second = 1e9 / step so both agree. CPU numbers, not GPU performance.
SAMPLE = (
    '{"run_time": 0.2015, "steps_per_second": 794.2167, "converged_worlds": 8, '
    '"step": 1259102.15, "step.forward": 1219653.79, "step.euler": 38863.05, '
    '"step.forward.fwd_position": 691028.73, '
    '"step.forward.fwd_position.fwd_kinematics": 81632.62, '
    '"step.forward.fwd_position.collision": 452981.55, '
    '"step.forward.fwd_position.fwd_kinematics.kinematics": 34824.56}'
)
'''

EX2_STUB = EX2_HEAD + r'''

def parse_testspeed(json_text, nworld):
    """Return {"sps", "ns_per_world_step", "ok", "children"} from one testspeed JSON line.

    ok: every world converged; children(prefix) -> {child name: ns} one level below prefix."""
    ...


r = parse_testspeed(SAMPLE, nworld=8)
assert round(r["sps"]) == 794
assert abs(r["ns_per_world_step"] - 1e9 / 794.2167) < 1e-6
assert r["ok"] is True and parse_testspeed(SAMPLE, nworld=16)["ok"] is False
assert r["children"]("step") == {"forward": 1219653.79, "euler": 38863.05}
assert r["children"]("step.forward.fwd_position") == {"fwd_kinematics": 81632.62,
                                                      "collision": 452981.55}
assert r["children"]("step.forward.fwd_position.fwd_kinematics") == {"kinematics": 34824.56}
print("parse_testspeed OK")
'''

EX2_SOL = EX2_HEAD + r'''

def parse_testspeed(json_text, nworld):
    """Return {"sps", "ns_per_world_step", "ok", "children"} from one testspeed JSON line.

    ok: every world converged; children(prefix) -> {child name: ns} one level below prefix."""
    m = json.loads(json_text.strip().splitlines()[-1])
    sps = m["steps_per_second"]

    def children(prefix):
        depth = prefix.count(".") + 1
        return {k[len(prefix) + 1:]: v for k, v in m.items()
                if k.startswith(prefix + ".") and k.count(".") == depth}

    return {"sps": sps, "ns_per_world_step": 1e9 / sps, "ok": m["converged_worlds"] == nworld,
            "children": children}


r = parse_testspeed(SAMPLE, nworld=8)
assert round(r["sps"]) == 794
assert abs(r["ns_per_world_step"] - 1e9 / 794.2167) < 1e-6
assert r["ok"] is True and parse_testspeed(SAMPLE, nworld=16)["ok"] is False
assert r["children"]("step") == {"forward": 1219653.79, "euler": 38863.05}
assert r["children"]("step.forward.fwd_position") == {"fwd_kinematics": 81632.62,
                                                      "collision": 452981.55}
assert r["children"]("step.forward.fwd_position.fwd_kinematics") == {"kinematics": 34824.56}
print("parse_testspeed OK")
'''

STRETCH = r'''
# Stretch (GPU): reproduce the nightly humanoid row on your Colab GPU.
# The humanoid benchmark is {"nworld": 8192, "nconmax": 24, "njmax": 64} (benchmarks/humanoid/
# __init__.py) and run.py adds --event_trace --memory --measure_solver --measure_alloc.
# The shipped test_data humanoid is a close stand-in; for the exact MJCF clone the repo:
#   !git clone -q https://github.com/google-deepmind/mujoco_warp && cd mujoco_warp && git checkout 8f5b9f1
#   !mjwarp-testspeed mujoco_warp/benchmarks/humanoid/humanoid.xml --nworld 8192 --nconmax 24 \
#        --njmax 64 --format json --event_trace
# Compare steps_per_second and step.forward.* with your own trace from Example 25.1.
if ON_GPU:
    !mjwarp-testspeed test_data/humanoid/humanoid.xml --nworld 8192 --nconmax 24 --njmax 64 --format short --event_trace
else:
    print("skipped on CPU: mjwarp-testspeed is GPU only")
'''

CHECKLIST = r'''
# Part VI tuning checklist (Ch 25 section 8). Fill in your own numbers on the GPU.
CHECKLIST = [
    ("nworld",            "raise until world-steps/s stops growing (Ch 24 sweep)"),
    ("nconmax / njmax",   "p95 of --measure_alloc + headroom; zero overflow (Ch 9, Example 25.6)"),
    ("solver + iterations", "Newton for stiff contact; cap iterations near the converged count (Ch 20)"),
    ("cone",              "pyramidal: 2(condim-1) rows per contact; elliptic: condim rows; measure"),
    ("broadphase",        "NXN for small scenes, SAP_TILE / SAP_SEGMENTED for many geoms (Ch 15)"),
    ("integrator",        "Euler / implicitfast; RK4 runs forward 4 times per step (Ch 13)"),
    ("determinism",       "off unless you need bitwise replays (Ch 22)"),
    ("sleep",             "enable for scenes that come to rest (Ch 21)"),
    ("CUDA graphs",       "capture step (+ your kernels); recapture after baked changes (Ch 24)"),
    ("warn_overflow",     "set before the first launch: it is wp.static (recompile)"),
]
for knob, rule in CHECKLIST:
    print(f"[ ] {knob:<20} {rule}")
'''

ICICLE = r'''
# Figure 25.5 from YOUR run: an icicle chart of `tree` (left by Example 25.1).
# Width = ns per world-step, rows = nesting depth. Numbers above were printed first (Rule O).
try:
    import matplotlib.pyplot as plt
except ImportError:
    print("skipped: matplotlib not installed")
else:
    label = f"your GPU ({wp.get_device()})" if ON_GPU else "CPU stand-in (wall clock), not GPU performance"
    fig, ax = plt.subplots(figsize=(11, 3.2))
    colors = plt.cm.tab20.colors

    def draw(nodes, x0, depth, scale, max_depth=4):
        x = x0
        for i, (name, node) in enumerate(nodes.items()):
            w = node["ns"] * scale
            ax.barh(-depth, w, left=x, height=0.9, color=colors[(depth * 5 + i) % 20],
                    edgecolor="white", linewidth=0.5)
            if w > 0.04:                              # label only boxes wide enough to read
                ax.text(x + w / 2, -depth, name, ha="center", va="center", fontsize=7, clip_on=True)
            if depth + 1 < max_depth:
                draw(node["sub"], x, depth + 1, scale, max_depth)
            x += w

    draw(tree, 0.0, 0, 1.0 / tree["step"]["ns"])
    ax.set_xlim(0, 1); ax.set_yticks([0, -1, -2, -3], ["step", "depth 1", "depth 2", "depth 3"])
    ax.set_xlabel(f"fraction of step = {tree['step']['ns']:,.0f} ns per world-step")
    ax.set_title(f"EventTracer tree, {label}")
    plt.tight_layout(); plt.show()
'''

CELLS = [
    ["md", "This notebook mirrors the chapter page: every example in order. On a GPU runtime the "
           "examples call the real `mjwarp-testspeed` and `EventTracer`; on CPU they print a skip note "
           "and run a small hand-made stand-in. Numbers printed on CPU are CPU numbers, not GPU "
           "performance; on Colab you get your own GPU numbers."],
    ["md", "## 1. Profile one captured step with `EventTracer`\n`with EventTracer(enabled=ON_GPU)` "
           "around a captured step; `trace()` after each replay gives `{name: (ms, sub)}`. Divide by "
           "`nworld` (and the number of replays) for ns per world-step, the unit testspeed prints."],
    ["example", "ex1_event_trace.py", "25.1"],
    ["md", "Draw Figure 25.5 from the trace you just recorded: on a GPU runtime this is your own "
           "`EventTracer` tree; on CPU it is the wall-clock stand-in, labelled as such."],
    ["code", ICICLE],
    ["md", "## 2. `mjwarp-testspeed` and its JSON\nThe model path falls back to the installed package, "
           "so `test_data/humanoid/humanoid.xml` works without a clone. On CPU testspeed raises "
           "`ValueError: testspeed available for gpu only`; the example then runs `mini_testspeed`."],
    ["example", "ex2_testspeed.py", "25.2"],
    ["md", "## 3. What `--noise_std` and `--function` change\nWithout ctrl noise every world repeats "
           "world 0; `--function forward` never advances time. `--function` accepts only public "
           "functions whose parameters are exactly `(m, d)` or `(m, d, rc)`."],
    ["example", "ex3_testspeed_noise_function.py", "25.3"],
    ["md", "## 4. Solver settings with `-o/--override`\n`io.override_model` mutates in place and returns "
           "`None`; testspeed applies it to the `MjModel` and again to the `mjw.Model`."],
    ["example", "ex4_overrides.py", "25.4"],
    ["md", "## 5. Control trajectories\n`find_keys`, `make_trajectory` (linear interpolation of ctrl "
           "keyframes), `load_trajectory` (zero-order hold of an NPZ). Note testspeed's ctrl filter: "
           "set `--noise_rate 1e-6` as well as `--noise_std 0` for an exact replay."],
    ["example", "ex5_trajectory_replay.py", "25.5"],
    ["md", "## 6. Size buffers from measured counts\n`--measure_alloc` reports per-bucket mean/std/min/"
           "max of `nacon` (all worlds) and `nefc` (worst world). Pick p95 + headroom, rerun, and check "
           "that nothing overflows."],
    ["example", "ex6_measure_alloc.py", "25.6"],
    ["md", "## 7. Memory versus nworld\nData grows linearly with nworld; `njmax` sets the slope of the "
           "constraint arrays. On a GPU the example also prints the nworld that fits in memory."],
    ["example", "ex7_memory_vs_nworld.py", "25.7"],
    ["md", "## 8. A tuning study on `box_stack(8)`\nOne knob per row; a row only counts if it has no "
           "overflow and the correctness probe (top box height) does not move. Graph replay on GPU."],
    ["example", "ex8_tuning_study.py", "25.8"],
    ["md", "## Part VI tuning checklist\nPrint it, then fill in your own GPU numbers next to each item."],
    ["code", CHECKLIST],
    ["md", "## Exercise 25.1: `pick_budget(maxima, headroom)`\nTurn the sizing rule into a function and "
           "assert it on the data from Example 25.6."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 25.1"],
    ["md", "## Exercise 25.2: `parse_testspeed(json_text, nworld)`\nParse one `--format json` line: "
           "throughput, ns per world-step, the converged check and the trace children of a prefix."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 25.2"],
    ["md", "## Stretch: reproduce a nightly benchmark row on your GPU"],
    ["code", STRETCH],
]
