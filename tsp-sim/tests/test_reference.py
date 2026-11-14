"""tsp.reference.evaluate on small graphs whose results are worked out by hand."""

import numpy as np
import pytest

from tsp.errors import GraphError
from tsp.graph import Graph
from tsp.reference import evaluate, matvec_fp16, wrap_int32

I32_MAX = np.iinfo(np.int32).max
I32_MIN = np.iinfo(np.int32).min


def _one(build, inputs=None):
    """Build a graph with `build(g)` returning the output tensor; evaluate it."""
    g = Graph("t", lanes=16)  # not-a-parameter: test size
    g.output("out", build(g))
    return evaluate(g, inputs or {})["out"]


def test_int_add_sub_mul_wrap():
    a = np.array([1, I32_MAX, I32_MIN, 7], dtype=np.int32)
    b = np.array([2, 1, -1, -3], dtype=np.int32)

    def mk(op):
        return lambda g: getattr(g, op)(g.const("a", a, "int32"), g.const("b", b, "int32"))

    assert _one(mk("add")).tolist() == [3, I32_MIN, I32_MAX, 4]
    assert _one(mk("sub")).tolist() == [-1, I32_MAX - 1, I32_MIN + 1, 10]
    assert _one(mk("mul")).tolist() == [2, I32_MAX, I32_MIN, -21]


def test_int_neg_relu():
    a = np.array([5, -5, 0, I32_MIN], dtype=np.int32)
    assert _one(lambda g: g.neg(g.const("a", a, "int32"))).tolist() == [-5, 5, 0, I32_MIN]
    assert _one(lambda g: g.relu(g.const("a", a, "int32"))).tolist() == [5, 0, 0, 0]


def test_float_ops():
    a = np.array([1.5, -2.0, 0.25], dtype=np.float32)
    b = np.array([0.5, 4.0, -0.25], dtype=np.float32)

    def mk(op):
        return lambda g: getattr(g, op)(g.const("a", a, "fp32"), g.const("b", b, "fp32"))

    assert _one(mk("add")).tolist() == [2.0, 2.0, 0.0]
    assert _one(mk("sub")).tolist() == [1.0, -6.0, 0.5]
    assert _one(mk("mul")).tolist() == [0.75, -8.0, -0.0625]
    out = _one(lambda g: g.neg(g.const("a", a, "fp32")))
    assert out.dtype == np.float32 and out.tolist() == [-1.5, 2.0, -0.25]


def test_float_relu_gives_positive_zero():
    a = np.array([-0.0, -3.0, 2.5], dtype=np.float32)
    out = _one(lambda g: g.relu(g.const("a", a, "fp32")))
    assert out.tolist() == [0.0, 0.0, 2.5]
    assert not np.signbit(out).any()


def test_same_operand_twice():
    out = _one(lambda g: (lambda x: g.mul(x, x))(g.input("x", "int32", 3)),
               {"x": np.array([3, -4, 5], dtype=np.int32)})
    assert out.tolist() == [9, 16, 25]


def test_transcendentals():
    a = np.array([0.0, 1.0, 4.0], dtype=np.float32)
    out = _one(lambda g: g.exp(g.const("a", a, "fp32")))
    assert out.dtype == np.float32
    assert np.array_equal(out, np.exp(a))
    assert out[0] == 1.0
    out = _one(lambda g: g.tanh(g.const("a", a, "fp32")))
    assert np.array_equal(out, np.tanh(a)) and out[0] == 0.0
    out = _one(lambda g: g.rsqrt(g.const("a", np.array([4.0, 16.0, 0.25], np.float32), "fp32")))
    assert out.tolist() == [0.5, 0.25, 2.0]


