"""Small graphs for the compiler tests, and a tile-aware evaluator built on tsp.numerics.

The graphs mirror the milestone definitions of plan section 6 (M3 is written out
here from the plan, independently of tsp/models). Data come from NumPy's
default_rng; `scale` multiplies the generator's draws so that the
data-independence test can vary the constant values but not the shapes.
"""
from __future__ import annotations

import numpy as np

from tsp import numerics
from tsp.graph import Graph
from tsp.isa import DType


def _i8(rng, shape, lo=-16, hi=15):
    return rng.integers(lo, hi + 1, shape).astype(np.int8)


def _f16(rng, shape):
    return (rng.integers(-64, 65, shape) / 256).astype(np.float16)    # not a machine parameter: plan 6 data range


def _f32(rng, shape):
    return (rng.integers(-64, 65, shape) / 64).astype(np.float32)     # not a machine parameter: plan 6 data range


def m1_graph(n_in=20, n_out=24, seed=1, shift=0):
    rng = np.random.default_rng(seed)
    g = Graph("m1")
    x = g.vector("x", DType.I8, n_in)
    W = g.matrix("W", DType.I8, n_out, n_in, data=_i8(rng, (n_out, n_in)))
    b = g.vector("b", DType.I32, n_out, data=rng.integers(-1000, 1001, n_out).astype(np.int32))
    g.output("y", g.relu(g.add(g.matvec(W, x), b)))
    return g, {"x": _i8(rng, n_in, -128, 127)}


def m2_graph(seed=2):
    rng = np.random.default_rng(seed)
    g = Graph("m2")
    x = g.vector("x", DType.I8, 48)
    W1 = g.matrix("W1", DType.I8, 40, 48, data=_i8(rng, (40, 48)))
    b1 = g.vector("b1", DType.I32, 40, data=rng.integers(-1000, 1001, 40).astype(np.int32))
    W2 = g.matrix("W2", DType.I8, 10, 40, data=_i8(rng, (10, 40)))
    b2 = g.vector("b2", DType.I32, 10, data=rng.integers(-1000, 1001, 10).astype(np.int32))
    h = g.requant(g.relu(g.add(g.matvec(W1, x, name="mv1"), b1)), 6, name="h")
    g.output("y", g.add(g.matvec(W2, h), b2, name="y"))
    return g, {"x": _i8(rng, 48, -128, 127)}


def m3_graph(seed=3):
    """plan section 6, M3 definition, written out literally."""
    d, T, F, V = 16, 8, 32, 32     # not a machine parameter: M3 model shapes (plan 6)
    rng = np.random.default_rng(seed)
    F16, F32 = DType.F16, DType.F32
    g = Graph("m3")
    x = g.vector("x", F32, d)
    Kc = g.matrix("Kc", F16, d, d)
    Vc = [g.vector(f"V{i}", F16, d) for i in range(T - 1)]
    Wq, Wk, Wv, Wo = (g.matrix(n, F16, d, d, data=_f16(rng, (d, d))) for n in ("Wq", "Wk", "Wv", "Wo"))
    W1 = g.matrix("W1", F16, F, d, data=_f16(rng, (F, d)))
    W2 = g.matrix("W2", F16, d, F, data=_f16(rng, (d, F)))
    Wu = g.matrix("Wu", F16, V, d, data=_f16(rng, (V, d)))
    b1 = g.vector("b1", F32, F, data=_f32(rng, F))
    b2 = g.vector("b2", F32, d, data=_f32(rng, d))
    sum0 = np.zeros((d, d), np.float16)
    sum0[0] = 1
    SUM0 = g.matrix("SUM0", F16, d, d, data=sum0)
    ONES = g.matrix("ONES", F16, d, d, data=np.ones((d, d), np.float16))
    scale = g.vector("scale", F32, d, data=np.full(d, 1 / np.sqrt(d), np.float32))
    mask = g.vector("mask", F32, d, data=np.where(np.arange(d) < T, 0, -1e4).astype(np.float32))  # not a machine parameter: plan 6 mask value

    def c16(v):
        return g.cast(v, F16)

    x16 = c16(x)
    q, k, v = g.matvec(Wq, x16), g.matvec(Wk, x16, name="k"), g.matvec(Wv, x16, name="v")
    s_cache = g.matvec(Kc, c16(q))
    s_self = g.shift(g.matvec(SUM0, c16(g.mul(q, k))), T - 1)
    e = g.exp(g.add(g.mul(g.add(s_cache, s_self), scale), mask))
    S = g.matvec(ONES, c16(e))
    r = g.rsqrt(S)
    a = g.mul(e, g.mul(r, r))
    o = g.matvec_cols(Vc + [c16(v)], c16(a))
    h = g.add(x, g.matvec(Wo, c16(o)))
    f = g.add(g.matvec(W2, c16(g.relu(g.add(g.matvec(W1, c16(h)), b1)))), b2)
    y = g.add(h, f)
    g.output("logits", g.matvec(Wu, c16(y)))
    g.output("k", k)
    g.output("v", v)
    kc = np.zeros((d, d), np.float16)
    kc[:T - 1] = _f32(rng, (T - 1, d)).astype(np.float16)
    feeds = {"x": _f32(rng, d), "Kc": kc}
    for i in range(T - 1):
        feeds[f"V{i}"] = _f32(rng, d).astype(np.float16)
    return g, feeds


def evaluate(graph: Graph, feeds: dict, tile_len: int) -> dict[str, np.ndarray]:
    """Bit-exact expected outputs (plan 3.3 semantics, tsp.numerics kernels)."""
    vals: dict[int, np.ndarray] = {}
    for n in graph.nodes:
        ins = [vals[i] for i in n.inputs]
        if n.kind == "vector":
            vals[n.id] = np.asarray(graph.constants.get(n.name, feeds.get(n.name))).astype(n.dtype.np)
        elif n.kind == "matvec":
            mat = graph.matrices[n.matrix]
            W = np.asarray(graph.constants.get(mat.name, feeds.get(mat.name))).astype(mat.dtype.np)
            acc = None
            for j in range(0, mat.n, tile_len):
                part = numerics.matvec(mat.dtype, ins[0][j:j + tile_len], W[:, j:j + tile_len].T)
                acc = part if acc is None else numerics.vop("ADD", n.dtype, acc, part)
            vals[n.id] = acc
        elif n.kind == "matvec_cols":
            cols = np.stack(ins[1:])
            vals[n.id] = numerics.matvec(graph.nodes[n.inputs[0]].dtype, ins[0][:len(cols)], cols)
        elif n.kind == "shift":
            vals[n.id] = numerics.shift_lanes(ins[0], n.imm)
        elif n.kind == "cast":
            vals[n.id] = numerics.vop("CAST", graph.nodes[n.inputs[0]].dtype, ins[0], to=n.dtype)
        elif n.kind == "requant":
            vals[n.id] = numerics.vop("REQUANT", DType.I32, ins[0], imm=n.imm)
        else:
            vals[n.id] = numerics.vop(n.kind.upper(), graph.nodes[n.inputs[0]].dtype, *ins)
    return {name: vals[i] for name, i in graph.outputs.items()}
