"""Reference evaluators for a Graph (plan.md sections 3.3, 4, 9).

`evaluate` is the bit-exact reference: it evaluates the graph node by node with
the shared kernels in tsp/numerics.py, following the whole-tensor semantics of
plan 3.3, including the multi-tile matvec rule. It knows nothing about streams,
schedules or the simulator.

`evaluate_plain` is an independent cross-check that shares no arithmetic code
with the simulator: plain NumPy written from the semantics table (plan 2.7,
3.3). Integers are computed in int64 with explicit wrap / saturation; floats
are float64 throughout, so F16/F32 rounding is NOT modelled (a cast F32 -> F16
is the identity). It must not import tsp.numerics.

Both take `feeds` for runtime inputs (leaf vectors and matrices without data)
and use `graph.constants` for the rest. With `return_all=True` both return
`(outputs, values)` where `values` maps every node name to its value.
"""
from __future__ import annotations

import numpy as np

from . import numerics
from .graph import LEAF, Graph
from .isa import DType

_VOP = {"add": "ADD", "sub": "SUB", "mul": "MUL", "relu": "RELU",
        "exp": "EXP", "rsqrt": "RSQRT", "tanh": "TANH"}


class FeedError(ValueError):
    pass


def _leaf_data(graph: Graph, name: str, feeds: dict, shape: tuple[int, ...]) -> np.ndarray:
    """Data of a leaf vector or matrix: constant, or feed."""
    if name in graph.constants:
        if name in feeds:
            raise FeedError(f"feed given for constant {name!r}")
        arr = np.asarray(graph.constants[name])
    elif name in feeds:
        arr = np.asarray(feeds[name])
    else:
        raise FeedError(f"missing feed for runtime input {name!r} of graph {graph.name!r}")
    if arr.shape != shape:
        raise FeedError(f"{name}: shape {arr.shape} != {shape}")
    return arr


def _check_feed_names(graph: Graph, feeds: dict) -> None:
    known = set(graph.input_names())
    unknown = [n for n in feeds if n not in known and n not in graph.constants]
    if unknown:
        raise FeedError(f"unexpected feeds {unknown} for graph {graph.name!r}")


def _finish(graph: Graph, vals: dict[int, np.ndarray], return_all: bool):
    outputs = {name: vals[nid] for name, nid in graph.outputs.items()}
    if not return_all:
        return outputs
    return outputs, {graph.nodes[nid].name: v for nid, v in vals.items()}


# ---- bit-exact reference --------------------------------------------------------
def evaluate(graph: Graph, feeds: dict, tile_len: int, return_all: bool = False):
    """Bit-exact value of every graph output, computed with tsp.numerics."""
    if tile_len < 1:
        raise ValueError("tile_len must be >= 1")
    _check_feed_names(graph, feeds)
    vals: dict[int, np.ndarray] = {}
    for node in graph.nodes:
        ins = [vals[i] for i in node.inputs]
        kind = node.kind
        if kind == LEAF:
            v = _leaf_data(graph, node.name, feeds, (node.n,)).astype(node.dtype.np)
        elif kind == "matvec":
            mat = graph.matrices[node.matrix]
            W = _leaf_data(graph, mat.name, feeds, (mat.m, mat.n)).astype(mat.dtype.np)
            x = ins[0]
            out_dt = DType.I32 if mat.dtype == DType.I8 else DType.F32
            v = None
            # left-to-right sum of per-input-tile products (plan 3.3)
            for lo in range(0, mat.n, tile_len):
                hi = min(lo + tile_len, mat.n)
                part = numerics.matvec(mat.dtype, x[lo:hi], W[:, lo:hi].T)
                v = part if v is None else numerics.vop("ADD", out_dt, v, part)
        elif kind == "matvec_cols":
            x, cols = ins[0], ins[1:]
            rows = np.stack(cols)                      # (k, m): row r is column r of the product
            v = numerics.matvec(graph.nodes[node.inputs[0]].dtype, x[: len(cols)], rows)
        elif kind in ("add", "sub", "mul"):
            v = numerics.vop(_VOP[kind], node.dtype, ins[0], ins[1])
        elif kind in ("relu", "exp", "rsqrt", "tanh"):
            v = numerics.vop(_VOP[kind], node.dtype, ins[0])
        elif kind == "requant":
            v = numerics.vop("REQUANT", DType.I32, ins[0], imm=node.imm)
        elif kind == "cast":
            src = graph.nodes[node.inputs[0]].dtype
            v = numerics.vop("CAST", src, ins[0], to=node.dtype)
        elif kind == "shift":
            v = numerics.shift_lanes(ins[0], node.imm)
        else:
            raise ValueError(f"unknown node kind {kind!r}")
        vals[node.id] = np.asarray(v, dtype=node.dtype.np)
    return _finish(graph, vals, return_all)


