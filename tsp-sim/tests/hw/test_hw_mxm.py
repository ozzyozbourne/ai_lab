"""MXM: weight install and MATVEC against NumPy, usability boundary, fp16 unit rule (plan.md 2.8)."""
import math

import numpy as np
import pytest

from hw_testlib import TOY, Prog, load_value, sref
from tsp.config import OpTiming
from tsp.hw import SimFault
from tsp.isa import IW, DType, MatVec, plane_tags

M = TOY.mem_slices_per_hemi
L = TOY.lanes
RNG = np.random.default_rng(42)


class Bench:
    """Weight rows come from MEM_{side}0.. (row i of an install: slices nb*i.., streams nb*i..);
    activations from MEM_{side}15 (and 14), outward stream 16; results inward on streams 0..3,
    parked in MEM_{side}15..12 bank 1."""

    def __init__(self, cfg=TOY, side="W"):
        self.cfg, self.side = cfg, side
        self.p = Prog(cfg)
        self.mpos = cfg.pos(f"MXM_{side}")
        self.din, self.dout = (side, "E" if side == "W" else "W")
        self.n_iw = 0
        self.mvs = []

    def install(self, plane, dtype, rows: dict, T, name="w", total_streams_ok=True):
        nb = dtype.nbytes
        refs = []
        for i, (r, vals) in enumerate(rows.items()):
            slices = [f"MEM_{self.side}{(nb * i + j) % M}" for j in range(nb)]
            tags = self.p.value(slices, 0, self.n_iw, vals, dtype, f"{name}.r{r}")
            self.p.read_value_to(slices, 0, self.n_iw, self.din, (nb * i) % 32, tags, T, self.mpos)
            refs.append((r, sref(self.din, (nb * i) % 32, tags)))
        self.n_iw += 1
        iw = IW(dtype, tuple(refs))
        self.p.sample_at(f"MXM_{self.side}.{plane}", T, iw)
        return iw

    def matvec(self, plane, dtype, x, k, T, expect_rows, name=None):
        name = name or f"x{len(self.mvs)}"
        nb = dtype.nbytes
        xs = [f"MEM_{self.side}{M - 1 - j}" for j in range(nb)]
        addr = 32 + len(self.mvs)
        xt = self.p.value(xs, 0, addr, x, dtype, name)
        self.p.read_value_to(xs, 0, addr, self.din, 16, xt, T, self.mpos)
        mv = MatVec(dtype, k, sref(self.din, 16, xt), sref(self.dout, 0, plane_tags(f"{name}.y", DType.F32)),
                    tuple(expect_rows))
        out_dt = mv.out_dtype
        mv = MatVec(dtype, k, mv.a, sref(self.dout, 0, plane_tags(f"{name}.y", out_dt)), mv.expect_rows)
        self.p.sample_at(f"MXM_{self.side}.{plane}", T, mv)
        ys = [f"MEM_{self.side}{M - 1 - j}" for j in range(out_dt.nbytes)]
        self.p.write_value_from(ys, 1, len(self.mvs), self.dout, 0, mv.out.tags,
                                T + self.cfg.timing["MATVEC"].d_func, self.mpos)
        self.mvs.append((ys, len(self.mvs), out_dt))
        return mv

    def run(self):
        self.trace, self.mem = self.p.run()
        return [load_value(self.mem, ys, 1, addr, dt) for ys, addr, dt in self.mvs]


def i8(shape):
    return RNG.integers(-128, 128, shape).astype(np.int8)


def f16(shape):
    return (RNG.standard_normal(shape) * 2).astype(np.float16)


def fsum_ref(x, W):
    """Independent F16 reference: exact products, correctly rounded lane sums, one rounding to F32."""
    return np.array([math.fsum(float(x[r]) * float(W[r, l]) for r in range(len(x))) for l in range(W.shape[1])],
                    dtype=np.float32)


