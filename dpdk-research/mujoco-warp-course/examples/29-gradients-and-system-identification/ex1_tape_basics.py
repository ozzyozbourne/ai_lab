"""Example 29.1 - reverse-mode autodiff with wp.Tape on a two-line kernel, y = x**2.

The forward kernel runs under a tape. Warp generated an adjoint (backward) kernel for it when it
compiled the module. We seed the output cotangent y.grad = 1, call tape.backward(), and read
x.grad = dy/dx = 2x. A central finite difference checks the answer.
Run: python ex1_tape_basics.py
"""
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

np.set_printoptions(precision=4, suppress=True)


@wp.kernel
def square(x: wp.array[float], y: wp.array[float]):
    i = wp.tid()
    y[i] = x[i] * x[i]


x_np = np.array([-1.0, 0.5, 1.5, 3.0], dtype=np.float32)
x = wp.array(x_np, dtype=float, requires_grad=True)   # leaf: we want dL/dx
y = wp.zeros(4, dtype=float, requires_grad=True)

tape = wp.Tape()
with tape:                                             # 1. forward, recorded
    wp.launch(square, dim=4, inputs=[x], outputs=[y])
print("recorded launches:", len(tape.launches))
print("y      =", y.numpy())

y.grad.fill_(1.0)                                      # 2. seed: L = sum(y), dL/dy = 1
tape.backward()                                        # 3. run the adjoint kernels in reverse
print("x.grad =", x.grad.numpy(), " (expected 2x)")

# 4. central finite differences, one input at a time, float64 on the host
eps = 1e-3
f = lambda v: v * v
fd = (f(x_np.astype(np.float64) + eps) - f(x_np.astype(np.float64) - eps)) / (2 * eps)
print("FD     =", fd)
print("max |tape - FD| =", float(np.abs(x.grad.numpy() - fd).max()))

# 5. the backward CONSUMED the output cotangent: the forward overwrote y, so y.grad is now the
#    cotangent of y's old contents (0). Re-seed it and x.grad ACCUMULATES (+=), it is not reset.
print("y.grad after backward =", y.grad.numpy())
y.grad.fill_(1.0)
tape.backward()
print("re-seeded, 2nd backward: x.grad =", x.grad.numpy(), " (4x: summed)")
tape.zero()                                            # zero every gradient the tape knows
print("after tape.zero():       x.grad =", x.grad.numpy())
