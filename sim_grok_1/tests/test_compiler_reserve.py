"""Compiler stage 5 (plan 4.5): reservation table, the diagonal claim, scheduling rules."""

import itertools

import numpy as np
import pytest

from tsp.compiler.reserve import ReservationTable, path_cells
from tsp.compiler.schedule import Scheduler, priorities, schedule, tile_order
from tsp.compiler.timetable import plan_graph
from tsp.errors import CompileError
from tsp.graph import Graph
from tsp.params import ChipConfig

CFG = ChipConfig.toy()


# -- the table itself --------------------------------------------------------
def test_path_cells_follow_the_diagonal():
    assert path_cells("E", 3, 10, 6) == [(3, 10), (4, 11), (5, 12), (6, 13)]
    assert path_cells("W", 6, 10, 4) == [(6, 10), (5, 11), (4, 12)]
    assert path_cells("E", 2, 0, 2) == [(2, 0)]
    with pytest.raises(ValueError):
        path_cells("E", 5, 0, 4)


def test_units_cells_and_rollback():
    t = ReservationTable()
    t.claim_unit("MEM_E0", 5, "a")
    assert not t.unit_free("MEM_E0", 5) and t.unit_free("MEM_E0", 6) and t.unit_free("MEM_E1", 5)
    cells = path_cells("E", 0, 0, 3)
    t.claim_cells("E", 2, cells, "v")
    assert not t.cells_free("E", 2, [(1, 1)])
    assert t.cells_free("W", 2, [(1, 1)]) and t.cells_free("E", 3, [(1, 1)])
    assert t.cells_free("E", 2, [(1, 2)])          # off the diagonal
    with pytest.raises(ValueError):
        t.claim_unit("MEM_E0", 5, "b")
    t.begin()
    t.claim_unit("MEM_E0", 6, "c")
    t.claim_cells("E", 2, [(9, 9)], "w")
    t.rollback()
    assert t.unit_free("MEM_E0", 6) and t.cells_free("E", 2, [(9, 9)])
    assert not t.unit_free("MEM_E0", 5) and not t.cells_free("E", 2, [(3, 3)])
    t.set_busy_until("MXM_W0", 7)
    assert t.plane_busy_until("MXM_W0") == 7 and t.plane_busy_until("MXM_E0") is None


# -- dossier 4.6: two values in one stream and direction collide only on the
#    same diagonal with overlapping position ranges -------------------------
@pytest.mark.parametrize("dir", ["E", "W"])
def test_collision_only_on_same_diagonal_with_overlap(dir):
    n_pos = 7
    T = 8
    paths = []
    for x0 in range(n_pos):
        for x1 in range(n_pos):
            if (x1 - x0) * (1 if dir == "E" else -1) < 0:
                continue
            for t0 in range(T):
                paths.append((x0, t0, x1))
    sign = 1 if dir == "E" else -1
    checked = 0
    for (a, b) in itertools.combinations(paths, 2):
        ca = set(path_cells(dir, *a))
        cb = set(path_cells(dir, *b))
        collide = bool(ca & cb)
        # diagonal invariant: t - x eastward, t + x westward
        diag_a = a[1] - sign * a[0]
        diag_b = b[1] - sign * b[0]
        lo_a, hi_a = sorted((a[0], a[2]))
        lo_b, hi_b = sorted((b[0], b[2]))
        overlap = max(lo_a, lo_b) <= min(hi_a, hi_b)
        assert collide == (diag_a == diag_b and overlap)
        checked += 1
    assert checked > 10000


# -- scheduling rules ----------------------------------------------------------
def two_layer():
    g = Graph("mlp")
    x = g.input("x", "int8", 6)
    W1 = g.const_matrix("W1", np.ones((5, 6)), "int8")
    W2 = g.const_matrix("W2", np.ones((3, 5)), "int8")
    W3 = g.const_matrix("W3", np.ones((2, 3)), "int8")
    h1 = g.requant(g.matvec(W1, x, name="a1"), 1, name="h1")
    h2 = g.requant(g.matvec(W2, h1, name="a2"), 1, name="h2")
    g.output("y", g.matvec(W3, h2, name="y"))
    return g


