"""Example 27.12 - every create_render_context option, geom groups, and cam_active by name.

Part 1 prints the option table straight from inspect.signature (so it always matches your
installed version). Part 2: a geom in group 3 is not in the BVH with the default
enabled_geom_groups=[0, 1, 2], so it is invisible; [0, 1, 2, 3] shows it. Part 3: cam_active
selects cameras by name; camera_index in get_rgb is the position in that ACTIVE list.
Run: python ex12_options_and_groups.py
"""
import inspect

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

GROUPS = """
<mujoco model="groups">
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1" directional="true"/>
    <camera name="front" pos="0 -3 .5" xyaxes="1 0 0 0 0 1"/>
    <camera name="side" pos="3 0 .5" xyaxes="0 1 0 0 0 1"/>
    <geom name="floor" type="plane" size="3 3 .1" group="0"/>
    <geom name="visual_ball" type="sphere" pos="-.5 0 .5" size=".25" group="1" rgba="1 .3 .3 1"/>
    <geom name="collision_box" type="box" pos=".5 0 .5" size=".2 .2 .2" group="3"
          rgba=".3 .3 1 1"/>
  </worldbody>
</mujoco>
"""

# Part 1: the options table, from the installed library itself
sig = inspect.signature(mjw.create_render_context)
print(f"create_render_context: {len(sig.parameters)} parameters")
for name, p in sig.parameters.items():
    default = "(required)" if p.default is inspect.Parameter.empty else repr(p.default)
    print(f"  {name:25s} = {default}")

mjm = mujoco.MjModel.from_xml_string(GROUPS)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
mjw.forward(m, d)
box = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_GEOM, "collision_box")


def box_pixels(**opts):
    rc = mjw.create_render_context(mjm, nworld=1, cam_res=(32, 32), render_rgb=True,
                                   render_depth=False, render_seg=True, **opts)
    mjw.refit_bvh(m, d, rc)
    mjw.render(m, d, rc)
    seg = rc.seg_data.numpy()[0]
    return rc, int((seg[:, 0] == box).sum())


# Part 2: geom groups (keyword arguments only, always)
rc, n = box_pixels(cam_active=["front"])
print("\ngeom groups:", mjm.geom_group.tolist(), "| bvh_ngeom with default groups:", rc.bvh_ngeom)
print("group-3 box pixels, enabled_geom_groups=[0, 1, 2]   :", n)
rc, n = box_pixels(cam_active=["front"], enabled_geom_groups=[0, 1, 2, 3])
print("group-3 box pixels, enabled_geom_groups=[0, 1, 2, 3]:", n, "| bvh_ngeom:", rc.bvh_ngeom)

# Part 3: cam_active by name -> camera_index counts ACTIVE cameras only
for active in (None, ["side"], ["side", "front"]):
    rc, n = box_pixels(cam_active=active, enabled_geom_groups=[0, 1, 2, 3])
    names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_CAMERA, int(c))
             for c in rc.cam_id_map.numpy()]
    print(f"cam_active={active!s:17s} nrender {rc.nrender} | cam_id_map "
          f"{rc.cam_id_map.numpy().tolist()} -> camera_index 0 is {names[0]!r}"
          f" | box px (all cams) {n}")
