"""Reference evaluators: hand-computed cases for every node kind, and evaluate vs evaluate_plain."""
import numpy as np
import pytest

from tsp import models
from tsp.graph import Graph
from tsp.isa import DType
from tsp.reference import FeedError, evaluate, evaluate_plain

I8, I32, F16, F32 = DType.I8, DType.I32, DType.F16, DType.F32
MAX32 = 2**31 - 1


def one(g, v, feeds=None, tile_len=32):
    g.output("out", v)
    exact = evaluate(g, feeds or {}, tile_len)["out"]
    plain = evaluate_plain(g, feeds or {})["out"]
    return exact, plain


# ---- integer kinds ---------------------------------------------------------------
@pytest.mark.parametrize("kind,a,b,want", [
    ("add", [MAX32, -5, 3], [1, -2**31, 4], [-2**31, 2**31 - 5, 7]),
    ("sub", [-2**31, 10, 0], [1, 3, 0], [MAX32, 7, 0]),
    ("mul", [65536, -3, 46341], [65536, 7, 46341], [0, -21, -2147479015]),
])
def test_i32_binary_wraps(kind, a, b, want):
    g = Graph("t")
    va = g.vector("a", I32, 3, data=a)
    vb = g.vector("b", I32, 3, data=b)
    exact, plain = one(g, getattr(g, kind)(va, vb))
    assert exact.dtype == np.int32 and list(exact) == want
    assert list(plain) == want


def test_relu_requant_cast_i8():
    g = Graph("t")
    a = g.vector("a", I32, 5, data=[1000, -70000, 37, -5, 300])
    g.output("relu", g.relu(a))
    g.output("rq", g.requant(a, 2))
    x = g.vector("x", I8, 3, data=[-128, 0, 127])
    g.output("cast", g.cast(x, I32))
    for res in (evaluate(g, {}, 32), evaluate_plain(g, {})):
        assert list(res["relu"]) == [1000, 0, 37, 0, 300]
        assert list(res["rq"]) == [127, -128, 9, -2, 75]          # -5 >> 2 == -2 (arithmetic), saturation
        assert list(res["cast"]) == [-128, 0, 127]
    assert evaluate(g, {}, 32)["rq"].dtype == np.int8


def test_matvec_i8_and_multi_tile():
    g = Graph("t")
    W_np = np.array([[1, 2, 3], [-4, 5, -6]], dtype=np.int8)
    W = g.matrix("W", I8, 2, 3, data=W_np)
    x = g.vector("x", I8, 3)
    feeds = {"x": np.array([3, -2, 1], dtype=np.int8)}
    g.output("y", g.matvec(W, x))
    for tl in (1, 2, 3, 32):
        assert list(evaluate(g, feeds, tl)["y"]) == [2, -28]
    assert list(evaluate_plain(g, feeds)["y"]) == [2, -28]


def test_matvec_i8_wraps():
    g = Graph("t")
    W = g.matrix("W", I8, 1, 2, data=[[-128, -128]])
    x = g.vector("x", I8, 2, data=[-128, -128])
    # 2 * 16384 = 32768: no wrap; build a wrapping sum through the I32 add instead
    big = g.vector("big", I32, 1, data=[MAX32])
    exact, plain = one(g, g.add(g.matvec(W, x), big))
    assert list(exact) == [-2**31 + 32767] and list(plain) == [-2**31 + 32767]


# ---- float kinds ----------------------------------------------------------------
def test_f32_arith_and_relu():
    g = Graph("t")
    a = g.vector("a", F32, 3, data=[1.5, -2.0, 0.25])
    b = g.vector("b", F32, 3, data=[0.5, 4.0, -1.0])
    g.output("add", g.add(a, b))
    g.output("mul", g.mul(a, b))
    g.output("relu", g.relu(a))
    for res in (evaluate(g, {}, 16), evaluate_plain(g, {})):
        assert list(res["add"]) == [2.0, 2.0, -0.75]
        assert list(res["mul"]) == [0.75, -8.0, -0.25]
        assert list(res["relu"]) == [1.5, 0.0, 0.25]


