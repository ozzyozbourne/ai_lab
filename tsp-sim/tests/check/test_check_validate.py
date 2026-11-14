"""Validator tests on hand-built programs and traces (plan.md section 9, "Unit, checking").

Traces come from the test-only mini recorder (check_minirec.py), then are mutated.
Each negative test asserts that exactly the intended check fails.
"""
import dataclasses

import pytest

from check_minirec import build_queues, issue_at, record, visible
from tsp.config import ChipConfig, OpTiming
from tsp.isa import IW, DType, Issue, MatVec, Nop, Read, SRef, VOp, Write, plane_tags
from tsp.program import Program
from tsp.trace import Event, Trace
from tsp.validate import CHECK_NAMES, MAX_FAILURES, validate

TOY = ChipConfig.toy()
SKEWED = TOY.with_timing(READ=OpTiming(1, 3), WRITE=OpTiming(1, 2), VARITH=OpTiming(2, 1),
                         IW=OpTiming(1, 2), MATVEC=OpTiming(1, 4))


def program(config, queues):
    return Program("t", config.name, config.fingerprint(), config.lanes, queues)


# ---- program 1: Read -> flight -> CAST -> flight -> 4 Writes ------------------------
def basic_items(config, out_base=4):
    """x (I8) read from MEM_W1, cast to I32 on VXM.0, parked in MEM_E0..E3."""
    rd = Read(0, 0, SRef("E", 0, ("x.t0#0",)))
    ts_r = 2
    t_arr = visible(config, rd, ts_r) + (config.vxm_pos - config.pos("MEM_W1"))
    cast = VOp("CAST", DType.I8, SRef("E", 0, ("x.t0#0",)), None,
               SRef("E", out_base, plane_tags("c.t0", DType.I32)), to=DType.I32)
    items = [("MEM_W1", issue_at(config, rd, ts_r), rd),
             ("VXM.0", issue_at(config, cast, t_arr), cast)]
    tv_c = visible(config, cast, t_arr)
    writes = {}
    for j in range(4):
        w = Write(1, 0, SRef("E", out_base + j, (f"c.t0#{j}",)))
        unit = f"MEM_E{j}"
        ts_w = tv_c + config.pos(unit) - config.vxm_pos
        items.append((unit, issue_at(config, w, ts_w), w))
        writes[unit] = ts_w
    info = {"ts_read": ts_r, "t_cast": t_arr, "tv_cast": tv_c, "ts_write": writes}
    image = {("MEM_W1", 0, 0): "x.t0#0", ("MEM_W1", 0, 2): "w.t0#0",
             ("MEM_W0", 0, 1): "z.t0#0", ("MEM_E1", 1, 5): "z.t0#0", ("MEM_W1", 0, 7): "other#0"}
    return items, image, info


def run(config, items, image, **kw):
    queues = build_queues(config, items)
    return program(config, queues), record(queues, config, image, **kw)


def only_fails(report, letter):
    assert report.failed() == [letter], report.summary()


