"""Compiler stage 2 (plan 4.2): placement invariants."""

import numpy as np
import pytest

from tsp import isa
from tsp.compiler import tiling
from tsp.compiler.placement import hemi_of, interference, place
from tsp.errors import CompileError
from tsp.graph import Graph
from tsp.models import m2, m3
from tsp.params import ChipConfig

CFG = ChipConfig.toy()


def placed(g, cfg=CFG):
    chains = tiling.fuse(g)
    stored = tiling.stored_tensors(g, chains)
    return chains, stored, place(g, chains, stored, cfg)


def check_invariants(g, chains, stored, pl, cfg):
    # every stored tensor has exactly width(dtype) planes
    assert sorted(pl) == sorted(stored)
    used = []
    for tid in stored:
        planes = pl[tid]
        assert len(planes) == isa.width(g.t(tid).dtype)
        units = [u for u, _ in planes]
        assert len(set(units)) == len(units), "planes on distinct slices"
        assert len({hemi_of(u) for u in units}) == 1, "one hemisphere"
        for u, a in planes:
            assert u in cfg.units() and cfg.kind(u) == "MEM"
            assert 0 <= a < cfg.mem_words
            used.append((u, a))
    assert len(used) == len(set(used)), "an address is never shared"
    # addresses per slice are 0, 1, 2, ... (bump allocation)
    for u in cfg.units():
        addrs = sorted(a for uu, a in used if uu == u)
        assert addrs == list(range(len(addrs)))
    # interfering tensors (unless both are matrix rows) share no slice
    rows = [r for m in g.matrices for r in m.rows]
    inter = interference(chains)
    for a, others in inter.items():
        for b in others:
            if a in rows and b in rows:
                continue
            ua = {u for u, _ in pl[a]}
            ub = {u for u, _ in pl[b]}
            assert not (ua & ub)


@pytest.mark.parametrize("build", [m2.build, m3.build])
def test_invariants_on_milestones(build):
    g, _ = build()
    chains, stored, pl = placed(g)
    check_invariants(g, chains, stored, pl, CFG)


def test_matrix_row_rule():
    g = Graph("rows")
    x = g.input("x", "fp16", 4)
    A = g.const_matrix("A", np.ones((5, 4)), "fp16")     # matrix 0 -> W
    B = g.const_matrix("B", np.ones((2, 4)), "fp16")     # matrix 1 -> E
    g.output("y", g.matvec(A, x, name="y"))
    g.output("z", g.matvec(B, x, name="z"))
    _, _, pl = placed(g)
    k = CFG.mem_slices_per_hemi
    for r, row in enumerate(g.matrices[0].rows):
        expect = [f"MEM_W{(k - 1 - (2 * r + j)) % k}" for j in range(2)]
        assert [u for u, _ in pl[row]] == expect
    assert [u for u, _ in pl[g.matrices[0].rows[4]]] == ["MEM_W7", "MEM_W6"]   # wrapped round
    assert [u for u, _ in pl[g.matrices[1].rows[0]]] == ["MEM_E7", "MEM_E6"]
    assert [u for u, _ in pl[g.matrices[1].rows[1]]] == ["MEM_E5", "MEM_E4"]


def test_row_of_two_matrices_keeps_first_place():
    g = Graph("shared")
    x = g.input("x", "int8", 4)
    r0 = g.const("r0", np.ones(4), "int8")
    r1 = g.const("r1", np.ones(4), "int8")
    g.matrix("A", [r0])
    g.matrix("B", [r1, r0])
    _, _, pl = placed(g)
    assert pl[r0][0][0] == "MEM_W7"
    assert pl[r1][0][0] == "MEM_E7"


def test_other_tensors_window_order_and_interference():
    g = Graph("i")
    a = g.input("a", "int32", 4)      # id 0, even: E first
    b = g.input("b", "int32", 4)      # id 1, odd: W first
    c = g.input("c", "int32", 4)      # id 2, even: E first; interferes with a
    s = g.add(a, c, name="s")         # id 3
    g.output("s", s)
    _, _, pl = placed(g)
    assert [u for u, _ in pl[a]] == ["MEM_E0", "MEM_E1", "MEM_E2", "MEM_E3"]
    assert [u for u, _ in pl[b]] == ["MEM_W0", "MEM_W1", "MEM_W2", "MEM_W3"]
    assert [u for u, _ in pl[c]] == ["MEM_E4", "MEM_E5", "MEM_E6", "MEM_E7"]
    assert [u for u, _ in pl[s]] == ["MEM_W0", "MEM_W1", "MEM_W2", "MEM_W3"]
    assert [a_ for _, a_ in pl[s]] == [1, 1, 1, 1]


def test_impossible_placement_is_compile_error():
    cfg = ChipConfig(mem_slices_per_hemi=4)
    g = Graph("x")
    a = g.input("a", "int32", 4)
    b = g.input("b", "int32", 4)
    c = g.input("c", "int32", 4)
    # a, b, c pairwise interfere; each needs a whole 4-slice hemisphere.
    g.output("s", g.add(a, b, name="s"))
    g.output("t", g.add(b, c, name="t"))
    g.output("u", g.add(a, c, name="u"))
    with pytest.raises(CompileError):
        placed(g, cfg)


def test_memory_full_is_compile_error():
    cfg = ChipConfig(mem_words=1)
    g = Graph("full")
    a = g.input("a", "int32", 4)
    g.output("s", g.neg(a, name="s"))
    g.output("t", g.relu(a, name="t"))
    with pytest.raises(CompileError):
        placed(g, cfg)
