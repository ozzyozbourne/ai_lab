"""Compiled programs run on the simulator and agree with plain NumPy.

These tests need tsp.hw (and use tsp.validate when present); they are skipped
when those modules are missing.
"""

import numpy as np
import pytest

from tsp.compiler import compile_graph
from tsp.compiler.timetable import plan_graph
from tsp.errors import CompileError
from tsp.graph import Graph
from tsp.params import ChipConfig

hw = pytest.importorskip("tsp.hw")
CFG = ChipConfig.toy()


def run(g, inputs, config=CFG, record_cells=True):
    program = compile_graph(g, config)
    sim = hw.Simulator(program, record_cells=record_cells)
    for name, value in inputs.items():
        sim.poke(name, value)
    trace = sim.run()
    try:
        from tsp.validate import validate
    except ImportError:
        validate = None
    if validate is not None:
        errors = validate(program, trace, check_cells=record_cells)
        assert errors == [], errors[:5]
    return {name: sim.peek(name) for name in g.outputs}, trace


def i32(a):
    return (np.asarray(a, dtype=np.int64) & 0xFFFFFFFF).astype(np.uint32).view(np.int32)


def mv_int8(W, x):
    return i32(W.astype(np.int64) @ x.astype(np.int64))


def mv_fp16(W, x):
    """B6/B7: float64 products summed in ascending lane order, one rounding to fp32."""
    acc = np.zeros(W.shape[0], dtype=np.float64)
    for c in range(W.shape[1]):
        acc += W[:, c].astype(np.float64) * np.float64(x[c])
    return acc.astype(np.float32)


def requant(a, s):
    return np.clip(a.astype(np.int64) >> s, -128, 127).astype(np.int8)


def test_dense_relu_int8():
    rng = np.random.default_rng(1)
    x = rng.integers(-128, 128, 12).astype(np.int8)
    W = rng.integers(-128, 128, (8, 12)).astype(np.int8)
    b = rng.integers(-20000, 20000, 8).astype(np.int32)
    g = Graph("m1")
    tx = g.input("x", "int8", 12)
    y = g.relu(g.add(g.matvec(g.const_matrix("W", W, "int8"), tx), g.const("b", b, "int32")), name="y")
    g.output("y", y)
    out, trace = run(g, {"x": x})
    expect = np.maximum(i32(W.astype(np.int64) @ x.astype(np.int64) + b), 0)
    assert np.array_equal(out["y"], expect)
    assert trace.n_cycles > CFG.barrier_cycles


def test_two_layer_mlp_with_requant():
    rng = np.random.default_rng(2)
    x = rng.integers(-128, 128, 12).astype(np.int8)
    W1 = rng.integers(-128, 128, (16, 12)).astype(np.int8)
    b1 = rng.integers(-5000, 5000, 16).astype(np.int32)
    W2 = rng.integers(-128, 128, (8, 16)).astype(np.int8)
    b2 = rng.integers(-5000, 5000, 8).astype(np.int32)
    g = Graph("mlp")
    tx = g.input("x", "int8", 12)
    h = g.requant(g.relu(g.add(g.matvec(g.const_matrix("W1", W1, "int8"), tx), g.const("b1", b1, "int32"))), 7, name="h")
    y = g.add(g.matvec(g.const_matrix("W2", W2, "int8"), h), g.const("b2", b2, "int32"), name="y")
    g.output("y", y)
    out, _ = run(g, {"x": x})
    hh = requant(np.maximum(i32(W1.astype(np.int64) @ x.astype(np.int64) + b1), 0), 7)
    assert np.array_equal(out["y"], i32(mv_int8(W2, hh).astype(np.int64) + b2))


def float_graph():
    """mul(x, x), cast, a one-row matvec, broadcast, rsqrt, and a matrix with a computed row."""
    d = 8
    rng = np.random.default_rng(3)
    x = rng.standard_normal(d).astype(np.float32)
    K0 = rng.standard_normal((2, d)).astype(np.float16)
    g = Graph("float")
    tx = g.input("x", "fp32", d)
    sq16 = g.cast(g.mul(tx, tx, name="sq"), "fp16", name="sq16")
    mean_row = np.full((1, d), 1.0 / d, dtype=np.float16)
    ms = g.matvec(g.const_matrix("mean", mean_row, "fp16"), sq16, name="ms")
    eps = g.const("eps", np.array([1e-5], dtype=np.float32), "fp32")
    r = g.rsqrt(g.broadcast(g.add(ms, eps, name="mse"), 0, d, name="msb"), name="r")
    n = g.mul(tx, r, name="n")
    n16 = g.cast(n, "fp16", name="n16")
    K = g.matrix("K", [g.const("K0", K0[0], "fp16"), g.const("K1", K0[1], "fp16"), n16])
    s = g.matvec(K, n16, name="s")
    g.output("s", s)
    g.output("n16", n16)

    def numpy_ref():
        sq = (x * x).astype(np.float32)
        ms_ = mv_fp16(mean_row, sq.astype(np.float16))
        mse = np.float32(ms_[0] + np.float32(1e-5))
        r_ = np.full(d, np.float32(1) / np.sqrt(np.float32(mse)), dtype=np.float32)
        n_ = (x * r_).astype(np.float32)
        n16_ = n_.astype(np.float16)
        Kfull = np.vstack([K0, n16_[None, :]])
        return {"s": mv_fp16(Kfull, n16_), "n16": n16_}

    return g, {"x": x}, numpy_ref()