# ---- program 2: F16 weight install + MATVEC + 4 Writes -------------------------------
def mxm_items(config, t_iw=14, t_mv=None):
    """Rows W.c0, W.c1 (F16) installed on MXM_W.0 at sample cycle t_iw; MATVEC at t_mv."""
    if t_mv is None:
        t_mv = t_iw + config.timing["IW"].d_func
    items = []

    def read_to_mxm(unit, stream, tag, t_arrive):
        rd = Read(0, 0, SRef("W", stream, (tag,)))
        ts = t_arrive - config.pos(unit) - config.timing["READ"].d_func
        items.append((unit, issue_at(config, rd, ts), rd))

    read_to_mxm("MEM_W15", 0, "W.c0#0", t_iw)
    read_to_mxm("MEM_W14", 1, "W.c0#1", t_iw)
    read_to_mxm("MEM_W13", 2, "W.c1#0", t_iw)
    read_to_mxm("MEM_W12", 3, "W.c1#1", t_iw)
    read_to_mxm("MEM_W11", 4, "a.t0#0", t_mv)
    read_to_mxm("MEM_W10", 5, "a.t0#1", t_mv)
    iw = IW(DType.F16, ((0, SRef("W", 0, ("W.c0#0", "W.c0#1"))), (1, SRef("W", 2, ("W.c1#0", "W.c1#1")))))
    mv = MatVec(DType.F16, 2, SRef("W", 4, ("a.t0#0", "a.t0#1")),
                SRef("E", 0, plane_tags("y.t0", DType.F32)), ("W.c0#0", "W.c1#0"))
    items.append(("MXM_W.0", issue_at(config, iw, t_iw), iw))
    items.append(("MXM_W.0", issue_at(config, mv, t_mv), mv))
    tv = visible(config, mv, t_mv)
    for j in range(4):
        unit = f"MEM_W{15 - j}"
        w = Write(1, 0, SRef("E", j, (f"y.t0#{j}",)))
        items.append((unit, issue_at(config, w, tv + config.pos(unit)), w))
    image = {}
    for unit, tag in (("MEM_W15", "W.c0#0"), ("MEM_W14", "W.c0#1"), ("MEM_W13", "W.c1#0"),
                      ("MEM_W12", "W.c1#1"), ("MEM_W11", "a.t0#0"), ("MEM_W10", "a.t0#1")):
        image[(unit, 0, 0)] = tag
    return items, image, {"t_iw": t_iw, "t_mv": t_mv}


# ---- good cases ------------------------------------------------------------------------
@pytest.mark.parametrize("config", [TOY, SKEWED], ids=["toy", "skewed"])
@pytest.mark.parametrize("builder", [basic_items, mxm_items], ids=["basic", "mxm"])
def test_good_program_passes(config, builder):
    items, image, _ = builder(config)
    prog, trace = run(config, items, image)
    rep = validate(prog, trace, config)
    assert rep.ok, rep.summary()
    assert [c.name for c in rep.checks] == list(CHECK_NAMES)
    assert all(c.checked > 0 for c in rep.checks)
    assert "ALL CHECKS PASSED" in rep.summary()


def test_good_trace_survives_json_roundtrip():
    items, image, _ = mxm_items(TOY)
    prog, trace = run(TOY, items, image)
    assert validate(prog, Trace.from_json(trace.to_json()), TOY).ok


def test_good_basic_trace_shape():
    """Sanity of the hand-built case itself: hand-computed cycles on the toy chip."""
    items, image, info = basic_items(TOY)
    _, trace = run(TOY, items, image)
    # Read samples at 2, drives at 4 at pos 16, arrives at the VXM (pos 18) at 6; CAST visible at 7
    assert info["t_cast"] == 6 and info["tv_cast"] == 7
    assert info["ts_write"] == {"MEM_E0": 8, "MEM_E1": 9, "MEM_E2": 10, "MEM_E3": 11}
    assert trace.n_cycles == 12
    drives = [(e.cycle, e.pos, e.stream, e.tag) for e in trace.by_kind("drive")]
    assert drives[0] == (4, 16, 0, "x.t0#0")


# ---- A: exact arrival ------------------------------------------------------------------
def patch(trace, pred, **changes):
    """Copy of trace with every event matching pred changed."""
    evs = [dataclasses.replace(e, **changes) if pred(e) else e for e in trace.events]
    return Trace(trace.config_name, trace.n_cycles, evs, trace.occupancy, trace.digests)


def test_a_fails_on_wrong_tag_seen():
    items, image, _ = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    bad = patch(trace, lambda e: e.kind == "sample" and e.unit == "VXM.0", tag="wrong#0")
    rep = validate(prog, bad, TOY)
    only_fails(rep, "A")
    assert "wrong#0" in rep.check("A").failures[0]


def test_a_fails_on_wrong_matvec_row_tag():
    items, image, _ = mxm_items(TOY)
    prog, trace = run(TOY, items, image)
    bad = patch(trace, lambda e: e.kind == "matvec_row" and e.row == 1, tag=None)
    only_fails(validate(prog, bad, TOY), "A")


