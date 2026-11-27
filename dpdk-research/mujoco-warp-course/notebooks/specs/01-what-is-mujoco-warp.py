# Notebook spec for Ch 01. Build with:
#   python3 tools/make_notebook.py notebooks/specs/01-what-is-mujoco-warp.py
SLUG = "01-what-is-mujoco-warp"
TITLE = "Ch 01 · What Is MuJoCo Warp?"

CH = "https://github.com/ozzyozbourne/ai_lab/blob/main/dpdk-research/mujoco-warp-course"

EX11_STUB = '''import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

RADIUS, TIMESTEP, H0, G = 0.05, 0.001, 1.0, 9.81
XML = f"""
<mujoco>
  <option timestep="{TIMESTEP}"/>
  <worldbody>
    <geom type="plane" size="5 5 .1"/>
    <body pos="0 0 {H0}"><freejoint/><geom type="sphere" size="{RADIUS}" mass="1"/></body>
  </worldbody>
</mujoco>
"""
t_pred = ...   # your formula
t_sim = ...    # step mjw until the first contact (d.nacon.numpy()[0] > 0), then i * TIMESTEP
if t_pred is ... or t_sim is ...:
    print("Exercise 1.1: fill in t_pred and t_sim, or open the solution")
else:
    assert abs(t_sim - t_pred) / t_pred < 0.05
    print("Exercise 1.1 passed")'''

EX11_SOL = '''mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=4, njmax=16)

t_pred = np.sqrt(2 * (H0 - RADIUS) / G)          # free fall until the surface touches the floor
t_sim = None
for i in range(1, 2000):
    mjw.step(m, d)
    if d.nacon.numpy()[0] > 0:                    # first step with a contact
        t_sim = i * TIMESTEP
        break
print(f"predicted {t_pred:.4f} s, simulated {t_sim:.4f} s")
assert abs(t_sim - t_pred) / t_pred < 0.05
print("Exercise 1.1 passed")'''

EX12_STUB = '''import mujoco
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

BASE = """
<mujoco>
  <option {opt}/>
  <worldbody>
    <geom type="plane" size="1 1 .1"/>
    <body pos="0 0 .5">
      <joint name="j" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".03"/>
    </body>
  </worldbody>
  {act}
</mujoco>
"""
SNIPPETS = {
    "pgs": BASE.format(opt='solver="PGS"', act=""),
    "rk4": BASE.format(opt='integrator="RK4"', act=""),
    "pid": BASE.format(opt="", act='<actuator><pid joint="j" kp="1"/></actuator>'),
    "elliptic": BASE.format(opt='cone="elliptic"', act=""),
}
predictions = {"pgs": ..., "rk4": ..., "pid": ..., "elliptic": ...}   # True = loads


def check(predictions):
    if any(v is ... for v in predictions.values()):
        print("Exercise 1.2: fill in your predictions, or open the solution")
        return
    for name, xml in SNIPPETS.items():
        mjm = mujoco.MjModel.from_xml_string(xml)          # C MuJoCo accepts all four
        try:
            mjw.put_model(mjm)
            loaded = True
        except NotImplementedError as e:
            loaded = False
            print(f"{name}: {e}")
        assert loaded == predictions[name], f"{name}: you predicted {predictions[name]}, got {loaded}"
    print("Exercise 1.2 passed")


check(predictions)'''

EX12_SOL = '''predictions = {"pgs": False, "rk4": True, "pid": False, "elliptic": True}
check(predictions)'''

SUMMARY = '''# Your environment, for bug reports and for comparing with the course's CPU numbers.
import importlib.metadata as md
import platform
import mujoco
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

wp.init()
print("python        :", platform.python_version())
print("mujoco-core   :", md.version("mujoco-core"), "(import mujoco ->", mujoco.__version__ + ")")
print("mujoco-warp   :", md.version("mujoco-warp"))
print("warp-lang     :", wp.__version__)
print("device        :", wp.get_device(), "| CUDA devices:", wp.get_cuda_device_count())
if wp.get_cuda_device_count() > 0:
    dev = wp.get_device("cuda:0")
    print("GPU           :", dev.name, "| memory:", round(dev.total_memory / 2**30, 1), "GiB")
    print("conditional graphs supported:", wp.is_conditional_graph_supported())
print("kernel cache  :", wp.config.kernel_cache_dir)'''