def test_float_graph():
    g, inputs, expect = float_graph()
    out, _ = run(g, inputs)
    for name in expect:
        assert np.array_equal(out[name], expect[name]), name


def test_op_a_a_and_restart_graph():
    g = Graph("aa")
    a = g.input("a", "int32", 5)
    c = g.const("c", np.array([3, -4, 5, 6, 7]), "int32")
    sq = g.mul(a, a, name="sq")                 # op(a, a): one read, both operands
    t1 = g.add(sq, c, name="t1")
    t2 = g.add(t1, c, name="t2")                # forces a no_fuse restart
    u = g.sub(t2, t2, name="u")                 # op(r, r) on a computed tensor
    g.output("t2", t2)
    g.output("u", u)
    assert plan_graph(g, CFG).no_fuse == [(t1, t2)]
    av = np.array([1, -2, 30000, 4, -50000], dtype=np.int32)
    out, _ = run(g, {"a": av})
    sqv = i32(av.astype(np.int64) * av)
    t2v = i32(sqv.astype(np.int64) + 2 * np.array([3, -4, 5, 6, 7]))
    assert np.array_equal(out["t2"], t2v)
    assert np.array_equal(out["u"], np.zeros(5, dtype=np.int32))


def test_several_matvecs_in_a_row():
    rng = np.random.default_rng(4)
    x = rng.integers(-128, 128, 10).astype(np.int8)
    Ws = [rng.integers(-128, 128, (r, c)).astype(np.int8) for r, c in ((9, 10), (16, 9), (4, 16), (7, 4))]
    g = Graph("chain")
    h = g.input("x", "int8", 10)
    for i, W in enumerate(Ws):
        m = g.const_matrix(f"W{i}", W, "int8")
        y = g.matvec(m, h, name=f"y{i}")
        if i + 1 < len(Ws):
            h = g.requant(y, 8, name=f"h{i}")
    g.output("y", y)
    out, _ = run(g, {"x": x})
    hv = x
    for i, W in enumerate(Ws):
        yv = mv_int8(W, hv)
        if i + 1 < len(Ws):
            hv = requant(yv, 8)
    assert np.array_equal(out["y"], yv)


def test_computed_row_used_twice_and_as_output():
    rng = np.random.default_rng(5)
    x = rng.integers(-60, 60, 6).astype(np.int8)
    W = rng.integers(-60, 60, (3, 6)).astype(np.int8)
    g = Graph("rows")
    tx = g.input("x", "int8", 6)
    acc = g.matvec(g.const_matrix("W", W, "int8"), tx, name="acc")
    acc6 = g.add(acc, acc, name="acc2")  # length 3; build a length-6 row from a second matvec
    W6 = rng.integers(-60, 60, (6, 6)).astype(np.int8)
    row = g.requant(g.matvec(g.const_matrix("W6", W6, "int8"), tx, name="z"), 4, name="row")
    M = g.matrix("M", [row, tx, row])           # computed row twice, an input as a row
    y = g.matvec(M, tx, name="y")
    g.output("y", y)
    g.output("row", row)
    g.output("acc2", acc6)
    out, _ = run(g, {"x": x})
    rowv = requant(mv_int8(W6, x), 4)
    assert np.array_equal(out["row"], rowv)
    assert np.array_equal(out["y"], mv_int8(np.vstack([rowv, x, rowv]), x))
    assert np.array_equal(out["acc2"], i32(2 * mv_int8(W, x).astype(np.int64)))


def test_m1_320_on_isca2020():
    cfg = ChipConfig.isca2020()
    rng = np.random.default_rng(6)
    n = cfg.lanes
    x = rng.integers(-128, 128, n).astype(np.int8)
    W = rng.integers(-128, 128, (n, n)).astype(np.int8)
    b = rng.integers(-20000, 20000, n).astype(np.int32)
    g = Graph("m1_320", lanes=cfg.lanes)
    tx = g.input("x", "int8", n)
    g.output("y", g.relu(g.add(g.matvec(g.const_matrix("W", W, "int8"), tx), g.const("b", b, "int32")), name="y"))
    out, trace = run(g, {"x": x}, config=cfg, record_cells=False)
    assert np.array_equal(out["y"], np.maximum(i32(W.astype(np.int64) @ x.astype(np.int64) + b), 0))