def test_wrong_address_fails_a_and_b():
    """A consistent trace of a Read from the wrong word: the stored tag travels on, so A and B both see it."""
    items, image, _ = basic_items(TOY)
    items[0] = (items[0][0], items[0][1], Read(0, 7, SRef("E", 0, ("x.t0#0",))))
    prog, trace = run(TOY, items, image)
    assert validate(prog, trace, TOY).failed() == ["A", "B"]


def test_failures_are_capped_with_total():
    items, image, _ = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    evs = list(trace.events)
    extra = [Event(100 + i, "sample", "VXM.0", 18, "ADD", "E", 0, "bad", "good", issue_cycle=100 + i)
             for i in range(15)]
    bad = Trace(trace.config_name, trace.n_cycles, evs + extra, trace.occupancy, trace.digests)
    fa = validate(prog, bad, TOY).check("A").failures
    assert len(fa) == MAX_FAILURES and "15 failures in total" in fa[-1]


# ---- B: stream replay ------------------------------------------------------------------
def test_b_fails_when_live_flight_is_overwritten():
    """Another Read drives onto x's diagonal between its producer and its consumer.

    A simulator with broken stream code still reports the expected tags (we patch the
    sample events back), so only the geometric replay can catch it.
    """
    items, image, info = basic_items(TOY)
    clob = Read(0, 1, SRef("E", 0, ("z.t0#0",)))
    # x passes MEM_W0 (pos 17) at cycle t_cast - 1; drive z there at that cycle
    ts = info["t_cast"] - 1 - TOY.timing["READ"].d_func
    items.append(("MEM_W0", issue_at(TOY, clob, ts), clob))
    prog, trace = run(TOY, items, image)
    assert validate(prog, trace, TOY).failed() == ["A", "B"]       # honest trace: both see z
    hidden = Trace(trace.config_name, trace.n_cycles,
                   [dataclasses.replace(e, tag=e.expect) if e.kind == "sample" else e for e in trace.events],
                   trace.occupancy, trace.digests)
    rep = validate(prog, hidden, TOY)
    only_fails(rep, "B")
    assert "z.t0#0" in rep.check("B").failures[0]


def test_b_fails_on_two_drives_of_one_cell():
    items, image, _ = basic_items(TOY)
    dup = [it for it in items if it[0] == "VXM.0"][0]
    items.append(("VXM.1", dup[1], dup[2]))
    prog, trace = run(TOY, items, image)
    rep = validate(prog, trace, TOY)
    only_fails(rep, "B")
    assert "2 drives on cell" in rep.check("B").failures[0]


def test_b_fails_when_sample_has_no_source():
    items, image, _ = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    bad = Trace(trace.config_name, trace.n_cycles, [e for e in trace.events if e.kind != "drive"],
                [[] for _ in trace.occupancy], trace.digests)
    assert "B" in validate(prog, bad, TOY).failed()


# ---- C: units --------------------------------------------------------------------------
def test_c_fails_on_two_reads_in_one_slice_in_one_cycle():
    items, image, _ = basic_items(TOY)
    unit, t, rd = items[0]
    items.append((unit, t, Read(0, 2, SRef("E", 1, ("w.t0#0",)))))
    prog, trace = run(TOY, items, image)
    rep = validate(prog, trace, TOY)
    only_fails(rep, "C")
    text = "\n".join(rep.check("C").failures)
    assert "2 Reads" in text and "max one each" in text


def test_c_fails_on_read_and_write_on_one_bank():
    items, image, info = basic_items(TOY)
    rd = Read(1, 5, SRef("E", 8, ("z.t0#0",)))
    items.append(("MEM_E1", issue_at(TOY, rd, info["ts_write"]["MEM_E1"]), rd))
    prog, trace = run(TOY, items, image)
    rep = validate(prog, trace, TOY)
    only_fails(rep, "C")
    assert "Read and Write on bank 1" in rep.check("C").failures[0]