# ---- independent plain-NumPy reference ------------------------------------------
_I32_SPAN = 1 << 32       # not a machine parameter: modulus of the I32 wrap (plan 2.7)
_I32_HALF = 1 << 31       # not a machine parameter: offset of the I32 wrap
_I8_MIN, _I8_MAX = -128, 127  # not a machine parameter: I8 saturation bounds (plan 2.7)


def _wrap32(a: np.ndarray) -> np.ndarray:
    return (a + _I32_HALF) % _I32_SPAN - _I32_HALF


def _plain_leaf(dtype: DType, arr: np.ndarray) -> np.ndarray:
    if dtype.is_float:
        return np.asarray(arr).astype(dtype.np).astype(np.float64)   # the stored value, then exact float64
    a64 = np.asarray(arr).astype(np.int64)
    lo, hi = (_I8_MIN, _I8_MAX) if dtype == DType.I8 else (-_I32_HALF, _I32_HALF - 1)
    if a64.size and (a64.min() < lo or a64.max() > hi):
        raise FeedError(f"data does not fit {dtype.value}")
    return a64


def evaluate_plain(graph: Graph, feeds: dict, return_all: bool = False):
    """Independent value of every output: int64 with explicit wrap, float64 without F16/F32 rounding.

    Integer outputs are int64 arrays, float outputs float64 arrays.
    """
    _check_feed_names(graph, feeds)
    vals: dict[int, np.ndarray] = {}
    with np.errstate(all="ignore"):
        for node in graph.nodes:
            ins = [vals[i] for i in node.inputs]
            kind = node.kind
            is_int = not node.dtype.is_float
            if kind == LEAF:
                v = _plain_leaf(node.dtype, _leaf_data(graph, node.name, feeds, (node.n,)))
            elif kind == "matvec":
                mat = graph.matrices[node.matrix]
                W = _plain_leaf(mat.dtype, _leaf_data(graph, mat.name, feeds, (mat.m, mat.n)))
                v = np.sum(W * ins[0][None, :], axis=1)          # W @ x, no tiling
                v = _wrap32(v) if is_int else v
            elif kind == "matvec_cols":
                x, cols = ins[0], ins[1:]
                v = np.sum(np.stack(cols) * x[: len(cols), None], axis=0)
                v = _wrap32(v) if is_int else v
            elif kind == "add":
                v = ins[0] + ins[1]
                v = _wrap32(v) if is_int else v
            elif kind == "sub":
                v = ins[0] - ins[1]
                v = _wrap32(v) if is_int else v
            elif kind == "mul":
                v = ins[0] * ins[1]
                v = _wrap32(v) if is_int else v
            elif kind == "relu":
                v = np.where(ins[0] > 0, ins[0], 0 * ins[0])
            elif kind == "exp":
                v = np.exp(ins[0])
            elif kind == "tanh":
                v = np.tanh(ins[0])
            elif kind == "rsqrt":
                a = ins[0]
                v = np.where(a == 0, np.inf, 1.0 / np.sqrt(a))
            elif kind == "requant":
                v = np.clip(ins[0] >> node.imm, _I8_MIN, _I8_MAX)   # arithmetic shift on int64
            elif kind == "cast":
                v = ins[0].copy()          # I8 -> I32 sign-extends (already int64); float casts are identities here
            elif kind == "shift":
                a, n = ins[0], node.imm
                v = np.zeros_like(a)
                if n < a.shape[0]:
                    v[n:] = a[: a.shape[0] - n]
            else:
                raise ValueError(f"unknown node kind {kind!r}")
            vals[node.id] = v
    return _finish(graph, vals, return_all)