@pytest.mark.parametrize("side", ["W", "E"])
def test_i8_matvec_full_k(side):
    W, x = i8((L, L)), i8(L)
    b = Bench(side=side)
    b.install(0, DType.I8, {r: W[r] for r in range(16)}, 20)
    b.install(0, DType.I8, {r: W[r] for r in range(16, 32)}, 21)
    b.matvec(0, DType.I8, x, L, 22, [f"w.r{r}#0" for r in range(L)])
    (y,) = b.run()
    assert y.dtype == np.int32
    assert np.array_equal(y, (x.astype(np.int64) @ W.astype(np.int64)).astype(np.int32))
    rows = b.trace.by_kind("matvec_row")
    assert [r.row for r in rows] == list(range(L)) and all(r.tag == r.expect for r in rows)
    assert len(b.trace.by_kind("iw_row")) == L
    assert all(e.tag == e.expect for e in b.trace.by_kind("sample"))


@pytest.mark.parametrize("side", ["W", "E"])
def test_f16_matvec(side):
    k = L // 2
    W, x = f16((k, L)), f16(L)
    x[k:] = 0
    b = Bench(side=side)
    b.install(0, DType.F16, {r: W[r] for r in range(8)}, 20)
    b.install(0, DType.F16, {r: W[r] for r in range(8, 16)}, 21)
    b.matvec(0, DType.F16, x, k, 22, [f"w.r{r}#0" for r in range(k)])
    (y,) = b.run()
    assert y.dtype == np.float32
    assert np.array_equal(y, fsum_ref(x[:k], W))
    assert np.allclose(y, x[:k].astype(np.float64) @ W.astype(np.float64), rtol=1e-6, atol=1e-6)


def test_matvec_uses_only_first_k_rows_and_elements():
    W, x = i8((8, L)), i8(L)
    b = Bench()
    b.install(0, DType.I8, {r: W[r] for r in range(8)}, 20)
    b.matvec(0, DType.I8, x, 5, 21, [f"w.r{r}#0" for r in range(5)])
    (y,) = b.run()
    assert np.array_equal(y, x[:5].astype(np.int64) @ W[:5].astype(np.int64))


def test_both_i8_planes_of_a_hemisphere():
    W0, W1, x = i8((4, L)), i8((4, L)), i8(L)
    b = Bench()
    b.install(0, DType.I8, {r: W0[r] for r in range(4)}, 20, name="a")
    b.install(1, DType.I8, {r: W1[r] for r in range(4)}, 21, name="b")
    b.matvec(0, DType.I8, x, 4, 22, [f"a.r{r}#0" for r in range(4)])
    b.matvec(1, DType.I8, x, 4, 23, [f"b.r{r}#0" for r in range(4)])
    y0, y1 = b.run()
    assert np.array_equal(y0, x[:4].astype(np.int64) @ W0.astype(np.int64))
    assert np.array_equal(y1, x[:4].astype(np.int64) @ W1.astype(np.int64))


def test_iw_usable_from_sample_plus_d_func():
    """Rows re-installed at sample 23 with d_func(IW) = 3: a MATVEC sampling at 25 sees the old rows, 26 the new."""
    cfg = TOY.with_timing(IW=OpTiming(0, 3))
    Wo, Wn, x = i8((4, L)), i8((4, L)), i8(L)
    b = Bench(cfg)
    b.install(0, DType.I8, {r: Wo[r] for r in range(4)}, 20, name="old")
    b.install(0, DType.I8, {r: Wn[r] for r in range(4)}, 23, name="new")
    b.matvec(0, DType.I8, x, 4, 25, [f"new.r{r}#0" for r in range(4)])
    b.matvec(0, DType.I8, x, 4, 26, [f"new.r{r}#0" for r in range(4)])
    y_early, y_late = b.run()
    assert np.array_equal(y_early, x[:4].astype(np.int64) @ Wo.astype(np.int64))
    assert np.array_equal(y_late, x[:4].astype(np.int64) @ Wn.astype(np.int64))
    rows = b.trace.by_kind("matvec_row")
    assert [(r.cycle, r.tag) for r in rows if r.row == 0] == [(25, "old.r0#0"), (26, "new.r0#0")]
    assert rows[0].expect == "new.r0#0"          # recorded mismatch, not a fault


