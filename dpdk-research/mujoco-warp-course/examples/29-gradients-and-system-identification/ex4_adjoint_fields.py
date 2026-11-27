"""Example 29.4 - rules on Data fields: in_fields, out_fields, a supported() hook, the
"not declared by this rule" guard, and why a native rule cannot work for an MJWarp function.

spring(m, d) writes d.qfrc_applied = -K * d.qpos (it reads one Data field and writes another).
Its rule declares in_fields=("qpos",) and out_fields=("qfrc_applied",) so the wrapper turns on
gradients for both, and a supported() hook refuses models with nv > 6. A native Warp loss kernel
recorded on the same tape composes with the custom rule: L = 0.5 * sum(qfrc_applied**2), so
dL/dqpos = K**2 * qpos.
Run: python ex4_adjoint_fields.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import diff   # private API

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


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


K = 3.0


@wp.kernel(enable_backward=False)
def spring_kernel(k: float, qpos_in: wp.array2d[float], qfrc_out: wp.array2d[float]):
    w, i = wp.tid()
    qfrc_out[w, i] = -k * qpos_in[w, i]          # hinge-only model: nq == nv


@wp.kernel(enable_backward=False)
def spring_bwd_kernel(k: float, qfrc_grad: wp.array2d[float], qpos_grad_out: wp.array2d[float]):
    w, i = wp.tid()
    qpos_grad_out[w, i] += -k * qfrc_grad[w, i]


@wp.kernel(enable_backward=False)
def spring_damper_kernel(k: float, qpos_in: wp.array2d[float], qvel_in: wp.array2d[float],
                         qfrc_out: wp.array2d[float]):
    w, i = wp.tid()
    qfrc_out[w, i] = -k * qpos_in[w, i] - 0.5 * qvel_in[w, i]


@wp.kernel                                       # plain Warp kernel WITH an adjoint
def half_sq_loss(x: wp.array2d[float], loss: wp.array[float]):
    w, i = wp.tid()
    wp.atomic_add(loss, 0, 0.5 * x[w, i] * x[w, i])


def spring(m, d):
    wp.launch(spring_kernel, dim=(d.nworld, m.nv), inputs=[K, d.qpos], outputs=[d.qfrc_applied])


def spring_bwd(m, d):
    wp.launch(spring_bwd_kernel, dim=(d.nworld, m.nv), inputs=[K, d.qfrc_applied.grad],
              outputs=[d.qpos.grad])
    d.qfrc_applied.grad.zero_()                  # overwritten output: consumed


def spring_ok(m, d):
    return f"nv = {m.nv} > 6" if m.nv > 6 else None   # None / () / [] mean "supported"


def spring_damper(m, d):
    wp.launch(spring_damper_kernel, dim=(d.nworld, m.nv), inputs=[K, d.qpos, d.qvel],
              outputs=[d.qfrc_applied])


w_spring = diff._wrap(spring)
diff.register_adjoint(spring, spring_bwd, in_fields=("qpos",), out_fields=("qfrc_applied",),
                      supported=spring_ok)

# 1. the gradient on a Data field, composed with a native loss kernel on the same tape
NWORLD = 3
mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
d.qpos.assign(np.array([[0.1, -0.2], [0.5, 0.0], [1.0, 0.3]]))
loss = wp.zeros(1, dtype=float, requires_grad=True)
with wp.Tape() as tape:
    w_spring(m, d)                               # custom rule (recorded as a function)
    wp.launch(half_sq_loss, dim=(NWORLD, m.nv), inputs=[d.qfrc_applied], outputs=[loss])
print("recorded:", len(tape.launches), "entries | loss =", round(float(loss.numpy()[0]), 4))
loss.grad.fill_(1.0)
tape.backward()
print("dL/dqpos (tape)   =\n", d.qpos.grad.numpy())
print("K^2 * qpos (exact) =\n", K * K * d.qpos.numpy())

# 2. supported() refuses a model with nv > 6: raised before anything is recorded
mjm5 = mujoco.MjModel.from_xml_string(box_stack(2))
m5, d5 = mjw.put_model(mjm5), mjw.make_data(mjm5, nconmax=8, njmax=32)
try:
    with wp.Tape() as tape5:
        w_spring(m5, d5)
except NotImplementedError as e:
    print("NotImplementedError:", e, "| recorded:", len(tape5.launches))

# 3. a rule that forgets a field the call reads. qvel already has gradients (an earlier rule,
#    or the user, enabled them), so silently reading it would drop its gradient: the wrapper
#    checks the scratch tape's launches and raises.
w_sd = diff._wrap(spring_damper)
diff.register_adjoint(spring_damper, lambda m, d: None,
                      in_fields=("qpos",), out_fields=("qfrc_applied",))
d.qvel.requires_grad = True
try:
    with wp.Tape():
        w_sd(m, d)
except NotImplementedError as e:
    print("NotImplementedError:", e)

# 4. a "native" rule (no backward) asks Warp to replay the forward's own kernel adjoints. MJWarp
#    kernels are compiled with enable_backward=False, so for an API function this must raise.
diff.register_adjoint("kinematics", in_fields=("qpos",), out_fields=("xpos",))
try:
    with wp.Tape():
        mjw.kinematics(m, d)
except NotImplementedError as e:
    print("NotImplementedError:", e)
diff.RULES["kinematics"] = None                  # undo: back to the shipped 4.0.1 state
for n in ("spring", "spring_damper"):          # and drop the rules this script added
    diff.RULES.pop(n, None)
    diff._PARAMS.pop(n, None)
