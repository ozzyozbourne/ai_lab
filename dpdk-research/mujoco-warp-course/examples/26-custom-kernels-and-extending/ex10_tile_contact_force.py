"""Example 26.10 - per-world reductions with tiles: launch_tiled, tile, tile_load, tile_sum,
tile_store and tile_load_indexed.

A tiled launch wp.launch_tiled(kernel, dim=nworld, block_dim=B) gives every world one BLOCK of B
threads; wp.tid() returns (worldid, lane) and the block's threads cooperate on tiles.
 1. world_normal_force: each lane sums the normal forces of a strided subset of the shared
    contact pool (contacts of its world only), wp.tile(partial) gathers the B partials and
    wp.tile_sum reduces them; checked against a NumPy bincount of mjw.contact_force.
 2. make_row_sum(n): sums one world's live efc.force rows (i < nefc; rows past nefc keep stale
    values from earlier steps, so a whole-row wp.tile_load would add them in). The bound n = njmax
    is a compile-time constant, hence a cache_kernel factory keyed by n.
 3. make_gather_sum(k): wp.tile_load_indexed gathers qpos entries by index (the box heights).
Scene: box_stack(3) with a different mass scale per world (body_mass batched). Resting stack:
floor carries 3 boxes, the next contact 2, the top 1, so the normal forces add up to 6 m g s.
On CPU block_dim is effectively 1 (one lane covers every entry); on a GPU B lanes share the work.
Run: python ex10_tile_contact_force.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.warp_util import cache_kernel   # private API

np.set_printoptions(precision=4, suppress=True)


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 200                                  # 1 s: the stack settles
BLOCK = 64 if ON_GPU else 1                  # lanes per world (CPU runs one lane anyway)


@wp.kernel(module="unique")                  # own module: it is launched with a custom block_dim
def world_normal_force(
    # Data in:
    contact_worldid_in: wp.array[int],
    nacon_in: wp.array[int],
    # In:
    force_in: wp.array[wp.spatial_vector],
    # Out:
    total_out: wp.array[float],
):
    worldid, lane = wp.tid()
    partial = float(0.0)
    for cid in range(lane, nacon_in[0], wp.block_dim()):   # strided walk over the shared pool
        if contact_worldid_in[cid] == worldid:
            partial += force_in[cid][0]                     # normal component (contact frame)
    s = wp.tile_sum(wp.tile(partial))                       # tree reduction across the block
    wp.tile_store(total_out, s, offset=worldid)             # 1-element tile -> total_out[worldid]


@cache_kernel
def make_row_sum(n: int):
    @wp.kernel(module="unique", enable_backward=False)
    def kernel(
        # Data in:
        nefc_in: wp.array[int],
        efc_force_in: wp.array2d[float],
        # Out:
        total_out: wp.array[float],
    ):
        worldid, lane = wp.tid()
        # rows past nefc keep stale forces from earlier steps: mask, then reduce
        partial = float(0.0)
        for i in range(lane, wp.min(nefc_in[worldid], wp.static(n)), wp.block_dim()):
            partial += efc_force_in[worldid, i]
        wp.tile_store(total_out, wp.tile_sum(wp.tile(partial)), offset=worldid)   # every lane

    return kernel


@cache_kernel
def make_gather_sum(k: int):
    @wp.kernel(module="unique", enable_backward=False)
    def kernel(
        # Data in:
        qpos_in: wp.array2d[float],
        # In:
        index: wp.array[int],
        # Out:
        total_out: wp.array[float],
    ):
        worldid, lane = wp.tid()
        idx = wp.tile_load(index, shape=wp.static(k))                    # the k column indices
        vals = wp.tile_load_indexed(qpos_in[worldid], idx, shape=(wp.static(k),))   # gather
        wp.tile_store(total_out, wp.tile_sum(vals), offset=worldid)

    return kernel


mjm = mujoco.MjModel.from_xml_string(box_stack(3))
m = mjw.put_model(mjm, batch_sizes={"body_mass": NWORLD, "body_inertia": NWORLD})
scale = np.linspace(1.0, 2.5, NWORLD, dtype=np.float32)
m.body_mass.assign(mjm.body_mass[None, :] * scale[:, None])
m.body_inertia.assign(mjm.body_inertia[None, :, :] * scale[:, None, None])
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
for _ in range(NSTEP):
    mjw.step(m, d)

nacon = int(d.nacon.numpy()[0])                       # host read: diagnostics only
ids = wp.array(np.arange(nacon, dtype=np.int32), dtype=int)
force = wp.zeros(nacon, dtype=wp.spatial_vector)
mjw.contact_force(m, d, ids, False, force)            # contact frame: force[:, 0] = normal

total = wp.zeros(NWORLD, dtype=float)
wp.launch_tiled(world_normal_force, dim=NWORLD, inputs=[d.contact.worldid, d.nacon, force],
                outputs=[total], block_dim=BLOCK)
efc_sum = wp.zeros(NWORLD, dtype=float)
wp.launch_tiled(make_row_sum(d.njmax), dim=NWORLD, inputs=[d.nefc, d.efc.force], outputs=[efc_sum],
                block_dim=BLOCK)
zcols = wp.array(np.array([7 * i + 2 for i in range(3)], dtype=np.int32), dtype=int)  # box z
height_sum = wp.zeros(NWORLD, dtype=float)
wp.launch_tiled(make_gather_sum(3), dim=NWORLD, inputs=[d.qpos, zcols], outputs=[height_sum],
                block_dim=BLOCK)
wp.synchronize()

f = force.numpy()
wid = d.contact.worldid.numpy()[:nacon]
ref = np.bincount(wid, weights=f[:, 0], minlength=NWORLD)
box_mass = float(mjm.body_mass[1])
print(f"nacon {nacon} ({nacon // NWORLD} per world) | block_dim {BLOCK} | mass scale {scale[:4]}")
print("tile sum of normal forces per world: ", total.numpy()[:4])
print("NumPy bincount of contact_force[:, 0]:", ref[:4].astype(np.float32))
print("analytic 6 m g s (resting stack):     ", (6 * box_mass * 9.81 * scale[:4]))
print(f"max |tile - bincount| = {np.abs(total.numpy() - ref).max():.1e}")
nefc = d.nefc.numpy()
efc_ref = np.array([d.efc.force.numpy()[w, :nefc[w]].sum() for w in range(NWORLD)])
print("masked row sum of efc.force (< nefc): ", efc_sum.numpy()[:4], "| NumPy:", efc_ref[:4])
print("tile_load_indexed sum of box heights: ", height_sum.numpy()[:4],
      "| NumPy:", d.qpos.numpy()[:4][:, [2, 9, 16]].sum(axis=1))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
