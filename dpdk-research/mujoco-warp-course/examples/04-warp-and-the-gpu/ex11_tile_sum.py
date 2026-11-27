"""Example 4.11 (going deeper) - a tiled per-world reduction with wp.launch_tiled.

launch_tiled starts block_dim threads per logical index (one block per world here). The block
cooperatively loads one world's row into a tile (shared memory on a GPU), reduces it with
wp.tile_sum and stores the result. On Warp's CPU device the block collapses to one thread
(unless wp.config.enable_cpu_blocks is set), and the code still runs. Owner chapter: Ch 26.
Run: python ex11_tile_sum.py
"""
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

NW, N = 4, 64
TILE = N                                           # tile shapes must be compile-time constants


@wp.kernel
def per_world_sum(data: wp.array2d[float], out: wp.array[float]):
    worldid = wp.tid()                             # one logical index per block
    t = wp.tile_load(data[worldid], shape=(TILE,))   # the whole row, loaded by the block
    s = wp.tile_sum(t)                             # cooperative reduction -> 1-element tile
    wp.tile_store(out, s, offset=(worldid,))


arr_np = np.arange(NW * N, dtype=np.float32).reshape(NW, N)
arr = wp.array(arr_np)
out = wp.zeros(NW, dtype=float)
wp.launch_tiled(per_world_sum, dim=[NW], inputs=[arr], outputs=[out], block_dim=32)

print("device:", wp.get_device(), "| block_dim requested: 32")
print("tile sums :", out.numpy().astype(int).tolist())
print("NumPy sums:", arr_np.sum(axis=1).astype(int).tolist())
