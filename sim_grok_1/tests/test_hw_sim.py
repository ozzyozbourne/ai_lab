"""The cycle loop: arrival rule, commit timing, errors, Repeat, trace format."""

import numpy as np
import pytest

from tsp import isa
from tsp.errors import EmptyOperandError, OperandTagError, ProgramError, StreamCollisionError
from tsp.params import ChipConfig, default_latency

from test_hw_helpers import (E, W, TensorLoc, cells_of_vid, dispatch_of, emissions_of, image,
                             padded, program, ref, run, toy)

CFG = toy()
LAT = CFG.latency
T0 = CFG.barrier_cycles          # first cycle at which a data instruction can dispatch
P = CFG.pos
LAST = CFG.n_positions - 1


def with_latency(**changes):
    lat = default_latency()
    lat.update(changes)
    return ChipConfig(latency=lat)


def int32_image(units, addr, values, config=CFG):
    return image([(u, addr) for u in units], values, "int32", config)


# --- barrier, shift, fall-off, arrival -----------------------------------------
def test_first_dispatch_after_barrier_and_read_arrival_and_falloff():
    c = T0 + 3
    late = c + CFG.n_positions + LAT["read"]   # a later Read keeps the run going past the fall-off
    prog = program(CFG, {"MEM_W0": [(c, isa.Read(0, ref(E, 5), tag="a#0"))],
                         "MEM_E7": [(late, isa.Read(0, ref(E, 6), tag="z#0"))]},
                   mem_image={("MEM_W0", 0): bytes(range(CFG.lanes)), ("MEM_E7", 0): bytes(CFG.lanes)})
    _, tr = run(prog)
    d = dispatch_of(tr, "MEM_W0", c)
    assert d["kind"] == "read" and d["pos"] == P("MEM_W0") and d["reads"] == []
    (em,) = emissions_of(tr, d["did"])
    assert em["cycle"] == c + LAT["read"] and em["pos"] == P("MEM_W0") and em["s"] == 5
    assert em["overwrote"] is None and em["tag"] == "a#0"
    cells = cells_of_vid(tr, em["vid"])
    # one position per cycle, eastward, until it leaves the chip
    assert cells == [(em["cycle"] + k, E, 5, P("MEM_W0") + k) for k in range(LAST - P("MEM_W0") + 1)]
    # B21: the run ends with the last emission; values still flowing are ignored
    assert tr.n_cycles == late + LAT["read"] + 1
    assert max(c_ for c_, *_ in tr.cells) == late + LAT["read"]


def test_barrier_releases_every_queue_at_t15():
    prog = program(CFG, {
        "MEM_E0": [(T0, isa.Read(0, ref(W, 0), tag="x#0"))],
        "MEM_W7": [(T0, isa.Read(0, ref(E, 0), tag="y#0"))],
    }, mem_image={("MEM_E0", 0): bytes(CFG.lanes), ("MEM_W7", 0): bytes(CFG.lanes)})
    _, tr = run(prog)
    assert [d["cycle"] for d in tr.dispatches] == [T0, T0]
    assert [d["unit"] for d in tr.dispatches] == ["MEM_W7", "MEM_E0"]   # canonical unit order


def test_read_arrival_at_distance_exact_cycle_only():
    """A Write at distance k sees the value at exactly t + T6 + k (T2, T3)."""
    t = T0
    src, dst = "MEM_W2", "MEM_E3"
    dist = P(dst) - P(src)
    arrive = t + LAT["read"] + dist
    img = {(src, 0): bytes(range(CFG.lanes))}
    ok = program(CFG, {src: [(t, isa.Read(0, ref(E, 1), tag="a#0"))],
                       dst: [(arrive, isa.Write(7, ref(E, 1), expect=("a#0",)))]},
                 mem_image=img, outputs={"a": TensorLoc("a", "int8", CFG.lanes, ((dst, 7),))})
    sim, tr = run(ok)
    assert sim.peek("a").tolist() == list(range(CFG.lanes))
    assert tr.outputs["a"] == bytes(range(CFG.lanes)).hex()
    w = dispatch_of(tr, dst, arrive)
    assert w["reads"] == [{"dir": E, "s": 1, "pos": P(dst), "vid": 0, "tag": "a#0"}]
    for wrong in (arrive - 1, arrive + 1):
        bad = program(CFG, {src: [(t, isa.Read(0, ref(E, 1), tag="a#0"))],
                            dst: [(wrong, isa.Write(7, ref(E, 1), expect=("a#0",)))]}, mem_image=img)
        with pytest.raises(EmptyOperandError):
            run(bad)