def test_iw_same_cycle_matvec_sees_previous_rows():
    """Default d_func(IW) = 1; MATVEC skew 2 lets a MATVEC sample in the IW's own sample cycle."""
    cfg = TOY.with_timing(MATVEC=OpTiming(2, 3))
    Wo, Wn, x = i8((2, L)), i8((2, L)), i8(L)
    b = Bench(cfg)
    b.install(0, DType.I8, {r: Wo[r] for r in range(2)}, 20, name="old")
    b.install(0, DType.I8, {r: Wn[r] for r in range(2)}, 23, name="new")
    b.matvec(0, DType.I8, x, 2, 23, ["old.r0#0", "old.r1#0"])   # issued 21, samples 23
    b.matvec(0, DType.I8, x, 2, 24, ["new.r0#0", "new.r1#0"])   # issued 22, samples 24 = 23 + d_func
    y_same, y_next = b.run()
    assert np.array_equal(y_same, x[:2].astype(np.int64) @ Wo.astype(np.int64))
    assert np.array_equal(y_next, x[:2].astype(np.int64) @ Wn.astype(np.int64))
    assert all(r.tag == r.expect for r in b.trace.by_kind("matvec_row"))


def test_matvec_before_any_install_is_fault_5():
    b = Bench()
    b.install(0, DType.I8, {r: i8(L) for r in range(2)}, 20)
    b.matvec(0, DType.I8, i8(L), 2, 20 + 2, ["w.r0#0", "w.r1#0"])
    b.run()                                      # control: fine
    b = Bench(TOY.with_timing(IW=OpTiming(0, 3)))
    b.install(0, DType.I8, {r: i8(L) for r in range(2)}, 20)
    b.matvec(0, DType.I8, i8(L), 2, 22, ["w.r0#0", "w.r1#0"])   # 22 < 20 + 3
    with pytest.raises(SimFault) as e:
        b.run()
    assert e.value.code == 5 and e.value.cycle == 22 and "row 0 is not installed" in e.value.message


def test_matvec_row_not_installed_is_fault_5():
    b = Bench()
    b.install(0, DType.I8, {r: i8(L) for r in range(3)}, 20)
    b.matvec(0, DType.I8, i8(L), 4, 21, [f"w.r{r}#0" for r in range(4)])
    with pytest.raises(SimFault) as e:
        b.run()
    assert e.value.code == 5 and e.value.unit == "MXM_W.0" and "row 3" in e.value.message


def test_matvec_row_dtype_mismatch_is_fault_5():
    b = Bench()
    b.install(0, DType.F16, {0: f16(L)}, 20)
    b.matvec(0, DType.I8, i8(L), 1, 21, ["w.r0#0"])
    with pytest.raises(SimFault) as e:
        b.run()
    assert e.value.code == 5 and "f16" in e.value.message


def test_expect_rows_length_is_fault_5():
    b = Bench()
    b.install(0, DType.I8, {r: i8(L) for r in range(3)}, 20)
    b.matvec(0, DType.I8, i8(L), 3, 21, ["w.r0#0", "w.r1#0"])
    with pytest.raises(SimFault) as e:
        b.run()
    assert e.value.code == 5 and e.value.cycle == 21


# ---- fp16 unit rule (L-X9): fault 6 and the clearing rules --------------------------------
def test_f16_iw_on_plane_1_is_fault_6():
    b = Bench()
    b.install(1, DType.F16, {0: f16(L)}, 20)
    with pytest.raises(SimFault) as e:
        b.run()
    assert e.value.code == 6 and e.value.unit == "MXM_W.1" and e.value.cycle == 20


def test_f16_matvec_on_plane_1_is_fault_6():
    b = Bench()
    b.matvec(1, DType.F16, f16(L), 1, 22, ["w.r0#0"])
    with pytest.raises(SimFault) as e:
        b.run()
    assert e.value.code == 6


