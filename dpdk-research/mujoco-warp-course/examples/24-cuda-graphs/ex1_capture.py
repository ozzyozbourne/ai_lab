"""Example 24.1 - warm up, capture one mjw.step into a graph, replay it 5 times.

Capturing RECORDS the kernel launches of one step; it does not run them, so d.time is the same
before and after the `with wp.ScopedCapture()` block. Each wp.capture_launch(graph) then runs
the whole recorded step with one call. We also count the launches recorded during capture by
wrapping wp.launch / wp.launch_tiled (the same trick as Example 7.5).
Works on CPU (Warp 1.19 records CPU graphs) and on a CUDA GPU without changes.
Run: python ex1_capture.py
"""
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

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
d.qpos.assign(np.tile(mjm.key_qpos[0], (NWORLD, 1)))      # start horizontal in every world

# Rule G: CUDA < 12.4 has no conditional graph nodes; fall back to fixed iteration counts.
if wp.get_device().is_cuda and not wp.is_conditional_graph_supported():
    m.opt.graph_conditional = False
    print("note: CUDA < 12.4, using m.opt.graph_conditional = False")


def t0():
    return f"{d.time.numpy()[0]:.2f}"


print("device:", wp.get_device(), "| nworld:", NWORLD)
print("after make_data:        d.time =", t0())

mjw.step(m, d)                                  # 1. warm-up: compiles (or loads) every kernel
print("after 1 warm-up step:   d.time =", t0())

# count launches while capturing (wrap the two launch functions MJWarp calls)
count = {"launch": 0, "launch_tiled": 0}
orig = {name: getattr(wp, name) for name in count}


def counting(name):
    def wrapper(*args, **kwargs):
        count[name] += 1
        return orig[name](*args, **kwargs)
    return wrapper


for name in count:
    setattr(wp, name, counting(name))
try:
    with wp.ScopedCapture() as capture:         # 2. record one step
        mjw.step(m, d)
finally:
    for name in count:
        setattr(wp, name, orig[name])
graph = capture.graph
print("after capture:          d.time =", t0(), "(recorded, not executed)")
print(f"launches recorded: {count['launch']} wp.launch + {count['launch_tiled']} "
      f"wp.launch_tiled")

for i in range(5):                              # 3. replay: one call runs the whole step
    wp.capture_launch(graph)
    print(f"after replay {i + 1}:         d.time =", t0())
wp.synchronize()

print("hinge angles, world 0:", d.qpos.numpy()[0])
print("all worlds identical:", bool(np.all(d.qpos.numpy() == d.qpos.numpy()[0])))