def test_westward_arrival():
    t = T0
    src, dst = "MEM_E5", "MEM_W1"
    arrive = t + LAT["read"] + (P(src) - P(dst))
    prog = program(CFG, {src: [(t, isa.Read(0, ref(W, 3), tag="a#0"))],
                         dst: [(arrive, isa.Write(0, ref(W, 3), expect=("a#0",)))]},
                   mem_image={(src, 0): bytes([9] * CFG.lanes)})
    _, tr = run(prog)
    assert tr.mem_writes == [{"cycle": arrive + LAT["write"] - 1, "did": 1, "unit": dst, "addr": 0, "tag": "a#0"}]


# --- arrival rule for each unit kind and latency class ---------------------------
def _vxm_case(op, dtype, out_dtype="", imm=0):
    """Read operand(s) from MEM_W0/MEM_E0 so they reach the VXM at cycle tv; run op on VXM_A5."""
    w = isa.width(dtype)
    ua = [f"MEM_W{j}" for j in range(w)]
    ub = [f"MEM_E{j}" for j in range(w)]
    vals = np.arange(1, CFG.lanes + 1)
    img = {}
    img.update(image([(u, 0) for u in ua], vals, dtype, CFG))
    img.update(image([(u, 0) for u in ub], vals * 2, dtype, CFG))
    tv = T0 + LAT["read"] + w + 2
    tl = {}
    for j, u in enumerate(ua):
        tl[u] = [(tv - LAT["read"] - (CFG.vxm_pos - P(u)), isa.Read(0, ref(E, j), tag=f"a#{j}"))]
    binary = op in ("add", "sub", "mul")
    if binary:
        for j, u in enumerate(ub):
            tl[u] = [(tv - LAT["read"] - (P(u) - CFG.vxm_pos), isa.Read(0, ref(W, j), tag=f"b#{j}"))]
    b = ref(W, 0) if binary else None
    exp = ("a", "b") if binary else ("a",)
    tl["VXM_A5"] = [(tv, isa.Vxm(op, dtype, ref(E, 0), b, ref(E, 8), CFG.lanes, out_dtype=out_dtype,
                                 imm=imm, tag="r", expect=exp))]
    return tl, img, tv


@pytest.mark.parametrize("op,dtype,out", [
    ("add", "int32", ""), ("sub", "fp32", ""), ("neg", "int32", ""), ("relu", "fp32", ""),
    ("cast", "fp16", "fp32"), ("requant", "int32", "int8"),
    ("mul", "int32", ""), ("mul", "fp32", ""),
    ("tanh", "fp32", ""), ("exp", "fp32", ""), ("rsqrt", "fp32", ""),
])
def test_vxm_emission_cycle_is_dispatch_plus_latency(op, dtype, out):
    tl, img, tv = _vxm_case(op, dtype, out, imm=1 if op == "requant" else 0)
    _, tr = run(program(CFG, tl, mem_image=img))
    d = dispatch_of(tr, "VXM_A5", tv)
    ems = emissions_of(tr, d["did"])
    rdt = out or dtype
    assert len(ems) == isa.width(rdt)
    for j, em in enumerate(ems):
        assert em["cycle"] == tv + LAT[op] and em["pos"] == CFG.vxm_pos
        assert em["s"] == 8 + j and em["tag"] == f"r#{j}"


