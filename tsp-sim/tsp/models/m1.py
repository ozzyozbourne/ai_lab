"""Milestone M1: one dense layer, y = relu(W.x + b).

x is an int8 vector, W an int8 matrix, b an int32 bias and y an int32 vector
(plan.md section 6).  The default size is 12 inputs and 8 outputs on the
16-lane toy chip; `build(n_in=320, n_out=320, lanes=320)` gives the same layer
at the size of the sourced 320-lane geometry.

The compiler turns this into one operation tile (matvec -> add -> relu) plus
the install slots that load W into an MXM plane.
"""

import numpy as np

from .. import params
from ..graph import Graph

N_IN = 12  # not-a-parameter: model size
N_OUT = 8  # not-a-parameter: model size
LANES = 16  # not-a-parameter: model size (toy chip lane count, ledger G1, G2)
BIAS_RANGE = 20000  # not-a-parameter: random scale, puts about half of W.x + b above zero


def _params(seed, n_in, n_out):
    """Draw the input and constants from `seed`: (x, W, b)."""
    rng = np.random.default_rng(seed)
    x = rng.integers(params.INT8_MIN, params.INT8_MAX, size=n_in, endpoint=True).astype(np.int8)
    w = rng.integers(params.INT8_MIN, params.INT8_MAX, size=(n_out, n_in), endpoint=True).astype(np.int8)
    b = rng.integers(-BIAS_RANGE, BIAS_RANGE, size=n_out, endpoint=True).astype(np.int32)
    return x, w, b


def build(seed=0, n_in=N_IN, n_out=N_OUT, lanes=LANES):
    """The M1 graph and its input values: (Graph, {"x": int8 array})."""
    x, w, b = _params(seed, n_in, n_out)
    g = Graph("m1", lanes=lanes)
    tx = g.input("x", "int8", n_in)
    tw = g.const_matrix("W", w, "int8")
    tb = g.const("b", b, "int32")
    acc = g.matvec(tw, tx, name="Wx")
    pre = g.add(acc, tb, name="Wx_b")
    y = g.relu(pre, name="y")
    g.output("y", y)
    return g, {"x": x}


def reference(seed=0, n_in=N_IN, n_out=N_OUT, lanes=LANES):
    """Expected outputs computed directly with NumPy: {"y": int32 array}."""
    x, w, b = _params(seed, n_in, n_out)
    pre = w.astype(np.int64) @ x.astype(np.int64) + b.astype(np.int64)
    y = np.maximum(pre, 0)
    return {"y": y.astype(np.int32)}
