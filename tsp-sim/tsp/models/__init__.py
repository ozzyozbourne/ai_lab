"""The three milestone models (plan.md section 6).

Each function returns `(graph, feeds)`: constants are graph constants, runtime
inputs are in `feeds`. Data come from a small 64-bit linear congruential
generator (`Lcg`), not from NumPy's random distributions, so they are identical
on every platform and NumPy version. Each model has a fixed default seed;
`seed=` overrides it (the graph structure never depends on the seed).

Value ranges (plan section 6): I8 inputs -128..127; I8 weights -16..15; I32
biases -1000..1000; F16 weights multiples of 1/256 in [-0.25, 0.25]; F32 inputs
multiples of 1/64 in [-1, 1].
"""
from __future__ import annotations

import numpy as np

from ..graph import Graph
from ..isa import DType

# Knuth's MMIX LCG: state <- A * state + C (mod 2**64); outputs are the top 32 bits.
_LCG_A = 6364136223846793005    # not a machine parameter: PRNG constant
_LCG_C = 1442695040888963407    # not a machine parameter: PRNG constant
_LCG_MASK = (1 << 64) - 1       # not a machine parameter: PRNG constant (64-bit state)
_LCG_OUT_SHIFT = 32             # not a machine parameter: PRNG constant (keep the high half)

DEFAULT_SEEDS = {"m1": 1, "m2": 2, "m3": 3}  # not a machine parameter: model data seeds


class Lcg:
    """64-bit LCG. Deterministic, platform independent, pure Python integers."""

    def __init__(self, seed: int):
        self.state = (int(seed) * _LCG_A + _LCG_C) & _LCG_MASK

    def next_u32(self) -> int:
        self.state = (self.state * _LCG_A + _LCG_C) & _LCG_MASK
        return self.state >> _LCG_OUT_SHIFT

    def integers(self, lo: int, hi: int, shape) -> np.ndarray:
        """Integers in lo..hi inclusive (tiny modulo bias, irrelevant here), as int64, row-major."""
        shape = (shape,) if isinstance(shape, int) else tuple(shape)
        count = int(np.prod(shape)) if shape else 1
        span = hi - lo + 1
        vals = [lo + self.next_u32() % span for _ in range(count)]
        return np.array(vals, dtype=np.int64).reshape(shape)


# ---- value ranges (plan section 6) ---------------------------------------------
def _i8_input(rng: Lcg, shape) -> np.ndarray:
    return rng.integers(-128, 127, shape).astype(np.int8)


def _i8_weight(rng: Lcg, shape) -> np.ndarray:
    return rng.integers(-16, 15, shape).astype(np.int8)


def _i32_bias(rng: Lcg, shape) -> np.ndarray:
    return rng.integers(-1000, 1000, shape).astype(np.int32)


def _f16_weight(rng: Lcg, shape) -> np.ndarray:
    return (rng.integers(-64, 64, shape) / 256.0).astype(np.float16)   # exact in F16


def _f32_input(rng: Lcg, shape) -> np.ndarray:
    return (rng.integers(-64, 64, shape) / 64.0).astype(np.float32)    # exact in F16 and F32


def _seed(name: str, seed: int | None) -> int:
    return DEFAULT_SEEDS[name] if seed is None else seed


# ---- M1 --------------------------------------------------------------------------
def m1(n_in: int = 20, n_out: int = 24, seed: int | None = None):
    """M1: y = relu(W x + b).

    Shapes: x I8[n_in] (runtime input), W I8[n_out x n_in], b I32[n_out]
    (constants), y I32[n_out] (output). Default 20 -> 24; the paper-size scale
    test uses n_in = n_out = 320. Simplifications: none beyond batch 1.
    """
    rng = Lcg(_seed("m1", seed))
    W_np = _i8_weight(rng, (n_out, n_in))
    b_np = _i32_bias(rng, n_out)
    x_np = _i8_input(rng, n_in)

    g = Graph("m1")
    x = g.vector("x", DType.I8, n_in)
    b = g.vector("b", DType.I32, n_out, data=b_np)
    W = g.matrix("W", DType.I8, n_out, n_in, data=W_np)
    y = g.relu(g.add(g.matvec(W, x, name="Wx"), b, name="Wx_b"), name="y")
    g.output("y", y)
    return g, {"x": x_np}