def test_sxm_emission_cycle_for_each_op():
    lps = CFG.lanes_per_superlane
    instrs = [
        isa.Distribute(1, ref(E, 0), ref(W, 4), tuple([0] * lps), CFG.lanes, tag="d", expect=("a",)),
        isa.Permute(1, ref(E, 0), ref(W, 5), tuple(range(CFG.lanes)), CFG.lanes, tag="p", expect=("a",)),
        isa.Shift(1, ref(E, 0), ref(W, 6), 1, CFG.lanes, tag="s", expect=("a",)),
    ]
    # a value read eastward from MEM_W0 never reaches SXM_W (west of it); use SXM_E
    t = T0
    arrive = t + LAT["read"] + (P("SXM_E") - P("MEM_W0"))
    tl = {"MEM_W0": [(t, isa.Read(0, ref(E, 0), tag="a#0")), (t + 1, isa.Read(0, ref(E, 0), tag="a#0")),
                     (t + 2, isa.Read(0, ref(E, 0), tag="a#0"))],
          "SXM_E": [(arrive + k, ins) for k, ins in enumerate(instrs)]}
    _, tr = run(program(CFG, tl, mem_image={("MEM_W0", 0): bytes(range(CFG.lanes))}))
    for k, ins in enumerate(instrs):
        d = dispatch_of(tr, "SXM_E", arrive + k)
        assert d["kind"] == isa.kind_of(ins)
        (em,) = emissions_of(tr, d["did"])
        assert em["cycle"] == arrive + k + LAT[isa.kind_of(ins)] and em["pos"] == P("SXM_E")


# --- MXM: install, commit timing, hand-written y = relu(W.x + b) --------------------
def matvec_program(config, Wm, x, b, abc_delay=None):
    """Hand-scheduled y = relu(W.x + b) on MXM_W (int8 weights and input, int32 bias)."""
    lat = config.latency
    n_out, n_in = Wm.shape
    pos = config.pos
    rows = [f"MEM_W{i}" for i in range(n_out)]
    img = {}
    for i, u in enumerate(rows):
        img[(u, 0)] = padded(Wm[i], "int8", config).tobytes()
    b_units = [f"MEM_E{j}" for j in range(isa.width("int32"))]
    img.update(image([(u, 0) for u in b_units], b, "int32", config))
    y_units = [f"MEM_E{j}" for j in range(isa.width("int32"), 2 * isa.width("int32"))]
    x_unit = f"MEM_W{n_out}"
    tl = {}
    t_iw = config.barrier_cycles + lat["read"] + pos(rows[0])
    for i, u in enumerate(rows):
        tl[u] = [(t_iw - lat["read"] - pos(u), isa.Read(0, ref(W, i), tag=f"w{i}#0"))]
    tl["MXM_W0"] = [(t_iw, isa.Iw("int8", tuple((i, ref(W, i)) for i in range(n_out)),
                                  expect=tuple(f"w{i}" for i in range(n_out))))]
    t_abc = t_iw + (lat["iw"] if abc_delay is None else abc_delay)
    tl[x_unit] = [(t_abc - lat["read"] - pos(x_unit), isa.Read(0, ref(W, 16), tag="x#0"))]
    tl["MXM_W0"].append((t_abc, isa.Abc("int8", ref(W, 16), ref(E, 0), n_out, tag="acc", expect=("x",))))
    tv = t_abc + lat["abc"] + config.vxm_pos
    for j, u in enumerate(b_units):
        tl[u] = [(tv - lat["read"] - (pos(u) - config.vxm_pos), isa.Read(0, ref(W, 8 + j), tag=f"b#{j}"))]
    tl["VXM_A1"] = [(tv, isa.Vxm("add", "int32", ref(E, 0), ref(W, 8), ref(E, 4), n_out, tag="s",
                                 expect=("acc", "b")))]
    tr_ = tv + lat["add"]
    tl["VXM_A2"] = [(tr_, isa.Vxm("relu", "int32", ref(E, 4), None, ref(E, 12), n_out, tag="y", expect=("s",)))]
    for j, u in enumerate(y_units):
        tl[u] = [(tr_ + lat["relu"] + pos(u) - config.vxm_pos, isa.Write(0, ref(E, 12 + j), expect=(f"y#{j}",)))]
    inputs = {"x": TensorLoc("x", "int8", n_in, ((x_unit, 0),))}
    outputs = {"y": TensorLoc("y", "int32", n_out, tuple((u, 0) for u in y_units))}
    return program(config, tl, mem_image=img, inputs=inputs, outputs=outputs), (t_iw, t_abc, tv)