CELLS = [
    ["md", "## How to use this notebook\n"
           "Run the two cells above first: `!nvidia-smi` shows whether the runtime has a GPU, and the setup "
           "cell checks the driver **before** installing, picks the right Warp build (PyPI `warp-lang==1.19.0` "
           "for an R580+ driver, otherwise NVIDIA's `+cu12` wheel), installs pinned versions with the "
           "`[viewer]` extra, sets `wp.config.log_level = wp.LOG_WARNING` right after `import warp`, and "
           "confirms that Warp itself sees the GPU (`ON_GPU`).\n\n"
           "If it prints `WARNING: Warp sees no GPU`, use Runtime > Change runtime type > GPU and run it again. "
           "Every example also runs on CPU with small budgets (that is how the course is verified).\n\n"
           "Pitfalls: the distribution is `mujoco-core` but the import name is `mujoco`; never also "
           "`pip install mujoco` on top."],
    ["md", "## 1. Check the environment (chapter section 6)\n"
           "Versions, the default Warp device, and the GPU count. Note that `md.version('mujoco')` fails: the "
           "distribution is called `mujoco-core`."],
    ["example", "ex1_env_check.py", "1.1"],
    ["md", "## 2. The smallest model\n"
           "The official tutorial's install check: an empty `<mujoco/>` moved to the device with `put_model`. "
           "On the host `opt.timestep` is a float64 number; on the device it is a float32 Warp array with a "
           "leading batch dimension."],
    ["example", "ex2_empty_model.py", "1.2"],
    ["md", "## 3. BALL_DROP in classic C MuJoCo\n"
           "One world, float64, on the CPU. The ball lands at about t = 0.43 s and rests at z = 0.0996 "
           "(contacts are soft, a tiny penetration is normal)."],
    ["example", "ex3_ball_c.py", "1.3"],
    ["md", "## 4. The same ball in MJWarp (nworld = 1)\n"
           "`put_model` / `make_data(nworld=1)` / `mjw.step`, run next to C MuJoCo. The difference stays "
           "around 1e-6 m: float32 vs float64."],
    ["example", "ex4_ball_mjw.py", "1.4"],
    ["md", "## 5. Many worlds\n"
           "1024 worlds on a GPU (8 on CPU), each with its own start height written in place with "
           "`d.qpos.assign`. One `mjw.step` advances them all."],
    ["example", "ex5_ball_1024.py", "1.5"],
    ["md", "## 5b. 256 double pendulums (the chapter's hero replay)\n"
           "Start angles spread over 0.1 rad; chaos spreads them much further within 3 s. "
           "Run with `--dump-json` from a terminal to write the replay frames."],
    ["example", "ex5b_pendulum_grid.py", "1.5b"],
    ["md", "## 6. Why the first step is slow\n"
           "Warp JIT-compiles every kernel module on first use and caches the binaries. This cell prints "
           "**your** timings (they differ on every machine) and counts the kernel launches inside one step.\n\n"
           "Within one notebook process, only the **first** cell that steps pays the compile cost: by now "
           "Examples 1.4 to 1.5b have already compiled and loaded every kernel module, so running Example 1.6 "
           "in this process would show a first step as fast as the second. The next cell therefore writes the "
           "example to a file, and the cell after it runs it twice in **fresh** Python processes: once with the "
           "kernel cache on disk (the first step only loads the binaries), once with `--cold` (an empty, "
           "temporary cache, so every kernel module is compiled from scratch; this takes a while)."],
    ["writefile", "ex6_jit_timing.py", "examples/01-what-is-mujoco-warp/ex6_jit_timing.py"],
    ["code", "# Example 1.6 - run in fresh processes: warm disk cache, then an empty cache (--cold).\n"
             "!python ex6_jit_timing.py\n"
             "!python ex6_jit_timing.py --cold"],
    ["md", "## 7. What is not supported, read from the code (`.deeper`)\n"
           "`put_model` rejects every enum value the MJWarp enums do not contain. Diffing MuJoCo's `mjt*` "
           "enums against MJWarp's lists the unsupported features. This example imports two enums from "
           "`mujoco_warp._src.types` (private API: the name may change)."],
    ["example", "ex7_unsupported_enums.py", "1.7"],
    ["md", "## 8. What an unsupported feature looks like\n"
           "C MuJoCo compiles a PGS model fine; `mjw.put_model` raises `NotImplementedError`."],
    ["example", "ex8_unsupported_pgs.py", "1.8"],
    ["md", "## Exercise 1.1: predict the landing time\n"
           "Change the radius to 0.05 m and the timestep to 0.001 s. Predict when the ball first touches the "
           "floor with the free-fall formula, simulate it, and assert within 5%."],
    ["code", EX11_STUB],
    ["solution", EX11_SOL, "Exercise 1.1"],
    ["md", "## Exercise 1.2: which models will load?\n"
           "Predict `True` (loads) or `False` (rejected by `put_model`) for each of the four snippets, then run "
           "the check."],
    ["code", EX12_STUB],
    ["solution", EX12_SOL, "Exercise 1.2"],
    ["md", "## Stretch: 65536 worlds\n"
           "Copy Example 1.5, raise `NWORLD` through 1024, 4096, 16384 and 65536, warm up with one step, then "
           "time 100 steps (with `wp.synchronize()` before reading the clock) and print world-steps per second. "
           "Where does the number stop growing? Check `d.overflow` at the end."],
    ["code", "# your stretch experiment here"],
    ["md", "## Where to go next\n"
           f"- [Ch 2 · MuJoCo Essentials for MJWarp Users]({CH}/chapters/02-mujoco-essentials.html)\n"
           f"- [Course map]({CH}/reference/course-map.html): every Part, chapter and pipeline stage\n"
           f"- [Repository tour]({CH}/reference/repo-tour.html): what lives where in `mujoco_warp/`\n"
           f"- [API at a glance]({CH}/reference/api-at-a-glance.html): public names and the supported-feature explorer\n"
           f"- [Troubleshooting]({CH}/reference/troubleshooting.html)"],
    ["md", "## Your environment summary\nPrint this when you ask for help or compare numbers."],
    ["code", SUMMARY],
]