def test_c_read_and_write_on_different_banks_is_fine():
    items, image, info = basic_items(TOY)
    image[("MEM_E1", 0, 5)] = "z.t0#0"
    rd = Read(0, 5, SRef("E", 8, ("z.t0#0",)))
    items.append(("MEM_E1", issue_at(TOY, rd, info["ts_write"]["MEM_E1"]), rd))
    prog, trace = run(TOY, items, image)
    assert validate(prog, trace, TOY).ok


def test_c_fails_on_matvec_row_installed_too_late():
    """MATVEC samples one cycle after the IW, but d_func(IW) is 2. A simulator that ignores the
    install latency (iw_delay=1) reports the new rows, so only the timing re-check catches it."""
    cfg = TOY.with_timing(IW=OpTiming(0, 2))
    items, image, info = mxm_items(cfg, t_mv=15)
    assert info["t_mv"] - info["t_iw"] < cfg.timing["IW"].d_func
    prog, trace = run(cfg, items, image, iw_delay=1)
    rep = validate(prog, trace, cfg)
    only_fails(rep, "C")
    assert "no iw_row installed by cycle 13" in rep.check("C").failures[0]
    # the same trace is fine for a chip whose install latency is 1
    prog1, trace1 = run(TOY, items, image)
    assert validate(prog1, trace1, TOY).ok


def test_c_fails_on_wrong_unit_kind():
    """A Write placed on a VXM queue, sampling the CAST result where it is visible."""
    items, image, info = basic_items(TOY)
    w = Write(1, 3, SRef("E", 4, ("c.t0#0",)))
    items.append(("VXM.1", issue_at(TOY, w, info["tv_cast"]), w))
    prog, trace = run(TOY, items, image)
    rep = validate(prog, trace, TOY)
    only_fails(rep, "C")
    assert "WRITE issued on a VXM unit" in rep.check("C").failures[0]


def test_c_fails_on_misaligned_stream_group():
    items, image, _ = basic_items(TOY, out_base=2)
    prog, trace = run(TOY, items, image)
    rep = validate(prog, trace, TOY)
    only_fails(rep, "C")
    assert "not aligned" in rep.check("C").failures[0]


def test_c_fails_on_nop_count():
    items, image, _ = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    prog.queues["VXM.7"] = [Nop(0)]
    rep = validate(prog, trace, TOY)
    only_fails(rep, "C")
    assert "Nop(0)" in rep.check("C").failures[0]


def test_c_fails_on_fp16_two_plane_rule():
    """An I8 IW on MXM_W.1 while MXM_W.0 holds F16 rows (L-X9)."""
    items, image, info = mxm_items(TOY)
    iw1 = IW(DType.I8, ((0, SRef("W", 0, ("W.c0#0",))),))
    items.append(("MXM_W.1", issue_at(TOY, iw1, info["t_iw"]), iw1))
    prog, trace = run(TOY, items, image)
    rep = validate(prog, trace, TOY)
    only_fails(rep, "C")
    assert "L-X9" in rep.check("C").failures[0]


def test_c_fails_on_mxm_direction():
    """MATVEC result on outward-flowing streams (L-X6); the Writes follow it, so only C fails."""
    items, image, info = mxm_items(TOY)
    out = []
    for unit, t, ins in items:
        if isinstance(ins, MatVec):
            ins = dataclasses.replace(ins, out=SRef("W", 8, ins.out.tags))
        if isinstance(ins, Write):
            continue
        out.append((unit, t, ins))
    prog, trace = run(TOY, out, image)
    rep = validate(prog, trace, TOY)
    only_fails(rep, "C")
    assert "L-X6" in rep.check("C").failures[0]


# ---- D: program / trace agreement ------------------------------------------------------
def test_d_fails_on_issue_event_at_wrong_cycle():
    items, image, _ = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    bad = patch(trace, lambda e: e.kind == "issue" and e.unit == "VXM.0", cycle=5)
    rep = validate(prog, bad, TOY)
    only_fails(rep, "D")
    text = "\n".join(rep.check("D").failures)
    assert "missing issue at cycle 6" in text and "unexpected issue at cycle 5" in text