def mv_data(seed=0, n_out=4, n_in=12):
    rng = np.random.default_rng(seed)
    Wm = rng.integers(-128, 128, (n_out, n_in)).astype(np.int8)
    x = rng.integers(-128, 128, n_in).astype(np.int8)
    b = rng.integers(-3000, 3000, n_out).astype(np.int32)
    return Wm, x, b


def test_hand_written_matvec_relu():
    Wm, x, b = mv_data()
    prog, (t_iw, t_abc, tv) = matvec_program(CFG, Wm, x, b)
    sim, tr = run(prog, {"x": x})
    want = np.maximum(Wm.astype(np.int64) @ x.astype(np.int64) + b, 0).astype(np.int32)
    assert sim.peek("y").tolist() == want.tolist()
    abc = dispatch_of(tr, "MXM_W0", t_abc)
    ems = emissions_of(tr, abc["did"])
    assert [e["cycle"] for e in ems] == [t_abc + LAT["abc"]] * isa.width("int32")
    assert [e["pos"] for e in ems] == [P("MXM_W0")] * isa.width("int32")
    iw = dispatch_of(tr, "MXM_W0", t_iw)
    assert emissions_of(tr, iw["did"]) == [] and len(iw["reads"]) == Wm.shape[0]
    assert iw["text"] and iw["kind"] == "iw"


def test_iw_commit_timing():
    """With an install latency of L, an Abc dispatched L cycles after the Iw sees the weights
    and one dispatched earlier sees the reset (zero) weights."""
    big = 3
    cfg = with_latency(iw=big)
    Wm, x, b = mv_data(1)
    b = np.abs(b)  # relu(0 + b) = b when the weights are not yet installed
    prog, _ = matvec_program(cfg, Wm, x, b, abc_delay=big)
    sim, _ = run(prog, {"x": x})
    assert sim.peek("y").tolist() == np.maximum(Wm.astype(np.int64) @ x + b, 0).tolist()
    prog, _ = matvec_program(cfg, Wm, x, b, abc_delay=big - 1)
    sim, _ = run(prog, {"x": x})
    assert sim.peek("y").tolist() == b.tolist()


def test_write_commit_timing_and_read_back():
    """Write dispatched at t commits at the end of t + T7 - 1; a Read at t + T7 sees it."""
    for wlat in (LAT["write"], 3):
        cfg = with_latency(write=wlat)
        t = T0
        u = "MEM_E2"
        arrive = t + cfg.latency["read"] + P(u) - P("MEM_W0")
        tl = {"MEM_W0": [(t, isa.Read(0, ref(E, 0), tag="a#0"))],
              u: [(arrive, isa.Write(4, ref(E, 0), expect=("a#0",))),
                  (arrive + wlat, isa.Read(4, ref(W, 0), tag="back#0"))]}
        img = {("MEM_W0", 0): bytes([7] * cfg.lanes)}
        _, tr = run(program(cfg, tl, mem_image=img))
        assert tr.mem_writes[0]["cycle"] == arrive + wlat - 1
        if wlat > 1:
            tl[u][1] = (arrive + wlat - 1, isa.Read(4, ref(W, 0), tag="back#0"))
            with pytest.raises(EmptyOperandError):
                run(program(cfg, tl, mem_image=img))


