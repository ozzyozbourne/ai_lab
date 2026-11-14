"""End to end from the compiler's side: compile, run on tsp.hw, compare bit for bit.

Expected values come from comp_graphs.evaluate (tsp.numerics kernels, plan 3.3
semantics) and, when present, from tsp.reference.evaluate. Skipped if the
hardware model is not importable.
"""
import numpy as np
import pytest

from comp_graphs import evaluate, m1_graph, m2_graph, m3_graph
from test_comp_compile import GRAPHS, SKEWED, SLOW
from tsp.compiler import compile
from tsp.config import ChipConfig

hw = pytest.importorskip("tsp.hw")
TOY = ChipConfig.toy()


def same_bits(a, b):
    a, b = np.asarray(a), np.asarray(b).astype(np.asarray(a).dtype)
    return a.shape == b.shape and np.array_equal(a.view(np.uint8), b.view(np.uint8))


def feeds_for(graph, seed=0):
    rng = np.random.default_rng(seed)
    feeds = {}
    for name in graph.input_names():
        if name in graph.matrices:
            m = graph.matrices[name]
            feeds[name] = (rng.integers(-16, 16, (m.m, m.n)) / 64).astype(m.dtype.np)
        else:
            n = next(nd for nd in graph.nodes if nd.name == name)
            if n.dtype.is_float:
                feeds[name] = (rng.integers(-64, 65, n.n) / 64).astype(n.dtype.np)
            else:
                feeds[name] = rng.integers(-100, 100, n.n).astype(n.dtype.np)
    return feeds


def run_and_compare(graph, feeds, cfg):
    p = compile(graph, cfg)
    res = hw.run_program(p, feeds, cfg)
    want = evaluate(graph, feeds, p.tile_len)
    for name in graph.outputs:
        assert same_bits(res.outputs[name], want[name]), name
    try:
        from tsp.reference import evaluate as ref_eval
    except ImportError:
        return res
    ref = ref_eval(graph, feeds, p.tile_len)
    for name in graph.outputs:
        assert same_bits(res.outputs[name], ref[name]), name
    return res


@pytest.mark.parametrize("cfg", [TOY, SLOW, SKEWED], ids=["toy", "slow", "skewed"])
@pytest.mark.parametrize("make", [m1_graph, m2_graph, m3_graph], ids=["m1", "m2", "m3"])
def test_milestone_mirrors_run_bit_exact(make, cfg):
    g, feeds = make()
    run_and_compare(g, feeds, cfg)


@pytest.mark.parametrize("name", ["fan", "shift", "wide"])
def test_small_graphs_run_bit_exact(name):
    g = GRAPHS[name]()
    run_and_compare(g, feeds_for(g), TOY)


def test_paper_m1_320():
    g, feeds = m1_graph(320, 320)
    run_and_compare(g, feeds, ChipConfig.paper())


def test_models_package():
    models = pytest.importorskip("tsp.models")
    for make in (models.m1, models.m2, models.m3):
        g, feeds = make()
        run_and_compare(g, feeds, TOY)
    g, feeds = models.m1(n_in=320, n_out=320)
    run_and_compare(g, feeds, ChipConfig.paper())


def test_validator_accepts_compiled_programs():
    validate = pytest.importorskip("tsp.validate").validate
    for make in (m1_graph, m2_graph, m3_graph):
        g, feeds = make()
        for cfg in (TOY, SKEWED):
            p = compile(g, cfg)
            res = hw.run_program(p, feeds, cfg)
            rep = validate(p, res.trace, cfg)
            assert rep.ok, rep.summary()