def test_transcendentals():
    g = Graph("t")
    a = g.vector("a", F32, 4, data=[0.0, 4.0, 1.0, -1.0])
    g.output("exp", g.exp(a))
    g.output("rsqrt", g.rsqrt(a))
    g.output("tanh", g.tanh(a))
    ex, pl = evaluate(g, {}, 16), evaluate_plain(g, {})
    assert ex["exp"][0] == 1.0 and ex["exp"][2] == np.float32(np.e)
    assert ex["rsqrt"][1] == 0.5 and np.isinf(ex["rsqrt"][0]) and np.isnan(ex["rsqrt"][3])
    assert pl["rsqrt"][1] == 0.5 and np.isinf(pl["rsqrt"][0]) and np.isnan(pl["rsqrt"][3])
    assert ex["tanh"][0] == 0.0 and ex["tanh"][3] == np.float32(np.tanh(-1.0))
    assert ex["exp"].dtype == np.float32
    assert abs(pl["exp"][2] - np.e) < 1e-15


def test_cast_f32_to_f16_rounds_in_exact_not_in_plain():
    g = Graph("t")
    vals = [1.0 + 2**-12, 1.0 + 3 * 2**-12, 70000.0, -0.1]
    a = g.vector("a", F32, 4, data=vals)
    h = g.cast(a, F16)
    g.output("h", h)
    g.output("back", g.cast(h, F32))
    ex = evaluate(g, {}, 16)
    assert ex["h"].dtype == np.float16
    assert ex["h"][0] == 1.0                       # tie rounds to even
    assert ex["h"][1] == 1.0 + 2**-10              # above the tie rounds up
    assert np.isinf(ex["h"][2])                    # beyond the F16 range
    assert ex["h"][3] == np.float16(-0.1)
    assert np.array_equal(ex["back"][:2], ex["h"][:2].astype(np.float32))
    pl = evaluate_plain(g, {})
    assert list(pl["h"]) == list(np.array(vals, dtype=np.float32).astype(np.float64))   # identity


def test_matvec_f16_and_multi_tile_order():
    """Per-input-tile products, each rounded to F32, summed left to right (plan 3.3)."""
    g = Graph("t")
    W = g.matrix("W", F16, 1, 3, data=[[4096.0, 2**-12, 2**-12]])
    x = g.vector("x", F16, 3, data=[1.0, 1.0, 1.0])
    g.output("y", g.matvec(W, x))
    exact_sum = 4096.0 + 2**-11                    # representable in F32
    assert evaluate(g, {}, 3)["y"][0] == np.float32(exact_sum)     # one tile: rounded once
    # tile_len 2: tile 0 = 4096 + 2**-12 -> tie -> 4096; then + 2**-12 -> 4096 again
    assert evaluate(g, {}, 2)["y"][0] == 4096.0
    # tile_len 1: ((4096 + 2^-12) + 2^-12) left to right -> 4096; right to left would give exact_sum
    assert evaluate(g, {}, 1)["y"][0] == 4096.0
    assert evaluate_plain(g, {})["y"][0] == exact_sum
    assert evaluate(g, {}, 1)["y"].dtype == np.float32


def test_matvec_f16_hand_case():
    g = Graph("t")
    W = g.matrix("W", F16, 3, 2, data=[[1, 0.5], [2, 0.25], [3, -1]])
    x = g.vector("x", F16, 2, data=[1.5, 2.0])
    exact, plain = one(g, g.matvec(W, x), tile_len=16)
    assert list(exact) == [2.5, 3.5, 2.5] and list(plain) == [2.5, 3.5, 2.5]


def test_matvec_cols_ignores_extra_operand_elements():
    g = Graph("t")
    c0 = g.vector("c0", I8, 3, data=[1, 2, 3])
    c1 = g.vector("c1", I8, 3, data=[-1, 0, 4])
    x = g.vector("x", I8, 4, data=[2, 3, 127, -128])
    exact, plain = one(g, g.matvec_cols([c0, c1], x))
    assert list(exact) == [-1, 4, 18] and list(plain) == [-1, 4, 18]
    assert exact.dtype == np.int32


def test_matvec_cols_f16_with_computed_column():
    g = Graph("t")
    c0 = g.vector("c0", F16, 2, data=[1.0, 2.0])
    f = g.vector("f", F32, 2, data=[0.5, -1.0])
    x = g.vector("x", F16, 3, data=[2.0, 4.0, 1000.0])
    exact, plain = one(g, g.matvec_cols([c0, g.cast(f, F16)], x), tile_len=16)
    assert list(exact) == [4.0, 0.0] and list(plain) == [4.0, 0.0]


