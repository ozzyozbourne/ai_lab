"""VXM, MXM and SXM arithmetic, tested directly on arrays (no queues)."""

import numpy as np
import pytest

from tsp import isa, params
from tsp.errors import ProgramError
from tsp.hw import mxm, sxm, vxm

LANES = 16
N = 12
R = isa.StreamRef("E", 0)


def rand(dtype, seed, positive=False, small=False):
    rng = np.random.default_rng(seed)
    if dtype == "int32":
        return rng.integers(-2**31, 2**31, LANES, dtype=np.int64).astype(np.int32)
    if dtype == "fp16":
        return (rng.standard_normal(LANES) * 100).astype(np.float16)
    x = rng.standard_normal(LANES) * (3 if small else 1e3)
    if positive:
        x = np.abs(x) + 0.01
    return x.astype(np.float32)


def wrap32(x):
    x = np.asarray(x, dtype=object)
    return np.array([((int(v) + 2**31) % 2**32) - 2**31 for v in x], dtype=np.int32)


def same_bits(a, b):
    a, b = np.asarray(a), np.asarray(b)
    return a.dtype == b.dtype and a.tobytes() == b.tobytes()


def run_vxm(op, dtype, a, b=None, out_dtype="", imm=0, n=N):
    instr = isa.Vxm(op, dtype, R, R if b is not None else None, R, n, out_dtype=out_dtype, imm=imm)
    ops = [a] if b is None else [a, b]
    return vxm.compute(instr, ops, LANES)


def ref_on_lanes(result_lanes, dtype, n=N):
    out = np.zeros(LANES, dtype=isa.np_dtype(dtype))
    out[:n] = result_lanes[:n]
    return out


BINARY_CASES = [(op, dt) for op in ("add", "sub", "mul") for dt in ("int32", "fp32")]


@pytest.mark.parametrize("op,dtype", BINARY_CASES)
def test_vxm_binary_ops_match_numpy(op, dtype):
    a, b = rand(dtype, 1), rand(dtype, 2)
    got = run_vxm(op, dtype, a, b)
    if dtype == "int32":
        a64, b64 = a.astype(np.int64), b.astype(np.int64)
        exact = {"add": a64 + b64, "sub": a64 - b64, "mul": a64 * b64}[op]
        want = ref_on_lanes(wrap32(exact), dtype)
    else:
        want = ref_on_lanes({"add": a + b, "sub": a - b, "mul": a * b}[op], dtype)
    assert same_bits(got, want)


@pytest.mark.parametrize("dtype", ["int32", "fp32"])
def test_vxm_neg_and_relu(dtype):
    a = rand(dtype, 3)
    a[0] = np.iinfo(np.int32).min if dtype == "int32" else a[0]
    got_neg = run_vxm("neg", dtype, a)
    want_neg = wrap32(-a.astype(np.int64)) if dtype == "int32" else -a
    assert same_bits(got_neg, ref_on_lanes(want_neg, dtype))
    got_relu = run_vxm("relu", dtype, a)
    assert same_bits(got_relu, ref_on_lanes(np.where(a > 0, a, 0).astype(a.dtype), dtype))


def test_vxm_relu_negative_zero_gives_positive_zero():
    a = np.zeros(LANES, dtype=np.float32)
    a[0] = -0.0
    got = run_vxm("relu", "fp32", a)
    assert not np.signbit(got[0])


@pytest.mark.parametrize("op", ["tanh", "exp", "rsqrt"])
def test_vxm_transcendentals_fp32(op):
    a = rand("fp32", 4, positive=(op == "rsqrt"), small=True)
    got = run_vxm(op, "fp32", a)
    f = {"tanh": np.tanh, "exp": np.exp, "rsqrt": lambda x: np.float32(1) / np.sqrt(x)}[op]
    want = ref_on_lanes(f(a), "fp32")
    assert same_bits(got, want)


def test_vxm_transcendental_padding_has_no_inf():
    # rsqrt of the zero padding would be inf; lanes >= n must stay zero (B19)
    a = np.zeros(LANES, dtype=np.float32)
    a[:N] = 4.0
    got = run_vxm("rsqrt", "fp32", a)
    assert np.all(got[:N] == np.float32(0.5)) and np.all(got[N:] == 0)


