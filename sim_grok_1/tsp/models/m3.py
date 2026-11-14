"""Milestone M3: one decode step of a tiny transformer block (plan.md section 6).

The model is a single-head, pre-norm transformer block followed by an
un-embedding, evaluated for one new token at a fixed sequence length:

    d_model D = 8, sequence length T = 4, hidden size H = 16, vocabulary V = 16

Values are fp32 on the VXM; every MXM operand (weights and activations) is
fp16, made with explicit casts in the graph, and every matvec gives fp32.

Inputs supplied by the host each step:
    x              fp32[D]   embedding of the current token
    K0 .. K{T-2}   fp16[D]   cached keys of the T-1 earlier tokens
    Vt0 .. Vt{D-1} fp16[T]   cached values, stored transposed: Vt_j[t] is
                             element j of the value of token t; the last
                             element (the current token) is zero

Computation (rms(z) = rsqrt(mean(z*z) + eps)):
    1. RMS norm:  mean(x*x) is mul(x, x) -> cast fp16 -> one-row matvec with
       the row (1/D, ..., 1/D); add eps; broadcast to D lanes; rsqrt; then
       xn = x * r and xg = xn * g1 (gain).
    2. q, k, v = Wq.xg, Wk.xg, Wv.xg (three matvecs on cast(xg, fp16)).
    3. k16 = cast(k, fp16).  Scores s = K.q16 where K is the matrix whose
       rows are K0 .. K{T-2} and k16: part of the weight matrix is computed
       in this step.
    4. Softmax over the T scores without max-subtraction:
       e = exp(s * scale) with scale = 1/sqrt(D); sum = one-row matvec of
       ones over cast(e, fp16); broadcast to T lanes; r = rsqrt(sum);
       p = e * (r * r).
    5. Attention output: a = Vt.p16 (cached tokens; the zero last column
       drops the current token) plus broadcast(p, T-1, D) * v.
    6. h1 = x + Wo.a16 (output projection and residual).
    7. Second RMS norm of h1 with gain g2, giving hg.
    8. Feed-forward: f = W2.relu(W1.hg16 + b1)16 + b2; h2 = h1 + f.
    9. logits = Wu.h2_16.
Outputs: "logits" (fp32[V]), "k16" (fp16[D]) and "v" (fp32[D]); the host
appends k16 and v to its caches for the next step.

Stated simplifications:
- a single attention head;
- no max-subtraction in the softmax: the random weights are scaled so that
  the scores stay small and exp is far from overflow;
- the reciprocal of the softmax sum is formed as rsqrt(sum) squared, since
  the VXM operation set (ledger B11) has no division;
- the cache update is left to the host;
- the sequence length is fixed: it is part of the compiled program's static
  shape (dossier section 3, static shapes);
- no final norm before the un-embedding.

`reference` recomputes the same step with ordinary NumPy matrix products in
float32, applying the same fp16 casts at the same points; it agrees with the
simulator to a loose tolerance (plan.md section 5.3), while `evaluate` from
tsp.reference agrees bit for bit.
"""

import numpy as np

from .. import params
from ..graph import Graph

D = 8  # not-a-parameter: model size (d_model)
T = 4  # not-a-parameter: model size (sequence length)
H = 16  # not-a-parameter: model size (feed-forward hidden size)
V = 16  # not-a-parameter: model size (vocabulary)
LANES = params.LANES_PER_SUPERLANE * params.TILES_TOY  # the toy chip lane count (ledger G1, G2)
EPS = 1e-5  # not-a-parameter: model constant, RMS-norm epsilon
BIAS_SCALE = 0.1  # not-a-parameter: random scale of the biases
GAIN_SPREAD = 0.1  # not-a-parameter: random scale, gains are 1 +- this


