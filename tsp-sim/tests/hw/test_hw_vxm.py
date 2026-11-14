"""VXM operations on streams against tsp.numerics and plain NumPy (plan.md 2.7)."""
import math

import numpy as np
import pytest

from hw_testlib import TOY, Prog, load_value, mem_slices, sref
from tsp import numerics
from tsp.config import OpTiming
from tsp.isa import DType, VOp, plane_tags, timing_key

TS = 12   # sample cycle of the VXM operation


def run_vop(cfg, op, dtype, a, b=None, imm=0, to=None, same_operand=False, unit="VXM.3"):
    """a from MEM_W0.. flowing East, b from MEM_E0.. flowing West, result East to MEM_E0.. bank 1."""
    p = Prog(cfg)
    vxm = cfg.vxm_pos
    n = dtype.nbytes
    ta = p.value(mem_slices(cfg, "W", range(n)), 0, 0, a, dtype, "a")
    p.read_value_to(mem_slices(cfg, "W", range(n)), 0, 0, "E", 0, ta, TS, vxm)
    bref = None
    if b is not None and not same_operand:
        tb = p.value(mem_slices(cfg, "E", range(n)), 0, 0, b, dtype, "b")
        p.read_value_to(mem_slices(cfg, "E", range(n)), 0, 0, "W", 0, tb, TS, vxm)
        bref = sref("W", 0, tb)
    elif same_operand:
        bref = sref("E", 0, ta)
    instr0 = VOp(op, dtype, sref("E", 0, ta), bref, sref("E", 4, ("x",)), imm, to)
    out_dt = instr0.out_dtype
    tr = plane_tags("r", out_dt)
    instr = VOp(op, dtype, sref("E", 0, ta), bref, sref("E", 4, tr), imm, to)
    p.sample_at(unit, TS, instr)
    t_v = TS + cfg.timing[timing_key(instr)].d_func
    out_slices = mem_slices(cfg, "E", range(out_dt.nbytes))
    p.write_value_from(out_slices, 1, 0, "E", 4, tr, t_v, vxm)
    trace, mem = p.run()
    return load_value(mem, out_slices, 1, 0, out_dt), trace


RNG = np.random.default_rng(1234)
L = TOY.lanes
I32A = RNG.integers(-2**31, 2**31, L).astype(np.int32)
I32B = RNG.integers(-2**31, 2**31, L).astype(np.int32)
F32A = (RNG.standard_normal(L) * 4).astype(np.float32)
F32B = (RNG.standard_normal(L) * 4).astype(np.float32)


def _wrap(x):
    return ((x.astype(np.int64) + 2**31) % 2**32 - 2**31).astype(np.int32)


@pytest.mark.parametrize("op,plain", [
    ("ADD", lambda a, b: a.astype(np.int64) + b), ("SUB", lambda a, b: a.astype(np.int64) - b),
    ("MUL", lambda a, b: a.astype(np.int64) * b)])
def test_int32_binary(op, plain):
    got, _ = run_vop(TOY, op, DType.I32, I32A, I32B)
    assert np.array_equal(got, numerics.vop(op, DType.I32, I32A, I32B))
    assert np.array_equal(got, _wrap(plain(I32A, I32B)))


@pytest.mark.parametrize("op,plain", [
    ("ADD", np.add), ("SUB", np.subtract), ("MUL", np.multiply)])
def test_f32_binary(op, plain):
    got, _ = run_vop(TOY, op, DType.F32, F32A, F32B)
    assert got.dtype == np.float32
    assert np.array_equal(got, plain(F32A, F32B))


@pytest.mark.parametrize("dtype,a", [(DType.I32, I32A), (DType.F32, F32A)])
def test_relu(dtype, a):
    got, _ = run_vop(TOY, "RELU", dtype, a)
    assert np.array_equal(got, np.maximum(a, 0))


def test_requant():
    got, _ = run_vop(TOY, "REQUANT", DType.I32, I32A, imm=20)
    assert got.dtype == np.int8
    assert np.array_equal(got, np.clip(I32A.astype(np.int64) >> 20, -128, 127))


@pytest.mark.parametrize("src,dst,a", [
    (DType.I8, DType.I32, RNG.integers(-128, 128, L).astype(np.int8)),
    (DType.F32, DType.F16, F32A),
    (DType.F16, DType.F32, F32A.astype(np.float16))])
def test_cast(src, dst, a):
    got, _ = run_vop(TOY, "CAST", src, a, to=dst)
    assert got.dtype == dst.np
    assert np.array_equal(got, a.astype(dst.np))


@pytest.mark.parametrize("op,fn", [("EXP", math.exp), ("TANH", math.tanh), ("RSQRT", lambda v: 1 / math.sqrt(v))])
def test_transcendental(op, fn):
    a = np.abs(F32A) + np.float32(0.25)
    got, trace = run_vop(TOY, op, DType.F32, a)
    assert np.array_equal(got, numerics.vop(op, DType.F32, a))
    assert np.array_equal(got, np.array([fn(float(v)) for v in a], dtype=np.float32))
    (iss,) = [e for e in trace.by_kind("issue") if e.unit.startswith("VXM")]
    assert iss.visible_cycle == TS + TOY.timing["VTRANS"].d_func


def test_rsqrt_special_values():
    a = np.zeros(L, dtype=np.float32)
    a[1] = -1
    got, _ = run_vop(TOY, "RSQRT", DType.F32, a)
    assert np.isinf(got[0]) and np.isnan(got[1])


def test_same_stream_group_in_both_slots():
    got, trace = run_vop(TOY, "MUL", DType.F32, F32A, F32A, same_operand=True)
    assert np.array_equal(got, F32A * F32A)
    samples = [e for e in trace.by_kind("sample") if e.unit.startswith("VXM")]
    assert [(e.dir, e.stream) for e in samples] == [("E", j) for j in range(4)] * 2


def test_vxm_result_tags_and_timing():
    _, trace = run_vop(TOY, "ADD", DType.I32, I32A, I32B)
    drives = [e for e in trace.by_kind("drive") if e.unit == "VXM.3"]
    assert [(e.cycle, e.dir, e.stream, e.tag, e.issue_cycle) for e in drives] == [
        (TS + 1, "E", 4 + j, f"r#{j}", TS) for j in range(4)]
    assert all(e.tag == e.expect for e in trace.by_kind("sample"))


def test_nonzero_skew_vxm():
    cfg = TOY.with_timing(READ=OpTiming(1, 2), VARITH=OpTiming(2, 1), WRITE=OpTiming(3, 1))
    got, trace = run_vop(cfg, "SUB", DType.I32, I32A, I32B)
    assert np.array_equal(got, numerics.vop("SUB", DType.I32, I32A, I32B))
    (iss,) = [e for e in trace.by_kind("issue") if e.unit == "VXM.3"]
    assert (iss.cycle, iss.sample_cycle, iss.visible_cycle) == (TS - 2, TS, TS + 1)
    reads = [e for e in trace.by_kind("issue") if e.opcode == "READ"]
    assert all(e.sample_cycle == e.cycle + 1 and e.visible_cycle == e.cycle + 3 for e in reads)
    assert all(e.cycle == e.issue_cycle + 1 for e in trace.by_kind("mem_read"))
    assert all(e.tag == e.expect for e in trace.by_kind("sample"))