def test_run_ends_after_last_commit():
    cfg = with_latency(write=4)
    t = T0
    tl = {"MEM_W0": [(t, isa.Read(0, ref(E, 0), tag="a#0"))],
          "MEM_E0": [(t + LAT["read"] + 2, isa.Write(1, ref(E, 0)))]}
    _, tr = run(program(cfg, tl, mem_image={("MEM_W0", 0): bytes(cfg.lanes)}))
    # MEM_W0 -> MEM_E0 is 2 positions; the value falls off later but the run ends at the commit
    assert tr.mem_writes[0]["cycle"] == t + LAT["read"] + 2 + 3
    assert tr.n_cycles == max(tr.mem_writes[0]["cycle"], tr.emissions[-1]["cycle"]) + 1


def test_write_does_not_end_the_stream():
    """Ledger B2: a MEM Write samples the stream and leaves it flowing.

    The value written at MEM_E0 is still on the stream further east, where a
    second slice stores it again.  ([HC22] slide 30 says "a write terminates a
    stream"; the simulator follows [TSP20] Sec. V, where a stream ends only by
    falling off the edge or being overwritten.)
    """
    t = T0
    src, near, far = "MEM_W0", "MEM_E0", "MEM_E3"
    arrive = lambda u: t + LAT["read"] + P(u) - P(src)
    data = bytes(range(1, CFG.lanes + 1))
    tl = {src: [(t, isa.Read(0, ref(E, 0), tag="a#0"))],
          near: [(arrive(near), isa.Write(1, ref(E, 0), expect=("a#0",)))],
          far: [(arrive(far), isa.Write(2, ref(E, 0), expect=("a#0",)))]}
    sim, tr = run(program(CFG, tl, mem_image={(src, 0): data}))
    (em,) = emissions_of(tr, dispatch_of(tr, src, t)["did"])
    # both Writes sampled the same value, the second one three positions downstream of the first
    assert [d["reads"][0]["vid"] for d in tr.dispatches if d["kind"] == "write"] == [em["vid"], em["vid"]]
    assert sim.mem.read(near, 1).tobytes() == data and sim.mem.read(far, 2).tobytes() == data
    # the value occupies one register per cycle from its emission to the east edge, Writes or not
    cells = cells_of_vid(tr, em["vid"])
    last_recorded = min(LAST, P(src) + (tr.n_cycles - 1 - em["cycle"]))
    assert cells == [(em["cycle"] + k, E, 0, P(src) + k) for k in range(last_recorded - P(src) + 1)]
    assert last_recorded >= P(far) > P(near)   # the run ends with the last commit (B21)


def test_one_instruction_per_queue_per_cycle_in_the_cycle_loop():
    """Ledger T16: three data instructions queued back to back dispatch on three consecutive cycles."""
    tl = {"MEM_W0": [(T0 + k, isa.Read(k, ref(E, k), tag=f"a{k}#0")) for k in range(3)]}
    img = {("MEM_W0", k): bytes(CFG.lanes) for k in range(3)}
    _, tr = run(program(CFG, tl, mem_image=img))
    assert [d["cycle"] for d in tr.dispatches if d["unit"] == "MEM_W0"] == [T0, T0 + 1, T0 + 2]
    per_unit_cycle = [(d["unit"], d["cycle"]) for d in tr.dispatches]
    assert len(per_unit_cycle) == len(set(per_unit_cycle))


# --- Repeat, op(a, a), two results per cycle, overwrite ------------------------------
def test_repeat_program():
    t, n, d = T0, 2, 3
    u, dst = "MEM_W0", "MEM_E1"
    dist = P(dst) - P(u)
    tl = {u: [(t, isa.Read(0, ref(E, 2), tag="a#0")), (t + 1, ("repeat", n, d)),
              (t + 1 + n * d, isa.Read(1, ref(E, 3), tag="c#0"))],
          dst: [(t + LAT["read"] + dist, isa.Write(9, ref(E, 2), expect=("a#0",))), (t + LAT["read"] + dist + 1,
                                                                                       ("repeat", n, d))]}
    img = {(u, 0): bytes([1] * CFG.lanes), (u, 1): bytes([2] * CFG.lanes)}
    _, tr = run(program(CFG, tl, mem_image=img))
    reads = [x["cycle"] for x in tr.dispatches if x["unit"] == u]
    assert reads == [t, t + d, t + 2 * d, t + 1 + n * d]
    writes = [x["cycle"] for x in tr.dispatches if x["unit"] == dst]
    assert writes == [c + LAT["read"] + dist for c in reads[:3]]
    assert len(tr.mem_writes) == n + 1
    assert [e["tag"] for e in tr.emissions] == ["a#0", "a#0", "a#0", "c#0"]


