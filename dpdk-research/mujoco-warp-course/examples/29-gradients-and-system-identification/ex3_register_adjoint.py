"""Example 29.3 - give your own wrapped function an adjoint rule with diff.register_adjoint.

square(m, d, x, y) writes y = x**2 with a kernel compiled WITHOUT a backward (like every MJWarp
kernel). diff._wrap makes it a "differentiable API function" exactly like mjw.step, and
register_adjoint attaches a custom backward: it must += into x.grad and then consume y.grad.
Under a wp.Tape the wrapper validates the call, runs the forward on a scratch tape and records
our backward; tape.backward() calls it.
Run: python ex3_register_adjoint.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import diff   # private API: register_adjoint, _wrap, RULES

np.set_printoptions(precision=4, suppress=True)


@wp.kernel(enable_backward=False)          # no generated adjoint, as in MJWarp's own kernels
def square_kernel(x: wp.array[float], y_out: wp.array[float]):
    i = wp.tid()
    y_out[i] = x[i] * x[i]


@wp.kernel(enable_backward=False)
def square_bwd_kernel(x: wp.array[float], y_grad: wp.array[float], x_grad_out: wp.array[float]):
    i = wp.tid()
    x_grad_out[i] += 2.0 * x[i] * y_grad[i]   # accumulate (+=), never overwrite


def square(m, d, x, y):
    """User op with the API calling convention (m, d, ...)."""
    wp.launch(square_kernel, dim=x.shape[0], inputs=[x], outputs=[y])


def square_bwd(m, d, x, y):
    """Called by tape.backward() with the forward arguments and the tape paused."""
    wp.launch(square_bwd_kernel, dim=x.shape[0], inputs=[x, y.grad], outputs=[x.grad])
    y.grad.zero_()   # consume: y was overwritten, so the cotangent of its old contents is 0


w = diff._wrap(square)                     # what _differentiable does to every mjw function
print("after _wrap:            RULES['square'] =", diff.RULES["square"])
diff.register_adjoint(square, square_bwd, array_args=("x", "y"))
rule = diff.RULES["square"]
print("after register_adjoint: backward =", rule.backward.__name__,
      "| array_args =", rule.array_args,
      "| in/out fields =", rule.in_fields, rule.out_fields)

mjm = mujoco.MjModel.from_xml_string("<mujoco><worldbody/></mujoco>")
m = mjw.put_model(mjm)
d = mjw.make_data(mjm)

x_np = np.array([1.5, -0.5, 2.0], dtype=np.float32)
x = wp.array(x_np, dtype=float)            # no requires_grad: array_args are promoted for us
y = wp.zeros(3, dtype=float)

w(m, d, x, y)                              # no tape: the wrapper calls square() directly
print("untaped: y =", y.numpy(), "| x.requires_grad =", x.requires_grad)

with wp.Tape() as tape:
    w(m, d, x, y)
print("taped:   recorded entries =", len(tape.launches), "| x.requires_grad =", x.requires_grad)
y.grad.fill_(1.0)
tape.backward()
print("x.grad =", x.grad.numpy(), " (2x; 3.0 for x = 1.5)")
print("y.grad =", y.grad.numpy(), " (consumed by the rule)")

eps = 1e-2                                 # float32 central difference through the same kernel
xp, xm = wp.array(x_np + eps, dtype=float), wp.array(x_np - eps, dtype=float)
yp, ym = wp.zeros(3, dtype=float), wp.zeros(3, dtype=float)
square(m, d, xp, yp)
square(m, d, xm, ym)
fd = (yp.numpy() - ym.numpy()) / (2 * eps)
print("FD     =", fd, "| max diff =", float(np.abs(fd - x.grad.numpy()).max()))

diff.RULES.pop("square", None)                 # undo: _wrap and register_adjoint edit global registries
diff._PARAMS.pop("square", None)
