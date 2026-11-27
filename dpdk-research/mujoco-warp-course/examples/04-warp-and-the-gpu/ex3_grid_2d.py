"""Example 4.3 - a 2D launch over (nworld, ndof): wp.tid() returns two indices.

Each thread writes worldid * 100 + dofid, the same shape of launch MJWarp uses for
dim=(d.nworld, m.nv). A second kernel records the order in which threads ran.
Run: python ex3_grid_2d.py [--dump-json PATH]
  --dump-json PATH writes the grid and the CPU run order for the page's thread-grid figure.
"""
import argparse
import json

import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD, NDOF = 4, 6


@wp.kernel
def label(out: wp.array2d[int]):
    worldid, dofid = wp.tid()                      # 2D launch -> two indices
    out[worldid, dofid] = worldid * 100 + dofid


@wp.kernel
def run_order(counter: wp.array[int], order: wp.array2d[int]):
    worldid, dofid = wp.tid()
    order[worldid, dofid] = wp.atomic_add(counter, 0, 1)   # ticket = when this thread ran


grid = wp.zeros((NWORLD, NDOF), dtype=int)
wp.launch(label, dim=(NWORLD, NDOF), outputs=[grid])
print("launch dim:", (NWORLD, NDOF), "->", NWORLD * NDOF, "threads")
print(grid.numpy())

counter = wp.zeros(1, dtype=int)
order = wp.zeros((NWORLD, NDOF), dtype=int)
wp.launch(run_order, dim=(NWORLD, NDOF), inputs=[counter], outputs=[order])
print("run order on", wp.get_device(), "(on a GPU the order is not defined):")
print(order.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "ndof": NDOF, "grid": grid.numpy().tolist(),
                   "order": order.numpy().tolist(), "device": str(wp.get_device())},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