def _params(seed):
    """Draw every constant and input from `seed`.

    Returns a dict of NumPy arrays.  fp16 quantities are returned already
    rounded to float16, fp32 quantities as float32.
    """
    rng = np.random.default_rng(seed)

    def mat(rows, cols):
        # Scaled by 1/sqrt(cols) so every matvec output has roughly unit size.
        w = rng.standard_normal((rows, cols)) / np.sqrt(cols)
        return w.astype(np.float16)

    p = {}
    p["x"] = rng.standard_normal(D).astype(np.float32)
    p["K"] = rng.standard_normal((T - 1, D)).astype(np.float16)
    vals = rng.standard_normal((T - 1, D))
    vt = np.zeros((D, T))
    vt[:, : T - 1] = vals.T
    p["Vt"] = vt.astype(np.float16)
    p["g1"] = (1 + GAIN_SPREAD * rng.uniform(-1, 1, D)).astype(np.float32)
    p["g2"] = (1 + GAIN_SPREAD * rng.uniform(-1, 1, D)).astype(np.float32)
    p["Wq"] = mat(D, D)
    p["Wk"] = mat(D, D)
    p["Wv"] = mat(D, D)
    p["Wo"] = mat(D, D)
    p["W1"] = mat(H, D)
    p["b1"] = (BIAS_SCALE * rng.standard_normal(H)).astype(np.float32)
    p["W2"] = mat(D, H)
    p["b2"] = (BIAS_SCALE * rng.standard_normal(D)).astype(np.float32)
    p["Wu"] = mat(V, D)
    p["mean_row"] = np.full((1, D), 1 / D).astype(np.float16)
    p["ones_row"] = np.ones((1, T)).astype(np.float16)
    p["eps"] = np.array([EPS], dtype=np.float32)
    p["scale"] = np.full(T, 1 / np.sqrt(D)).astype(np.float32)
    return p


def _rms_norm(g, z, mean_row, eps, gain, tag):
    """Graph nodes for gain * z * rsqrt(mean(z*z) + eps)."""
    zz = g.mul(z, z, name=f"{tag}_sq")
    zz16 = g.cast(zz, "fp16", name=f"{tag}_sq16")
    ms = g.matvec(mean_row, zz16, name=f"{tag}_ms")
    mse = g.add(ms, eps, name=f"{tag}_mse")
    msb = g.broadcast(mse, 0, D, name=f"{tag}_msb")
    r = g.rsqrt(msb, name=f"{tag}_r")
    zn = g.mul(z, r, name=f"{tag}_n")
    return g.mul(zn, gain, name=f"{tag}_g")


