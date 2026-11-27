"""Example 22.1 - float atomics and slot counters, with and without Warp's RUN_TO_RUN mode.

Two kernel factories, built the way MJWarp builds its deterministic kernels: when
deterministic=True they set the Warp module option "deterministic" to
wp.DeterministicMode.RUN_TO_RUN. Kernel A sums N float32 values into one accumulator with
wp.atomic_add (a scatter/reduce atomic). Kernel B reserves a slot with
slot = wp.atomic_add(counter, 0, 1) and writes its thread id there (a counter atomic, the same
pattern as contact slots in collision_core.write_contact). Each kernel runs twice per mode and we
print the bits. On a GPU the default mode can change the low bits of the sum and the slot order
between runs; RUN_TO_RUN makes them repeat. On Warp's CPU device threads run one after another in
index order and Warp compiles the deterministic path for CUDA only, so every CPU run matches.
Part 2 emulates GPU arrival order in NumPy (random permutations, sequential float32 sums) and
shows the record-sort-reduce idea behind RUN_TO_RUN.
Run: python ex1_atomic_order.py
"""
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

ON_GPU = wp.get_device().is_cuda
N = 1 << 20 if ON_GPU else 1 << 16


def hexf(v) -> str:
    """Bit pattern of a float32 as 8 hex digits."""
    return f"{int(np.float32(v).view(np.uint32)):08x}"


def make_sum_kernel(deterministic: bool = False):
    opts = {"enable_backward": False}
    if deterministic:
        opts["deterministic"] = wp.DeterministicMode.RUN_TO_RUN

    @wp.kernel(module="unique", module_options=opts)
    def atomic_sum(x: wp.array[float], total: wp.array[float]):
        i = wp.tid()
        wp.atomic_add(total, 0, x[i])  # scatter/reduce: the return value is unused

    return atomic_sum


def make_slot_kernel(deterministic: bool = False):
    opts = {"enable_backward": False}
    if deterministic:
        opts["deterministic"] = wp.DeterministicMode.RUN_TO_RUN

    @wp.kernel(module="unique", module_options=opts)
    def reserve_slot(counter: wp.array[int], owner: wp.array[int]):
        i = wp.tid()
        slot = wp.atomic_add(counter, 0, 1)  # counter atomic: the return value IS used
        owner[slot] = i

    return reserve_slot


x_np = np.random.default_rng(0).random(N, dtype=np.float32)
x = wp.array(x_np, dtype=float)
NSLOT = 16
print(f"device: {wp.get_device()} | N = {N}")
for det in (False, True):
    mode = "RUN_TO_RUN    " if det else "NOT_GUARANTEED"
    k_sum, k_slot = make_sum_kernel(det), make_slot_kernel(det)
    sums, orders = [], []
    for _ in range(2):
        total = wp.zeros(1, dtype=float)
        wp.launch(k_sum, dim=N, inputs=[x], outputs=[total])
        counter, owner = wp.zeros(1, dtype=int), wp.zeros(NSLOT, dtype=int)
        wp.launch(k_slot, dim=NSLOT, inputs=[counter], outputs=[owner])
        sums.append(total.numpy()[0])
        orders.append(owner.numpy().tolist())
    print(f"{mode} sum run1 {sums[0]:.4f} (0x{hexf(sums[0])})  run2 0x{hexf(sums[1])}"
          f"  bitwise equal: {hexf(sums[0]) == hexf(sums[1])}")
    print(f"{mode} slot owners run1 {orders[0][:8]}...  same order in run2:"
          f" {orders[0] == orders[1]}")

# Part 2: what a GPU does to the same sum. Threads arrive in an order we do not control.
rng = np.random.default_rng(1)
vals = rng.random(4096, dtype=np.float32)
NORDER = 200
racy, sorted_red = set(), set()
for _ in range(NORDER):
    perm = rng.permutation(vals.size)            # arrival order of the 4096 "threads"
    racy.add(hexf(np.add.accumulate(vals[perm], dtype=np.float32)[-1]))
    # RUN_TO_RUN idea: keep (thread id, value) records, sort by thread id, then reduce in order
    records = np.stack([perm, vals[perm].view(np.uint32)], axis=1)
    records = records[np.argsort(records[:, 0], kind="stable")]
    sorted_red.add(hexf(np.add.accumulate(records[:, 1].astype(np.uint32).view(np.float32),
                                          dtype=np.float32)[-1]))
exact = float(np.sum(vals, dtype=np.float64))
ulp = float(np.spacing(np.float32(exact)))
r = sorted(int(h, 16) for h in racy)
print(f"emulated GPU, {NORDER} arrival orders of 4096 values (exact sum {exact:.6f}):")
print(f"  plain atomic order : {len(racy)} distinct float32 results, spread {r[-1] - r[0]} ulp"
      f" (1 ulp = {ulp:.2e})")
print(f"  record-sort-reduce : {len(sorted_red)} distinct result: 0x{next(iter(sorted_red))}")
