# Notebook spec for Chapter 24. Build with:
#   python3 tools/make_notebook.py notebooks/specs/24-cuda-graphs.py
SLUG = "24-cuda-graphs"
TITLE = "Ch 24 · CUDA Graphs: Capture, Replay and What Gets Baked"

EX1_HEAD = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"/>
  <worldbody>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
</mujoco>
"""
NWORLD, NSTEP = 4, 50
mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
if wp.get_device().is_cuda and not wp.is_conditional_graph_supported():
    m.opt.graph_conditional = False                 # Rule G fallback
d = mjw.make_data(mjm, nworld=NWORLD)
q0 = np.zeros((NWORLD, 2), dtype=np.float32)
q0[:, 0] = np.linspace(0.5, 2.0, NWORLD)


def restart():
    d.qpos.assign(q0)
    d.qvel.zero_()
    d.time.zero_()
'''

EX1_STUB = EX1_HEAD + r'''
# 1. restart(), step NSTEP times eagerly, keep a copy of d.qpos in `eager`
# 2. restart(), capture ONE mjw.step, replay it NSTEP times, read d.qpos into `graph`
eager = None  # TODO
graph = None  # TODO
assert isinstance(eager, np.ndarray) and isinstance(graph, np.ndarray), "fill in eager and graph"
assert np.array_equal(graph, eager), np.abs(graph - eager).max()
print("graph replay == eager stepping")
'''

EX1_SOL = EX1_HEAD + r'''
restart()
for _ in range(NSTEP):
    mjw.step(m, d)
eager = d.qpos.numpy().copy()

restart()
with wp.ScopedCapture() as capture:       # recording does not advance d
    mjw.step(m, d)
for _ in range(NSTEP):
    wp.capture_launch(capture.graph)
graph = d.qpos.numpy()

assert np.array_equal(graph, eager), np.abs(graph - eager).max()
print("graph replay == eager stepping")   # exact on CPU; on a GPU contact scenes may differ in low bits
'''

EX2_HEAD = r'''
import mujoco
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

mjm = mujoco.MjModel.from_xml_string("<mujoco><worldbody><body><freejoint/>"
                                     "<geom size='.1'/></body></worldbody></mujoco>")
m = mjw.put_model(mjm)
'''

EX2_STUB = EX2_HEAD + r'''
def needs_recapture(field):
    """True if a graph captured before changing m.opt.<field> must be captured again."""
    ...  # hint: what kind of Python object is getattr(m.opt, field)?

assert needs_recapture("timestep") is False
assert needs_recapture("tolerance") is False
assert needs_recapture("iterations") is True
assert needs_recapture("ls_iterations") is True
assert needs_recapture("integrator") is True
print("needs_recapture OK on 5 fields")
'''

EX2_SOL = EX2_HEAD + r'''
def needs_recapture(field):
    """True if a graph captured before changing m.opt.<field> must be captured again.

    Array fields are read from device memory at replay (live: change them in place);
    everything else is a Python value read while recording (baked).
    """
    return not isinstance(getattr(m.opt, field), wp.array)

assert needs_recapture("timestep") is False
assert needs_recapture("tolerance") is False
assert needs_recapture("iterations") is True
assert needs_recapture("ls_iterations") is True
assert needs_recapture("integrator") is True
print("needs_recapture OK on 5 fields;", "gravity:", needs_recapture("gravity"),
      "| warn_overflow:", needs_recapture("warn_overflow"))
'''

STRETCH = r'''
# Stretch: where does your GPU saturate with graphs?
# Re-run Example 24.4 with a finer sweep, e.g. NWORLDS = [2**k for k in range(0, 18)], and find the
# nworld where graph world-steps/s stops growing (the step time starts to grow with nworld).
# Repeat with box_stack(5) (nconmax=32, njmax=128) instead of BALL_DROP: does it saturate earlier?
'''

CELLS = [
    ["md", "This notebook mirrors the chapter page: every example in page order (24.1, 24.2, 24.3, 24.6, 24.5, 24.8, 24.4, 24.7). It runs on a GPU runtime "
           "(big budgets) and on CPU (small budgets, `ON_GPU = False`). Numbers printed on CPU are CPU "
           "numbers, not GPU performance; on Colab you get your own GPU numbers."],
    ["md", "## The running project: `my_env.py` (snapshot after Ch 24)\nThis chapter adds "
           "`needs_conditional_fallback(device)` and `capture_step(m, d, nsub=1, post=None)`. The cell "
           "writes the whole module so the notebook runs in an empty Colab runtime."],
    ["writefile", "my_env.py", "examples/24-cuda-graphs/my_env_step24.py"],
    ["md", "## 1. Capture once, replay many times\nWarm up (compile), record one `mjw.step` inside "
           "`wp.ScopedCapture()`, then replay with `wp.capture_launch(graph)`. Watch `d.time`: capturing "
           "records the launches and does not run them."],
    ["example", "ex1_capture.py", "24.1"],
    ["md", "## 2. Baked vs live\nArray *contents* (`d.ctrl`, `m.opt.timestep`) are read at replay time. "
           "Python values (`m.opt.integrator`) were read while recording, so the graph ignores changes."],
    ["example", "ex2_baked_vs_live.py", "24.2"],
    ["md", "## 3. Replacing an array after capture\nThe graph holds addresses. `d.qpos = wp.array(...)` "
           "points `d` at new memory the graph never touches. Use `.assign()`, or recapture."],
    ["example", "ex3_replace_after_capture.py", "24.3"],
    ["md", "## 4. The knob board\nThis example counts the Warp modules that a change compiles, so it must "
           "run in a fresh Python process: the cell writes the file and runs it with `!python`."],
    ["writefile", "ex6_knob_board.py", "examples/24-cuda-graphs/ex6_knob_board.py"],
    ["code", "!python ex6_knob_board.py"],
    ["md", "## 5. Conditional graph nodes: `graph_conditional` True vs False\nWith True the solver loop "
           "is one `wp.capture_while` node; with False the graph holds `m.opt.iterations` copies of the "
           "iteration. Compare launches recorded, mean `solver_niter`, time per step and the results."],
    ["example", "ex5_graph_conditional.py", "24.5"],
    ["md", "## 6. Toolkit and driver check\nConditional nodes need CUDA >= 12.4 for both the toolkit Warp "
           "was built with and the driver. `put_model` only warns; `capture_step` (defined in `my_env.py` above) applies the fallback."],
    ["example", "ex8_toolkit_check.py", "24.8"],
    ["md", "## 7. Measuring eager vs graph throughput\nWarm up, `wp.synchronize()` before reading the "
           "clock, report world-steps/s. Uses `my_env.capture_step`. On a GPU the sweep goes to 65536 "
           "worlds; set `--plot` or run here to see the log-log chart."],
    ["example", "ex4_eager_vs_graph.py", "24.4"],
    ["md", "## 8. Substeps and your own kernels in one graph\n`capture_step(m, d, nsub=4, post=...)` "
           "records 4 physics steps plus a reward kernel; one replay is one control step."],
    ["example", "ex7_substeps_and_kernels.py", "24.7"],
    ["md", "## Exercise 24.1: a graph replays the same trajectory as eager stepping\nCapture one step, "
           "replay it NSTEP times, and assert the final `d.qpos` equals NSTEP eager steps from the same "
           "start (exact on CPU)."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 24.1"],
    ["md", "## Exercise 24.2: `needs_recapture(field)`\nTurn the knob-board rule into code and assert it on "
           "five Option fields."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 24.2"],
    ["md", "## Stretch: find the nworld where your GPU saturates"],
    ["code", STRETCH],
]
