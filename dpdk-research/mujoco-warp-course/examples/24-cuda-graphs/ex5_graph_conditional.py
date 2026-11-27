"""Example 24.5 - m.opt.graph_conditional True vs False on box_stack(5).

True (the default): solver.py records wp.capture_while(nsolving, while_body=_solver_iteration):
the device repeats the iteration until every world has converged. False: the graph holds
m.opt.iterations (100) unrolled copies of the iteration; converged worlds skip the work, but every
copy is still launched. We count the launches recorded, replay NSTEP steps, and compare the mean
d.solver_niter (in a second, untimed pass), the time per step / world-steps per second and the
final qpos.
CPU: Warp 1.19 records CPU graphs (APIC) and replays capture_while there too; timings printed on
CPU are CPU-dev-box numbers, not GPU performance. On CUDA < 12.4 only False can run (Rule G).
Run: python ex5_graph_conditional.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 1000 if ON_GPU else 100
REPEAT = 3
COND_OK = (not ON_GPU) or wp.is_conditional_graph_supported()

print("device:", wp.get_device())
print("wp.is_conditional_graph_supported():", wp.is_conditional_graph_supported())
if not ON_GPU:
    print("CPU: conditional nodes replay through Warp's CPU graph recorder (no CUDA needed)")

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
orig_launch, orig_tiled = wp.launch, wp.launch_tiled


def capture_counting(m, d):
    """Capture one step and count the wp.launch / wp.launch_tiled calls recorded."""
    n = [0]

    def launch(*a, **k):
        n[0] += 1
        return orig_launch(*a, **k)

    def tiled(*a, **k):
        n[0] += 1
        return orig_tiled(*a, **k)

    wp.launch, wp.launch_tiled = launch, tiled
    try:
        with wp.ScopedCapture() as capture:
            mjw.step(m, d)
    finally:
        wp.launch, wp.launch_tiled = orig_launch, orig_tiled
    return capture.graph, n[0]


results = {}
for gc in (True, False):
    if gc and not COND_OK:
        print("graph_conditional=True: skipped (CUDA < 12.4 has no conditional graph nodes)")
        continue
    m = mjw.put_model(mjm)
    m.opt.graph_conditional = gc
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
    mjw.step(m, d)                                   # warm-up
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)   # fresh state, same start
    graph, nlaunch = capture_counting(m, d)
    # timed passes: NSTEP replays between two synchronize calls, no host reads inside;
    # best of REPEAT runs, each from the same start (reset in place keeps the recorded addresses)
    sec = float("inf")
    for _ in range(REPEAT):
        mjw.reset_data(m, d)
        wp.synchronize()
        t = time.perf_counter()
        for _ in range(NSTEP):
            wp.capture_launch(graph)
        wp.synchronize()
        sec = min(sec, time.perf_counter() - t)
    ms, wsps = sec / NSTEP * 1e3, NWORLD * NSTEP / sec
    q_timed = d.qpos.numpy().copy()
    # untimed pass from the same start: reset in place (same addresses), replay, sample niter
    mjw.reset_data(m, d)
    niter = []
    for i in range(NSTEP):
        wp.capture_launch(graph)
        if i % 10 == 0:                              # a host read: fine here, this pass is not timed
            niter.append(d.solver_niter.numpy().mean())
    results[gc] = d.qpos.numpy().copy()
    rerun = np.abs(q_timed - results[gc]).max()
    if ON_GPU:   # contact scenes are not bitwise reproducible on a GPU (Ch 22): float noise only
        assert np.allclose(q_timed, results[gc], atol=1e-4), f"untimed pass drifted: {rerun:.2e}"
    else:        # on CPU the replay is exact
        assert rerun == 0.0, f"untimed pass should repeat the timed one: {rerun:.2e}"
    print(f"graph_conditional={gc!s:5}: {nlaunch:5d} launches recorded, "
          f"mean solver_niter {np.mean(niter):.2f}, {ms:.3f} ms/step, {wsps:,.0f} world-steps/s"
          f"{'' if ON_GPU else ' (CPU dev box)'}, nefc w0 {d.nefc.numpy()[0]}, "
          f"overflow {'none' if not d.overflow.numpy().any() else d.overflow.numpy()}")

if len(results) == 2:
    diff = np.abs(results[True] - results[False]).max()
    print(f"max |qpos(True) - qpos(False)| after {NSTEP} steps: {diff:.2e}")
    print("exact on this run" if diff == 0 else "agrees to float noise (on a GPU, contacts reorder; Ch 22)"
          if diff < 1e-4 else "LARGER than float noise: check the run")
