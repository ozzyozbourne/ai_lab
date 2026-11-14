"""A hand-written program for y = relu(W·x + b), run_program, determinism, d_skew != 0, paper scale.

Toy geometry (M = 16, P = 37): MXM_W at x = 0, MEM_Wi at 17 - i, VXM at 18, MEM_Ei at 19 + i.
Default timing: READ d_func 2, IW 1, MATVEC 3, VARITH 1, WRITE 1, every d_skew 0.

Placement (I8 W 24x20 stored by columns, I8 x[20], I32 b[24], I32 y[24]):
  column r of W (= weight row r)  MEM_W{r % 16}, bank 0, addr r // 16, tag W.o0.c{r}#0
  x                               MEM_W15, bank 1, addr 0, tag x.t0#0
  b plane j                       MEM_Ej, bank 0, addr 0, tag b.t0#j
  y plane j                       MEM_Ej, bank 1, addr 0

Hand-computed schedule (a Read issued at t drives at t + 2 at its slice; a value
driven at x reaches x' at |x - x'| cycles later):
  wave 1, IW samples at 19: row r < 16 read in MEM_Wr (x = 17 - r) at cycle r,
          drives W stream r at r + 2, reaches x = 0 at r + 2 + 17 - r = 19.
  wave 2, IW samples at 20: row 16 + j read in MEM_Wj at cycle 1 + j, on W stream 16 + j,
          drives at 3 + j at x = 17 - j, reaches x = 0 at 20.
  MATVEC  samples at 21 = 20 + d_func(IW) (the first cycle wave 2 is usable);
          x read in MEM_W15 (x = 2) at 17, drives W0 at 19, at x = 0 at 21.
          Result on E0..3 at x = 0 in cycle 24, at the VXM (18) in cycle 42.
  ADD     VXM.0 samples at 42; b plane j read in MEM_Ej (x = 19 + j) at 42 - (1 + j) - 2 = 39 - j,
          on W stream j. Result on E4..7 at 43.
  RELU    VXM.1 samples at 43 (same position, distance 0). Result on E8..11 at 44.
  WRITE   plane j in MEM_Ej (distance 1 + j) samples at 45 + j. Last activity 48 -> n_cycles 49.
"""
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import pytest

from hw_testlib import TOY, Prog, sref
from tsp.config import ChipConfig, OpTiming
from tsp.hw import RunResult, SimFault, run_program
from tsp.isa import IW, DType, Issue, MatVec, Nop, Read, VOp, Write, plane_tags
from tsp.program import MATRIX_COLS, VECTOR, PlaneLoc, Program, TensorLayout, TileLayout

N_IN, N_OUT = 20, 24


def S(d, base, tags):
    return sref(d, base, tags)


def W_row(r):
    return f"W.o0.c{r}#0"


MV = plane_tags("mv", DType.I32)
B = plane_tags("b.t0", DType.I32)
SUM = plane_tags("s", DType.I32)
Y = plane_tags("y.t0", DType.I32)


def hand_queues() -> dict:
    """The program, written as queues with the cycles computed by hand (module docstring)."""
    q = {}
    q["MEM_W0"] = [Issue((Read(0, 0, S("W", 0, W_row(0))),)),                         # 0
                   Issue((Read(0, 1, S("W", 16, W_row(16))),))]                        # 1
    for j in (1, 2, 3):
        q[f"MEM_W{j}"] = [Nop(j), Issue((Read(0, 0, S("W", j, W_row(j))),)),           # j
                          Issue((Read(0, 1, S("W", 16 + j, W_row(16 + j))),))]         # j + 1
    for r in range(4, 15):
        q[f"MEM_W{r}"] = [Nop(r), Issue((Read(0, 0, S("W", r, W_row(r))),))]           # r
    q["MEM_W15"] = [Nop(15), Issue((Read(0, 0, S("W", 15, W_row(15))),)),              # 15
                    Nop(1), Issue((Read(1, 0, S("W", 0, "x.t0#0")),))]                 # 17
    q["MXM_W.0"] = [Nop(19),
                    Issue((IW(DType.I8, tuple((r, S("W", r, W_row(r))) for r in range(16))),)),        # 19
                    Issue((IW(DType.I8, tuple((r, S("W", r, W_row(r))) for r in range(16, 20))),)),    # 20
                    Issue((MatVec(DType.I8, N_IN, S("W", 0, "x.t0#0"), S("E", 0, MV),
                                  tuple(W_row(r) for r in range(N_IN))),))]                           # 21
    for j in range(4):
        q[f"MEM_E{j}"] = [Nop(39 - j), Issue((Read(0, 0, S("W", j, B[j])),)),         # 39 - j
                          Nop(5 + 2 * j), Issue((Write(1, 0, S("E", 8 + j, Y[j])),))]  # 45 + j
    q["VXM.0"] = [Nop(42), Issue((VOp("ADD", DType.I32, S("E", 0, MV), S("W", 0, B), S("E", 4, SUM)),))]
    q["VXM.1"] = [Nop(43), Issue((VOp("RELU", DType.I32, S("E", 4, SUM), None, S("E", 8, Y)),))]
    return q


