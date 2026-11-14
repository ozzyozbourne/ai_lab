"""Compiler stage 1 (plan 4.1): fusion, op(a, a), install slots, tile numbering."""

import numpy as np
import pytest

from tsp.compiler import tiling
from tsp.compiler.placement import place
from tsp.compiler.timetable import plan_graph
from tsp.graph import Graph
from tsp.params import ChipConfig

CFG = ChipConfig.toy()


def m1_graph(n_in=12, n_out=8):
    g = Graph("m1")
    x = g.input("x", "int8", n_in)
    W = g.const_matrix("W", np.ones((n_out, n_in)), "int8")
    b = g.const("b", np.zeros(n_out), "int32")
    y = g.relu(g.add(g.matvec(W, x, name="Wx"), b, name="Wx_b"), name="y")
    g.output("y", y)
    return g


def names(g, chain):
    return [g.t(s.tid).name for s in chain]


def test_m1_is_one_chain():
    g = m1_graph()
    chains = tiling.fuse(g)
    assert [names(g, c) for c in chains] == [["Wx", "Wx_b", "y"]]
    assert chains[0][1].spine_slot == 0
    b = next(t.id for t in g.tensors if t.name == "b")
    x = next(t.id for t in g.tensors if t.name == "x")
    assert chains[0][0].mem_operands == (x,)
    assert chains[0][1].mem_operands == (b,)
    assert chains[0][2].mem_operands == ()


def test_uses_counted_per_slot_and_row():
    g = Graph("u")
    a = g.input("a", "int32", 4)
    r = g.add(a, a, name="r")
    s = g.mul(r, r, name="s")        # r used twice: never fused
    g.output("s", s)
    uses = tiling.count_uses(g)
    assert uses[a] == [("op", r, 0), ("op", r, 1)]
    assert uses[r] == [("op", s, 0), ("op", s, 1)]
    chains = tiling.fuse(g)
    assert [names(g, c) for c in chains] == [["r"], ["s"]]
    # op(a, a): read once, both operand slots name it
    assert chains[0][0].mem_operands == (a,)
    assert chains[1][0].mem_operands == (r,)


def test_matrix_row_use_prevents_fusion():
    g = Graph("row")
    a = g.input("a", "fp32", 4)
    h = g.cast(g.neg(a, name="na"), "fp16", name="h")   # neg fuses into cast
    M = g.matrix("M", [h])
    x = g.input("x", "fp16", 4)
    y = g.matvec(M, x, name="y")
    z = g.relu(y, name="z")
    g.output("z", z)
    chains = tiling.fuse(g)
    # h is a matrix row, so it ends its tile; the matvec starts a new one.
    assert [names(g, c) for c in chains] == [["na", "h"], ["y", "z"]]


def test_outputs_and_multi_use_end_a_tile_and_matvec_starts_one():
    g = Graph("t")
    x = g.input("x", "int8", 4)
    W = g.const_matrix("W", np.ones((4, 4)), "int8")
    y = g.matvec(W, x, name="y")
    a = g.relu(y, name="a")
    g.output("a", a)                 # output: ends the tile
    b = g.neg(a, name="b")
    h = g.requant(b, 2, name="h")
    y2 = g.matvec(W, h, name="y2")   # matvec: starts a tile
    c = g.add(y2, y2, name="c")      # y2 used twice
    g.output("c", c)
    chains = tiling.fuse(g)
    assert [names(g, ch) for ch in chains] == [["y", "a"], ["b", "h"], ["y2"], ["c"]]


def test_first_operand_fused_when_both_qualify():
    g = Graph("both")
    a = g.input("a", "int32", 4)
    p = g.neg(a, name="p")
    q = g.relu(a, name="q")
    s = g.add(p, q, name="s")
    g.output("s", s)
    chains = tiling.fuse(g)
    assert [names(g, ch) for ch in chains] == [["p", "s"], ["q"]]
    assert chains[0][1].spine_slot == 0 and chains[0][1].mem_operands == (q,)


def test_no_fuse_pairs_are_respected():
    g = Graph("nf")
    a = g.input("a", "int32", 4)
    p = g.neg(a, name="p")
    s = g.relu(p, name="s")
    g.output("s", s)
    assert len(tiling.fuse(g)) == 1
    assert [names(g, ch) for ch in tiling.fuse(g, [(p, s)])] == [["p"], ["s"]]


def test_install_slots_first_fit():
    # 12 int8 rows on 8 slices per hemisphere: rows 8..11 wrap onto slices 7..4,
    # which are taken in slot 0, so they go to slot 1.
    g = m1_graph(n_in=8, n_out=12)
    chains = tiling.fuse(g)
    pl = place(g, chains, tiling.stored_tensors(g, chains), CFG)
    slots = tiling.install_slots(g, 0, pl, CFG)
    assert slots == [tuple(range(8)), tuple(range(8, 12))]
    for slot in slots:
        units = [u for r in slot for u, _ in pl[g.matrices[0].rows[r]]]
        assert len(units) == len(set(units))


def test_install_slots_stream_limit():
    cfg = ChipConfig(mem_slices_per_hemi=40)
    g = Graph("big", lanes=cfg.lanes)
    x = g.input("x", "int8", 4)
    W = g.const_matrix("W", np.ones((16, 4)), "int8")
    g.output("y", g.matvec(W, x, name="y"))
    chains = tiling.fuse(g)
    pl = place(g, chains, tiling.stored_tensors(g, chains), cfg)
    small = ChipConfig(mem_slices_per_hemi=40, iw_max_streams=5)
    slots = tiling.install_slots(g, 0, pl, small)
    assert [len(s) for s in slots] == [5, 5, 5, 1]


def test_tile_numbering_and_deps():
    g = m1_graph(n_in=8, n_out=12)
    planned = plan_graph(g, CFG)
    tiles = planned.tiling.tiles
    assert [t.kind for t in tiles] == ["install", "install", "op"]
    assert tiles[2].deps == (0, 1)
    assert planned.tiling.slots[tiles[2].steps[0].tid] == (0, 1)


def test_stored_tensors_exclude_fused_intermediates():
    g = m1_graph()
    chains = tiling.fuse(g)
    stored = tiling.stored_tensors(g, chains)
    by_name = [g.t(t).name for t in stored]
    assert "Wx" not in by_name and "Wx_b" not in by_name
    assert "y" in by_name and "x" in by_name and "b" in by_name
