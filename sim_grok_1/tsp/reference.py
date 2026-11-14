"""A NumPy interpreter of a tsp.graph.Graph.

`evaluate(graph, inputs)` computes every node of the graph with exactly the
arithmetic the simulated hardware uses (plan.md section 2.5), so that the
simulator's outputs can be compared with it bit for bit:

- Integer add, sub, mul and neg wrap around modulo 2**32 (ledger B11).
- Floating-point add, sub and mul are single float32 NumPy operations.
- relu keeps lanes with x > 0 and gives +0 everywhere else.
- tanh and exp are numpy.tanh / numpy.exp on float32 arrays; rsqrt is
  float32(1) / numpy.sqrt(x).
- cast uses NumPy `astype` (fp32 -> fp16 rounds to nearest even).
- requant is an arithmetic shift right followed by saturation to the int8
  range (ledger B20).
- matvec int8: operands widened to 64-bit integers, multiplied and summed,
  the sum wrapped to int32 (ledger B6).
- matvec fp16: operands converted to float64, the products accumulated in
  ascending column order starting from +0, then rounded once to float32
  (ledger B6, B7).
- broadcast(a, lane, n): result[i] = a[lane] for i < n.

Every value is kept at its logical length.  On the chip the lanes at and
above the length are zero (ledger B19); those lanes never change a result
here (a zero product added to a float64 sum that started at +0 leaves it
unchanged), so they are not stored.
"""

import numpy as np

from . import isa, params
from .errors import GraphError

_INT32_MODULUS = np.int64(2) ** np.int64(32)  # not-a-parameter: width of int32 arithmetic
_INT32_OFFSET = np.int64(2) ** np.int64(31)  # not-a-parameter: width of int32 arithmetic


def wrap_int32(values):
    """Wrap 64-bit integers to int32 (two's complement, modulo 2**32)."""
    v = np.asarray(values, dtype=np.int64)
    return ((v + _INT32_OFFSET) % _INT32_MODULUS - _INT32_OFFSET).astype(np.int32)


def matvec_int8(rows, x):
    """y[r] = sum_c W[r][c] * x[c] for int8 W and x, as int32 with wrap-around."""
    w = np.asarray(rows, dtype=np.int64)
    xv = np.asarray(x, dtype=np.int64)
    return wrap_int32((w * xv[None, :]).sum(axis=1))


def matvec_fp16(rows, x):
    """y[r] = sum_c W[r][c] * x[c] for fp16 W and x.

    Products and the running sum are float64, the sum runs over the columns
    in ascending order, and the result is rounded once to float32.
    """
    w = np.asarray(rows, dtype=np.float16).astype(np.float64)
    xv = np.asarray(x, dtype=np.float16).astype(np.float64)
    acc = np.zeros(w.shape[0], dtype=np.float64)
    for c in range(w.shape[1]):
        acc += w[:, c] * xv[c]
    return acc.astype(np.float32)


def requant(a, shift):
    """int32 -> int8: arithmetic shift right by `shift`, then saturate (ledger B20)."""
    shifted = np.right_shift(np.asarray(a, dtype=np.int32), np.int32(shift))
    return np.clip(shifted, params.INT8_MIN, params.INT8_MAX).astype(np.int8)


def _pointwise(op, dtype, a, b):
    """One VXM point-wise operation on arrays of the operand dtype."""
    zero = a.dtype.type(0)
    if op == "add":
        return a + b
    if op == "sub":
        return a - b
    if op == "mul":
        return a * b
    if op == "neg":
        return -a
    if op == "relu":
        return np.where(a > zero, a, zero)
    if op == "tanh":
        return np.tanh(a)
    if op == "exp":
        return np.exp(a)
    if op == "rsqrt":
        return np.float32(1) / np.sqrt(a)
    raise GraphError(f"unknown point-wise operation {op!r}")


def _node(graph, t, values):
    """Value of one computed tensor `t`, given the values of earlier tensors."""
    np_out = isa.np_dtype(t.dtype)
    if t.op == "matvec":
        m = graph.matrices[t.matrix]
        rows = np.stack([values[r] for r in m.rows])
        x = values[t.args[0]]
        if m.dtype == "int8":
            return matvec_int8(rows, x)
        return matvec_fp16(rows, x)
    a = values[t.args[0]]
    if t.op == "cast":
        return a.astype(np_out)
    if t.op == "requant":
        return requant(a, t.attr)
    if t.op == "broadcast":
        return np.full(t.n, a[t.attr], dtype=np_out)
    b = values[t.args[1]] if len(t.args) > 1 else None
    with np.errstate(all="ignore"):
        return np.asarray(_pointwise(t.op, t.dtype, a, b)).astype(np_out)


def evaluate(graph, inputs):
    """Interpret `graph` with NumPy.

    inputs: input tensor name -> array of that tensor's length.
    Returns: output name -> array of the output's dtype and logical length.
    """
    values = {}
    for t in graph.tensors:
        np_dt = isa.np_dtype(t.dtype)
        if t.kind == "input":
            if t.name not in inputs:
                raise GraphError(f"no value given for input {t.name!r}")
            arr = np.asarray(inputs[t.name])
            if arr.shape != (t.n,):
                raise GraphError(f"input {t.name!r}: shape {arr.shape}, expected ({t.n},)")
            values[t.id] = arr.astype(np_dt)
        elif t.kind == "const":
            values[t.id] = np.asarray(t.data).astype(np_dt)
        else:
            v = _node(graph, t, values)
            if v.shape != (t.n,) or v.dtype != np_dt:
                raise GraphError(f"internal: {t.name} evaluated to {v.dtype}{v.shape}")
            values[t.id] = v
    return {name: values[tid].copy() for name, tid in graph.outputs.items()}