@pytest.mark.parametrize("src,dst", [("fp32", "fp16"), ("fp16", "fp32"), ("int32", "fp32")])
def test_vxm_cast(src, dst):
    a = rand(src, 5)
    if src == "int32":
        a = (a // 1000).astype(np.int32)
    got = run_vxm("cast", src, a, out_dtype=dst)
    assert same_bits(got, ref_on_lanes(a.astype(isa.np_dtype(dst)), dst))


def test_vxm_cast_fp32_to_fp16_rounds_to_nearest_even():
    a = np.zeros(LANES, dtype=np.float32)
    a[0] = 1 + 2**-11          # halfway between 1 and the next fp16; ties to even -> 1
    a[1] = 1 + 3 * 2**-11      # halfway; ties to even -> 1 + 2**-9
    got = run_vxm("cast", "fp32", a, out_dtype="fp16")
    assert got[0] == np.float16(1) and got[1] == np.float16(1 + 2**-9)


@pytest.mark.parametrize("imm", [0, 3, 8])
def test_vxm_requant_shift_and_saturate(imm):
    a = np.array([0, 1, -1, 127, 128, -128, -129, 1000, -1000, 2**20, -2**20, 255, 7, -7, 5, 5],
                 dtype=np.int32)
    got = run_vxm("requant", "int32", a, out_dtype="int8", imm=imm)
    shifted = np.array([int(v) >> imm for v in a])
    want = ref_on_lanes(np.clip(shifted, params.INT8_MIN, params.INT8_MAX).astype(np.int8), "int8")
    assert same_bits(got, want)


def test_vxm_zero_padding_ignores_junk_lanes():
    a = np.arange(LANES, dtype=np.int32) + 1
    b = np.arange(LANES, dtype=np.int32) + 100
    got = run_vxm("add", "int32", a, b, n=5)
    assert got[:5].tolist() == (a[:5] + b[:5]).tolist()
    assert np.all(got[5:] == 0)


@pytest.mark.parametrize("op,dtype,out", [
    ("add", "int8", ""), ("tanh", "int32", ""), ("cast", "fp16", "int32"), ("requant", "fp32", "int8"),
    ("mask", "int32", ""),
])
def test_vxm_illegal_combinations(op, dtype, out):
    with pytest.raises(ProgramError):
        vxm.result_dtype(isa.Vxm(op, dtype, R, None, R, N, out_dtype=out))


# --- MXM ------------------------------------------------------------------------
def test_mxm_int8_matches_int64_reference():
    rng = np.random.default_rng(7)
    p = mxm.MxmPlane(LANES, params.IW_MAX_STREAMS)
    W = rng.integers(-128, 128, (LANES, LANES)).astype(np.int8)
    x = rng.integers(-128, 128, LANES).astype(np.int8)
    p.install("int8", [(r, W[r]) for r in range(LANES)])
    got = p.abc("int8", x, LANES)
    want = (W.astype(np.int64) @ x.astype(np.int64)).astype(np.int32)
    assert got.dtype == np.int32 and got.tolist() == want.tolist()


def test_mxm_abc_row_count_zeroes_rows_beyond_n_rows():
    p = mxm.MxmPlane(LANES, params.IW_MAX_STREAMS)
    ones = np.ones(LANES, dtype=np.int8)
    p.install("int8", [(r, ones) for r in range(LANES)])
    got = p.abc("int8", ones, 5)
    assert got[:5].tolist() == [LANES] * 5 and np.all(got[5:] == 0)


def test_mxm_weights_zero_at_reset():
    p = mxm.MxmPlane(LANES, params.IW_MAX_STREAMS)
    assert np.all(p.abc("int8", np.ones(LANES, dtype=np.int8), LANES) == 0)


def test_mxm_fp16_ascending_float64_sum_single_rounding():
    p = mxm.MxmPlane(LANES, params.IW_MAX_STREAMS)
    row = np.full(LANES, 0.25, dtype=np.float16)
    row[0] = 2048
    x = np.ones(LANES, dtype=np.float16)
    x[0] = 2048
    p.install("fp16", [(0, row)])
    got = p.abc("fp16", x, 1)
    exact = 2048.0 * 2048.0 + 0.25 * (LANES - 1)
    assert got.dtype == np.float32
    assert got[0] == np.float32(exact)
    # a float32 running sum would lose every 0.25 (ulp of 2**22 is 0.5)
    acc32 = np.float32(0)
    for c in range(LANES):
        acc32 = np.float32(acc32 + np.float32(row[c]) * np.float32(x[c]))
    assert got[0] != acc32


def test_mxm_fp16_random_matches_explicit_loop():
    rng = np.random.default_rng(11)
    W = rng.standard_normal((LANES, LANES)).astype(np.float16)
    x = rng.standard_normal(LANES).astype(np.float16)
    p = mxm.MxmPlane(LANES, params.IW_MAX_STREAMS)
    p.install("fp16", [(r, W[r]) for r in range(LANES)])
    got = p.abc("fp16", x, LANES)
    want = np.zeros(LANES, dtype=np.float32)
    for r in range(LANES):
        acc = 0.0
        for c in range(LANES):
            acc += float(W[r, c]) * float(x[c])
        want[r] = np.float32(acc)
    assert same_bits(got, want)


def test_mxm_iw_stream_limit():
    p = mxm.MxmPlane(LANES, params.IW_MAX_STREAMS)
    wr = isa.StreamRef("W", 0)
    p.check_iw(isa.Iw("int8", tuple((r, wr) for r in range(params.IW_MAX_STREAMS))))
    p.check_iw(isa.Iw("fp16", tuple((r, wr) for r in range(params.IW_MAX_STREAMS // 2))))
    with pytest.raises(ProgramError):
        p.check_iw(isa.Iw("int8", tuple((r, wr) for r in range(params.IW_MAX_STREAMS + 1))))
    with pytest.raises(ProgramError):
        p.check_iw(isa.Iw("fp16", tuple((r, wr) for r in range(params.IW_MAX_STREAMS // 2 + 1))))
    with pytest.raises(ProgramError):
        p.check_iw(isa.Iw("int32", ((0, wr),)))


def test_mxm_dtype_mismatch_on_used_row():
    p = mxm.MxmPlane(LANES, params.IW_MAX_STREAMS)
    p.install("fp16", [(0, np.ones(LANES, dtype=np.float16))])
    with pytest.raises(ProgramError):
        p.abc("int8", np.ones(LANES, dtype=np.int8), 1)


# --- SXM ------------------------------------------------------------------------
def sxm_apply(instr, values, dtype, lanes=LANES, lps=LANES):
    planes = isa.to_planes(values, dtype)
    return isa.from_planes(sxm.compute(instr, planes, lanes, lps), dtype)


def test_sxm_distribute_broadcast_and_minus_one():
    v = (np.arange(LANES, dtype=np.int32) - 5) * 100000
    m = tuple([3] * 10 + [-1] * 6)
    got = sxm_apply(isa.Distribute(4, R, R, m, 8), v, "int32")
    assert got[:8].tolist() == [int(v[3])] * 8 and np.all(got[8:] == 0)


def test_sxm_distribute_per_superlane():
    lanes, lps = 8, 4
    v = np.arange(lanes, dtype=np.int8) + 1
    got = sxm_apply(isa.Distribute(1, R, R, (1, 0, -1, 3), lanes), v, "int8", lanes, lps)
    assert got.tolist() == [2, 1, 0, 4, 6, 5, 0, 8]


def test_sxm_permute():
    v = np.arange(LANES, dtype=np.float32) * 1.5
    m = tuple(reversed(range(LANES)))
    got = sxm_apply(isa.Permute(4, R, R, m, LANES), v, "fp32")
    assert got.tolist() == v[::-1].tolist()
    got_n = sxm_apply(isa.Permute(4, R, R, m, 3), v, "fp32")
    assert got_n[:3].tolist() == v[::-1][:3].tolist() and np.all(got_n[3:] == 0)
    with pytest.raises(ProgramError):
        sxm_apply(isa.Permute(4, R, R, (0,) * LANES, LANES), v, "fp32")


@pytest.mark.parametrize("shift", [0, 3, -2])
def test_sxm_shift_zero_fill(shift):
    v = np.arange(LANES, dtype=np.float16) + 1
    got = sxm_apply(isa.Shift(2, R, R, shift, LANES), v, "fp16")
    want = [float(v[i - shift]) if 0 <= i - shift < LANES else 0.0 for i in range(LANES)]
    assert got.tolist() == want