def test_d_fails_on_missing_issue_event():
    items, image, _ = mxm_items(TOY)
    prog, trace = run(TOY, items, image)
    bad = Trace(trace.config_name, trace.n_cycles,
                [e for e in trace.events if not (e.kind == "issue" and e.opcode == "IW")],
                trace.occupancy, trace.digests)
    rep = validate(prog, bad, TOY)
    only_fails(rep, "D")
    assert "missing issue" in rep.check("D").failures[0]


def test_d_fails_on_missing_mem_write_and_wrong_issue_cycle():
    items, image, _ = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    bad = Trace(trace.config_name, trace.n_cycles,
                [e for e in trace.events if not (e.kind == "mem_write" and e.unit == "MEM_E2")],
                trace.occupancy, trace.digests)
    only_fails(validate(prog, bad, TOY), "D")
    bad2 = patch(trace, lambda e: e.kind == "mem_read", issue_cycle=1)
    only_fails(validate(prog, bad2, TOY), "D")


def test_d_fails_when_queue_differs_from_trace():
    """The trace is of another program: the program has one more instruction."""
    items, image, info = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    extra = Read(0, 2, SRef("E", 9, ("w.t0#0",)))
    prog.queues["MEM_W1"] = prog.queues["MEM_W1"] + [Nop(3), Issue((extra,))]
    rep = validate(prog, trace, TOY)
    assert "D" in rep.failed() and "B" not in rep.failed()


# ---- E: occupancy replay ---------------------------------------------------------------
def test_e_fails_on_wrong_occupancy():
    items, image, info = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    t = info["t_cast"]
    occ = [list(o) for o in trace.occupancy]
    occ[t] = [(d, s, p, "ghost#0" if tag == "x.t0#0" else tag) for d, s, p, tag in occ[t]]
    rep = validate(prog, Trace(trace.config_name, trace.n_cycles, trace.events, occ, trace.digests), TOY)
    only_fails(rep, "E")
    assert f"cycle {t}" in rep.check("E").failures[0]


def test_e_fails_on_occupancy_length():
    items, image, _ = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    rep = validate(prog, Trace(trace.config_name, trace.n_cycles, trace.events,
                               trace.occupancy[:-1], trace.digests), TOY)
    only_fails(rep, "E")


def test_e_fails_on_missing_fall_off():
    """A trace that keeps a value at the East edge instead of letting it fall off."""
    rd = Read(0, 0, SRef("E", 3, ("x.t0#0",)))
    unit = "MEM_E15"            # pos 34; the value reaches pos 36 two cycles after its drive
    items = [(unit, 0, rd)]
    # a late Write elsewhere keeps the run going past the fall-off
    w = Write(1, 0, SRef("W", 0, ("q#0",)))
    items.append(("MEM_E0", 12, w))
    image = {(unit, 0, 0): "x.t0#0"}
    queues = build_queues(TOY, items)
    trace = record(queues, TOY, image)
    prog = program(TOY, queues)
    # the Write samples nothing: A and B fail; C, D, E pass on the honest trace
    assert validate(prog, trace, TOY).failed() == ["A", "B"]
    occ = [list(o) for o in trace.occupancy]
    occ[8].append(("E", 3, 36, "x.t0#0"))
    occ[8].sort()
    bad = Trace(trace.config_name, trace.n_cycles, trace.events, occ, trace.digests)
    assert validate(prog, bad, TOY).failed() == ["A", "B", "E"]


def test_validator_does_not_crash_on_garbage():
    items, image, _ = basic_items(TOY)
    prog, trace = run(TOY, items, image)
    bad = Trace(trace.config_name, trace.n_cycles,
                trace.events + [Event(0, "drive", "NOPE", 0, "X", "E", 0, "t")], trace.occupancy, trace.digests)
    rep = validate(prog, bad, TOY)
    assert not rep.ok