def test_op_with_both_operands_on_same_streams():
    tl, img, tv = _vxm_case("add", "int32")
    a = ref(E, 0)
    tl = {k: v for k, v in tl.items() if not k.startswith("MEM_E")}
    tl["VXM_A5"] = [(tv, isa.Vxm("mul", "int32", a, a, ref(E, 8), CFG.lanes, tag="sq", expect=("a", "a")))]
    out_units = [f"MEM_E{j}" for j in range(isa.width("int32"))]
    for j, u in enumerate(out_units):
        tl[u] = [(tv + LAT["mul"] + P(u) - CFG.vxm_pos, isa.Write(0, ref(E, 8 + j), expect=(f"sq#{j}",)))]
    prog = program(CFG, tl, mem_image=img,
                   outputs={"sq": TensorLoc("sq", "int32", CFG.lanes, tuple((u, 0) for u in out_units))})
    sim, tr = run(prog)
    vals = np.arange(1, CFG.lanes + 1)
    assert sim.peek("sq").tolist() == (vals * vals).tolist()
    d = dispatch_of(tr, "VXM_A5", tv)
    assert [r["s"] for r in d["reads"]] == [0, 1, 2, 3]   # each register recorded once


def test_two_results_from_one_unit_on_one_cycle():
    tl, img, tv = _vxm_case("add", "int32")
    mul = isa.Vxm("mul", "int32", ref(E, 0), ref(W, 0), ref(E, 8), CFG.lanes, tag="m", expect=("a", "b"))
    tl["MEM_W0"].append((tl["MEM_W0"][0][0] + 1, isa.Read(0, ref(E, 0), tag="a#0")))
    for j in range(1, isa.width("int32")):
        tl[f"MEM_W{j}"].append((tl[f"MEM_W{j}"][0][0] + 1, isa.Read(0, ref(E, j), tag=f"a#{j}")))
    for j in range(isa.width("int32")):
        tl[f"MEM_E{j}"].append((tl[f"MEM_E{j}"][0][0] + 1, isa.Read(0, ref(W, j), tag=f"b#{j}")))
    assert LAT["mul"] == LAT["add"] + 1, "test assumes T9 = T8 + 1"
    add = isa.Vxm("add", "int32", ref(E, 0), ref(W, 0), ref(E, 16), CFG.lanes, tag="s", expect=("a", "b"))
    tl["VXM_A5"] = [(tv, mul), (tv + 1, add)]
    _, tr = run(program(CFG, tl, mem_image=img))
    due = tv + LAT["mul"]
    ems = [e for e in tr.emissions if e["unit"] == "VXM_A5"]
    assert all(e["cycle"] == due for e in ems) and len(ems) == 2 * isa.width("int32")
    assert [e["tag"][0] for e in ems] == ["m"] * 4 + ["s"] * 4
    # same destination register on the same cycle is a collision
    tl["VXM_A5"] = [(tv, mul), (tv + 1, isa.Vxm("add", "int32", ref(E, 0), ref(W, 0), ref(E, 8), CFG.lanes))]
    with pytest.raises(StreamCollisionError):
        run(program(CFG, tl, mem_image=img))


def test_collision_between_two_alus():
    tl, img, tv = _vxm_case("add", "int32")
    tl["VXM_A6"] = [(tv, isa.Vxm("sub", "int32", ref(E, 0), ref(W, 0), ref(E, 8), CFG.lanes, tag="q"))]
    with pytest.raises(StreamCollisionError):
        run(program(CFG, tl, mem_image=img))


