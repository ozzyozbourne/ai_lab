"""One test per fault of plan.md 2.5 (more cases for 5, 6 and 8 are in test_hw_mxm.py), plus
'a tag mismatch is not a fault' and the SimFault attributes."""
import numpy as np
import pytest

from hw_testlib import TOY, Prog, sref
from tsp.hw import SimFault
from tsp.isa import IW, DType, Issue, Nop, Permute, Read, Shift, VOp, Write
from tsp.trace import Trace

L = TOY.lanes


def _plane(v):
    return np.full(L, v, dtype=np.uint8)


def _fault(p) -> SimFault:
    with pytest.raises(SimFault) as e:
        p.run()
    return e.value


def test_fault_1_sample_of_empty_cell():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(1), "a#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "a#0")))
    p.issue("MEM_E0", 4, Write(1, 0, sref("E", 1, "a#0")))      # right cycle, wrong stream
    f = _fault(p)
    assert (f.code, f.cycle, f.unit) == (1, 4, "MEM_E0")
    assert isinstance(f.trace, Trace)
    assert [e.kind for e in f.trace.events] == ["issue", "mem_read", "drive", "issue"]
    assert f.trace.n_cycles == len(f.trace.occupancy) == 5
    assert "empty" in f.message and str(f).startswith("cycle 4, MEM_E0")


def test_fault_2_two_drives_of_one_cell():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(1), "a#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "a#0")))       # at the VXM (18) in cycle 3
    for alu in (0, 5):
        p.issue(f"VXM.{alu}", 3, VOp("CAST", DType.I8, sref("E", 0, "a#0"), None,
                                     sref("W", 4, ("c#0", "c#1", "c#2", "c#3")), to=DType.I32))
    f = _fault(p)
    assert (f.code, f.cycle, f.unit) == (2, 4, "VXM.5") and "VXM.0" in f.message


def test_fault_3_read_and_write_same_bank_same_cycle():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(1), "a#0")
    p.word("MEM_E0", 0, 1, _plane(1), "b#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "a#0")))
    p.issue("MEM_E0", 4, Write(0, 0, sref("E", 0, "a#0")))
    p.issue("MEM_E0", 4, Read(0, 1, sref("W", 0, "b#0")))
    f = _fault(p)
    assert (f.code, f.cycle, f.unit) == (3, 4, "MEM_E0")


def test_fault_4_read_of_unwritten_word():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(1), "a#0")
    p.issue("MEM_W0", 2, Read(0, 1, sref("E", 0, "a#0")))
    f = _fault(p)
    assert (f.code, f.cycle, f.unit) == (4, 2, "MEM_W0")


def test_fault_5_matvec_without_rows():
    from tsp.isa import MatVec
    p = Prog()
    p.word("MEM_W15", 0, 0, _plane(1), "x#0")
    p.issue("MEM_W15", 0, Read(0, 0, sref("W", 0, "x#0")))      # x = 2 at 2, at the MXM (0) at 4
    p.issue("MXM_W.0", 4, MatVec(DType.I8, 1, sref("W", 0, "x#0"), sref("E", 0, ("y#0", "y#1", "y#2", "y#3")),
                                 ("w#0",)))
    f = _fault(p)
    assert (f.code, f.cycle, f.unit) == (5, 4, "MXM_W.0")


def test_fault_6_f16_on_plane_1():
    p = Prog()
    p.issue("MXM_E.1", 3, IW(DType.F16, ((0, sref("E", 0, ("w#0", "w#1"))),)))
    f = _fault(p)
    assert (f.code, f.cycle, f.unit) == (6, 3, "MXM_E.1")


@pytest.mark.parametrize("unit,instrs", [
    ("VXM.0", (VOp("RELU", DType.I32, sref("E", 0, ("a",) * 4), None, sref("E", 4, ("b",) * 4)),) * 2),
    ("MEM_W0", (Read(0, 0, sref("E", 0, "a")), Read(1, 0, sref("E", 1, "a")))),
    ("MEM_W0", (Write(0, 0, sref("E", 0, "a")), Write(1, 0, sref("E", 1, "a")))),
    ("MEM_W0", (Read(0, 0, sref("E", 0, "a")), Write(1, 0, sref("E", 1, "a")), Read(1, 1, sref("E", 2, "a")))),
    ("MEM_W0", (VOp("RELU", DType.I32, sref("E", 0, ("a",) * 4), None, sref("E", 4, ("b",) * 4)),)),
    ("VXM.2", (Read(0, 0, sref("E", 0, "a")),)),
    ("SXM_W.shift", (Permute(tuple(range(L)), sref("W", 0, "a"), sref("E", 0, "b")),)),
    ("SXM_W.permute", (Shift(1, sref("W", 0, "a"), sref("E", 0, "b")),)),
    ("MXM_W.0", (Shift(1, sref("W", 0, "a"), sref("E", 0, "b")),)),
])
def test_fault_7_queue_entry(unit, instrs):
    f = _fault_queue({unit: [Nop(2), Issue(instrs)]})
    assert (f.code, f.cycle, f.unit) == (7, 2, unit)
    assert f.trace.events == []        # the faulting entry is not issued


