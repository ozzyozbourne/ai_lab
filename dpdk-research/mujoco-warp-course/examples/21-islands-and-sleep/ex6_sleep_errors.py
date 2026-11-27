"""Example 21.6 - the sleep requirements, as an error gallery.

  (a) a body with sleep="init" (or "never" / "allowed")  -> NotImplementedError from put_model
  (b) sleep with solver="CG"                              -> ValueError from put_model
  (c) a flex equality constraint with sleep               -> NotImplementedError from put_model
  (d) SLEEP plus <flag island="disable"/>                 -> no error, but nothing ever sleeps
      4.0.1 pitfall: make_data then skips the compacted buffers (cM has shape (0, 0, 0)) although
      solver.solve still takes the compacted path. Pass nvmax explicitly or the step reads
      unallocated memory (a segfault on CPU). We only print the shapes, then step with nvmax=nv.
  (e) what sleep="auto" compiles to: an actuated tree gets AUTO_NEVER, a passive one AUTO_ALLOWED

Run: python ex6_sleep_errors.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2


def scene(option="", flags='sleep="enable"', body_attr="", extra=""):
    return (f'<mujoco><option timestep="0.01" {option}><flag {flags}/></option><worldbody>'
            '<geom type="plane" size="5 5 .1"/>'
            f'<body pos="0 0 .099" {body_attr}><freejoint/><geom type="box" size=".1 .1 .1"/></body>'
            f'<body pos=".5 0 .099"><freejoint/><geom type="box" size=".1 .1 .1"/></body>'
            f'{extra}</worldbody></mujoco>')


def try_put(label, xml):
    mjm = mujoco.MjModel.from_xml_string(xml)
    try:
        mjw.put_model(mjm)
        print(f"{label}: put_model OK")
    except (NotImplementedError, ValueError) as e:
        print(f"{label}: {type(e).__name__}: {e}")


for policy in ("init", "never", "allowed", "auto"):
    try_put(f'(a) body sleep="{policy}"', scene(body_attr=f'sleep="{policy}"'))
try_put('(b) solver="CG"', scene(option='solver="CG"'))
CLOTH = ('<flexcomp name="cloth" type="grid" count="3 3 1" spacing=".1 .1 .1" dim="2" '
         'pos="0 0 .6"><edge equality="true"/></flexcomp>')
try_put("(c) flex edge equality", scene(extra=CLOTH))

xml = scene(flags='sleep="enable" island="disable"')
mjm = mujoco.MjModel.from_xml_string(xml)
m = mjw.put_model(mjm)
d_bad = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
print("(d) island disabled, no nvmax:  cM shape", d_bad.cM.shape, "-> do not step this Data")
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64, nvmax=mjm.nv)
print("(d) island disabled, nvmax=nv:  cM shape", d.cM.shape)
for _ in range(100):
    mjw.step(m, d)
print("(d) after 100 resting steps: tree_asleep", d.tree_asleep.numpy()[0],
      "max |qvel|", round(float(np.abs(d.qvel.numpy()).max()), 6))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

ARM = ('<body pos="0 1 .5"><joint name="hinge" type="hinge"/><geom type="capsule" size=".03" '
       'fromto="0 0 0 .3 0 0"/></body>')
mjm = mujoco.MjModel.from_xml_string(
    scene(extra=ARM).replace("</mujoco>", '<actuator><motor joint="hinge"/></actuator></mujoco>'))
print("(e) tree_sleep_policy:", [mujoco.mjtSleepPolicy(p).name for p in mjm.tree_sleep_policy],
      "(trees: box, box, actuated arm)")
