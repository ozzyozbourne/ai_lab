"""Stream cells: shift one position per cycle, overwrite, fall-off, reading does not consume (plan.md 2.2, 2.3).

Toy geometry: M = 16, P = 37, VXM at 18, MEM_Wi at 17 - i, MEM_Ei at 19 + i,
SXM_W at 1, MXM_W at 0, SXM_E at 35, MXM_E at 36. Read d_func = 2, Write d_func = 1.
"""
import numpy as np
import pytest

from hw_testlib import TOY, Prog, sref
from tsp.hw import SimFault
from tsp.isa import Read, Shift, Write


def _plane(v):
    return np.full(TOY.lanes, v, dtype=np.uint8)


def test_geometry_assumed_by_these_tests():
    assert TOY.n_positions == 37 and TOY.vxm_pos == 18
    assert TOY.pos("MEM_W0") == 17 and TOY.pos("MEM_E0") == 19 and TOY.pos("MEM_E15") == 34
    assert TOY.pos("SXM_E.shift") == 35 and TOY.pos("MXM_E.0") == 36


def test_eastward_value_moves_one_position_per_cycle():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(7), "a#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 5, "a#0")))         # t_v = 2 at x = 17
    p.issue("MEM_E15", 19, Write(1, 0, sref("E", 5, "a#0")))      # x = 34 = 17 + 17 -> cycle 19
    trace, mem = p.run()
    assert trace.n_cycles == 20
    assert trace.occupancy[0] == [] and trace.occupancy[1] == []
    for t in range(2, 20):
        assert trace.occupancy[t] == [("E", 5, 17 + t - 2, "a#0")]
    data, tag = mem.read("MEM_E15", 1, 0)
    assert tag == "a#0" and (data == 7).all()


def test_westward_value_moves_one_position_per_cycle():
    p = Prog()
    p.word("MEM_E0", 0, 0, _plane(9), "a#0")
    p.issue("MEM_E0", 0, Read(0, 0, sref("W", 3, "a#0")))         # t_v = 2 at x = 19
    p.issue("MEM_W15", 19, Write(1, 0, sref("W", 3, "a#0")))      # x = 2 = 19 - 17 -> cycle 19
    trace, mem = p.run()
    for t in range(2, 20):
        assert trace.occupancy[t] == [("W", 3, 19 - (t - 2), "a#0")]
    assert mem.read("MEM_W15", 1, 0)[1] == "a#0"


def test_value_falls_off_the_edge():
    p = Prog()
    p.word("MEM_E15", 0, 0, _plane(1), "a#0")
    p.word("MEM_W0", 0, 0, _plane(2), "z#0")
    p.issue("MEM_E15", 0, Read(0, 0, sref("E", 0, "a#0")))        # x = 34 at 2, 35 at 3, 36 at 4, gone at 5
    p.issue("MEM_W0", 4, Read(0, 0, sref("W", 0, "z#0")))         # keeps the run going: drives at 6
    trace, _ = p.run()
    assert trace.n_cycles == 7
    assert [c for c in trace.occupancy[4] if c[0] == "E"] == [("E", 0, 36, "a#0")]
    for t in (5, 6):
        assert [c for c in trace.occupancy[t] if c[0] == "E"] == []
    # a sampler at the edge one cycle too late sees nothing
    p.issue("SXM_E.shift", 5, Shift(0, sref("E", 0, "a#0"), sref("W", 1, "s#0")))
    with pytest.raises(SimFault) as e:
        p.run()
    assert e.value.code == 1 and e.value.cycle == 5


def test_westward_value_falls_off_at_position_zero():
    p = Prog()
    p.word("MEM_W15", 0, 0, _plane(1), "a#0")
    p.issue("MEM_W15", 0, Read(0, 0, sref("W", 0, "a#0")))        # x = 2 at 2, 1 at 3, 0 at 4
    p.issue("MEM_W0", 5, Write(1, 0, sref("E", 9, "never#0")))    # would fault; we only look at occupancy
    with pytest.raises(SimFault) as e:
        p.run()
    occ = e.value.trace.occupancy
    assert occ[4] == [("W", 0, 0, "a#0")] and occ[5] == []


def test_producer_overwrites_what_would_arrive():
    p = Prog()
    p.word("MEM_W1", 0, 0, _plane(1), "A#0")
    p.word("MEM_W0", 0, 0, _plane(2), "B#0")
    p.issue("MEM_W1", 0, Read(0, 0, sref("E", 0, "A#0")))         # A: x = 16 at 2, would be at 17 at 3
    p.issue("MEM_W0", 1, Read(0, 0, sref("E", 0, "B#0")))         # B: x = 17 at 3 -> overwrites A
    p.issue("MEM_E0", 5, Write(1, 0, sref("E", 0, "A#0")))        # x = 19 at 5; expects A, sees B
    trace, mem = p.run()
    assert trace.occupancy[2] == [("E", 0, 16, "A#0")]
    assert trace.occupancy[3] == [("E", 0, 17, "B#0")]
    data, tag = mem.read("MEM_E0", 1, 0)
    assert tag == "B#0" and (data == 2).all()
    (s,) = trace.by_kind("sample")
    assert s.tag == "B#0" and s.expect == "A#0"     # a tag mismatch is recorded, not a fault


def test_reading_does_not_consume():
    p = Prog()
    p.word("MEM_W0", 0, 0, np.arange(TOY.lanes, dtype=np.uint8), "a#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 2, "a#0")))         # x = 17 at 2
    for i in (0, 1, 5):                                           # x = 19 + i at 4 + i
        p.issue(f"MEM_E{i}", 4 + i, Write(1, 3, sref("E", 2, "a#0")))
    trace, mem = p.run()
    for i in (0, 1, 5):
        data, tag = mem.read(f"MEM_E{i}", 1, 3)
        assert tag == "a#0" and list(data) == list(range(TOY.lanes))
    assert [e.cycle for e in trace.by_kind("sample")] == [4, 5, 9]


@pytest.mark.parametrize("sample", [3, 5])
def test_consumer_sees_the_value_at_t_v_plus_distance_only(sample):
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(1), "a#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "a#0")))         # at x = 19 exactly in cycle 4
    p.issue("MEM_E0", sample, Write(1, 0, sref("E", 0, "a#0")))
    with pytest.raises(SimFault) as e:
        p.run()
    assert e.value.code == 1 and e.value.cycle == sample and e.value.unit == "MEM_E0"


def test_drive_events_and_digests():
    p = Prog()
    p.word("MEM_W0", 0, 0, _plane(1), "a#0")
    p.issue("MEM_W0", 0, Read(0, 0, sref("E", 0, "a#0")))
    p.issue("MEM_E0", 4, Write(1, 0, sref("E", 0, "a#0")))
    trace, _ = p.run()
    (d,) = trace.by_kind("drive")
    assert (d.cycle, d.unit, d.pos, d.dir, d.stream, d.tag, d.issue_cycle) == (2, "MEM_W0", 17, "E", 0, "a#0", 0)
    assert len(trace.digests) == len(trace.occupancy) == trace.n_cycles == 5
    assert trace.digests[0] == trace.digests[1]           # both empty
    assert len(set(trace.digests[2:])) == 3               # the value is somewhere else each cycle
    t2, _ = p.run(record=False)
    assert t2.occupancy == [] and t2.digests == [] and t2.events == trace.events