def _fault_queue(queues) -> SimFault:
    from tsp.hw import Chip
    with pytest.raises(SimFault) as e:
        Chip(TOY).run(queues, [])
    return e.value


I32_4 = ("a#0", "a#1", "a#2", "a#3")


@pytest.mark.parametrize("unit,instr,what", [
    ("VXM.0", VOp("ADD", DType.I32, sref("E", 2, I32_4), sref("E", 8, I32_4), sref("E", 12, I32_4)), "multiple"),
    ("VXM.0", VOp("CAST", DType.F16, sref("W", 3, ("h#0", "h#1")), None, sref("E", 0, I32_4), to=DType.F32),
     "multiple"),
    ("VXM.0", VOp("ADD", DType.I32, sref("E", 28, I32_4), sref("E", 32, I32_4), sref("E", 0, I32_4)), "range"),
    ("VXM.0", VOp("RELU", DType.I32, sref("E", 0, I32_4), None, sref("E", 4, I32_4[:2])), "streams"),
    ("VXM.0", VOp("ADD", DType.I32, sref("E", 0, I32_4), None, sref("E", 4, I32_4)), "needs operand b"),
    ("VXM.0", VOp("ADD", DType.I8, sref("E", 0, "a"), sref("E", 1, "a"), sref("E", 4, "a")), "not defined"),
    ("VXM.0", VOp("REQUANT", DType.I32, sref("E", 0, I32_4), None, sref("E", 4, "a"), imm=32), "not defined"),
    ("VXM.0", VOp("CAST", DType.I32, sref("E", 0, I32_4), None, sref("E", 4, "a"), to=DType.I8), "not defined"),
    ("MEM_W0", Read(2, 0, sref("E", 0, "a")), "bank"),
    ("MEM_W0", Read(0, TOY.words_per_bank, sref("E", 0, "a")), "address"),
    ("MEM_W0", Read(0, 0, sref("E", 0, ("a", "b"))), "streams"),
    ("MEM_W0", Write(0, -1, sref("E", 0, "a")), "address"),
    ("MEM_W0", Read(0, 0, sref("W", 32, "a")), "range"),
    ("SXM_W.shift", Shift(1, sref("W", 0, ("a",) * 3), sref("E", 0, ("b",) * 3)), "width"),
    ("SXM_W.shift", Shift(1, sref("W", 1, ("a",) * 2), sref("E", 0, ("b",) * 2)), "multiple"),
    ("SXM_W.shift", Shift(1, sref("W", 0, ("a",) * 2), sref("E", 0, "b")), "streams"),
    ("SXM_W.permute", Permute((0,) * L, sref("W", 0, "a"), sref("E", 0, "b")), "bijection"),
    ("MXM_W.0", IW(DType.I8, ((0, sref("E", 0, "w")),)), "flow W"),
    ("MXM_W.0", IW(DType.I8, ((L, sref("W", 0, "w")),)), "row index"),
    ("MXM_W.0", IW(DType.I8, ((1, sref("W", 0, "w")), (1, sref("W", 1, "w")))), "twice"),
    ("MXM_W.0", IW(DType.I32, ((0, sref("W", 0, I32_4)),)), "I8 or F16"),
])
def test_fault_8_operand_rules(unit, instr, what):
    f = _fault_queue({unit: [Issue((instr,))]})
    assert (f.code, f.cycle, f.unit) == (8, 0, unit), f.message
    assert what in f.message


def test_fault_8_distribute_map():
    from tsp.isa import Distribute
    lps = TOY.lanes_per_superlane
    for m in [(0,) * (lps - 1), (lps,) + (0,) * (lps - 1), (-2,) + (0,) * (lps - 1)]:
        f = _fault_queue({"SXM_E.distribute": [Issue((Distribute(m, sref("E", 0, "a"), sref("W", 0, "b")),))]})
        assert f.code == 8


@pytest.mark.parametrize("n", [0, -1, TOY.nop_max + 1])
def test_fault_9_bad_nop(n):
    f = _fault_queue({"VXM.4": [Nop(3), Nop(n), Nop(1)]})
    assert (f.code, f.cycle, f.unit) == (9, 3, "VXM.4")


def test_nop_max_is_allowed():
    from tsp.hw import Chip
    trace, _ = Chip(TOY).run({"VXM.4": [Nop(TOY.nop_max)]}, [])
    assert trace.n_cycles == 0 and trace.events == []


def test_tag_mismatch_is_not_a_fault():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(1), "a#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "zzz#0")))
    p.issue("MEM_E0", 4, Write(1, 0, sref("E", 0, "yyy#0")))
    trace, mem = p.run()
    (r,) = trace.by_kind("mem_read")
    (s,) = trace.by_kind("sample")
    assert (r.tag, r.expect, s.tag, s.expect) == ("a#0", "zzz#0", "a#0", "yyy#0")
    assert mem.read("MEM_E0", 1, 0)[1] == "a#0"


def test_unknown_queue_name_is_rejected():
    from tsp.hw import Chip
    with pytest.raises(ValueError):
        Chip(TOY).run({"VXM.99": []}, [])
