"""Example 8.7 - control in the loop: step1, a PD controller kernel, step2.

PENDULUM: a PD law on hinge1 reads the jointpos/jointvel sensors that step1 just computed and
writes d.ctrl; step2 finishes the step. Each world tracks a different target angle.
Run: python ex07_step1_step2_pd.py [--dump-json PATH]
  --dump-json PATH writes the hinge1 angle of 8 worlds every 5 steps (Rule D, tracking plot).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 300  # 3 s
KP, KD = 50.0, 5.0


@wp.kernel
def pd_control(sensordata_in: wp.array2d[float], target_in: wp.array[float], kp: float,
               kd: float, ctrl_out: wp.array2d[float]):
    worldid = wp.tid()
    q = sensordata_in[worldid, 0]   # sensor "q1" (adr 0)
    qd = sensordata_in[worldid, 1]  # sensor "v1" (adr 1)
    ctrl_out[worldid, 0] = kp * (target_in[worldid] - q) - kd * qd


mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
print("sensor adr:", mjm.sensor_adr, "| integrator:", mjw.IntegratorType(m.opt.integrator).name)
target = wp.array(0.1 + 0.3 * (np.arange(NWORLD) % 8) / 7, dtype=float)  # 0.1 .. 0.4 rad
tgt = target.numpy()


def run(split):
    mjw.reset_data(m, d)
    errs = []
    for i in range(NSTEP):
        if split:
            mjw.step1(m, d)          # positions, velocities, sensors (pos + vel) are fresh
            wp.launch(pd_control, dim=d.nworld, inputs=[d.sensordata, target, KP, KD],
                      outputs=[d.ctrl])
            mjw.step2(m, d)          # actuation, acceleration, solve, integrate
        else:
            # plain step: the controller sees the sensors of the previous step
            wp.launch(pd_control, dim=d.nworld, inputs=[d.sensordata, target, KP, KD],
                      outputs=[d.ctrl])
            mjw.step(m, d)
        errs.append(tgt - d.qpos.numpy()[:, 0])  # host read every step: demo only
    return np.array(errs)


e_split = run(split=True)
print("tracking error q1* - q1 [rad], step1/step2, worlds 0, 3, 7:")
for k in range(49, NSTEP, 50):
    print(f"  t = {0.01 * (k + 1):.1f} s  {e_split[k][[0, 3, 7]]}")
# link2 swings freely (no damping), so the error oscillates around the static value
# g * (m1 * 0.25 + m2 * 0.5) * sin(q*) / kp  (link2 hanging straight down).
print("mean error over the last 1 s:", e_split[-100:].mean(axis=0)[[0, 3, 7]])
print("static estimate g*0.75*sin(q*)/kp: ", np.round(9.81 * 0.75 * np.sin(tgt[[0, 3, 7]]) / KP, 4))
if args.dump_json:
    q = tgt[None, :8] - e_split[::5, :8]
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": 8, "dt": 5 * float(mjm.opt.timestep),
                   "target": np.round(tgt[:8], 3).tolist(), "frames": np.round(q, 3).tolist()},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json, len(q), "frames")
e_plain = run(split=False)
print("max |error| difference, step1/step2 vs step with 1-step-old sensors at 3 s:",
      f"{np.abs(e_split[-1] - e_plain[-1]).max():.2e}")

# RK4 caveat: step2 always integrates with Euler (forward.py: "RK4 defaults to Euler")
mjw.reset_data_keyframe(m, d, 0)
s0 = wp.zeros((NWORLD, mujoco.mj_stateSize(mjm, int(mjw.State.INTEGRATION))), dtype=float)
mjw.get_state(m, d, s0, int(mjw.State.INTEGRATION))
res = {}
for name, integ, split in [("euler step", mjw.IntegratorType.EULER, False),
                           ("rk4 step", mjw.IntegratorType.RK4, False),
                           ("rk4 step1+step2", mjw.IntegratorType.RK4, True)]:
    m.opt.integrator = integ
    mjw.set_state(m, d, s0, int(mjw.State.INTEGRATION))
    for _ in range(20):
        if split:
            mjw.step1(m, d)
            mjw.step2(m, d)
        else:
            mjw.step(m, d)
    res[name] = d.qpos.numpy()[0].copy()
d_rk4 = np.abs(res["rk4 step"] - res["rk4 step1+step2"]).max()
d_eul = np.abs(res["euler step"] - res["rk4 step1+step2"]).max()
print(f"RK4: |step - step1/step2|      = {d_rk4:.2e}")
print(f"RK4 step1/step2 vs Euler step  = {d_eul:.2e}")
