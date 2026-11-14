"""Emission (plan 5.7): Nop splitting, merged MEM entries, issue cycles equal to the schedule."""
import dataclasses

from comp_graphs import m2_graph
from comp_selfcheck import check_program
from tsp.compiler import compile
from tsp.compiler.emit import emit_queues, nops
from tsp.compiler.resolve import Placed
from tsp.config import ChipConfig
from tsp.graph import Graph
from tsp.isa import DType, Issue, Nop, Read, SRef, Write, issue_cycles

TOY = ChipConfig.toy()


def test_nop_splitting():
    assert nops(0, 5) == []
    assert nops(5, 5) == [Nop(5)]
    assert nops(12, 5) == [Nop(5), Nop(5), Nop(2)]


def test_merge_read_and_write_and_recompute_cycles():
    r = Read(0, 3, SRef("E", 0, ("a#0",)))
    w = Write(1, 0, SRef("W", 1, ("b#0",)))
    placed = [Placed("MEM_W2", 9, 9, w), Placed("MEM_W2", 9, 9, r), Placed("MEM_W2", 2, 2, r)]
    q = emit_queues(placed, TOY)
    assert list(q) == TOY.unit_names()
    assert q["MEM_W2"] == [Nop(2), Issue((r,)), Nop(6), Issue((r, w))]
    assert all(q[u] == [] for u in TOY.unit_names() if u != "MEM_W2")


def test_compiled_queues_respect_nop_max_and_schedule():
    cfg = dataclasses.replace(TOY, nop_max=7)
    p = compile(m2_graph()[0], cfg)
    entries = [e for q in p.queues.values() for e in q]
    assert any(isinstance(e, Nop) and e.n == 7 for e in entries)
    assert all(1 <= e.n <= 7 for e in entries if isinstance(e, Nop))
    assert check_program(p, cfg) == []
    # the issue cycles recomputed from the queues equal those in the report
    p0 = compile(m2_graph()[0], TOY)
    a = {u: [t for t, _ in issue_cycles(q)] for u, q in p.queues.items()}
    b = {u: [t for t, _ in issue_cycles(q)] for u, q in p0.queues.items()}
    assert a == b                                     # nop_max changes the encoding, not the schedule
    reported = sorted((i["unit"], i["issue"]) for rec in p0.report for i in rec["instructions"])
    recomputed = sorted((u, t) for u, q in p0.queues.items() for t, _ in issue_cycles(q))
    assert reported == recomputed


def test_mem_entries_hold_read_and_write():
    g = Graph("wide")                 # many tiles: leaf Reads (bank 0) coincide with parking Writes (bank 1)
    a, b = g.vector("a", DType.I32, TOY.lanes * 8), g.vector("b", DType.I32, TOY.lanes * 8)
    g.output("y", g.relu(g.add(a, b)))
    p = compile(g, TOY)
    assert check_program(p, TOY) == []
    merged = 0
    for unit, q in p.queues.items():
        for e in q:
            if isinstance(e, Issue) and len(e.instrs) == 2:
                assert unit.startswith("MEM")
                assert [type(i) for i in e.instrs] == [Read, Write]
                merged += 1
    assert merged > 0
