"""Example 4.8 - compile-time specialization with wp.static inside a kernel factory.

make_clip(use_abs) returns a kernel in which `if wp.static(use_abs):` is decided while Warp
generates code, so each specialization contains only one side of the branch. The same pattern
appears all over MJWarp (factories are cached by warp_util.cache_kernel; Ch 26).
Run: python ex8_static.py
"""
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

np.set_printoptions(precision=4, suppress=True)

POWER = 3                                          # a Python int, read at compile time


def make_clip(use_abs: bool):
    @wp.kernel(module="unique", enable_backward=False)
    def clip(x_in: wp.array[float], y_out: wp.array[float]):
        i = wp.tid()
        v = x_in[i]
        if wp.static(use_abs):                     # resolved during code generation
            v = wp.abs(v)
        r = float(1.0)
        for _ in range(wp.static(POWER)):          # constant trip count: unrolled
            r *= v
        y_out[i] = wp.clamp(r, -1.0, 1.0)
    return clip


x = wp.array(np.array([-1.5, -0.5, 0.5, 1.5], dtype=np.float32))
y = wp.zeros(4, dtype=float)
kernels = {flag: make_clip(flag) for flag in (False, True)}
for flag, k in kernels.items():
    wp.launch(k, dim=4, inputs=[x], outputs=[y])
    expr = "clamp(|x|**3)" if flag else "clamp(x**3)  "
    print(f"use_abs={flag!s:5s} -> {expr} =", y.numpy(), "| module", k.module.name)

again = make_clip(True)                            # same source + same static values
print("modules compiled:", len({k.module.name for k in kernels.values()}))
print("make_clip(True) twice -> same kernel object:", again is kernels[True])
