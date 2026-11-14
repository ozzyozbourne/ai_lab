"""Unit tests of the early compiler passes: tiling, unit assignment, chains, placement."""
import numpy as np
import pytest

from comp_graphs import m1_graph, m2_graph, m3_graph
from tsp.compiler import CompileError
from tsp.compiler.assign import assign_units
from tsp.compiler.chains import form_chains, topo_order
from tsp.compiler.placement import LEAF_BANK, place_leaves
from tsp.compiler.tiling import MATVEC, tile_graph
from tsp.compiler.timetable import chain_timing
from tsp.config import ChipConfig
from tsp.graph import Graph
from tsp.isa import DType

TOY = ChipConfig.toy()


def front(graph, cfg=TOY):
    tg = tile_graph(graph, cfg)
    units = assign_units(tg, cfg)
    chains, chain_of = form_chains(tg)
    times = [chain_timing(tg, c, units, cfg) for c in chains]
    mem, marks = place_leaves(tg, chains, times, units, cfg)
    return tg, units, chains, chain_of, times, mem


def ops_of(tg, prefix):
    return [op for op in tg.ops if tg.vals[op.out].prefix.startswith(prefix)]


# ---- tiling ---------------------------------------------------------------------
def test_tile_len_and_m2_shapes():
    tg = tile_graph(m2_graph()[0], TOY)
    assert tg.tile_len == TOY.lanes
    mv1 = [op for op in tg.ops if op.kind == MATVEC and tg.node_names[op.node].startswith("n4")]
    # W1 is 40x48: 2 output tiles x 2 input tiles, k = 32 and 16
    assert [(op.tile, len(op.rows)) for op in mv1] == [(0, 32), (0, 16), (1, 32), (1, 16)]
    adds = [op for op in tg.ops if op.kind == "add" and tg.node_names[op.node].startswith("n4")]
    assert [tg.vals[a.out].prefix for a in adds] == ["n4_matvec.t0", "n4_matvec.t1"]
    # left-to-right partial sum: p0 + p1
    assert [tg.vals[v].prefix for v in adds[0].operands] == ["n4_matvec.t0.p0", "n4_matvec.t0.p1"]
    # matrix column tags and rows
    assert tg.vals[mv1[1].rows[0]].prefix == "W1.o0.c32"
    assert tg.vals[mv1[2].rows[5]].index == (1, 0, 5)
    # h has 40 elements -> 2 tiles; W2 (10x40) uses both
    mv2 = [op for op in tg.ops if op.kind == MATVEC][4:]
    assert [len(op.rows) for op in mv2] == [32, 8]


def test_f16_tile_len_and_matvec_cols():
    tg = tile_graph(m3_graph()[0], TOY)
    assert tg.tile_len == TOY.lanes // 2
    (o,) = [op for op in tg.ops if tg.node_names[op.node] == "n52_matvec_cols"] or [
        op for op in tg.ops if op.kind == MATVEC and len(op.rows) == 8]
    assert [tg.vals[r].prefix for r in o.rows[:7]] == [f"V{i}.t0" for i in range(7)]
    assert tg.vals[o.rows[7]].producer is not None          # c16(v) is computed
    # Wu is 32x16 -> two output tiles
    assert len([op for op in tg.ops if op.kind == MATVEC and tg.node_names[op.node] == tg.node_names[tg.ops[-1].node]]) == 2


def test_restrictions():
    g = Graph("mix")
    a = g.vector("a", DType.I8, 4)
    h = g.vector("h", DType.F16, 4)
    g.output("y1", g.matvec(g.matrix("A", DType.I8, 4, 4, data=np.ones((4, 4))), a))
    g.output("y2", g.matvec(g.matrix("H", DType.F16, 4, 4, data=np.ones((4, 4))), h))
    with pytest.raises(CompileError, match="mixes"):
        tile_graph(g, TOY)

    g = Graph("bigshift")
    g.output("y", g.shift(g.vector("a", DType.I32, TOY.lanes + 1), 1))
    with pytest.raises(CompileError, match="shift"):
        tile_graph(g, TOY)

    g = Graph("cols")
    x = g.vector("x", DType.I8, TOY.lanes + 1)
    cols = [g.vector(f"c{i}", DType.I8, 4) for i in range(TOY.lanes + 1)]
    g.output("y", g.matvec_cols(cols, x))
    with pytest.raises(CompileError, match="matvec_cols"):
        tile_graph(g, TOY)


def test_dead_code_is_not_tiled_but_leaves_are():
    g = Graph("dead")
    a = g.vector("a", DType.I32, 4)
    unused = g.vector("u", DType.I32, 4)
    g.relu(unused)                     # dead
    g.output("y", g.relu(a))
    tg = tile_graph(g, TOY)
    assert len(tg.ops) == 1 and tg.leaf_vectors == ["a", "u"]


# ---- unit assignment -----------------------------------------------------------------
def test_mxm_rotation_and_shift_hemisphere():
    tg = tile_graph(m2_graph()[0], TOY)
    units = assign_units(tg, TOY)
    assert [units[op.oid] for op in tg.ops if op.kind == MATVEC] == [
        "MXM_W.0", "MXM_E.0", "MXM_W.1", "MXM_E.1", "MXM_W.0", "MXM_E.0"]
    tg = tile_graph(m3_graph()[0], TOY)
    units = assign_units(tg, TOY)
    mv = [units[op.oid] for op in tg.ops if op.kind == MATVEC]
    assert set(mv) == {"MXM_W.0", "MXM_E.0"} and mv[:4] == ["MXM_W.0", "MXM_E.0"] * 2
    (sh,) = [op for op in tg.ops if op.kind == "shift"]
    prod = tg.vals[sh.operands[0]].producer
    assert units[sh.oid] == f"SXM_{TOY.hemi(units[prod])}.shift"


