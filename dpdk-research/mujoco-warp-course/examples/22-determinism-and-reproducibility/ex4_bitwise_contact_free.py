"""Example 22.4 - bitwise reproducibility of contact-free models under DeterminismType.ATOMICS.

Without contacts there is no contact slot order and no contact rows. If, in addition, each world has
at most one active limit, friction-loss or equality row, float atomics are the only source of
run-to-run noise, and ATOMICS removes it: the double PENDULUM (no limits, no rows) is such a model.
The HUMANOID with DisableBit.CONTACT is not: it falls into its joint limits, and the limit kernels
reserve rows with the same racy wp.atomic_add(nefc_out, worldid, 1) as contacts, which ATOMICS
does not cover. We run both, NWORLD worlds with different start velocities and controls, twice per
mode, and compare qpos, qvel and qacc bit for bit.
GPU (Colab): PENDULUM with ATOMICS is bitwise equal by construction. HUMANOID with ATOMICS is
bitwise equal only if the limit rows happen to keep their order; determinism_test.py observes
equality for its contact-free scenes on 2 worlds x 3 steps, which is not a guarantee. With NONE
either model may differ in the low bits. CPU: Warp runs threads in order, so every run matches.
Run: python ex4_bitwise_contact_free.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""
HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 8
NSTEP = 200 if ON_GPU else 30
FIELDS = ("qpos", "qvel", "qacc")


def run(mjm, mode, qvel0, ctrl0):
    """One rollout from a fixed per-world start; returns copies of FIELDS."""
    m = mjw.put_model(mjm)
    m.opt.deterministic = mode
    d = mjw.make_data(mjm, nworld=NWORLD)
    d.qvel.assign(qvel0)
    d.ctrl.assign(ctrl0)
    for _ in range(NSTEP):
        mjw.step(m, d)
    return {f: getattr(d, f).numpy().copy() for f in FIELDS}


def bitwise_equal(r1, r2):
    return all(r1[f].tobytes() == r2[f].tobytes() for f in FIELDS)


humanoid = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
humanoid.opt.disableflags |= mujoco.mjtDisableBit.mjDSBL_CONTACT   # = mjw.DisableBit.CONTACT
humanoid.opt.ls_iterations = 50   # joint limits engage; 20 trips the LS_ITERATIONS warning
models = [("HUMANOID (contacts off)", humanoid),
          ("PENDULUM", mujoco.MjModel.from_xml_string(PENDULUM))]
print(f"device: {wp.get_device()} | nworld {NWORLD} | {NSTEP} steps")
equal = {}                                     # (model, mode) -> run1 and run2 bitwise equal
for name, mjm in models:
    rng = np.random.default_rng(0)
    qvel0 = (0.1 * rng.standard_normal((NWORLD, mjm.nv))).astype(np.float32)
    ctrl0 = (0.2 * rng.standard_normal((NWORLD, mjm.nu))).astype(np.float32)
    res = {}
    for mode in (mjw.DeterminismType.NONE, mjw.DeterminismType.ATOMICS):
        r1, r2 = run(mjm, mode, qvel0, ctrl0), run(mjm, mode, qvel0, ctrl0)
        res[mode] = r1
        equal[name, mode.name] = bitwise_equal(r1, r2)
        dq = np.abs(r1["qpos"] - r2["qpos"]).max()
        print(f"{name:24s} {mode.name:7s} run1 vs run2: max |dqpos| = {dq:.3g}, "
              f"bitwise equal: {equal[name, mode.name]}")
    dq = np.abs(res[mjw.DeterminismType.NONE]["qpos"] - res[mjw.DeterminismType.ATOMICS]["qpos"])
    print(f"{name:24s} NONE vs ATOMICS: max |dqpos| = {dq.max():.3g}"
          f" (only the summation order may differ)")
    print(f"{name:24s} worlds distinct: {not np.array_equal(r1['qacc'][0], r1['qacc'][1])}")
