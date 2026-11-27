"""Example 26.8 - feed your own contacts to the solver with opt.run_collision_detection=False.

With run_collision_detection=False, fwd_position skips collision_driver.collision entirely and
make_constraint reads whatever is in d.contact.* and d.nacon. Our kernel writes one contact per
world (ball on the floor) into exactly the fields the constraint builder needs:
dist, pos, frame, dim, geom, worldid, friction, solref, solimp, includemargin and type = 1
(ContactType.CONSTRAINT). It never touches d.contact.flex/elem/vert: with nflex == 0 those arrays
have shape (0,), and an out-of-bounds write crashes the CPU process or corrupts GPU memory.
We compare the solver force with C MuJoCo's own collision, then with DisableBit.CONTACT.
Run: python ex8_user_contacts.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import vec5   # private API: may change between releases

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

NWORLD = 2          # one contact per world: small on purpose, same on GPU
Z0 = 0.099          # ball centre 1 mm below "touching": dist = -0.001 (a contact needs dist < 0)


@wp.kernel
def write_ball_contacts(
    # Data in:
    qpos_in: wp.array2d[float],
    # In:
    radius: float,
    floor_geom: int,
    ball_geom: int,
    friction: vec5,
    solref: wp.vec2,
    solimp: vec5,
    # Data out:
    contact_dist_out: wp.array[float],
    contact_pos_out: wp.array[wp.vec3],
    contact_frame_out: wp.array[wp.mat33],
    contact_includemargin_out: wp.array[float],
    contact_friction_out: wp.array[vec5],
    contact_solref_out: wp.array[wp.vec2],
    contact_solreffriction_out: wp.array[wp.vec2],
    contact_solimp_out: wp.array[vec5],
    contact_dim_out: wp.array[int],
    contact_geom_out: wp.array[wp.vec2i],
    contact_worldid_out: wp.array[int],
    contact_type_out: wp.array[int],
    nacon_out: wp.array[int],
):
    worldid = wp.tid()
    cid = worldid                                   # slot = world: one contact per world
    z = qpos_in[worldid, 2]                         # ball centre height (free joint z)
    contact_dist_out[cid] = z - radius              # negative = penetration
    contact_pos_out[cid] = wp.vec3(qpos_in[worldid, 0], qpos_in[worldid, 1], 0.5 * (z - radius))
    # rows of frame: normal (from geom[0]=floor to geom[1]=ball), then two tangents
    contact_frame_out[cid] = wp.mat33(0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0)
    contact_includemargin_out[cid] = 0.0
    contact_friction_out[cid] = friction
    contact_solref_out[cid] = solref
    contact_solreffriction_out[cid] = wp.vec2(0.0, 0.0)   # (0, 0): friction rows use solref
    contact_solimp_out[cid] = solimp
    contact_dim_out[cid] = 3                        # condim 3: normal + 2 friction directions
    contact_geom_out[cid] = wp.vec2i(floor_geom, ball_geom)
    contact_worldid_out[cid] = worldid
    contact_type_out[cid] = 1                       # ContactType.CONSTRAINT: solver uses it
    if worldid == 0:
        nacon_out[0] = qpos_in.shape[0]             # one contact per world in total


def fill(m, d, mjm):
    c = d.contact
    fr = mjm.geom_friction[1]
    wp.launch(write_ball_contacts, dim=d.nworld,
              inputs=[d.qpos, 0.1, 0, 1,                       # radius, floor geom, ball geom
                      vec5(fr[0], fr[0], fr[1], fr[2], fr[2]),  # MuJoCo's 5-entry contact friction
                      wp.vec2(*mjm.geom_solref[1]), vec5(*mjm.geom_solimp[1])],
              outputs=[c.dist, c.pos, c.frame, c.includemargin, c.friction, c.solref,
                       c.solreffriction, c.solimp, c.dim, c.geom, c.worldid, c.type, d.nacon])


mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
m.opt.run_collision_detection = False             # collision is now YOUR job
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
print("nflex:", m.nflex, "| contact.flex shape:", d.contact.flex.shape,
            "| contact.efc_address shape:", d.contact.efc_address.shape)

qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = Z0
d.qpos.assign(qpos)

fill(m, d, mjm)                                   # write the contacts ...
mjw.forward(m, d)                                 # ... then forward: no collision, just solve
print("user contacts:  nacon", d.nacon.numpy()[0], "| nefc per world", d.nefc.numpy())
f = d.efc.force.numpy()
print("efc.force world 0 rows 0-3:", f[0, :4], " sum", round(float(f[0, :4].sum()), 4))
print("contact.efc_address[0] (filled by make_constraint):", d.contact.efc_address.numpy()[0])

# reference: C MuJoCo with its own collision detection in the same state
mjd = mujoco.MjData(mjm)
mjd.qpos[:] = qpos[0]
mujoco.mj_forward(mjm, mjd)
print("C MuJoCo:       ncon", mjd.ncon, "| nefc", mjd.nefc, "| efc_force", mjd.efc_force[:4],
            " sum", round(float(mjd.efc_force[:4].sum()), 4))
print("max |MJWarp - C| over the 4 rows:", f"{np.abs(f[0, :4] - mjd.efc_force[:4]).max():.2e}")

# the contacts survive a step: collision never runs, so nothing overwrites them
mjw.step(m, d)
print("after mjw.step: nacon", d.nacon.numpy()[0], "| nefc", d.nefc.numpy(),
            "| ball vz", d.qvel.numpy()[:, 2])

# contrast: DisableBit.CONTACT zeroes nacon at every step, user contacts or not
m.opt.run_collision_detection = True
m.opt.disableflags |= mjw.DisableBit.CONTACT
fill(m, d, mjm)
mjw.forward(m, d)
print("DisableBit.CONTACT: nacon", d.nacon.numpy()[0], "| nefc", d.nefc.numpy())
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
