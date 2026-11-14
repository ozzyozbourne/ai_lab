"""Milestone models: shapes, dtypes, ranges, determinism, seeds, M3 sanity (plan.md section 6)."""
import numpy as np
import pytest

from tsp import models
from tsp.graph import LEAF
from tsp.isa import DType
from tsp.models import Lcg
from tsp.reference import evaluate, evaluate_plain

I8, I32, F16, F32 = DType.I8, DType.I32, DType.F16, DType.F32


def leaf(g, name):
    return [n for n in g.nodes if n.kind == LEAF and n.name == name][0]


def out_node(g, name):
    return g.nodes[g.outputs[name]]


def structure(g):
    return (g.name, list(g.nodes), dict(g.matrices), dict(g.outputs),
            {k: (v.shape, v.dtype) for k, v in g.constants.items()})


def test_lcg_is_fixed():
    r = Lcg(1)
    first = [r.next_u32() for _ in range(3)]
    # state0 = 1*A + C; then state = A*state + C (mod 2**64); output = state >> 32
    a, c, m = 6364136223846793005, 1442695040888963407, 2**64
    s = (a + c) % m
    want = []
    for _ in range(3):
        s = (a * s + c) % m
        want.append(s >> 32)
    assert first == want
    v = Lcg(5).integers(-3, 3, (1000,))
    assert v.min() == -3 and v.max() == 3 and v.dtype == np.int64


def test_m1_shapes():
    g, feeds = models.m1()
    assert (leaf(g, "x").dtype, leaf(g, "x").n) == (I8, 20)
    assert g.matrices["W"].dtype == I8 and (g.matrices["W"].m, g.matrices["W"].n) == (24, 20)
    assert (leaf(g, "b").dtype, leaf(g, "b").n) == (I32, 24)
    assert list(g.outputs) == ["y"] and (out_node(g, "y").dtype, out_node(g, "y").n) == (I32, 24)
    assert g.input_names() == ["x"] and list(feeds) == ["x"]
    assert feeds["x"].dtype == np.int8 and feeds["x"].shape == (20,)
    W, b = g.constants["W"], g.constants["b"]
    assert W.min() >= -16 and W.max() <= 15 and b.min() >= -1000 and b.max() <= 1000
    assert [n.kind for n in g.nodes if n.kind != LEAF] == ["matvec", "add", "relu"]


def test_m1_paper_size():
    g, feeds = models.m1(n_in=320, n_out=320)
    assert g.constants["W"].shape == (320, 320) and feeds["x"].shape == (320,)
    assert out_node(g, "y").n == 320


def test_m2_shapes():
    g, feeds = models.m2()
    assert (leaf(g, "x").dtype, leaf(g, "x").n) == (I8, 48)
    assert g.constants["W1"].shape == (40, 48) and g.constants["W2"].shape == (10, 40)
    assert g.constants["b1"].dtype == np.int32 and g.constants["b1"].shape == (40,)
    assert g.constants["b2"].shape == (10,)
    h = [n for n in g.nodes if n.name == "h"][0]
    assert h.kind == "requant" and h.imm == 6 and (h.dtype, h.n) == (I8, 40)
    assert list(g.outputs) == ["y"] and (out_node(g, "y").dtype, out_node(g, "y").n) == (I32, 10)
    assert g.input_names() == ["x"] and feeds["x"].min() >= -128 and feeds["x"].max() <= 127


M3_NAMES = ["x16", "q", "k", "v", "s_cache", "s_self", "e", "S", "r", "a", "o", "h", "f", "y", "logits"]