def test_overwrite():
    t = T0
    a_src, b_src, dst = "MEM_W0", "MEM_E0", "MEM_E1"
    t_b = t + (P(b_src) - P(a_src))   # b is emitted on the cycle a reaches b_src's position
    tl = {a_src: [(t, isa.Read(0, ref(E, 0), tag="a#0"))],
          b_src: [(t_b, isa.Read(0, ref(E, 0), tag="b#0"))],
          dst: [(t_b + LAT["read"] + 1, isa.Write(0, ref(E, 0), expect=("b#0",)))]}
    img = {(a_src, 0): bytes([1] * CFG.lanes), (b_src, 0): bytes([2] * CFG.lanes)}
    _, tr = run(program(CFG, tl, mem_image=img))
    ea, eb = tr.emissions[0], tr.emissions[1]
    assert eb["overwrote"] == ea["vid"] and eb["cycle"] == ea["cycle"] + P(b_src) - P(a_src)
    assert max(c for c, _, _, _ in cells_of_vid(tr, ea["vid"])) == eb["cycle"] - 1
    tl[dst] = [(t_b + LAT["read"] + 1, isa.Write(0, ref(E, 0), expect=("a#0",)))]
    with pytest.raises(OperandTagError):
        run(program(CFG, tl, mem_image=img))


# --- errors ------------------------------------------------------------------------
def test_empty_operand_on_stream():
    tl = {"VXM_A3": [(T0, isa.Vxm("neg", "int32", ref(E, 0), None, ref(E, 4), CFG.lanes))]}
    with pytest.raises(EmptyOperandError):
        run(program(CFG, tl))


def test_input_never_poked_is_error_when_read():
    tl = {"MEM_W0": [(T0, isa.Read(0, ref(E, 0), tag="x#0"))]}
    prog = program(CFG, tl, inputs={"x": TensorLoc("x", "int8", 4, (("MEM_W0", 0),))})
    with pytest.raises(EmptyOperandError):
        run(prog)
    sim, _ = run(prog, {"x": np.array([1, 2, 3, 4], dtype=np.int8)})
    assert sim.peek("x").tolist() == [1, 2, 3, 4]


def test_tag_mismatch_on_one_plane():
    tl, img, tv = _vxm_case("add", "int32")
    tl["MEM_W2"] = [(tl["MEM_W2"][0][0], isa.Read(0, ref(E, 2), tag="zz#2"))]
    with pytest.raises(OperandTagError):
        run(program(CFG, tl, mem_image=img))


def test_run_calls_check_program():
    prog = program(CFG, {"MEM_W0": [(T0, isa.Read(0, ref(E, 1), tag="a#0"))]},
                   mem_image={("MEM_W0", 0): bytes(CFG.lanes)})
    prog.queues["VXM_A0"] = [isa.Sync()]     # no Notify anywhere
    with pytest.raises(ProgramError):
        run(prog)


def test_poke_checks_length_and_dtype_and_pads():
    prog = program(CFG, {}, inputs={"x": TensorLoc("x", "int32", 3, tuple((f"MEM_W{j}", 2) for j in range(4)))})
    from tsp.hw import Simulator
    sim = Simulator(prog)
    with pytest.raises(ValueError):
        sim.poke("x", np.array([1, 2], dtype=np.int32))
    with pytest.raises(ValueError):
        sim.poke("x", np.array([1, 2, 3], dtype=np.float32))
    sim.poke("x", [1, -2, 3])
    assert sim.peek("x").tolist() == [1, -2, 3]
    plane0 = sim.mem.read("MEM_W0", 2)
    assert np.all(plane0[3:] == 0)


