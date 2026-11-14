"""Reservation-table logic (plan 5.6): diagonal keys, inclusive live intervals, dead tails, ports, slots."""
from tsp.compiler.resolve import Tables
from tsp.config import ChipConfig

TOY = ChipConfig.toy()


def test_diagonal_keys():
    # eastward: t - x is constant along a flight; westward: t + x
    assert Tables.flight_key("E", 3, 10, 50) == Tables.flight_key("E", 3, 15, 55)
    assert Tables.flight_key("W", 3, 10, 50) == Tables.flight_key("W", 3, 5, 55)
    assert Tables.flight_key("E", 3, 10, 50) != Tables.flight_key("W", 3, 10, 50)
    assert Tables.flight_key("E", 3, 10, 50) != Tables.flight_key("E", 4, 10, 50)


def test_live_intervals_are_inclusive_and_dead_tails_free():
    tb = Tables(TOY)
    tb.take_flight("E", 0, (10, 100, 20))            # driven at x=10, cycle 100, last sampler at x=20
    # same diagonal, driven at the last sampler's position -> overlaps (inclusive)
    assert not tb.flight_free("E", 0, (20, 110, 25))
    # driven just beyond the last sampler: overwrites only the dead tail
    assert tb.flight_free("E", 0, (21, 111, 30))
    # upstream flight whose live part ends before x=10 is fine; one reaching x=10 is not
    assert tb.flight_free("E", 0, (2, 92, 9))
    assert not tb.flight_free("E", 0, (2, 92, 10))
    # same cell, same cycle as the drive -> conflict
    assert not tb.flight_free("E", 0, (10, 100, 10))
    # another diagonal or another stream: free
    assert tb.flight_free("E", 0, (15, 100, 20)) and tb.flight_free("E", 1, (10, 100, 20))
    # westward intervals run from high to low positions
    tb.take_flight("W", 0, (30, 100, 5))
    assert not tb.flight_free("W", 0, (5, 125, 0))
    assert tb.flight_free("W", 0, (4, 126, 0))
    assert not tb.flight_free("W", 0, (31, 99, 30))


def test_find_group_alignment_and_rollback():
    tb = Tables(TOY)
    cnt = {"streams": 0}
    m = tb.mark()
    assert tb.find_group("E", [(18, 5, 18)] * 4, cnt) == 0
    assert tb.find_group("E", [(18, 5, 18)] * 2, cnt) == 4      # pairs on even streams
    assert tb.find_group("E", [(18, 5, 18)], cnt) == 6
    assert cnt["streams"] == 0 + 2 + 6                           # pair: bases 0, 2 taken; single: 0..5 taken
    tb.rollback(m)
    assert tb.find_group("E", [(18, 5, 18)] * 4, cnt) == 0


def test_ports_and_slots():
    tb = Tables(TOY)
    tb.take_port("read", "MEM_W0", 7, 0)
    assert not tb.read_free("MEM_W0", 7, 1)                      # one read per slice per cycle
    assert tb.write_free("MEM_W0", 7, 1) and not tb.write_free("MEM_W0", 7, 0)
    assert tb.read_free("MEM_W0", 8, 0) and tb.read_free("MEM_W1", 7, 0)
    tb.take_slot("MEM_W0", 7, "R")
    assert not tb.slot_free("MEM_W0", 7, "R") and tb.slot_free("MEM_W0", 7, "W")
    tb.take_slot("MEM_W0", 7, "W")
    assert not tb.slot_free("MEM_W0", 7, "W")
    tb.take_slot("VXM.0", 3, "X")
    assert not tb.slot_free("VXM.0", 3, "X") and tb.slot_free("VXM.1", 3, "X")
    m = tb.mark()
    tb.take_port("write", "MEM_E3", 4, 1)
    tb.take_slot("MEM_E3", 4, "W")
    tb.rollback(m)
    assert tb.write_free("MEM_E3", 4, 1) and tb.slot_free("MEM_E3", 4, "W")