def test_plane_1_must_idle_while_plane_0_holds_f16():
    b = Bench()
    b.install(0, DType.F16, {0: f16(L)}, 20)        # usable (held) from 21
    b.install(1, DType.I8, {0: i8(L)}, 22)
    with pytest.raises(SimFault) as e:
        b.run()
    assert e.value.code == 6 and e.value.unit == "MXM_W.1" and e.value.cycle == 22
    assert e.value.trace.by_kind("iw_row")[0].unit == "MXM_W.0"     # partial trace up to the fault


def test_f16_iw_on_plane_0_clears_plane_1():
    def bench(with_f16):
        b = Bench()
        b.install(1, DType.I8, {r: i8(L) for r in range(2)}, 20, name="p1")
        if with_f16:
            b.install(0, DType.F16, {0: f16(L)}, 21)
        b.install(0, DType.I8, {0: i8(L)}, 23, name="p0")            # clears plane .0's F16 rows
        b.matvec(1, DType.I8, i8(L), 2, 25, ["p1.r0#0", "p1.r1#0"])
        return b
    bench(False).run()                                                # control: plane .1 keeps its rows
    with pytest.raises(SimFault) as e:
        bench(True).run()
    assert e.value.code == 5 and e.value.unit == "MXM_W.1" and "row 0 is not installed" in e.value.message


def test_i8_iw_on_plane_0_clears_its_f16_rows():
    b = Bench()
    b.install(0, DType.F16, {0: f16(L), 1: f16(L)}, 20)
    b.install(0, DType.I8, {0: i8(L)}, 21, name="q")    # commit at 22 removes F16 rows 0 and 1
    b.install(1, DType.I8, {0: i8(L)}, 23, name="p1")   # legal again: plane .0 holds no F16 row
    b.matvec(0, DType.I8, i8(L), 1, 24, ["q.r0#0"])
    b.run()
    b.matvec(0, DType.I8, i8(L), 2, 25, ["q.r0#0", "w.r1#0"])
    with pytest.raises(SimFault) as e:
        b.run()
    assert e.value.code == 5 and "row 1 is not installed" in e.value.message


# ---- direction and capacity rules (fault 8) --------------------------------------------------
@pytest.mark.parametrize("side", ["W", "E"])
def test_mxm_direction_rules(side):
    inward = "E" if side == "W" else "W"
    unit = f"MXM_{side}.0"
    cases = [
        IW(DType.I8, ((0, sref(inward, 0, "w#0")),)),                                       # row inward
        MatVec(DType.I8, 1, sref(inward, 0, "x#0"), sref(inward, 0, ("y#0",) * 4), ("w#0",)),  # a inward
        MatVec(DType.I8, 1, sref(side, 0, "x#0"), sref(side, 0, ("y#0",) * 4), ("w#0",)),     # out outward
    ]
    for instr in cases:
        p = Prog()
        p.issue(unit, 0, instr)
        with pytest.raises(SimFault) as e:
            p.run()
        assert e.value.code == 8 and e.value.cycle == 0, instr


def test_iw_stream_limit_is_fault_8():
    rows = tuple((r, sref("W", 2 * r, ("w#0", "w#1"))) for r in range(TOY.iw_max_streams // 2 + 1))
    p = Prog()
    p.issue("MXM_W.0", 0, IW(DType.F16, rows))
    with pytest.raises(SimFault) as e:
        p.run()
    assert e.value.code == 8 and "L-X3" in e.value.message


def test_matvec_k_range_is_fault_8():
    for dtype, k in [(DType.I8, L + 1), (DType.F16, L // 2 + 1), (DType.I8, 0)]:
        nb = dtype.nbytes
        p = Prog()
        p.issue("MXM_W.0", 0, MatVec(dtype, k, sref("W", 0, ("x",) * nb), sref("E", 0, ("y",) * 4), ("w",) * k))
        with pytest.raises(SimFault) as e:
            p.run()
        assert e.value.code == 8