def test_m3_shapes_and_names():
    g, feeds = models.m3()
    names = [n.name for n in g.nodes]
    for nm in M3_NAMES:
        assert nm in names, nm
    assert list(g.outputs) == ["logits", "k", "v"]
    assert [(out_node(g, o).dtype, out_node(g, o).n) for o in g.outputs] == [(F32, 32), (F32, 16), (F32, 16)]
    assert sorted(g.input_names()) == sorted(["x", "Kc"] + [f"V{i}" for i in range(7)])
    assert sorted(feeds) == sorted(g.input_names())
    assert feeds["x"].dtype == np.float32 and feeds["x"].shape == (16,)
    assert feeds["Kc"].dtype == np.float16 and feeds["Kc"].shape == (16, 16)
    assert not feeds["Kc"][7:].any() and feeds["Kc"][:7].any()
    assert all(feeds[f"V{i}"].dtype == np.float16 and feeds[f"V{i}"].shape == (16,) for i in range(7))
    shapes = {"Wq": (16, 16), "Wk": (16, 16), "Wv": (16, 16), "Wo": (16, 16), "W1": (32, 16),
              "W2": (16, 32), "Wu": (32, 16), "SUM0": (16, 16), "ONES": (16, 16)}
    for nm, sh in shapes.items():
        assert g.matrices[nm].dtype == F16 and g.constants[nm].shape == sh, nm
    for nm in ("Wq", "Wk", "Wv", "Wo", "W1", "W2", "Wu"):
        w = g.constants[nm].astype(np.float64)
        assert np.abs(w).max() <= 0.25 and np.array_equal(w * 256, np.round(w * 256)), nm
    assert np.array_equal(g.constants["SUM0"][0], np.ones(16)) and not g.constants["SUM0"][1:].any()
    assert (g.constants["ONES"] == 1).all()
    assert (g.constants["scale"] == np.float32(0.25)).all() and g.constants["scale"].dtype == np.float32
    mask = g.constants["mask"]
    assert (mask[:8] == 0).all() and (mask[8:] == np.float32(-1e4)).all()
    x = feeds["x"].astype(np.float64)
    assert np.abs(x).max() <= 1 and np.array_equal(x * 64, np.round(x * 64))
    s_self = [n for n in g.nodes if n.name == "s_self"][0]
    assert s_self.kind == "shift" and s_self.imm == 7
    o = [n for n in g.nodes if n.name == "o"][0]
    assert o.kind == "matvec_cols" and len(o.inputs) == 1 + 8
    # compile-time restrictions of plan 3.3: no I8 matvec next to the F16 ones
    assert all(g.matrices[n.matrix].dtype == F16 for n in g.nodes if n.kind == "matvec")


@pytest.mark.parametrize("name", ["m1", "m2", "m3"])
def test_deterministic_and_seed_changes_data_only(name):
    make = models.ALL[name]
    g1, f1 = make()
    g2, f2 = make()
    assert structure(g1) == structure(g2)
    for k in g1.constants:
        assert np.array_equal(g1.constants[k], g2.constants[k])
    for k in f1:
        assert np.array_equal(f1[k], f2[k])
    g3, f3 = make(seed=12345)
    assert structure(g3) == structure(g1)
    assert {k: v.shape for k, v in f3.items()} == {k: v.shape for k, v in f1.items()}
    changed = [k for k in g1.constants if not np.array_equal(g1.constants[k], g3.constants[k])]
    changed += [k for k in f1 if not np.array_equal(f1[k], f3[k])]
    assert changed, "a different seed must change the data"
    # the default seed is the explicit one
    g4, _ = make(seed=models.DEFAULT_SEEDS[name])
    assert all(np.array_equal(g1.constants[k], g4.constants[k]) for k in g1.constants)


def test_m3_softmax_and_ranges():
    g, feeds = models.m3()
    _, pl = evaluate_plain(g, feeds, return_all=True)
    a = pl["a"]
    assert abs(a[:8].sum() - 1.0) < 1e-12
    assert (a[:8] > 0).all() and np.abs(a[8:]).max() < 1e-300
    s = pl["s"]
    assert np.abs(s).max() <= 16                     # plan 6: scores within +-16
    _, ex = evaluate(g, feeds, 16, return_all=True)
    assert abs(float(ex["a"][:8].astype(np.float64).sum()) - 1.0) < 2e-2


@pytest.mark.parametrize("seed", [None, 7, 99])
def test_m3_outputs_finite(seed):
    g, feeds = models.m3(seed=seed)
    for res in (evaluate(g, feeds, 16), evaluate_plain(g, feeds)):
        for name, v in res.items():
            assert np.isfinite(v).all(), name
