"""Example 21.4 - nvmax: capacity of the compacted (awake-DOF) solve.

With sleep enabled, every step packs the DOFs of awake trees into a dense buffer of nvmax_pad
columns (island.update_active_dofs) and runs the Newton solve there. If more DOFs are awake than
nvmax, the NVMAX overflow bit is set. Part 1: the 6-box scene (nv = 36) with nvmax = 12 while all
boxes are awake. Part 2: the right size. Part 3: the same small nvmax with sleep disabled: the
compacted path never runs, so no bit is ever set (nvmax only matters with SLEEP).
In part 1 the DOFs that did not fit are frozen (qacc 0), so those boxes look still and fall asleep:
the physics is wrong and nothing but the overflow bit tells you.

Run: python ex4_nvmax.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 20


def boxes_xml(sleep):
    flag = '<flag sleep="enable"/>' if sleep else ""
    bodies = "".join(
        f'<body name="box{i}" pos="{0.5 * i:.2f} 0 0.099"><freejoint/>'
        f'<geom type="box" size=".1 .1 .1"/></body>' for i in range(6))
    return (f'<mujoco><option timestep="0.01" solver="Newton">{flag}</option><worldbody>'
            f'<geom name="floor" type="plane" size="5 5 .1"/>{bodies}</worldbody></mujoco>')


def decode(bits):
    return [o.name for o in mjw.OverflowType if bits & o] or ["none"]


def run(sleep, nvmax, label):
    mjm = mujoco.MjModel.from_xml_string(boxes_xml(sleep))
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0                 # we decode the bits ourselves (no printf per world)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128, nvmax=nvmax)
    for _ in range(NSTEP):
        mjw.step(m, d)
    bits = int(np.bitwise_or.reduce(d.overflow.numpy()))
    print(f"{label}: nv {mjm.nv}, nvmax {d.nvmax}, nvmax_pad {d.nvmax_pad}, "
          f"ncdof {d.ncdof.numpy()[0]}, ntree_awake {d.ntree_awake.numpy()[0]} "
          f"-> overflow {decode(bits)}")
    print("   tree_asleep w0", d.tree_asleep.numpy()[0])


run(True, 12, "1. sleep on,  nvmax too small")
run(True, 36, "2. sleep on,  nvmax = nv     ")
run(False, 12, "3. sleep off, nvmax too small")

try:
    mjw.make_data(mujoco.MjModel.from_xml_string(boxes_xml(True)), nvmax=40)
except ValueError as e:
    print("nvmax > nv:", e)