def build(seed=0):
    """The M3 graph and its input values: (Graph, inputs dict)."""
    p = _params(seed)
    g = Graph("m3", lanes=LANES)

    # Inputs.
    x = g.input("x", "fp32", D)
    k_cache = [g.input(f"K{t}", "fp16", D) for t in range(T - 1)]
    vt_rows = [g.input(f"Vt{j}", "fp16", T) for j in range(D)]

    # Constants.
    mean_row = g.const_matrix("mean_row", p["mean_row"], "fp16")
    ones_row = g.const_matrix("ones_row", p["ones_row"], "fp16")
    eps = g.const("eps", p["eps"], "fp32")
    scale = g.const("scale", p["scale"], "fp32")
    g1 = g.const("g1", p["g1"], "fp32")
    g2 = g.const("g2", p["g2"], "fp32")
    wq = g.const_matrix("Wq", p["Wq"], "fp16")
    wk = g.const_matrix("Wk", p["Wk"], "fp16")
    wv = g.const_matrix("Wv", p["Wv"], "fp16")
    wo = g.const_matrix("Wo", p["Wo"], "fp16")
    w1 = g.const_matrix("W1", p["W1"], "fp16")
    b1 = g.const("b1", p["b1"], "fp32")
    w2 = g.const_matrix("W2", p["W2"], "fp16")
    b2 = g.const("b2", p["b2"], "fp32")
    wu = g.const_matrix("Wu", p["Wu"], "fp16")

    # 1. First RMS norm.
    xg = _rms_norm(g, x, mean_row, eps, g1, "n1")
    xg16 = g.cast(xg, "fp16", name="xg16")

    # 2. q, k, v.
    q = g.matvec(wq, xg16, name="q")
    k = g.matvec(wk, xg16, name="k")
    v = g.matvec(wv, xg16, name="v")

    # 3. Scores against the cached keys plus the new key.
    k16 = g.cast(k, "fp16", name="k16")
    keys = g.matrix("Kmat", k_cache + [k16])
    q16 = g.cast(q, "fp16", name="q16")
    s = g.matvec(keys, q16, name="scores")

    # 4. Softmax.
    ss = g.mul(s, scale, name="scaled")
    e = g.exp(ss, name="e")
    e16 = g.cast(e, "fp16", name="e16")
    total = g.matvec(ones_row, e16, name="esum")
    total_b = g.broadcast(total, 0, T, name="esum_b")
    r = g.rsqrt(total_b, name="esum_r")
    recip = g.mul(r, r, name="esum_inv")
    prob = g.mul(e, recip, name="p")

    # 5. Attention output.
    prob16 = g.cast(prob, "fp16", name="p16")
    values_t = g.matrix("Vt", vt_rows)
    a_cache = g.matvec(values_t, prob16, name="a_cache")
    p_last = g.broadcast(prob, T - 1, D, name="p_last")
    a_new = g.mul(p_last, v, name="a_new")
    attn = g.add(a_cache, a_new, name="attn")

    # 6. Output projection and residual.
    attn16 = g.cast(attn, "fp16", name="attn16")
    o = g.matvec(wo, attn16, name="o")
    h1 = g.add(x, o, name="h1")

    # 7. Second RMS norm.
    hg = _rms_norm(g, h1, mean_row, eps, g2, "n2")
    hg16 = g.cast(hg, "fp16", name="hg16")

    # 8. Feed-forward and residual.
    f1 = g.add(g.matvec(w1, hg16, name="ff1"), b1, name="ff1_b")
    f1r = g.relu(f1, name="ff1_relu")
    f1r16 = g.cast(f1r, "fp16", name="ff1_16")
    f2 = g.add(g.matvec(w2, f1r16, name="ff2"), b2, name="ff2_b")
    h2 = g.add(h1, f2, name="h2")

    # 9. Un-embedding.
    h2_16 = g.cast(h2, "fp16", name="h2_16")
    logits = g.matvec(wu, h2_16, name="logits")

    g.output("logits", logits)
    g.output("k16", k16)
    g.output("v", v)

    inputs = {"x": p["x"]}
    for t in range(T - 1):
        inputs[f"K{t}"] = p["K"][t].copy()
    for j in range(D):
        inputs[f"Vt{j}"] = p["Vt"][j].copy()
    return g, inputs


def reference(seed=0):
    """Expected outputs with ordinary NumPy matrix products (float32 throughout).

    The fp16 casts are applied at the same points as in the graph; sums use
    NumPy's own matrix product, so the result can differ from the simulator
    in the last bits (see the module docstring).
    """
    p = _params(seed)
    f16 = np.float16
    f32 = np.float32

    def mm(w, z):
        """fp16 matrix times fp16 vector, computed in float32."""
        return w.astype(f32) @ z.astype(f16).astype(f32)

    def rms_norm(z, gain):
        mean = mm(p["mean_row"], z * z)[0] + p["eps"][0]
        r = f32(1) / np.sqrt(np.full(D, mean, dtype=f32))
        return (z * r) * gain

    x = p["x"]
    xg = rms_norm(x, p["g1"])
    q = mm(p["Wq"], xg)
    k = mm(p["Wk"], xg)
    v = mm(p["Wv"], xg)
    k16 = k.astype(f16)
    keys = np.vstack([p["K"], k16[None, :]])
    s = mm(keys, q)
    e = np.exp(s * p["scale"])
    total = mm(p["ones_row"], e)[0]
    r = f32(1) / np.sqrt(np.full(T, total, dtype=f32))
    prob = e * (r * r)
    attn = mm(p["Vt"], prob) + prob[T - 1] * v
    h1 = x + mm(p["Wo"], attn)
    hg = rms_norm(h1, p["g2"])
    f1 = np.maximum(mm(p["W1"], hg) + p["b1"], f32(0))
    h2 = h1 + (mm(p["W2"], f1) + p["b2"])
    logits = mm(p["Wu"], h2)
    return {
        "logits": logits.astype(f32),
        "k16": k16,
        "v": v.astype(f32),
    }