# ---- chains ------------------------------------------------------------------------
def test_m1_is_one_chain():
    tg, units, chains, *_ = front(m1_graph()[0])
    assert len(chains) == 1
    assert [tg.ops[o].kind for o in chains[0].ops] == ["matvec", "add", "relu"]
    assert chains[0].linked == [(False,), (True, False), (True,)]


def test_fan_out_parks_and_r_times_r_links_both_slots():
    g = Graph("fan")
    a = g.vector("a", DType.F32, 8)
    r = g.rsqrt(a, name="r")
    rr = g.mul(r, r, name="rr")            # one consumer node, both slots
    e = g.exp(a, name="e")
    s = g.add(e, rr, name="s")             # e is first operand but not linkable (2 consumers)
    t = g.mul(e, s, name="t")              # e fans out
    g.output("y", t)
    tg, units, chains, chain_of, *_ = front(g)
    by = {tg.vals[tg.ops[c.ops[-1]].out].prefix: c for c in chains}
    names = {k: [tg.vals[tg.ops[o].out].prefix for o in c.ops] for k, c in by.items()}
    assert names == {"t.t0": ["r.t0", "rr.t0", "s.t0", "t.t0"], "e.t0": ["e.t0"]}
    c = by["t.t0"]
    assert c.linked[1] == (True, True)                     # r * r
    assert c.linked[2] == (False, True)                    # joins rr, reads e from memory
    assert c.preds == [by["e.t0"].cid]
    assert [tg.vals[v].prefix for (i, v) in c.mem_reads] == ["a.t0", "e.t0", "e.t0"]


def test_both_operands_computed_and_outputs_are_parked():
    g = Graph("both")
    a = g.vector("a", DType.I32, 8)
    p = g.relu(a, name="p")
    q = g.relu(a, name="q")
    s = g.add(p, q, name="s")              # both qualify: joins the first (p)
    g.output("s", s)
    g.output("q", q)                       # q is an output: never linked... it has one consumer though
    tg, units, chains, *_ = front(g)
    names = [[tg.vals[tg.ops[o].out].prefix for o in c.ops] for c in chains]
    assert names == [["p.t0", "s.t0"], ["q.t0"]]
    assert topo_order(chains) == [1, 0]


def test_matvec_cols_columns_are_predecessors():
    tg, units, chains, chain_of, *_ = front(m3_graph()[0])
    (o,) = [op for op in tg.ops if op.kind == MATVEC and len(op.rows) == 8]
    c = chains[chain_of[o.oid]]
    col_chain = chain_of[tg.vals[o.rows[7]].producer]
    assert col_chain in c.preds and chains[col_chain].ops[-1] == tg.vals[o.rows[7]].producer


# ---- placement ---------------------------------------------------------------------------
def test_leaf_placement_rules():
    tg, units, chains, chain_of, times, mem = front(m3_graph()[0])
    S = min(TOY.mem_slices_per_hemi, TOY.iw_max_streams)
    for v in tg.vals:
        planes = mem.loc[v.vid] if v.leaf is not None else ()
        assert all(p.bank == LEAF_BANK for p in planes)
        assert len({p.slice for p in planes}) == len(planes)                 # distinct slices
        assert len({p.slice[:5] for p in planes}) <= 1                       # one hemisphere
    # install rows of one weight tile: round-robin over the S slices nearest the MXM
    for op in tg.ops:
        if op.kind != MATVEC:
            continue
        hemi = TOY.hemi(units[op.oid])
        near = sorted((f"MEM_{hemi}{i}" for i in range(TOY.mem_slices_per_hemi)),
                      key=lambda s: abs(TOY.pos(s) - TOY.pos(units[op.oid])))[:S]
        for r, v in enumerate(op.rows):
            if tg.vals[v].leaf is not None and tg.vals[v].leaf.startswith("W"):
                nb = tg.vals[v].dtype.nbytes
                assert [p.slice for p in mem.loc[v]] == [near[(r * nb + j) % S] for j in range(nb)]


def test_co_read_rule_between_leaves():
    """Many leaf operands so the cursor wraps: the operands of each add stay in disjoint slices."""
    g = Graph("coread")
    vs = [g.vector(f"v{i}", DType.I32, 8) for i in range(10)]
    acc = None
    for i in range(0, 10, 2):
        s = g.add(vs[i], vs[i + 1])
        acc = s if acc is None else g.mul(acc, s)
    g.output("y", acc)
    tg, units, chains, chain_of, times, mem = front(g)
    for op in tg.ops:
        mem_ops = [v for v in op.operands if tg.vals[v].leaf is not None]
        if len(mem_ops) == 2:
            a, b = ({p.slice for p in mem.loc[v]} for v in mem_ops)
            assert not a & b
    # 40 planes in 16 West slices: the cursor wrapped
    used = [p.slice for v in tg.vals if v.leaf for p in mem.loc[v.vid]]
    assert len(used) == 40 and len(set(used)) == TOY.mem_slices_per_hemi


def test_memory_over_capacity_is_a_compile_error():
    g = Graph("big")
    n_in = TOY.lanes * TOY.words_per_bank          # 64 words per slice cannot hold these columns
    x = g.vector("x", DType.I8, n_in)
    W = g.matrix("W", DType.I8, 4, n_in, data=np.zeros((4, n_in)))
    g.output("y", g.matvec(W, x))
    with pytest.raises(CompileError, match="full"):
        front(g)
