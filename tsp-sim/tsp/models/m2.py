"""Milestone M2: a two-layer integer MLP (plan.md section 6).

    h = requant(relu(W1.x + b1), SHIFT)     int8, length 16
    y = W2.h + b2                           int32, length 8

x is int8 of length 12, W1 is 16x12 int8, W2 is 8x16 int8, b1 and b2 are
int32.  requant is an arithmetic shift right then saturation to int8
(ledger B20).  The value ranges and SHIFT are chosen so that h is neither
all zero nor mostly saturated.  Everything is integer, so the simulator must
match the reference exactly.
"""

import numpy as np

from .. import params
from ..graph import Graph

N_IN = 12  # not-a-parameter: model size
N_HIDDEN = 16  # not-a-parameter: model size
N_OUT = 8  # not-a-parameter: model size
LANES = 16  # not-a-parameter: model size (toy chip lane count, ledger G1, G2)
SHIFT = 8  # not-a-parameter: model constant, scales W1.x into the int8 range
BIAS_RANGE = 4000  # not-a-parameter: random scale


def _params(seed):
    """Draw the input and constants from `seed`: (x, W1, b1, W2, b2)."""
    rng = np.random.default_rng(seed)

    def int8(shape):
        return rng.integers(params.INT8_MIN, params.INT8_MAX, size=shape, endpoint=True).astype(np.int8)

    x = int8(N_IN)
    w1 = int8((N_HIDDEN, N_IN))
    b1 = rng.integers(-BIAS_RANGE, BIAS_RANGE, size=N_HIDDEN, endpoint=True).astype(np.int32)
    w2 = int8((N_OUT, N_HIDDEN))
    b2 = rng.integers(-BIAS_RANGE, BIAS_RANGE, size=N_OUT, endpoint=True).astype(np.int32)
    return x, w1, b1, w2, b2


def build(seed=0):
    """The M2 graph and its input values: (Graph, {"x": int8 array})."""
    x, w1, b1, w2, b2 = _params(seed)
    g = Graph("m2", lanes=LANES)
    tx = g.input("x", "int8", N_IN)
    tw1 = g.const_matrix("W1", w1, "int8")
    tb1 = g.const("b1", b1, "int32")
    tw2 = g.const_matrix("W2", w2, "int8")
    tb2 = g.const("b2", b2, "int32")
    a1 = g.add(g.matvec(tw1, tx, name="W1x"), tb1, name="W1x_b1")
    r1 = g.relu(a1, name="relu1")
    h = g.requant(r1, SHIFT, name="h")
    y = g.add(g.matvec(tw2, h, name="W2h"), tb2, name="y")
    g.output("y", y)
    return g, {"x": x}


def hidden(seed=0):
    """The hidden activation h computed with NumPy (used by tests to check it is not trivial)."""
    x, w1, b1, _, _ = _params(seed)
    pre = w1.astype(np.int64) @ x.astype(np.int64) + b1
    shifted = np.maximum(pre, 0) >> SHIFT
    return np.clip(shifted, params.INT8_MIN, params.INT8_MAX).astype(np.int8)


def reference(seed=0):
    """Expected outputs computed directly with NumPy: {"y": int32 array}."""
    _, _, _, w2, b2 = _params(seed)
    h = hidden(seed)
    y = w2.astype(np.int64) @ h.astype(np.int64) + b2
    return {"y": y.astype(np.int32)}