def timed_queues(cfg: ChipConfig, n_in: int) -> dict:
    """The same program for any config, with cycles derived from config.timing (for skew / paper tests)."""
    t = cfg.timing
    p = Prog(cfg)
    M, waves, n_streams = cfg.mem_slices_per_hemi, cfg.iw_max_streams, cfg.streams_per_dir
    mxm, vxm = cfg.pos("MXM_W"), cfg.vxm_pos
    far = max(abs(cfg.pos(f"MEM_W{i}") - mxm) for i in range(waves))
    T1 = far + t["READ"].d_func + t["READ"].d_skew
    n_waves = -(-n_in // waves)
    for w in range(n_waves):
        rows = range(w * waves, min(n_in, (w + 1) * waves))
        for r in rows:
            p.read_to(f"MEM_W{r % waves}", 0, w, "W", r % n_streams, W_row(r), T1 + w, mxm)
        p.sample_at("MXM_W.0", T1 + w, IW(DType.I8, tuple((r, S("W", r % n_streams, W_row(r))) for r in rows)))
    T_last = T1 + n_waves - 1
    Tm = max(T_last + t["IW"].d_func, T_last - t["IW"].d_skew + 1 + t["MATVEC"].d_skew)
    p.read_to(f"MEM_W{M - 1}", 1, 0, "W", 0, "x.t0#0", Tm, mxm)
    p.sample_at("MXM_W.0", Tm, MatVec(DType.I8, n_in, S("W", 0, "x.t0#0"), S("E", 0, MV),
                                      tuple(W_row(r) for r in range(n_in))))
    Ta = Tm + t["MATVEC"].d_func + (vxm - mxm)
    p.read_value_to([f"MEM_E{j}" for j in range(4)], 0, 0, "W", 0, B, Ta, vxm)
    p.sample_at("VXM.0", Ta, VOp("ADD", DType.I32, S("E", 0, MV), S("W", 0, B), S("E", 4, SUM)))
    Tr = Ta + t["VARITH"].d_func
    p.sample_at("VXM.1", Tr, VOp("RELU", DType.I32, S("E", 4, SUM), None, S("E", 8, Y)))
    p.write_value_from([f"MEM_E{j}" for j in range(4)], 1, 0, "E", 8, Y, Tr + t["VARITH"].d_func, vxm)
    return p.queues()


def relu_program(cfg: ChipConfig, queues: dict, W: np.ndarray, b: np.ndarray) -> Program:
    n_out, n_in = W.shape
    M, waves = cfg.mem_slices_per_hemi, cfg.iw_max_streams
    e4 = tuple(PlaneLoc(f"MEM_E{j}", 0, 0) for j in range(4))
    inputs = {
        "x": TensorLayout("x", DType.I8, (n_in,), VECTOR, (TileLayout((0,), "x.t0", (PlaneLoc(f"MEM_W{M - 1}", 1, 0),)),)),
        "b": TensorLayout("b", DType.I32, (n_out,), VECTOR, (TileLayout((0,), "b.t0", e4),)),
        "W": TensorLayout("W", DType.I8, (n_out, n_in), MATRIX_COLS, tuple(
            TileLayout((0, 0, r), f"W.o0.c{r}", (PlaneLoc(f"MEM_W{r % waves}", 0, r // waves),)) for r in range(n_in))),
    }
    outputs = {"y": TensorLayout("y", DType.I32, (n_out,), VECTOR, (TileLayout(
        (0,), "y.t0", tuple(PlaneLoc(f"MEM_E{j}", 1, 0) for j in range(4))),))}
    full = {u: queues.get(u, []) for u in cfg.unit_names()}
    return Program("relu", cfg.name, cfg.fingerprint(), cfg.lanes, full,
                   constants={"W": W, "b": b}, inputs=inputs, outputs=outputs)


def data(n_in=N_IN, n_out=N_OUT, seed=3):
    rng = np.random.default_rng(seed)
    W = rng.integers(-16, 16, (n_out, n_in)).astype(np.int8)
    b = rng.integers(-1000, 1001, n_out).astype(np.int32)
    x = rng.integers(-128, 128, n_in).astype(np.int8)
    return W, b, x


def expected(W, b, x):
    return np.maximum(W.astype(np.int64) @ x.astype(np.int64) + b, 0).astype(np.int32)


# ---- the hand-written program ------------------------------------------------------------------
def test_hand_written_relu_program():
    W, b, x = data()
    prog = relu_program(TOY, hand_queues(), W, b)
    res = run_program(prog, {"x": x}, TOY)
    assert isinstance(res, RunResult)
    assert np.array_equal(res.outputs["y"], expected(W, b, x))
    tr = res.trace
    assert tr.n_cycles == 49 and len(tr.occupancy) == len(tr.digests) == 49

    issues = {(e.unit, e.opcode, e.cycle) for e in tr.by_kind("issue")}
    for r in range(16):
        assert (f"MEM_W{r}", "READ", r) in issues
    for unit, op, c in [("MEM_W0", "READ", 1), ("MEM_W3", "READ", 4), ("MEM_W15", "READ", 17),
                        ("MXM_W.0", "IW", 19), ("MXM_W.0", "IW", 20), ("MXM_W.0", "MATVEC", 21),
                        ("MEM_E0", "READ", 39), ("MEM_E3", "READ", 36), ("VXM.0", "ADD", 42),
                        ("VXM.1", "RELU", 43), ("MEM_E0", "WRITE", 45), ("MEM_E3", "WRITE", 48)]:
        assert (unit, op, c) in issues
    assert len(tr.by_kind("issue")) == 20 + 1 + 3 + 4 + 2 + 4

    def cycles(kind, unit):
        return sorted({e.cycle for e in tr.by_kind(kind) if e.unit == unit})
    assert cycles("iw_row", "MXM_W.0") == [19, 20]
    assert cycles("matvec_row", "MXM_W.0") == [21]
    assert cycles("drive", "MXM_W.0") == [24]
    assert cycles("sample", "VXM.0") == [42] and cycles("drive", "VXM.0") == [43]
    assert cycles("sample", "VXM.1") == [43] and cycles("drive", "VXM.1") == [44]
    assert [e.cycle for e in tr.by_kind("mem_write")] == [45, 46, 47, 48]
    # every value arrived exactly where and when it was expected
    for kind in ("sample", "mem_read", "matvec_row"):
        evs = tr.by_kind(kind)
        assert evs and all(e.tag == e.expect for e in evs), kind
    assert [e.tag for e in tr.by_kind("mem_write")] == list(Y)
    # the timed builder, which derives cycles from config.timing, agrees with the hand computation
    assert timed_queues(TOY, N_IN) == {u: q for u, q in hand_queues().items()}


@pytest.mark.parametrize("add_cycle", [41, 43])
def test_hand_written_program_is_one_cycle_from_failing(add_cycle):
    """The MATVEC result is at the VXM in cycle 42 only: an ADD one cycle early or late samples an empty cell."""
    W, b, x = data()
    q = hand_queues()
    q["VXM.0"] = [Nop(add_cycle), q["VXM.0"][1]]
    with pytest.raises(SimFault) as e:
        run_program(relu_program(TOY, q, W, b), {"x": x}, TOY)
    assert (e.value.code, e.value.cycle, e.value.unit) == (1, add_cycle, "VXM.0")


def test_run_program_rejects_other_config():
    W, b, x = data()
    prog = relu_program(TOY, hand_queues(), W, b)
    with pytest.raises(ValueError):
        run_program(prog, {"x": x}, TOY.with_timing(READ=OpTiming(0, 3)))


# ---- nonzero d_skew and other latencies --------------------------------------------------------
SKEWED = TOY.with_timing(READ=OpTiming(1, 3), WRITE=OpTiming(2, 2), VARITH=OpTiming(1, 2),
                         IW=OpTiming(2, 3), MATVEC=OpTiming(1, 4))


def test_relu_program_with_skewed_timing():
    W, b, x = data()
    prog = relu_program(SKEWED, timed_queues(SKEWED, N_IN), W, b)
    res = run_program(prog, {"x": x}, SKEWED)
    assert np.array_equal(res.outputs["y"], expected(W, b, x))
    for e in res.trace.by_kind("issue"):
        tim = SKEWED.timing[{"READ": "READ", "WRITE": "WRITE", "IW": "IW", "MATVEC": "MATVEC"}.get(e.opcode, "VARITH")]
        assert e.sample_cycle == e.cycle + tim.d_skew and e.visible_cycle == e.sample_cycle + tim.d_func
    for kind in ("sample", "mem_read", "matvec_row"):
        assert all(e.tag == e.expect for e in res.trace.by_kind(kind))
    # the hand schedule does not survive the new latencies
    with pytest.raises(SimFault):
        run_program(relu_program(SKEWED, hand_queues(), W, b), {"x": x}, SKEWED)


def test_single_read_with_skew():
    cfg = TOY.with_timing(READ=OpTiming(3, 2))
    p = Prog(cfg)
    p.word("MEM_W0", 0, 0, np.ones(cfg.lanes, dtype=np.uint8), "a#0")
    p.issue("MEM_W0", 0, Read(0, 0, S("E", 0, "a#0")))     # samples at 3, drives at 5 at x = 17
    p.issue("MEM_E0", 7, Write(1, 0, S("E", 0, "a#0")))    # x = 19 at 7
    tr, _ = p.run()
    (iss,) = [e for e in tr.by_kind("issue") if e.opcode == "READ"]
    assert (iss.cycle, iss.sample_cycle, iss.visible_cycle) == (0, 3, 5)
    assert [(e.kind, e.cycle) for e in tr.events if e.unit == "MEM_W0"] == [("issue", 0), ("mem_read", 3), ("drive", 5)]


# ---- determinism ------------------------------------------------------------------------------
def test_trace_is_deterministic():
    W, b, x = data()
    prog = relu_program(TOY, hand_queues(), W, b)
    a = run_program(prog, {"x": x}, TOY).trace
    c = run_program(prog, {"x": x}, TOY).trace
    assert a.to_json() == c.to_json() and a.digest() == c.digest()
    keys = [(e.cycle, TOY.unit_names().index(e.unit)) for e in a.events]
    assert keys == sorted(keys)
    assert all(e.issue_cycle is not None for e in a.events)


def test_trace_is_deterministic_across_processes():
    root = Path(__file__).resolve().parents[2]
    code = ("import sys; sys.path[:0] = [%r, %r]; import test_hw_program as t; "
            "W, b, x = t.data(); p = t.relu_program(t.TOY, t.hand_queues(), W, b); "
            "print(t.run_program(p, {'x': x}, t.TOY).trace.digest())") % (str(root), str(Path(__file__).parent))
    outs = []
    for seed in ("1", "12345"):
        env = {"PYTHONHASHSEED": seed, "PATH": "/usr/bin:/bin"}
        outs.append(subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=env,
                                   cwd=root, check=True).stdout.strip())
    assert outs[0] == outs[1] and len(outs[0]) == 64


# ---- paper scale ------------------------------------------------------------------------------
def test_paper_scale_relu_program():
    cfg = ChipConfig.paper()
    n = cfg.lanes
    W, b, x = data(n, n, seed=5)
    prog = relu_program(cfg, timed_queues(cfg, n), W, b)
    t0 = time.perf_counter()
    res = run_program(prog, {"x": x}, cfg)
    elapsed = time.perf_counter() - t0
    assert np.array_equal(res.outputs["y"], expected(W, b, x))
    assert res.trace.n_cycles > 100 and len(res.trace.occupancy) == res.trace.n_cycles
    assert elapsed < 30, elapsed
