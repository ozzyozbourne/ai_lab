"""SXM shift / permute / distribute on streams (plan.md 2.9)."""
import numpy as np
import pytest

from hw_testlib import TOY, Prog, load_value, mem_slices, sref
from tsp import numerics
from tsp.isa import DType, Distribute, Permute, Shift, plane_tags, to_bytes

TS = 25


def run_sxm(make, a, dtype, side="W"):
    """Operand from MEM_{side}0.. flowing outward to the SXM; result inward, parked in MEM_{side}15..12."""
    cfg = TOY
    unit_slice = f"SXM_{side}"
    out_dir = "E" if side == "W" else "W"
    n = dtype.nbytes
    p = Prog(cfg)
    src = mem_slices(cfg, side, range(n))
    ta = p.value(src, 0, 0, a, dtype, "a")
    pos = cfg.pos(unit_slice)
    p.read_value_to(src, 0, 0, side, 0, ta, TS, pos)
    tr = plane_tags("s", dtype)
    instr = make(sref(side, 0, ta), sref(out_dir, 4, tr))
    unit = f"{unit_slice}.{ {Shift: 'shift', Permute: 'permute', Distribute: 'distribute'}[type(instr)] }"
    p.sample_at(unit, TS, instr)
    dst = mem_slices(cfg, side, range(15, 15 - n, -1))
    p.write_value_from(dst, 1, 0, out_dir, 4, tr, TS + cfg.timing["SXM"].d_func, pos)
    trace, mem = p.run()
    return load_value(mem, dst, 1, 0, dtype), trace


RNG = np.random.default_rng(7)
L = TOY.lanes
I8V = RNG.integers(-128, 128, L).astype(np.int8)
I32V = RNG.integers(-2**31, 2**31, L).astype(np.int32)


@pytest.mark.parametrize("n", [0, 3, -2, L - 1, L + 4])
@pytest.mark.parametrize("dtype,v", [(DType.I8, I8V), (DType.I32, I32V)])
def test_shift(n, dtype, v):
    got, _ = run_sxm(lambda a, o: Shift(n, a, o), v, dtype)
    expect = np.array([v[l - n] if 0 <= l - n < L else 0 for l in range(L)], dtype=dtype.np)
    assert np.array_equal(got, expect)
    assert np.array_equal(got, numerics.shift_lanes(v, n))


def test_shift_east_side():
    got, trace = run_sxm(lambda a, o: Shift(5, a, o), I32V, DType.I32, side="E")
    assert np.array_equal(got, numerics.shift_lanes(I32V, 5))
    assert {e.pos for e in trace.by_kind("drive") if e.unit.startswith("SXM")} == {TOY.pos("SXM_E")}


@pytest.mark.parametrize("dtype,v", [(DType.I8, I8V), (DType.I32, I32V)])
def test_permute(dtype, v):
    perm = tuple(int(i) for i in RNG.permutation(L))
    got, _ = run_sxm(lambda a, o: Permute(perm, a, o), v, dtype)
    assert np.array_equal(got, v[list(perm)])


@pytest.mark.parametrize("dtype,v", [(DType.I8, I8V), (DType.I32, I32V)])
def test_distribute(dtype, v):
    lps = TOY.lanes_per_superlane
    m = tuple([3, -1, 0, 15, 15, -1] + list(range(lps - 6)))
    got, _ = run_sxm(lambda a, o: Distribute(m, a, o), v, dtype)
    expect = np.zeros(L, dtype=dtype.np)
    for j in range(TOY.superlanes):
        for i in range(lps):
            if m[i] >= 0:
                expect[lps * j + i] = v[lps * j + m[i]]
    assert np.array_equal(got, expect)


def test_sxm_is_bytewise_on_each_stream():
    """A shift of an I32 group is the same shift on each of its four byte planes."""
    v = I32V
    got, _ = run_sxm(lambda a, o: Shift(2, a, o), v, DType.I32)
    planes = to_bytes(v, DType.I32, L)
    assert np.array_equal(to_bytes(got, DType.I32, L), np.stack([numerics.shift_lanes(p, 2) for p in planes]))