def test_vector_longer_than_the_chip_is_rejected():
    """A graph built for 320 lanes must not compile for the 16-lane toy chip."""
    big = ChipConfig.isca2020()
    toy = ChipConfig.toy()
    n = toy.lanes + 1
    g = Graph("too_long", lanes=big.lanes)
    g.output("y", g.cast(g.input("x", "fp16", n), "fp32"))
    with pytest.raises(CompileError, match="does not fit"):
        compile_graph(g, toy)
    assert compile_graph(g, big).inputs["x"].n == n


def _sized_graph(case, n, lanes):
    """A graph (built for a `lanes`-lane chip) whose only oversize dimension, if any, is n."""
    g = Graph(f"sized_{case}", lanes=lanes)
    if case == "input":
        g.output("y", g.neg(g.input("x", "int32", n)))
    elif case == "const":
        g.output("y", g.neg(g.const("c", np.arange(n), "int32")))
    elif case == "broadcast":
        g.output("y", g.broadcast(g.input("x", "int32", 2), 1, n))
    elif case in ("matrix_rows", "unused_matrix"):
        m = g.const_matrix("W", np.ones((n, 4), dtype=np.int8), "int8")
        x = g.input("x", "int8", 4)
        g.output("y", g.neg(g.matvec(m, x)) if case == "matrix_rows" else g.neg(g.cast(g.input("f", "fp16", 4), "fp32")))
    elif case == "matrix_cols":
        m = g.const_matrix("W", np.ones((4, n), dtype=np.int8), "int8")
        g.output("y", g.neg(g.matvec(m, g.input("x", "int8", n))))
    elif case == "input_rows_cols":
        m = g.matrix("W", [g.input(f"r{r}", "int8", n) for r in range(4)])
        g.output("y", g.neg(g.matvec(m, g.input("x", "int8", n))))
    return g


SIZED_CASES = ["input", "const", "broadcast", "matrix_rows", "unused_matrix", "matrix_cols", "input_rows_cols"]


@pytest.mark.parametrize("case", SIZED_CASES)
def test_length_check_boundary(case):
    """Exactly `lanes` elements (or rows) compiles; `lanes + 1` is a CompileError
    for inputs, constants, computed vectors, matrix rows and matrix columns."""
    big = ChipConfig.isca2020()
    toy = ChipConfig.toy()
    compile_graph(_sized_graph(case, toy.lanes, big.lanes), toy)
    with pytest.raises(CompileError, match="not fit the chip's 16 lanes"):
        compile_graph(_sized_graph(case, toy.lanes + 1, big.lanes), toy)
    if case != "broadcast":   # broadcast is rejected on a multi-tile chip for another reason
        compile_graph(_sized_graph(case, toy.lanes + 1, big.lanes), big)


def test_matrix_with_too_many_rows_names_the_matrix():
    g = _sized_graph("matrix_rows", ChipConfig.toy().lanes + 1, ChipConfig.isca2020().lanes)
    with pytest.raises(CompileError, match=r"^W: 17 rows do not fit"):
        compile_graph(g, ChipConfig.toy())


@pytest.mark.parametrize("key", ["m1", "m2", "m3"])
def test_milestones_against_reference(key):
    models = pytest.importorskip("tsp.models")
    reference = pytest.importorskip("tsp.reference")
    mod = getattr(models, key) if hasattr(models, key) else __import__(f"tsp.models.{key}", fromlist=["build"])
    g, inputs = mod.build()
    out, _ = run(g, inputs)
    spec = reference.evaluate(g, inputs)
    for name in g.outputs:
        assert np.array_equal(out[name], spec[name]), name


@pytest.mark.parametrize("key", ["m1", "m2", "m3"])
def test_compiled_programs_never_read_a_value_after_its_write(key):
    """Ledger B2: the simulator lets a value flow on after a MEM Write stores it,
    where one Groq slide says a write ends the stream.  Compiled programs do not
    depend on that choice: no instruction samples a value on a later cycle than
    a Write that sampled it, so their outputs are the same under either reading."""
    from tsp.models import MILESTONES, compile_and_run

    g, inputs = MILESTONES[key].build()
    _, trace, _ = compile_and_run(g, inputs)
    written_at = {}
    for d in trace.dispatches:
        if d["kind"] == "write":
            for r in d["reads"]:
                written_at.setdefault(r["vid"], d["cycle"])
    assert written_at
    late = [(d["unit"], d["cycle"]) for d in trace.dispatches for r in d["reads"]
            if r["vid"] in written_at and d["cycle"] > written_at[r["vid"]]]
    assert late == []