def test_priority_and_order_put_install_slots_before_their_matvec():
    g = two_layer()
    pl = plan_graph(g, CFG)
    tiles = pl.tiling.tiles
    prio = priorities(pl.tiling)
    order = tile_order(g, pl.tiling)
    assert sorted(order) == list(range(len(tiles)))
    pos = {t: i for i, t in enumerate(order)}
    for t in tiles:
        for d in t.deps:
            assert pos[d] < pos[t.index]
            assert prio[d] > prio[t.index]
        if t.kind == "op" and g.t(t.steps[0].tid).op == "matvec":
            slots = pl.tiling.slots[t.steps[0].tid]
            assert order[pos[t.index] - len(slots):pos[t.index]] == list(slots)


def test_lower_bounds_and_plane_serialisation():
    g = two_layer()
    pl = plan_graph(g, CFG)
    placed = schedule(g, pl, CFG)
    tau = {}
    for p in placed:
        for ins in pl.plans[p.tile].instrs:
            tau[(p.tile, ins.key)] = (p.start + ins.t, ins, p.units[ins.key])
    writes = {(i.tid, i.plane): t for t, i, _ in tau.values() if i.kind == "write"}
    for t, ins, unit in tau.values():
        assert t >= 0
        if ins.kind == "read" and g.t(ins.tid).kind == "op":
            assert t >= writes[(ins.tid, ins.plane)] + CFG.latency["write"]
    # Per MXM plane: the Iws and Abc of one matvec never interleave with another's.
    for plane in ("MXM_W0", "MXM_E0"):
        events = sorted((t, i.kind, i.tid) for t, i, u in tau.values() if u == plane)
        last_abc = None
        for t, kind, tid in events:
            if kind == "iw" and last_abc is not None:
                assert t > last_abc
            if kind == "abc":
                iws = [tt for tt, k, mv in events if k == "iw" and mv == tid]
                assert t >= max(iws) + CFG.latency["iw"]
                last_abc = t


def test_rebind_takes_lowest_free_alu_and_recolour_lowest_stream():
    # Two independent VXM tiles that would like the same cycle.
    g = Graph("rb")
    a = g.input("a", "int32", 4)
    b = g.input("b", "int32", 4)
    g.output("p", g.neg(a, name="p"))
    g.output("q", g.neg(b, name="q"))
    pl = plan_graph(g, CFG)
    placed = schedule(g, pl, CFG)
    alus = []
    for p in placed:
        for ins in pl.plans[p.tile].instrs:
            if ins.kind == "neg":
                alus.append((p.start + ins.t, p.units[ins.key]))
    alus.sort()
    if alus[0][0] == alus[1][0]:
        assert [u for _, u in alus] == ["VXM_A0", "VXM_A1"]
    for p in placed:
        for v, base in p.bases.items():
            assert base % pl.plans[p.tile].values[v].width == 0


def test_horizon_is_compile_error():
    cfg = ChipConfig(max_schedule_cycles=3)
    g = Graph("far")
    x = g.input("x", "int8", 4)
    W = g.const_matrix("W", np.ones((4, 4)), "int8")
    g.output("y", g.matvec(W, x, name="y"))
    with pytest.raises(CompileError):
        schedule(g, plan_graph(g, cfg), cfg)


def test_scheduler_delay_when_unit_busy():
    g = Graph("delay")
    a = g.input("a", "int32", 4)
    g.output("p", g.neg(a, name="p"))
    pl = plan_graph(g, CFG)
    s = Scheduler(g, pl, CFG)
    plan = pl.plans[0]
    lb = s.lower_bound(plan)
    neg = next(i for i in plan.instrs if i.kind == "neg")
    for alu in s.alus:                       # every ALU busy on the natural cycle
        s.table.claim_unit(alu, lb + neg.t, "blocker")
    placed = s.place(plan)
    assert placed.start == lb + 1