# ---- M2 --------------------------------------------------------------------------
def m2(seed: int | None = None):
    """M2: h = requant(relu(W1 x + b1), 6); y = W2 h + b2.

    Shapes: x I8[48] (runtime input); W1 I8[40 x 48], b1 I32[40], W2 I8[10 x 40],
    b2 I32[10] (constants); h I8[40]; y I32[10] (output). On the toy chip
    (tile_len 32) W1 needs two input and two output tiles. Simplifications:
    integer-only, batch 1.
    """
    rng = Lcg(_seed("m2", seed))
    W1_np = _i8_weight(rng, (40, 48))
    b1_np = _i32_bias(rng, 40)
    W2_np = _i8_weight(rng, (10, 40))
    b2_np = _i32_bias(rng, 10)
    x_np = _i8_input(rng, 48)

    g = Graph("m2")
    x = g.vector("x", DType.I8, 48)
    b1 = g.vector("b1", DType.I32, 40, data=b1_np)
    b2 = g.vector("b2", DType.I32, 10, data=b2_np)
    W1 = g.matrix("W1", DType.I8, 40, 48, data=W1_np)
    W2 = g.matrix("W2", DType.I8, 10, 40, data=W2_np)
    z1 = g.relu(g.add(g.matvec(W1, x, name="W1x"), b1, name="W1x_b"), name="z1")
    h = g.requant(z1, 6, name="h")
    y = g.add(g.matvec(W2, h, name="W2h"), b2, name="y")
    g.output("y", y)
    return g, {"x": x_np}


# ---- M3 --------------------------------------------------------------------------
M3_D = 16          # not a machine parameter: model width d
M3_T = 8           # not a machine parameter: sequence length T (position T-1 is computed)
M3_FFN = 32        # not a machine parameter: FFN width
M3_VOCAB = 32      # not a machine parameter: vocabulary size
M3_MASK = -1e4     # not a machine parameter: additive mask for lanes >= T


