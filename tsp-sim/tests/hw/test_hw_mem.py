"""MEM slices: port rules, write-then-read timing, tags, the Memory API (plan.md 2.6, L-M1..L-M6)."""
import numpy as np
import pytest

from hw_testlib import TOY, Prog, sref
from tsp.config import OpTiming
from tsp.hw import Memory, SimFault
from tsp.isa import Read, Write
from tsp.program import MemInit


T = 6   # cycle in which the new word is written


def _plane(v):
    return np.full(TOY.lanes, v, dtype=np.uint8)


def _overwrite_prog(cfg, read_samples):
    """'new' arrives at MEM_E0 (x = 19) in cycle T and is written over 'old' (bank 0, addr 0) with sample cycle T."""
    p = Prog(cfg)
    p.word("MEM_W0", 0, 0, _plane(2), "new#0")
    p.word("MEM_E0", 0, 0, _plane(1), "old#0")
    p.read_to("MEM_W0", 0, 0, "E", 0, "new#0", arrive_cycle=T, arrive_pos=19)
    p.write_from("MEM_E0", 0, 0, "E", 0, "new#0", sample_cycle=T)
    for k, ts in enumerate(read_samples):
        p.sample_at("MEM_E0", ts, Read(0, 0, sref("W", 1 + k, "?#0")))
    return p


@pytest.mark.parametrize("d_write", [1, 2, 3])
@pytest.mark.parametrize("skew", [0, 1])
def test_write_is_seen_from_sample_cycle_plus_d_func(d_write, skew):
    cfg = TOY.with_timing(WRITE=OpTiming(skew, d_write), READ=OpTiming(skew, 2))
    before = [T - 1] + ([T + d_write - 1] if d_write > 1 else [])   # the boundary cycle t_s + d_func - 1 sees old
    p = _overwrite_prog(cfg, before + [T + d_write])
    trace, mem = p.run()
    reads = trace.by_kind("mem_read")
    reads = [r for r in reads if r.unit == "MEM_E0"]
    assert [r.cycle for r in reads] == before + [T + d_write]
    assert [r.tag for r in reads] == ["old#0"] * len(before) + ["new#0"]
    assert all(r.expect == "?#0" for r in reads)
    assert mem.read("MEM_E0", 0, 0)[1] == "new#0" and (mem.read("MEM_E0", 0, 0)[0] == 2).all()
    (w,) = trace.by_kind("mem_write")
    assert (w.cycle, w.tag, w.bank, w.addr, w.issue_cycle) == (T, "new#0", 0, 0, T - skew)
    (iw,) = [e for e in trace.by_kind("issue") if e.opcode == "WRITE"]
    assert (iw.sample_cycle, iw.visible_cycle) == (T, T + d_write)


def test_same_cycle_read_and_write_same_bank_is_a_port_fault():
    p = _overwrite_prog(TOY, [T])        # Read and Write of bank 0 in one entry, both sampling at T
    with pytest.raises(SimFault) as e:
        p.run()
    assert e.value.code == 3 and e.value.cycle == T and e.value.unit == "MEM_E0"


def test_read_and_write_on_different_banks_share_a_cycle():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(2), "new#0")
    p.word("MEM_E0", 0, 5, _plane(1), "old#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "new#0")))
    p.issue("MEM_E0", 4, Write(1, 0, sref("E", 0, "new#0")))
    p.issue("MEM_E0", 4, Read(0, 5, sref("W", 0, "old#0")))
    trace, mem = p.run()
    assert mem.read("MEM_E0", 1, 0)[1] == "new#0"
    assert [e.opcode for e in trace.by_kind("issue") if e.unit == "MEM_E0"] == ["WRITE", "READ"]


def test_port_fault_across_entries_with_skewed_write():
    cfg = TOY.with_timing(WRITE=OpTiming(1, 1))
    p = Prog(cfg)
    p.word("MEM_W0", 0, 0, _plane(2), "new#0")
    p.word("MEM_E0", 0, 1, _plane(1), "x#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "new#0")))      # at x = 19 in cycle 4
    p.issue("MEM_E0", 3, Write(0, 0, sref("E", 0, "new#0")))     # samples at 4
    p.issue("MEM_E0", 4, Read(0, 1, sref("W", 0, "x#0")))        # samples at 4, same bank
    with pytest.raises(SimFault) as e:
        p.run()
    assert e.value.code == 3 and e.value.cycle == 4


def test_read_drives_stored_tag_and_records_expect():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(3), "stored#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "expected#0")))
    p.issue("MEM_E0", 4, Write(1, 0, sref("E", 0, "expected#0")))
    trace, mem = p.run()          # no fault: tags never affect behaviour
    (r,) = trace.by_kind("mem_read")
    assert (r.cycle, r.tag, r.expect, r.bank, r.addr) == (0, "stored#0", "expected#0", 0, 0)
    (d,) = trace.by_kind("drive")
    assert d.tag == "stored#0"
    (s,) = trace.by_kind("sample")
    assert (s.tag, s.expect) == ("stored#0", "expected#0")
    assert mem.read("MEM_E0", 1, 0)[1] == "stored#0"


def test_memory_api():
    m = Memory(TOY)
    m.load([MemInit("MEM_W3", 1, 7, _plane(5), "v#0")])
    data, tag = m.read("MEM_W3", 1, 7)
    assert tag == "v#0" and (data == 5).all()
    data[:] = 0
    assert (m.read("MEM_W3", 1, 7)[0] == 5).all()           # read returns a copy
    assert m.has("MEM_W3", 1, 7) and not m.has("MEM_W3", 0, 7)
    with pytest.raises(KeyError):
        m.read("MEM_W3", 0, 7)
    for bad in [("VXM", 0, 0), ("MEM_W3", 2, 0), ("MEM_W3", 0, TOY.words_per_bank), ("MEM_W99", 0, 0)]:
        with pytest.raises(ValueError):
            m.write(*bad, _plane(0), "x")
    with pytest.raises(ValueError):
        m.write("MEM_W3", 0, 0, np.zeros(TOY.lanes + 1, dtype=np.uint8), "x")
    with pytest.raises(ValueError):
        m.write("MEM_W3", 0, 0, np.zeros(TOY.lanes, dtype=np.int32), "x")
    assert m.addresses() == [("MEM_W3", 1, 7)]