# --- zero padding through the machine -------------------------------------------------
def test_zero_padding_of_results():
    tl, img, tv = _vxm_case("add", "int32")   # operands are nonzero on every lane
    n = 5
    tl["VXM_A5"] = [(tv, isa.Vxm("add", "int32", ref(E, 0), ref(W, 0), ref(E, 8), n, tag="r", expect=("a", "b")))]
    out_units = [f"MEM_E{j}" for j in range(isa.width("int32"), 2 * isa.width("int32"))]
    for j, u in enumerate(out_units):
        tl[u] = [(tv + LAT["add"] + P(u) - CFG.vxm_pos, isa.Write(0, ref(E, 8 + j), expect=(f"r#{j}",)))]
    prog = program(CFG, tl, mem_image=img,
                   outputs={"r": TensorLoc("r", "int32", CFG.lanes, tuple((u, 0) for u in out_units))})
    sim, _ = run(prog)
    vals = np.arange(1, CFG.lanes + 1)
    got = sim.peek("r")
    assert got[:n].tolist() == (vals[:n] * 3).tolist() and np.all(got[n:] == 0)


# --- trace format and determinism ------------------------------------------------------
def test_trace_ordering_and_fields():
    Wm, x, b = mv_data(2)
    prog, _ = matvec_program(CFG, Wm, x, b)
    _, tr = run(prog, {"x": x})
    order = {u: i for i, u in enumerate(CFG.units())}
    assert [d["did"] for d in tr.dispatches] == list(range(len(tr.dispatches)))
    keys = [(d["cycle"], order[d["unit"]]) for d in tr.dispatches]
    assert keys == sorted(keys)
    ekeys = [(e["cycle"], e["did"], e["s"]) for e in tr.emissions]
    assert ekeys == sorted(ekeys)
    assert [e["vid"] for e in tr.emissions] == list(range(len(tr.emissions)))
    ck = [(c, d, s, x_) for c, d, s, x_, _ in tr.cells]
    assert ck == sorted(ck) and len(set(ck)) == len(ck)
    mk = [(m["cycle"], m["did"]) for m in tr.mem_writes]
    assert mk == sorted(mk)
    assert list(tr.values) == [str(e["vid"]) for e in tr.emissions]
    for e in tr.emissions:
        v = tr.values[str(e["vid"])]
        assert v == {"tag": e["tag"], "unit": e["unit"], "did": e["did"], "cycle": e["cycle"]}
        assert e["cycle"] - tr.dispatches[e["did"]]["cycle"] == LAT[tr.dispatches[e["did"]]["kind"]]
    assert tr.config == CFG.to_dict()
    assert set(tr.outputs) == {"y"} and len(tr.outputs["y"]) == 2 * CFG.lanes * isa.width("int32")


def test_trace_byte_identical_between_runs_and_record_cells_off():
    Wm, x, b = mv_data(3)
    p1, _ = matvec_program(CFG, Wm, x, b)
    p2, _ = matvec_program(CFG, Wm, x, b)
    _, t1 = run(p1, {"x": x})
    _, t2 = run(p2, {"x": x})
    assert t1.to_json() == t2.to_json() and t1.digest() == t2.digest()
    _, t3 = run(p1, {"x": x}, record_cells=False)
    assert t3.cells == [] and t3.dispatches == t1.dispatches and t3.emissions == t1.emissions


def test_isca2020_config_runs():
    cfg = ChipConfig.isca2020()
    t = cfg.barrier_cycles
    u, dst = "MEM_W43", "MEM_E43"
    arrive = t + cfg.latency["read"] + cfg.pos(dst) - cfg.pos(u)
    data = bytes(i % 256 for i in range(cfg.lanes))
    prog = program(cfg, {u: [(t, isa.Read(0, ref(E, 31), tag="a#0"))],
                         dst: [(arrive, isa.Write(cfg.mem_words - 1, ref(E, 31), expect=("a#0",)))]},
                   mem_image={(u, 0): data},
                   outputs={"a": TensorLoc("a", "int8", cfg.lanes, ((dst, cfg.mem_words - 1),))})
    sim, tr = run(prog)
    assert tr.outputs["a"] == data.hex()
