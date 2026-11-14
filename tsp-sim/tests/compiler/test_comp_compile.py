"""Whole-compiler tests: structural self-check on many graphs and latencies, Program
fields, determinism, data independence, CompileError on search limits and self-conflicts."""
import dataclasses
import json
import os
import pathlib
import subprocess
import sys
import time

import numpy as np
import pytest

from comp_graphs import m1_graph, m2_graph, m3_graph
from comp_selfcheck import check_program
from tsp.compiler import CompileError, compile
from tsp.config import ChipConfig, OpTiming
from tsp.graph import Graph
from tsp.isa import DType

TOY = ChipConfig.toy()
ROOT = pathlib.Path(__file__).resolve().parents[2]

SLOW = TOY.with_timing(READ=OpTiming(1, 3), WRITE=OpTiming(2, 2), VARITH=OpTiming(1, 2), VTRANS=OpTiming(2, 4),
                       IW=OpTiming(1, 2), MATVEC=OpTiming(2, 5), SXM=OpTiming(1, 2))
SKEWED = TOY.with_timing(READ=OpTiming(3, 1), WRITE=OpTiming(0, 3), VARITH=OpTiming(2, 1), VTRANS=OpTiming(0, 1),
                         IW=OpTiming(4, 1), MATVEC=OpTiming(0, 1), SXM=OpTiming(5, 1))


def fan_graph():
    g = Graph("fan")
    a = g.vector("a", DType.F32, 40)
    r = g.rsqrt(a)
    e = g.exp(a)
    g.output("y", g.mul(e, g.add(e, g.mul(r, r))))
    g.output("s", g.tanh(a))
    return g


def shift_graph():
    g = Graph("sh")
    a = g.vector("a", DType.I32, 20)
    b = g.vector("b", DType.I32, 20)
    g.output("y", g.add(g.shift(g.relu(a), 3), g.shift(b, 1)))
    return g


def wide_graph():
    g = Graph("wide")
    a, b = g.vector("a", DType.I32, TOY.lanes * 6), g.vector("b", DType.I32, TOY.lanes * 6)
    c = g.vector("c", DType.I8, TOY.lanes * 6)
    g.output("y", g.mul(g.relu(g.add(a, b)), g.cast(c, DType.I32)))
    return g


GRAPHS = {"m1": lambda: m1_graph()[0], "m2": lambda: m2_graph()[0], "m3": lambda: m3_graph()[0],
          "fan": fan_graph, "shift": shift_graph, "wide": wide_graph}


@pytest.mark.parametrize("cfg", [TOY, SLOW, SKEWED], ids=["toy", "slow", "skewed"])
@pytest.mark.parametrize("name", list(GRAPHS))
def test_structural_self_check(name, cfg):
    p = compile(GRAPHS[name](), cfg)
    assert check_program(p, cfg) == []


def test_paper_m1_320_compiles_fast_and_checks():
    cfg = ChipConfig.paper()
    g, _ = m1_graph(320, 320)
    t = time.perf_counter()
    p = compile(g, cfg)
    assert time.perf_counter() - t < 10
    assert p.tile_len == 320 and check_program(p, cfg) == []
    (rec,) = p.report
    assert len(rec["install_waves"]) == 320 // cfg.iw_max_streams


def test_program_fields():
    g, _ = m3_graph()
    p = compile(g, TOY)
    assert p.name == "m3" and p.config_name == "toy" and p.config_fingerprint == TOY.fingerprint()
    assert p.tile_len == TOY.lanes // 2
    assert list(p.queues) == TOY.unit_names()
    assert all(p.queues[u] == [] for u in TOY.unit_names() if u.endswith(".1") and u.startswith("MXM"))
    assert set(p.constants) == set(g.constants)
    for k, v in g.constants.items():
        assert np.array_equal(p.constants[k], v) and p.constants[k] is not v
    leaves = [n.name for n in g.nodes if n.kind == "vector"] + list(g.matrices)
    assert list(p.inputs) == leaves
    assert p.inputs["x"].tiles[0].tag == "x.t0"
    assert p.inputs["W1"].tiles[16].tag == "W1.o1.c0" and p.inputs["W1"].tiles[16].index == (1, 0, 0)
    assert p.inputs["W2"].tiles[20].tag == "W2.o0.c20" and p.inputs["W2"].tiles[20].index == (0, 1, 4)
    assert list(p.outputs) == ["logits", "k", "v"]
    assert all(o.kind == "vector" for o in p.outputs.values())
    assert len(p.outputs["logits"].tiles) == 2
    json.dumps(p.report)
    for rec in p.report:
        assert rec["ideal_anchor"] <= rec["anchor"]
        assert set(rec["rejected"]) >= {"alus", "slices", "streams", "anchors"}


def test_determinism_in_process():
    for name, make in GRAPHS.items():
        assert compile(make(), TOY).queues == compile(make(), TOY).queues, name


def test_determinism_across_processes():
    code = ("import sys; sys.path.insert(0, 'tests/compiler');"
            "from comp_graphs import m3_graph; from tsp.compiler import compile; from tsp.config import ChipConfig;"
            "print(compile(m3_graph()[0], ChipConfig.toy()).listing())")
    outs = []
    for seed in ("0", "12345"):
        env = dict(os.environ, PYTHONHASHSEED=seed, PYTHONPATH=str(ROOT))
        outs.append(subprocess.run([sys.executable, "-c", code], cwd=ROOT, env=env,
                                   capture_output=True, text=True, check=True).stdout)
    assert outs[0] == outs[1] and len(outs[0]) > 1000


def test_data_independence():
    """Same shapes, different constant values -> equal queues."""
    assert compile(m1_graph(seed=1)[0], TOY).queues == compile(m1_graph(seed=99)[0], TOY).queues
    assert compile(m2_graph(seed=2)[0], TOY).queues == compile(m2_graph(seed=7)[0], TOY).queues
    assert compile(m3_graph(seed=3)[0], TOY).queues == compile(m3_graph(seed=8)[0], TOY).queues


def test_search_bound_is_a_compile_error():
    cfg = dataclasses.replace(TOY, max_schedule_cycles=30)
    with pytest.raises(CompileError, match="chain .*max_schedule_cycles.*last conflict"):
        compile(m2_graph()[0], cfg)


def test_self_conflict_is_detected_before_searching():
    # With 4 streams per direction, add(a, b) needs two F32 groups flowing East on
    # the same diagonals in the same cycles: impossible at every anchor.
    cfg = dataclasses.replace(TOY, streams_per_dir=4, iw_max_streams=4, max_schedule_cycles=10 ** 9)
    g = Graph("tight")
    g.output("y", g.add(g.vector("a", DType.F32, 8), g.vector("b", DType.F32, 8)))
    t = time.perf_counter()
    with pytest.raises(CompileError, match="conflicts with itself"):
        compile(g, cfg)
    assert time.perf_counter() - t < 5


def test_parking_over_capacity_is_a_compile_error():
    cfg = dataclasses.replace(TOY, words_per_bank=1)
    g = Graph("deep")
    v = g.vector("a", DType.I32, 8)
    outs = [g.relu(v) for _ in range(8)]          # 7 parked I32 values = 28 planes > 16 West slices x 1 word
    acc = outs[0]
    for o in outs[1:]:
        acc = g.add(acc, o)
    g.output("y", acc)
    with pytest.raises(CompileError, match="bank 1 full"):
        compile(g, cfg)
