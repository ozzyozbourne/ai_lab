"""Example 2.10 - build a model in Python with mujoco.MjSpec instead of writing XML.

box_stack(n) builds the shared box-stack scene as an MJCF string; box_stack_spec(n) builds the
same scene with MjSpec (add_body, add_freejoint, add_geom, compile). Both compile to models with
the same sizes. spec.to_xml() turns the spec back into MJCF.
Run: python ex10_mjspec.py
"""
import mujoco
import numpy as np


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


def box_stack_spec(n=5, size=0.1):
    spec = mujoco.MjSpec()
    spec.modelname = "box_stack"
    spec.option.timestep = 0.005
    spec.worldbody.add_light(pos=[0, 0, 3], dir=[0, 0, -1])
    spec.worldbody.add_geom(name="floor", type=mujoco.mjtGeom.mjGEOM_PLANE, size=[5, 5, 0.1])
    for i in range(n):
        body = spec.worldbody.add_body(name=f"box{i}", pos=[0, 0, size + 2 * size * i + 0.001 * i])
        body.add_freejoint()
        body.add_geom(type=mujoco.mjtGeom.mjGEOM_BOX, size=[size, size, size])
    return spec


def sizes(mjm):
    return {k: getattr(mjm, k) for k in ["nq", "nv", "nbody", "ngeom", "njnt"]}


xml_model = mujoco.MjModel.from_xml_string(box_stack(3))
spec = box_stack_spec(3)
spec_model = spec.compile()
print("from XML   :", sizes(xml_model))
print("from MjSpec:", sizes(spec_model))
print("same sizes:", sizes(xml_model) == sizes(spec_model),
      "| same body_pos:", np.allclose(xml_model.body_pos, spec_model.body_pos))

# Edit the spec and recompile: a 4th box, now with its own colour
top = spec.worldbody.add_body(name="box3", pos=[0, 0, 0.1 + 0.6 + 0.003])
top.add_freejoint()
top.add_geom(type=mujoco.mjtGeom.mjGEOM_BOX, size=[0.1, 0.1, 0.1], rgba=[1, 0.3, 0.3, 1])
print("after adding box3:", sizes(spec.compile()))

xml = spec.to_xml()
print("spec.to_xml()[:200]:")
print(xml[:200])