def m3(seed: int | None = None):
    """M3: one decoder step, single head, position T-1 = 7 of a fixed length T = 8.

    Shapes: d = 16, FFN width 32, vocabulary 32. Runtime inputs: x F32[16],
    Kc F16[16 x 16] (cached keys in rows 0..6, rows 7..15 zero), V0..V6 F16[16]
    (cached values). Constants: Wq, Wk, Wv, Wo F16[16 x 16], W1 F16[32 x 16],
    W2 F16[16 x 32], Wu F16[32 x 16], b1 F32[32], b2 F32[16], SUM0 F16[16 x 16]
    (row 0 ones), ONES F16[16 x 16], scale F32[16] (0.25 = 1/sqrt(16)),
    mask F32[16] (0 for lanes < 8, -1e4 otherwise). Outputs: logits F32[32],
    k F32[16], v F32[16].

    Simplifications: no layer norm, one head, no argmax, the embedding lookup is
    done by the host, and the host appends k, v to the cache for the next step.
    Softmax is exp / sum with 1/S computed as rsqrt(S)^2 and no max subtraction
    (scores stay within +-16). Data choices not fixed by the plan: Kc rows 0..6
    and V0..V6 use the F32-input range (multiples of 1/64 in [-1, 1], exact in
    F16); b1, b2 use the same range.
    """
    d, T, F, V = M3_D, M3_T, M3_FFN, M3_VOCAB
    rng = Lcg(_seed("m3", seed))
    Wq_np, Wk_np, Wv_np, Wo_np = (_f16_weight(rng, (d, d)) for _ in range(4))
    W1_np = _f16_weight(rng, (F, d))
    W2_np = _f16_weight(rng, (d, F))
    Wu_np = _f16_weight(rng, (V, d))
    b1_np = _f32_input(rng, F)
    b2_np = _f32_input(rng, d)
    x_np = _f32_input(rng, d)
    Kc_np = np.zeros((d, d), dtype=np.float16)
    Kc_np[: T - 1] = _f32_input(rng, (T - 1, d)).astype(np.float16)
    Vs_np = [_f32_input(rng, d).astype(np.float16) for _ in range(T - 1)]

    sum0_np = np.zeros((d, d), dtype=np.float16)
    sum0_np[0] = 1
    ones_np = np.ones((d, d), dtype=np.float16)
    scale_np = np.full(d, 1.0 / np.sqrt(d), dtype=np.float32)
    mask_np = np.where(np.arange(d) < T, 0.0, M3_MASK).astype(np.float32)

    F16, F32 = DType.F16, DType.F32
    g = Graph("m3")
    # leaves: runtime inputs first, then constants
    x = g.vector("x", F32, d)
    Kc = g.matrix("Kc", F16, d, d)
    Vc = [g.vector(f"V{i}", F16, d) for i in range(T - 1)]
    Wq = g.matrix("Wq", F16, d, d, data=Wq_np)
    Wk = g.matrix("Wk", F16, d, d, data=Wk_np)
    Wv = g.matrix("Wv", F16, d, d, data=Wv_np)
    Wo = g.matrix("Wo", F16, d, d, data=Wo_np)
    W1 = g.matrix("W1", F16, F, d, data=W1_np)
    W2 = g.matrix("W2", F16, d, F, data=W2_np)
    Wu = g.matrix("Wu", F16, V, d, data=Wu_np)
    SUM0 = g.matrix("SUM0", F16, d, d, data=sum0_np)
    ONES = g.matrix("ONES", F16, d, d, data=ones_np)
    b1 = g.vector("b1", F32, F, data=b1_np)
    b2 = g.vector("b2", F32, d, data=b2_np)
    scale = g.vector("scale", F32, d, data=scale_np)
    mask = g.vector("mask", F32, d, data=mask_np)

    def c16(v, name):
        return g.cast(v, F16, name=name)

    x16 = c16(x, "x16")
    q = g.matvec(Wq, x16, name="q")
    k = g.matvec(Wk, x16, name="k")
    v = g.matvec(Wv, x16, name="v")
    s_cache = g.matvec(Kc, c16(q, "q16"), name="s_cache")
    qk16 = c16(g.mul(q, k, name="qk"), "qk16")
    s_self = g.shift(g.matvec(SUM0, qk16, name="qk_sum"), T - 1, name="s_self")
    s = g.add(s_cache, s_self, name="s")
    e = g.exp(g.add(g.mul(s, scale, name="s_scaled"), mask, name="s_masked"), name="e")
    S = g.matvec(ONES, c16(e, "e16"), name="S")
    r = g.rsqrt(S, name="r")
    a = g.mul(e, g.mul(r, r, name="rr"), name="a")
    o = g.matvec_cols(Vc + [c16(v, "v16")], c16(a, "a16"), name="o")
    h = g.add(x, g.matvec(Wo, c16(o, "o16"), name="Wo_o"), name="h")
    hid = g.relu(g.add(g.matvec(W1, c16(h, "h16"), name="W1h"), b1, name="W1h_b"), name="hid")
    f = g.add(g.matvec(W2, c16(hid, "hid16"), name="W2hid"), b2, name="f")
    y = g.add(h, f, name="y")
    logits = g.matvec(Wu, c16(y, "y16"), name="logits")
    g.output("logits", logits)
    g.output("k", k)
    g.output("v", v)

    feeds = {"x": x_np, "Kc": Kc_np}
    feeds.update({f"V{i}": Vs_np[i] for i in range(T - 1)})
    return g, feeds


ALL = {"m1": m1, "m2": m2, "m3": m3}