def test_shift():
    g = Graph("t")
    a = g.vector("a", I32, 4, data=[1, 2, 3, 4])
    g.output("s2", g.shift(a, 2))
    g.output("s0", g.shift(a, 0))
    g.output("s9", g.shift(a, 9))
    for res in (evaluate(g, {}, 32), evaluate_plain(g, {})):
        assert list(res["s2"]) == [0, 0, 1, 2]
        assert list(res["s0"]) == [1, 2, 3, 4]
        assert list(res["s9"]) == [0, 0, 0, 0]


def test_feeds_errors():
    g, feeds = models.m1()
    with pytest.raises(FeedError, match="missing feed for runtime input 'x'"):
        evaluate(g, {}, 32)
    with pytest.raises(FeedError, match="missing feed"):
        evaluate_plain(g, {})
    with pytest.raises(FeedError, match="shape"):
        evaluate(g, {"x": np.zeros(3, dtype=np.int8)}, 32)
    with pytest.raises(FeedError, match="unexpected"):
        evaluate(g, {"x": feeds["x"], "y": feeds["x"]}, 32)
    with pytest.raises(FeedError, match="constant"):
        evaluate(g, {"x": feeds["x"], "b": np.zeros(24)}, 32)


def test_return_all():
    g, feeds = models.m1()
    out, vals = evaluate(g, feeds, 32, return_all=True)
    assert set(vals) == {n.name for n in g.nodes}
    assert np.array_equal(out["y"], vals["y"])
    assert np.array_equal(vals["Wx_b"], vals["Wx"] + vals["b"])


# ---- models: exact vs plain --------------------------------------------------------
def tile_len(graph, lanes=32):
    has_f16 = any(n.dtype == F16 for n in graph.nodes) or any(m.dtype == F16 for m in graph.matrices.values())
    return lanes // 2 if has_f16 else lanes


@pytest.mark.parametrize("make", [models.m1, models.m2, lambda: models.m1(320, 320)], ids=["m1", "m2", "m1-paper"])
def test_integer_models_exact_equals_plain(make):
    g, feeds = make()
    lanes = 320 if g.nodes[0].n == 320 else 32
    exact = evaluate(g, feeds, tile_len(g, lanes))
    plain = evaluate_plain(g, feeds)
    assert set(exact) == set(plain) == set(g.outputs)
    for name in exact:
        assert np.array_equal(exact[name].astype(np.int64), plain[name]), name


def test_m2_tiling_does_not_change_integer_values():
    g, feeds = models.m2()
    ref = evaluate(g, feeds, 32)["y"]
    for tl in (1, 7, 16, 48):
        assert np.array_equal(evaluate(g, feeds, tl)["y"], ref)


def test_m2_exercises_requant_saturation():
    g, feeds = models.m2()
    _, vals = evaluate(g, feeds, 32, return_all=True)
    assert (vals["h"] == 127).any() and vals["h"].min() >= 0     # relu then requant: saturates at 127


def test_m3_exact_vs_plain_within_tolerance():
    g, feeds = models.m3()
    exact = evaluate(g, feeds, 16)
    plain = evaluate_plain(g, feeds)
    for name in ("logits", "k", "v"):
        e, p = exact[name].astype(np.float64), plain[name]
        diff = float(np.max(np.abs(e - p)))
        assert np.allclose(e, p, rtol=2e-2, atol=2e-2), f"{name}: max |evaluate - evaluate_plain| = {diff:.3g}"
    print("M3 max |evaluate - evaluate_plain|:",
          {n: float(np.max(np.abs(exact[n].astype(np.float64) - plain[n]))) for n in exact})


def test_m3_intermediates_agree():
    """Every intermediate, not only the outputs, is close between the two references."""
    g, feeds = models.m3()
    _, ex = evaluate(g, feeds, 16, return_all=True)
    _, pl = evaluate_plain(g, feeds, return_all=True)
    for n in g.nodes:
        e, p = ex[n.name].astype(np.float64), pl[n.name]
        if n.name in ("s_masked",):          # -1e4 lanes: compare relatively
            assert np.allclose(e, p, rtol=1e-6, atol=2e-2), n.name
        else:
            assert np.allclose(e, p, rtol=2e-2, atol=2e-2), (n.name, float(np.max(np.abs(e - p))))