def test_casts():
    a = np.array([1.0, 2049.0, 1.0 / 3.0], dtype=np.float32)
    out = _one(lambda g: g.cast(g.const("a", a, "fp32"), "fp16"))
    assert out.dtype == np.float16
    # 2049 is halfway between the fp16 neighbours 2048 and 2050: ties to even.
    assert out.tolist()[:2] == [1.0, 2048.0]
    assert out[2] == np.float16(1.0 / 3.0)
    h = np.array([0.5, -3.0], dtype=np.float16)
    out = _one(lambda g: g.cast(g.const("h", h, "fp16"), "fp32"))
    assert out.dtype == np.float32 and out.tolist() == [0.5, -3.0]
    i = np.array([16777217, -2], dtype=np.int32)
    out = _one(lambda g: g.cast(g.const("i", i, "int32"), "fp32"))
    assert out.dtype == np.float32 and out.tolist() == [16777216.0, -2.0]


def test_requant_shift_and_saturate():
    a = np.array([256, -256, 1000000, -1000000, 383, -1], dtype=np.int32)
    out = _one(lambda g: g.requant(g.const("a", a, "int32"), 2))
    assert out.dtype == np.int8
    # Arithmetic shift: -1 >> 2 is -1 (rounds toward minus infinity).
    assert out.tolist() == [64, -64, 127, -128, 95, -1]


def test_broadcast():
    a = np.array([7, 8, 9], dtype=np.int32)
    out = _one(lambda g: g.broadcast(g.const("a", a, "int32"), 2, 5))
    assert out.dtype == np.int32 and out.tolist() == [9, 9, 9, 9, 9]


def test_matvec_int8_widen_and_wrap():
    w = np.array([[1, 2, 3], [-128, -128, 0], [127, 127, 127]], dtype=np.int8)
    x = np.array([1, -1, 2], dtype=np.int8)

    def build(g):
        return g.matvec(g.const_matrix("W", w, "int8"), g.input("x", "int8", 3))

    out = _one(build, {"x": x})
    assert out.dtype == np.int32
    assert out.tolist() == [1 - 2 + 6, -128 + 128, 127 - 127 + 254]
    assert wrap_int32([I32_MAX + 1, -(2 ** 31) - 1]).tolist() == [I32_MIN, I32_MAX]  # not-a-parameter: test value


def test_matvec_fp16_ascending_order_single_rounding():
    # In float64, 2**30 + 1 - 2**30 is exactly 1, while a float32 running sum would lose the 1.
    w = np.array([[1.0, 1.0, 1.0]], dtype=np.float16)
    x = np.array([2.0 ** 15, 2.0 ** -10, -(2.0 ** 15)], dtype=np.float16)  # not-a-parameter: test values

    def build(g):
        return g.matvec(g.const_matrix("W", w, "fp16"), g.input("x", "fp16", 3))

    out = _one(build, {"x": x})
    assert out.dtype == np.float32
    assert out.tolist() == [2.0 ** -10]  # not-a-parameter: test value
    assert matvec_fp16(w, x).tolist() == [2.0 ** -10]  # not-a-parameter: test value


def test_matvec_computed_row_and_chain():
    g = Graph("chain", lanes=16)  # not-a-parameter: test size
    x = g.input("x", "fp16", 2)
    row = g.cast(g.const("r", np.array([2.0, 3.0], np.float32), "fp32"), "fp16")
    m = g.matrix("M", [row, x])
    y = g.matvec(m, x)                   # [2*x0 + 3*x1, x0^2 + x1^2]
    y16 = g.cast(y, "fp16")
    z = g.matvec(g.const_matrix("W", np.array([[1.0, -1.0]]), "fp16"), y16)
    g.output("y", y)
    g.output("z", z)
    out = evaluate(g, {"x": np.array([1.0, 2.0], dtype=np.float16)})
    assert out["y"].tolist() == [8.0, 5.0]
    assert out["z"].tolist() == [3.0]


def test_input_shape_checked():
    g = Graph("t", lanes=16)  # not-a-parameter: test size
    g.output("o", g.relu(g.input("x", "int32", 3)))
    with pytest.raises(GraphError):
        evaluate(g, {"x": np.zeros(4, np.int32)})
    with pytest.raises(GraphError):
        evaluate(g, {})
