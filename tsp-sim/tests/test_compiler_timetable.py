"""Compiler stages 3 and 4 (plan 4.3, 4.4): binding, relative times, self-check and restart."""

import numpy as np
import pytest

from tsp.compiler import timetable
from tsp.compiler.binding import bind
from tsp.compiler.timetable import PInstr, TilePlan, plan_graph, self_check
from tsp.compiler.tiling import Step, Tile
from tsp.errors import CompileError
from tsp.graph import Graph
from tsp.params import ChipConfig

CFG = ChipConfig.toy()
P = CFG.n_positions
VXM = CFG.vxm_pos
LAT = CFG.latency


def m1_graph():
    g = Graph("m1")
    x = g.input("x", "int8", 12)
    W = g.const_matrix("W", np.ones((8, 12)), "int8")
    b = g.const("b", np.zeros(8), "int32")
    g.output("y", g.relu(g.add(g.matvec(W, x, name="Wx"), b, name="Wx_b"), name="y"))
    return g


def by_kind(plan, kind):
    return [i for i in plan.instrs if i.kind == kind]


def test_m1_relative_times_by_hand():
    g = m1_graph()
    pl = plan_graph(g, CFG)
    assert [t.kind for t in pl.tiling.tiles] == ["install", "op"]
    install, op = pl.plans
    # Install slot: Iw at 0 on MXM_W0 (position 0); row r on MEM_W(7-r) at position 2+r... read at -2-x.
    (iw,) = by_kind(install, "iw")
    assert (iw.unit, iw.x, iw.t) == ("MXM_W0", 0, 0)
    for rd in by_kind(install, "read"):
        assert rd.t == -LAT["read"] - rd.x
        assert install.values[rd.result].dir == "W"
    # Operation tile: Abc at 0; x read on MEM_E0 (position VXM+1).
    abc, add, relu = [i for i in op.instrs if i.kind in ("abc", "add", "relu")]
    assert abc.t == 0 and abc.unit == "MXM_W0"
    assert add.t == LAT["abc"] + VXM            # t_next = t_prev + d_prev + |x_next - x_prev|
    assert relu.t == add.t + LAT["add"]          # same position
    xr = [i for i in by_kind(op, "read") if g.t(i.tid).name == "x"]
    assert [(i.unit, i.t) for i in xr] == [("MEM_E0", -LAT["read"] - (VXM + 1))]
    assert op.values[xr[0].result].dir == "W"   # MXM_W operands flow west (B10)
    for rd in by_kind(op, "read"):
        if g.t(rd.tid).name == "b":
            assert rd.t == add.t - LAT["read"] - abs(VXM - rd.x)
            assert op.values[rd.result].dir == "E"
    # The matvec result flows east (inward, B10); writes of y are on its path.
    assert op.values[abc.result].dir == "E"
    for wr in by_kind(op, "write"):
        assert wr.t == relu.t + LAT["relu"] + abs(wr.x - relu.x)
        assert wr.x > VXM


def test_arrival_equation_holds_in_every_plan():
    from tsp.models import m3
    g, _ = m3.build()
    pl = plan_graph(g, CFG)
    for plan in pl.plans:
        for v in plan.values:
            for p in v.planes:
                for _, x, t in p.readers:
                    dist = x - p.x_from if v.dir == "E" else p.x_from - x
                    assert dist >= 0 and t == p.t_emit + dist


def test_result_direction_rules():
    g = Graph("d")
    a = g.input("a", "fp32", 4)
    s = g.exp(a, name="s")
    bc = g.broadcast(s, 0, 4, name="bc")
    g.output("bc", bc)
    pl = plan_graph(g, CFG)
    (op,) = pl.plans
    exp_i = next(i for i in op.instrs if i.kind == "exp")
    dist_i = next(i for i in op.instrs if i.kind == "distribute")
    # broadcast after a VXM op, operand not read from MEM: SXM_W (third rule)
    assert dist_i.unit == "SXM_W" and dist_i.x == 1
    assert op.values[exp_i.result].dir == "W"
    assert dist_i.t == exp_i.t + LAT["exp"] + (VXM - 1)
    # SXM_W sits west of all MEM: its final result flows east
    assert op.values[dist_i.result].dir == "E"


def test_broadcast_sxm_rules():
    g = Graph("b")
    a = g.input("a", "fp32", 4)            # id 0: placed in E
    g.output("p", g.broadcast(a, 1, 4, name="p"))
    x = g.input("x", "int8", 4)
    W = g.const_matrix("W", np.ones((4, 4)), "int8")   # matrix 0 -> MXM_W0
    g.output("q", g.broadcast(g.matvec(W, x, name="mv"), 0, 4, name="q"))
    pl = plan_graph(g, CFG)
    units = {g.t(i.tid).name: i.unit for plan in pl.plans for i in plan.instrs if i.kind == "distribute"}
    assert units == {"p": "SXM_E", "q": "SXM_W"}


def test_broadcast_on_many_tiles_is_compile_error():
    cfg = ChipConfig.isca2020()
    g = Graph("b", lanes=cfg.lanes)
    a = g.input("a", "fp32", 4)
    g.output("p", g.broadcast(a, 1, 4, name="p"))
    with pytest.raises(CompileError):
        plan_graph(g, cfg)


def test_matvec_goes_to_majority_hemisphere():
    g = Graph("maj")
    g.const_matrix("A", np.ones((1, 4)), "int8")          # matrix 0, rows in W
    r = [g.const(f"r{i}", np.ones(4), "int8") for i in range(3)]
    g.matrix("B", r[:2])                                  # matrix 1: r0, r1 in E
    M = g.matrix("C", [g.matrices[0].rows[0], r[0], r[1]])  # 1 row in W, 2 in E
    x = g.input("x", "int8", 4)
    g.output("y", g.matvec(M, x, name="y"))
    pl = plan_graph(g, CFG)
    assert pl.planes_of[g.outputs["y"]] == "MXM_E0"


def test_no_fuse_restart_on_constructed_graph():
    # t2 = add(t1, c) with t1 = add(x, c): fusing would read c twice in one tile
    # (duplicate tag c@i), so the self-check asks for (t1, t2) and the pipeline restarts.
    g = Graph("restart")
    x = g.input("x", "int32", 4)
    c = g.const("c", np.arange(4), "int32")
    t1 = g.add(x, c, name="t1")
    t2 = g.add(t1, c, name="t2")
    g.output("t2", t2)
    pl = plan_graph(g, CFG)
    assert pl.no_fuse == [(t1, t2)]
    assert [[g.t(s.tid).name for s in t.steps] for t in pl.tiling.tiles] == [["t1"], ["t2"]]
    # The restarted placement now stores t1.
    assert t1 in pl.placement


def test_self_check_reports_timing_clash_pair():
    # A hand-made plan: two reads on one slice at one relative cycle, by steps 0 and 2.
    tile = Tile(0, "op", steps=(Step(10, -1, (1,)), Step(11, 0, ()), Step(12, 0, (2,))))
    plan = TilePlan(0, instrs=[
        PInstr(0, "read", -3, "MEM_E0", VXM + 1, tid=1, plane=0, step=0),
        PInstr(1, "read", -3, "MEM_E0", VXM + 1, tid=2, plane=0, step=2),
    ])
    assert self_check(None, tile, plan) == (11, 12)


def test_self_check_passes_install_tiles():
    tile = Tile(0, "install", matvec=3, rows=(0,))
    assert self_check(None, tile, TilePlan(0)) is None
