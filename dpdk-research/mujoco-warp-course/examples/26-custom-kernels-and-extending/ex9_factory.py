"""Example 26.9 - kernel factories specialized with wp.static and memoized by cache_kernel.

A factory is a Python function that takes compile-time parameters and returns a freshly defined
kernel. wp.static(...) evaluates its argument while Warp compiles the kernel, so the loop over
`power` is unrolled and the `if wp.static(absolute)` branch is removed from the variant that does
not need it. mujoco_warp._src.warp_util.cache_kernel (private API) memoizes the factory: the key
is one hash per POSITIONAL argument (objects with a .size attribute are keyed by their size,
lists by hash(tuple(...))) plus the factory's module and name. Nested kernels need
module="unique" (one Warp module each); enable_backward=False skips adjoint code generation.
Run: python ex9_factory.py
"""
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw  # noqa: F401  (imported for the course's standard import order)
from mujoco_warp._src.warp_util import _KERNEL_CACHE, cache_kernel   # private API

np.set_printoptions(precision=4, suppress=True)


@cache_kernel
def make_power(power: int, absolute: bool):
    @wp.kernel(module="unique", enable_backward=False)
    def kernel(
        # In:
        x_in: wp.array[float],
        # Out:
        y_out: wp.array[float],
    ):
        i = wp.tid()
        v = x_in[i]
        if wp.static(absolute):              # compiled in only when absolute=True
            v = wp.abs(v)
        r = float(1.0)
        for _ in range(wp.static(power)):    # unrolled: `power` is a compile-time constant
            r *= v
        y_out[i] = r

    return kernel


def my_keys():
    return [k for k in _KERNEL_CACHE if k[-2:] == (__name__, "make_power")]


x = wp.array(np.array([-2.0, -1.0, 0.5, 3.0], dtype=np.float32), dtype=float)
y = wp.zeros_like(x)

k3 = make_power(3, False)
k3_again = make_power(3, False)
k3_abs = make_power(3, True)
k2 = make_power(2, False)
print("make_power(3, False) is make_power(3, False):", k3 is k3_again)
print("make_power(3, False) is make_power(3, True): ", k3 is k3_abs)
print("make_power(3, False) is make_power(2, False):", k3 is k2)

for name, k in (("x^3", k3), ("|x|^3", k3_abs), ("x^2", k2)):
    wp.launch(k, dim=x.shape[0], inputs=[x], outputs=[y])
    print(f"{name:6}:", y.numpy())

print("cache keys:", my_keys())

# key rules: hash(1) == hash(True), so these two calls share one kernel object
print("make_power(2, 1) is make_power(2, True):", make_power(2, 1) is make_power(2, True))


# arrays (anything with .size) are keyed by their SIZE only: never bake array contents
@cache_kernel
def make_offset(table):
    offset = float(table[0])                 # baked into the kernel as a constant

    @wp.kernel(module="unique", enable_backward=False)
    def kernel(
        # In:
        x_in: wp.array[float],
        # Out:
        y_out: wp.array[float],
    ):
        i = wp.tid()
        y_out[i] = x_in[i] + wp.static(offset)

    return kernel


k_ten = make_offset(np.array([10.0, 0.0, 0.0]))
k_hundred = make_offset(np.array([100.0, 0.0, 0.0]))    # same size 3 -> cache hit!
wp.launch(k_hundred, dim=x.shape[0], inputs=[x], outputs=[y])
print("make_offset([100, 0, 0]) is make_offset([10, 0, 0]):", k_hundred is k_ten,
      "-> x + 100 gives", y.numpy())
# keyword arguments are not part of the key: the wrapper takes *args only
try:
    make_power(power=3, absolute=False)
except TypeError as e:
    print("keyword call:", type(e).__name__, "-", e)
print("number of make_power entries in _KERNEL_CACHE:", len(my_keys()))
